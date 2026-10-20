//! `greed-mail serve`: the mail session's greed-mail. It syncs every
//! account in the background and answers JSON-RPC 2.0 on its input and
//! output, one message a line (`greed.rpc.start` with `framing = "lines"`).
//!
//! Requests: `status` (each account, how much is in, what went wrong),
//! `index` (where `index.db` is, for `greed.index.open`), `sync` (sync now),
//! `summaries` (`keys` the index found, as a list shows them), `thread`
//! (a thread by its key or one of its messages', with their text; bodies
//! not in yet come ahead of everything else, then `changed` says so),
//! `act` (`action` on the messages `keys` name: read, unread, flag,
//! unflag, archive, trash, or move `to` a mailbox; made here at once and
//! sent to the server in the next round, which starts right away),
//! `draft` (a reply to the message `key`, to everyone with `all`) and
//! `send` (a draft, put in the outbox and sent in the next round).
//! Notifications: `changed` (the index changed: search again), `progress`
//! (an account's mailbox synced some), `trouble` (an account that can't
//! sync, and why), `refused` (a change or mail its server refused, and
//! why) and `sent` (mail its server took).
//!
//! The sync goes in rounds of at most `HEADERS` headers and `BODIES` bodies
//! a mailbox, so what's asked for never waits long. After a round with
//! nothing left to do it waits in IDLE on each account's inbox, so new
//! mail comes within seconds, until asked or for `QUIET`. An account that
//! fails is tried again after a wait twice as long each time.

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
use crate::imap::{Changing, Connection, Imap};
use crate::indexing;
use crate::pending;
use crate::reader::Reader;
use crate::send::{self, Draft, Failure};
use crate::store::{Action, Store, Wanting};
use crate::sync::{self, Options};

/// The most headers a round fetches a mailbox.
const HEADERS: usize = 2000;

/// The most bodies a round fetches a mailbox.
const BODIES: usize = 200;

/// How long it waits, with nothing left to do, before syncing again: an
/// account in IDLE wakes it sooner, as its mail changes.
const QUIET: Duration = Duration::from_secs(20 * 60);

/// How often an account whose server can't IDLE is synced.
const POLL: Duration = Duration::from_secs(120);

/// The longest a round may take before it counts as stuck, its server
/// gone quiet in the middle of something.
const STUCK: Duration = Duration::from_secs(10 * 60);

/// How long to wait before trying again after something went wrong:
/// twice as long each time it goes wrong again, up to five minutes.
#[derive(Debug, Default)]
struct Backoff {
    failures: u32,
}

impl Backoff {
    const FIRST: Duration = Duration::from_secs(2);
    const MOST: Duration = Duration::from_secs(300);

    fn next(&mut self) -> Duration {
        let wait = Self::FIRST.saturating_mul(1 << self.failures.min(16));
        self.failures += 1;
        wait.min(Self::MOST)
    }

    fn reset(&mut self) {
        self.failures = 0;
    }
}

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
/// closes. With `read`, it only answers, from what the store has: another
/// greed-mail syncs it (the mail session's), so this one takes no lock and
/// fetches nothing, and any number of them can run beside it.
pub async fn serve(config: Config, dir: PathBuf, read: bool) -> Result<(), String> {
    let open_index = || Index::open(&dir.join("index.db")).map_err(|e| e.0);
    let (stores, writer) = if read {
        (None, None)
    } else {
        let store = Store::open(&dir).map_err(|e| e.0)?;
        // Changes asked for are made with a store and index of their own,
        // as the sync holds its own while it waits on a server.
        let beside = store.beside(&dir).map_err(|e| e.0)?;
        let writer = RefCell::new((beside, open_index()?));
        (Some((store, open_index()?)), Some(writer))
    };
    let reader = Reader::open(&dir).map_err(|_| {
        format!(
            "there's no mail in {} yet: `greed mail` starts the mail session, which syncs it",
            dir.display()
        )
    })?;
    let (out, mut lines) = mpsc::unbounded_channel::<String>();
    let shared = Shared {
        out,
        wanted: RefCell::new(Vec::new()),
        standing: RefCell::new(BTreeMap::new()),
        wake: Notify::new(),
    };
    let output = async {
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
    let with = Answering {
        config: &config,
        reader: &reader,
        writer: writer.as_ref(),
        dir: &dir,
        shared: &shared,
    };
    let answering = answer(&with);
    let syncing = async {
        match stores {
            Some((store, index)) => keep_syncing(&config, store, index, &shared).await,
            None => std::future::pending().await,
        }
    };
    tokio::select! {
        () = answering => {}
        () = syncing => {}
        () = output => {}
    }
    Ok(())
}

/// What changes are made with: a store and an index, the mail session's
/// only.
type Writer = RefCell<(Store, Index)>;

/// What requests are answered from.
struct Answering<'a> {
    config: &'a Config,
    reader: &'a Reader,
    writer: Option<&'a Writer>,
    dir: &'a Path,
    shared: &'a Shared,
}

