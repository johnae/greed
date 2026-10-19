//! `greed-mail serve`: the mail session's greed-mail. It syncs every
//! account in the background and answers JSON-RPC 2.0 on its input and
//! output, one message a line (`greed.rpc.start` with `framing = "lines"`).
//!
//! Requests: `status` (each account, how much is in, what went wrong),
//! `index` (where `index.db` is, for `greed.index.open`), `sync` (sync now),
//! `summaries` (`keys` the index found, as a list shows them) and `thread`
//! (a thread by its key or one of its messages', with their text; bodies
//! not in yet come ahead of everything else, then `changed` says so).
//! Notifications: `changed` (the index changed: search again), `progress`
//! (an account's mailbox synced some) and `trouble` (an account that
//! can't sync, and why).
//!
//! The sync goes in rounds of at most `HEADERS` headers and `BODIES` bodies
//! a mailbox, so what's asked for never waits long; after a round with
//! nothing left to do it waits until asked, or `QUIET`.

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::time::Duration;

use greed_index::index::Index;
use serde::Serialize;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{Notify, mpsc};

use crate::config::{Account, Config};
use crate::imap::{Connection, Imap};
use crate::indexing;
use crate::reader::Reader;
use crate::store::{Store, Wanting};
use crate::sync::{self, Options};

/// The most headers a round fetches a mailbox.
const HEADERS: usize = 2000;

/// The most bodies a round fetches a mailbox.
const BODIES: usize = 200;

/// How long it waits, with nothing left to do, before syncing again.
const QUIET: Duration = Duration::from_secs(300);

/// What `status` says of an account.
#[derive(Debug, Clone, Default, Serialize)]
struct Standing {
    name: String,
    messages: i64,
    /// Whether everything on the server is in, headers and bodies.
    done: bool,
    trouble: Option<String>,
}

/// What the parts share: lines to write, bodies asked for, the accounts'
/// standing, and a nudge to sync now.
struct Shared {
    out: mpsc::UnboundedSender<String>,
    wanted: RefCell<Vec<String>>,
    standing: RefCell<BTreeMap<String, Standing>>,
    wake: Notify,
}

impl Shared {
    fn notify(&self, method: &str, params: &Value) {
        let message = json!({ "jsonrpc": "2.0", "method": method, "params": params });
        let _ = self.out.send(message.to_string());
    }
}

/// Serves `config`'s accounts from the store in `dir` until its input
/// closes.
pub async fn serve(config: Config, dir: PathBuf) -> Result<(), String> {
    let store = Store::open(&dir).map_err(|e| e.0)?;
    let index = Index::open(&dir.join("index.db")).map_err(|e| e.0)?;
    let reader = Reader::open(&dir).map_err(|e| e.0)?;
    let (out, mut lines) = mpsc::unbounded_channel::<String>();
    let shared = Shared {
        out,
        wanted: RefCell::new(Vec::new()),
        standing: RefCell::new(BTreeMap::new()),
        wake: Notify::new(),
    };
    let writing = async {
        let mut stdout = tokio::io::stdout();
        while let Some(line) = lines.recv().await {
            let written = async {
                stdout.write_all(line.as_bytes()).await?;
                stdout.write_all(b"\n").await?;
                stdout.flush().await
            };
            if written.await.is_err() {
                break;
            }
        }
    };
    let answering = answer(&reader, &dir, &shared);
    let syncing = keep_syncing(&config, store, index, &shared);
    tokio::select! {
        () = answering => {}
        () = syncing => {}
        () = writing => {}
    }
    Ok(())
}

/// Answers each request on the input until it closes.
async fn answer(reader: &Reader, dir: &Path, shared: &Shared) {
    let mut input = BufReader::new(tokio::io::stdin()).lines();
    while let Ok(Some(line)) = input.next_line().await {
        let Ok(request) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let Some(id) = request.get("id").cloned() else {
            continue;
        };
        let method = request["method"].as_str().unwrap_or("");
        let reply = match handle(method, &request["params"], reader, dir, shared) {
            Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
            Err(message) => json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": { "code": -32000, "message": message },
            }),
        };
        let _ = shared.out.send(reply.to_string());
    }
}

/// The result of request `method`, or why there's none.
fn handle(
    method: &str,
    params: &Value,
    reader: &Reader,
    dir: &Path,
    shared: &Shared,
) -> Result<Value, String> {
    match method {
        "status" => {
            let standing: Vec<Standing> = shared.standing.borrow().values().cloned().collect();
            Ok(json!({ "accounts": standing }))
        }
        "index" => Ok(json!({ "path": dir.join("index.db") })),
        "sync" => {
            shared.wake.notify_one();
            Ok(json!({}))
        }
        "summaries" => {
            let keys: Vec<String> = serde_json::from_value(params["keys"].clone())
                .map_err(|_| "summaries takes keys, a list of the index's keys".to_string())?;
            let found = reader.summaries(&keys).map_err(|e| e.0)?;
            serde_json::to_value(found).map_err(|e| e.to_string())
        }
        "thread" => {
            let key = params["key"]
                .as_str()
                .ok_or("thread takes key, a message's or a thread's")?;
            let Some(thread) = reader.thread(key).map_err(|e| e.0)? else {
                return Ok(Value::Null);
            };
            let bodiless = thread.bodiless();
            if !bodiless.is_empty() {
                shared.wanted.borrow_mut().extend(bodiless);
                shared.wake.notify_one();
            }
            serde_json::to_value(thread).map_err(|e| e.to_string())
        }
        _ => Err(format!("no method {method}")),
    }
}