/// Answers each request on the input until it closes.
async fn answer(with: &Answering<'_>) {
    let mut input = BufReader::new(tokio::io::stdin()).lines();
    while let Ok(Some(line)) = input.next_line().await {
        let Ok(request) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let Some(id) = request.get("id").cloned() else {
            continue;
        };
        let method = request["method"].as_str().unwrap_or("");
        let reply = match handle(method, &request["params"], with) {
            Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
            Err(message) => json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": { "code": -32000, "message": message },
            }),
        };
        let _ = with.shared.out.send(reply.to_string());
    }
}

/// The result of request `method`, or why there's none.
fn handle(method: &str, params: &Value, with: &Answering<'_>) -> Result<Value, String> {
    let Answering { reader, shared, .. } = with;
    let writer = || {
        with.writer
            .ok_or("mail is changed in the mail session; here it's only read")
    };
    match method {
        "status" => {
            let standing: Vec<Standing> = shared.standing.borrow().values().cloned().collect();
            Ok(json!({ "accounts": standing }))
        }
        "index" => Ok(json!({ "path": with.dir.join("index.db") })),
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
        "act" => {
            let writer = writer()?;
            let keys: Vec<String> = serde_json::from_value(params["keys"].clone())
                .map_err(|_| "act takes keys, a list of messages' or threads' keys".to_string())?;
            let action = action(params)?;
            let (store, index) = &mut *writer.borrow_mut();
            let mut changed = 0;
            for key in &keys {
                for id in store.messages_of(key).map_err(|e| e.0)? {
                    changed += usize::from(store.act(id, &action).map_err(|e| e.0)?);
                }
            }
            if changed > 0 {
                indexing::catch_up(store, index).map_err(|e| e.0)?;
                shared.notify("changed", &json!({}));
                shared.wake.notify_one();
            }
            Ok(json!({ "changed": changed }))
        }
        "draft" => {
            let key = params["key"]
                .as_str()
                .ok_or("draft takes key, the message to reply to")?;
            let Some((_, original)) = reader.original(key).map_err(|e| e.0)? else {
                return Err("that mail is gone".into());
            };
            let all = params["all"].as_bool().unwrap_or(false);
            serde_json::to_value(send::reply(&original, key, all)).map_err(|e| e.to_string())
        }
        "send" => {
            let writer = writer()?;
            let draft: Draft = serde_json::from_value(params.clone())
                .map_err(|e| format!("send takes a draft: {e}"))?;
            let original = match &draft.replying {
                Some(key) => reader.original(key).map_err(|e| e.0)?,
                None => None,
            };
            let name = original
                .as_ref()
                .map(|(name, _)| name.as_str())
                .or(params["account"].as_str());
            let account = match name {
                Some(name) => with.config.account(name),
                None => with.config.accounts.first(),
            }
            .ok_or_else(|| format!("no account {} in mail.toml", name.unwrap_or("")))?;
            let outgoing =
                send::compose(&account.address, &draft, original.as_ref().map(|(_, o)| o))?;
            let (store, _) = &mut *writer.borrow_mut();
            let id = store
                .account(&account.name, &account.address)
                .map_err(|e| e.0)?;
            let replying = match &draft.replying {
                Some(key) => store.messages_of(key).map_err(|e| e.0)?.first().copied(),
                None => None,
            };
            let posted = store.post(id, &outgoing, replying).map_err(|e| e.0)?;
            shared.wake.notify_one();
            Ok(json!({ "posted": posted }))
        }
        _ => Err(format!("no method {method}")),
    }
}

/// The action an `act` request asks for.
fn action(params: &Value) -> Result<Action, String> {
    let flag = |flag: &str, on: bool| Action::Flag {
        flag: flag.into(),
        on,
    };
    Ok(match params["action"].as_str().unwrap_or("") {
        "read" => flag("\\Seen", true),
        "unread" => flag("\\Seen", false),
        "flag" => flag("\\Flagged", true),
        "unflag" => flag("\\Flagged", false),
        "archive" => Action::Archive,
        "trash" => Action::Trash,
        "move" => Action::Move {
            to: params["to"]
                .as_str()
                .ok_or("move takes to, the mailbox to move it to")?
                .into(),
        },
        other => {
            return Err(format!(
                "no action {other:?}: read, unread, flag, unflag, archive, trash or move"
            ));
        }
    })
}

/// Syncs in rounds for as long as it runs. With nothing left to do it
/// waits: for an account's server to say something changed (IDLE), to
/// be asked, or for `QUIET`. After something went wrong it waits longer
/// each time before trying again.
async fn keep_syncing(config: &Config, mut store: Store, mut index: Index, shared: &Shared) {
    let mut backoff = Backoff::default();
    loop {
        let mut more = false;
        let mut failed = false;
        for account in &config.accounts {
            let done = tokio::time::timeout(STUCK, round(account, &mut store, &mut index, shared))
                .await
                .unwrap_or_else(|_| Err("its server stopped answering".into()));
            match done {
                Ok(left) => more |= left,
                Err(trouble) => {
                    failed = true;
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
        if failed {
            tokio::select! {
                () = shared.wake.notified() => {}
                () = tokio::time::sleep(backoff.next()) => {}
            }
            continue;
        }
        backoff.reset();
        if !more {
            let changed = async {
                if config.accounts.is_empty() {
                    std::future::pending::<()>().await;
                }
                futures::future::select_all(config.accounts.iter().map(|a| Box::pin(watch(a))))
                    .await;
            };
            tokio::select! {
                () = shared.wake.notified() => {}
                () = changed => {}
                () = tokio::time::sleep(QUIET) => {}
            }
        }
    }
}

/// Waits until `account`'s inbox changes, as its server says in IDLE, or
/// for `POLL` when its server can't IDLE. A connection that breaks ends
/// the wait a little later, so the next round finds out why.
async fn watch(account: &Account) {
    let Ok(connection) = Connection::to(account).await else {
        tokio::time::sleep(POLL).await;
        return;
    };
    if !connection.can_idle() {
        let _ = connection.close().await;
        tokio::time::sleep(POLL).await;
        return;
    }
    if connection.idle("INBOX", QUIET).await.is_err() {
        tokio::time::sleep(Backoff::FIRST).await;
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
        send_changes(&mut connection, store, index, account, id, shared).await?;
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

/// Sends what was written and changed here in `account` (store id `id`)
/// to its servers, saying what they refused.
async fn send_changes(
    connection: &mut Connection,
    store: &mut Store,
    index: &mut Index,
    account: &Account,
    id: i64,
    shared: &Shared,
) -> Result<(), String> {
    send_mail(connection, store, account, id, shared).await?;
    let sent = pending::send(connection, store, id)
        .await
        .map_err(|e| e.0)?;
    if sent.refused.is_empty() {
        return Ok(());
    }
    for why in &sent.refused {
        shared.notify(
            "refused",
            &json!({ "account": account.name, "message": format!("a change was refused: {why}") }),
        );
    }
    indexing::catch_up(store, index).map_err(|e| e.0)?;
    shared.notify("changed", &json!({}));
    Ok(())
}

/// Sends the mail in `account`'s outbox (store id `id`) over SMTP, a copy
/// of each in Sent where the server doesn't file one itself, and marks
/// what it answers answered. Mail the server refuses stays in the outbox,
/// saying why; when it can't be reached, it waits for the next round.
async fn send_mail(
    connection: &mut Connection,
    store: &mut Store,
    account: &Account,
    id: i64,
    shared: &Shared,
) -> Result<(), String> {
    let refused = |message: String| {
        shared.notify(
            "refused",
            &json!({ "account": account.name, "message": message }),
        );
    };
    for posted in store.outbox(id).map_err(|e| e.0)? {
        match send::deliver(account, &posted.outgoing).await {
            Ok(()) => {}
            Err(Failure::Refused(why)) => {
                store.sent_out(posted.id, Some(&why)).map_err(|e| e.0)?;
                refused(format!("mail wasn't sent: {why}"));
                continue;
            }
            Err(Failure::Later(why)) => {
                shared.notify(
                    "trouble",
                    &json!({ "account": account.name, "message": format!("mail waits to go: {why}") }),
                );
                return Ok(());
            }
        }
        store.sent_out(posted.id, None).map_err(|e| e.0)?;
        shared.notify(
            "sent",
            &json!({ "account": account.name, "posted": posted.id }),
        );
        // Gmail and Bridge file what they send themselves.
        let files_itself = account.provider.is_some();
        if !files_itself && let Some(sent) = store.role(id, "sent").map_err(|e| e.0)? {
            let kept = connection
                .append(&sent, &posted.outgoing.message)
                .await
                .map_err(|e| e.0)?;
            if let Err(why) = kept {
                refused(format!("mail was sent, but no copy is in {sent}: {why}"));
            }
        }
        if let Some(original) = posted.replying {
            let answered = Action::Flag {
                flag: "\\Answered".into(),
                on: true,
            };
            store.act(original, &answered).map_err(|e| e.0)?;
        }
    }
    Ok(())
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_failure_waits_twice_as_long_up_to_five_minutes() {
        let mut backoff = Backoff::default();
        let waits: Vec<u64> = (0..10).map(|_| backoff.next().as_secs()).collect();
        assert_eq!(waits, [2, 4, 8, 16, 32, 64, 128, 256, 300, 300]);
        backoff.reset();
        assert_eq!(backoff.next().as_secs(), 2, "from the start once it works");
    }
}