/// Syncs in rounds for as long as it runs, waiting when there's nothing
/// left to do.
async fn keep_syncing(config: &Config, mut store: Store, mut index: Index, shared: &Shared) {
    loop {
        let mut more = false;
        for account in &config.accounts {
            match round(account, &mut store, &mut index, shared).await {
                Ok(left) => more |= left,
                Err(trouble) => {
                    shared.notify(
                        "trouble",
                        &json!({ "account": account.name, "message": trouble }),
                    );
                    shared
                        .standing
                        .borrow_mut()
                        .entry(account.name.clone())
                        .or_insert_with(|| Standing {
                            name: account.name.clone(),
                            ..Standing::default()
                        })
                        .trouble = Some(trouble);
                }
            }
        }
        if !more {
            tokio::select! {
                () = shared.wake.notified() => {}
                () = tokio::time::sleep(QUIET) => {}
            }
        }
    }
}

/// One round for `account`: what was asked for, then each mailbox's next
/// headers and bodies, the index caught up after each. Gives whether
/// there's more to do.
async fn round(
    account: &Account,
    store: &mut Store,
    index: &mut Index,
    shared: &Shared,
) -> Result<bool, String> {
    let mut connection = Connection::to(account).await?;
    let id = store
        .account(&account.name, &account.address)
        .map_err(|e| e.0)?;
    let options = Options {
        limit: Some(HEADERS),
        ..Options::default()
    };
    let bodies = Options {
        limit: Some(BODIES),
        ..Options::default()
    };
    let mailboxes = connection.mailboxes().await.map_err(|e| e.0)?;
    let mut more = false;
    for mailbox in sync::chosen(account.provider, &mailboxes) {
        asked_for(&mut connection, store, index, id, shared).await?;
        let synced = sync::mailbox(
            &mut connection,
            store,
            id,
            &mailbox.name,
            mailbox.role,
            options,
        )
        .await
        .map_err(|e| format!("{}: {e}", mailbox.name))?;
        let fetched = sync::bodies(&mut connection, store, id, &mailbox.name, bodies)
            .await
            .map_err(|e| format!("{}: {e}", mailbox.name))?;
        more |= !synced.done || fetched >= BODIES;
        if indexing::catch_up(store, index).map_err(|e| e.0)? > 0 {
            shared.notify("changed", &json!({}));
        }
        if synced.fetched + synced.changed + synced.gone + fetched > 0 {
            shared.notify(
                "progress",
                &json!({
                    "account": account.name,
                    "mailbox": mailbox.name,
                    "fetched": synced.fetched,
                    "bodies": fetched,
                }),
            );
        }
    }
    asked_for(&mut connection, store, index, id, shared).await?;
    let (messages, _) = store.counts(id).map_err(|e| e.0)?;
    shared.standing.borrow_mut().insert(
        account.name.clone(),
        Standing {
            name: account.name.clone(),
            messages,
            done: !more,
            trouble: None,
        },
    );
    let _ = connection.close().await;
    Ok(more)
}

/// Fetches the bodies asked for of account `id`'s messages, from where
/// each is, then says they're in.
async fn asked_for(
    connection: &mut Connection,
    store: &mut Store,
    index: &mut Index,
    id: i64,
    shared: &Shared,
) -> Result<(), String> {
    let prefix = format!("m:{id}:");
    let (keys, others): (Vec<String>, Vec<String>) = shared
        .wanted
        .take()
        .into_iter()
        .partition(|key| key.starts_with(&prefix));
    *shared.wanted.borrow_mut() = others;
    if keys.is_empty() {
        return Ok(());
    }
    let mut by_mailbox: HashMap<String, Vec<Wanting>> = HashMap::new();
    for key in &keys {
        let identity = &key[prefix.len()..];
        if let Some((mailbox, wanting)) = store.place_of(id, identity).map_err(|e| e.0)? {
            by_mailbox.entry(mailbox).or_default().push(wanting);
        }
    }
    for (mailbox, wanting) in by_mailbox {
        connection.open(&mailbox).await.map_err(|e| e.0)?;
        sync::fetch_bodies(connection, store, &wanting)
            .await
            .map_err(|e| format!("{mailbox}: {e}"))?;
    }
    indexing::catch_up(store, index).map_err(|e| e.0)?;
    shared.notify("changed", &json!({ "keys": keys }));
    Ok(())
}
