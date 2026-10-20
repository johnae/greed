//! `greed-mail serve`: the mail session's greed-mail. It syncs every
//! account in the background and answers JSON-RPC 2.0 on its input and
//! output, one message a line (`greed.rpc.start` with `framing = "lines"`).
//!
//! Requests: `status` (each account, how much is in, what went wrong),
//! `index` (where `index.db` is, for `greed.index.open`), `sync` (sync now),
//! `summaries` (`keys` the index found, as a list shows them), `thread`
//! (a thread by its key or one of its messages', with their text; bodies
//! not in yet come ahead of everything else, then `changed` says so),
//! `find` (the key of the message with a `message_id`), `contacts` (people
//! whose name or address starts as `typed`), `accounts` (each account's
//! name, address and aliases),
//! `act` (`action` on the messages `keys` name: read, unread, flag,
//! unflag, archive, trash, move `to` a mailbox, or tag and untag with
//! `tag`; made here at once and sent to the server in the next round,
//! which starts right away; trashing what's in the trash only with
//! `for_good`), `undo` (the last change, or the mail just sent while it
//! waits `SENDING` in the outbox),
//! `draft` (a reply to the message `key`, to everyone with `all`), `send`
//! (a draft, put in the outbox and sent in the next round), `respond`
//! (`answer` to the invite in the message `key`: accepted, tentative or
//! declined, sent to its organizer the same way), `render` (the
//! message `key`'s HTML laid out `width` wide), `browse` (it as a page that
//! loads nothing) and `attachment` (thing number `index` attached to it,
//! saved `to` a path or kept beside the store).
//! Notifications: `changed` (the index changed: search again), `progress`
//! (an account's mailbox synced some), `trouble` (an account that can't
//! sync, and why), `refused` (a change or mail its server refused, and
//! why), `sent` (mail its server took), `arrived` (the keys of new mail,
//! once it's in the index: what came since its mailbox was all in, never
//! what a first sync brings), `attachment` (where one asked
//! for went, or why it couldn't), `indexing` (how far a long catch-up of
//! the index got: `done` of `of`) and `synced` (an account's round over:
//! how many `messages` it has, and whether it's all `done`).
//!
//! A greed-mail only reading the mail (`--read`, in other sessions) has
//! the mail session's make its changes, sends and fetches, over `SOCKET`
//! in the store's folder, and passes on the notifications it makes.
//!
//! The sync goes in rounds of at most `HEADERS` headers and `BODIES` bodies
//! a mailbox, so what's asked for never waits long. After a round with
//! nothing left to do it waits in IDLE on each account's inbox, so new
//! mail comes within seconds, until asked or for `QUIET`. An account that
//! fails is tried again after a wait twice as long each time.

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use greed_index::index::Index;
use serde::Serialize;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::unix::OwnedWriteHalf;
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{Notify, mpsc};

use crate::body;
use crate::config::{Account, Config, Provider};
use crate::files;
use crate::html;
use crate::imap::{Changing, Connection, Imap};
use crate::indexing;
use crate::invite;
use crate::pending;
use crate::reader::Reader;
use crate::send::{self, Draft, Failure};
use crate::store::{Action, Store, Undo, Wanting};
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
    /// Attachments asked for: of which message, which one, and where to
    /// save it (beside the store without a place).
    attachments: RefCell<Vec<(String, usize, Option<PathBuf>)>>,
    /// Where attachments opened from the store are kept.
    kept: PathBuf,
    standing: RefCell<BTreeMap<String, Standing>>,
    wake: Notify,
    /// Where notifications go besides the output: to the greed-mail of
    /// the sessions only reading the mail, in the mail session.
    copies: Option<mpsc::UnboundedSender<String>>,
    /// What undoes the last change asked for, in the mail session.
    last: RefCell<Option<Undoing>>,
}

impl Shared {
    fn notify(&self, method: &str, params: &Value) {
        let message = json!({ "jsonrpc": "2.0", "method": method, "params": params });
        if let Some(copies) = &self.copies {
            let _ = copies.send(message.to_string());
        }
        let _ = self.out.send(message.to_string());
    }
}

/// Where the mail session's greed-mail takes requests from the others,
/// in the store's folder.
const SOCKET: &str = "serve.sock";

/// What a greed-mail only reading the mail has the mail session's do:
/// changes, mail to send, answers to invites, syncing, and attachments and
/// bodies to fetch.
const FORWARDED: &[&str] = &[
    "act",
    "undo",
    "send",
    "respond",
    "sync",
    "attachment",
    "want",
];

/// Serves `config`'s accounts from the store in `dir` until its input
/// closes. With `read`, it only answers, from what the store has: another
/// greed-mail syncs it (the mail session's), so this one takes no lock and
/// fetches nothing, and any number of them can run beside it.
pub async fn serve(config: Config, dir: PathBuf, read: bool) -> Result<(), String> {
    let (stores, writer) = if read {
        (None, None)
    } else {
        let mut store = Store::open(&dir).map_err(|e| e.0)?;
        let index = indexing::open(&mut store, &dir.join("index.db")).map_err(|e| e.0)?;
        // Changes asked for are made with a store and index of their own,
        // as the sync holds its own while it waits on a server.
        let beside = store.beside(&dir).map_err(|e| e.0)?;
        let again = Index::open(&dir.join("index.db")).map_err(|e| e.0)?;
        (Some((store, index)), Some(RefCell::new((beside, again))))
    };
    let reader = Reader::open(&dir).map_err(|_| {
        format!(
            "there's no mail in {} yet: `greed mail` starts the mail session, which syncs it",
            dir.display()
        )
    })?;
    let (out, mut lines) = mpsc::unbounded_channel::<String>();
    let (copies, notes) = mpsc::unbounded_channel::<String>();
    // The others reach the mail session's greed-mail here; it holds the
    // store's lock, so a socket left from before is no one's.
    let listener = if read {
        None
    } else {
        let socket = dir.join(SOCKET);
        let _ = std::fs::remove_file(&socket);
        let listener = UnixListener::bind(&socket)
            .map_err(|e| format!("couldn't listen at {}: {e}", socket.display()))?;
        std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600))
            .map_err(|e| format!("couldn't keep {} to you: {e}", socket.display()))?;
        Some(listener)
    };
    let shared = Shared {
        out,
        wanted: RefCell::new(Vec::new()),
        attachments: RefCell::new(Vec::new()),
        kept: dir.join("attachments"),
        standing: RefCell::new(BTreeMap::new()),
        wake: Notify::new(),
        copies: listener.as_ref().map(|_| copies),
        last: RefCell::new(None),
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
            None => relay(&dir, &shared).await,
        }
    };
    let others = async {
        match listener {
            Some(listener) => listen(&with, listener, notes).await,
            None => std::future::pending().await,
        }
    };
    tokio::select! {
        () = answering => {}
        () = syncing => {}
        () = others => {}
        () = output => {}
    }
    Ok(())
}

/// The reply to the JSON-RPC `request`, made here; None for what isn't a
/// request.
fn reply_to(request: &Value, with: &Answering<'_>) -> Option<String> {
    let id = request.get("id")?.clone();
    let method = request["method"].as_str().unwrap_or("");
    Some(reply(&id, handle(method, &request["params"], with)))
}

fn reply(id: &Value, result: Result<Value, String>) -> String {
    match result {
        Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
        Err(message) => json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": { "code": -32000, "message": message },
        }),
    }
    .to_string()
}

/// Answers the other sessions' greed-mail on `listener`, in the mail
/// session: their requests as its own, and to those that subscribe, every
/// notification it makes (`notes`).
async fn listen(
    with: &Answering<'_>,
    listener: UnixListener,
    mut notes: mpsc::UnboundedReceiver<String>,
) {
    use futures::StreamExt;
    use futures::stream::{self, LocalBoxStream, SelectAll};

    let mut lines: SelectAll<LocalBoxStream<'static, (usize, Option<String>)>> = SelectAll::new();
    let mut writers: HashMap<usize, OwnedWriteHalf> = HashMap::new();
    let mut subscribed: Vec<usize> = Vec::new();
    let mut next = 0;
    loop {
        tokio::select! {
            Ok((stream, _)) = listener.accept() => {
                let (read, write) = stream.into_split();
                let id = next;
                next += 1;
                writers.insert(id, write);
                let read = stream::unfold(BufReader::new(read).lines(), |mut input| async move {
                    let line = input.next_line().await.ok().flatten()?;
                    Some((line, input))
                });
                lines.push(
                    read.map(move |line| (id, Some(line)))
                        .chain(stream::once(async move { (id, None) }))
                        .boxed_local(),
                );
            }
            Some((id, line)) = lines.next(), if !lines.is_empty() => {
                let Some(line) = line else {
                    writers.remove(&id);
                    subscribed.retain(|s| *s != id);
                    continue;
                };
                let Ok(request) = serde_json::from_str::<Value>(&line) else {
                    continue;
                };
                let answer = if request["method"] == "subscribe" {
                    subscribed.push(id);
                    request.get("id").map(|i| reply(i, Ok(json!({}))))
                } else {
                    reply_to(&request, with)
                };
                if let (Some(answer), Some(writer)) = (answer, writers.get_mut(&id))
                    && writer.write_all(format!("{answer}\n").as_bytes()).await.is_err()
                {
                    writers.remove(&id);
                }
            }
            Some(note) = notes.recv() => {
                let line = format!("{note}\n");
                for id in subscribed.clone() {
                    let sent = match writers.get_mut(&id) {
                        Some(writer) => writer.write_all(line.as_bytes()).await.is_ok(),
                        None => false,
                    };
                    if !sent {
                        writers.remove(&id);
                        subscribed.retain(|s| *s != id);
                    }
                }
            }
        }
    }
}

/// What the mail session isn't there to do, said so.
fn not_running() -> String {
    "the mail session isn't running: :mail-session starts it".to_string()
}

/// Has the mail session's greed-mail make request `method`, for a
/// greed-mail only reading the mail: its result, or why there's none.
async fn forward(dir: &Path, method: &str, params: &Value) -> Result<Value, String> {
    let stream = UnixStream::connect(dir.join(SOCKET))
        .await
        .map_err(|_| not_running())?;
    let (read, mut write) = stream.into_split();
    let request = json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params });
    write
        .write_all(format!("{request}\n").as_bytes())
        .await
        .map_err(|_| not_running())?;
    let line = BufReader::new(read)
        .lines()
        .next_line()
        .await
        .ok()
        .flatten()
        .ok_or_else(not_running)?;
    let answer: Value = serde_json::from_str(&line).map_err(|e| e.to_string())?;
    match answer.get("error") {
        Some(error) => Err(error["message"]
            .as_str()
            .unwrap_or("the mail session couldn't")
            .to_string()),
        None => Ok(answer["result"].clone()),
    }
}

/// For a greed-mail only reading the mail: passes on what the mail
/// session's says (the mail changed, sent, refused, an attachment came),
/// as if it were its own, reconnecting when the mail session comes back.
async fn relay(dir: &Path, shared: &Shared) {
    let socket = dir.join(SOCKET);
    loop {
        if let Ok(stream) = UnixStream::connect(&socket).await {
            let (read, mut write) = stream.into_split();
            let subscribe = json!({ "jsonrpc": "2.0", "method": "subscribe" });
            if write
                .write_all(format!("{subscribe}\n").as_bytes())
                .await
                .is_ok()
            {
                let mut input = BufReader::new(read).lines();
                while let Ok(Some(line)) = input.next_line().await {
                    let _ = shared.out.send(line);
                }
            }
        }
        tokio::time::sleep(RECONNECT).await;
    }
}

/// How often a greed-mail only reading the mail looks for the mail
/// session's again.
const RECONNECT: Duration = Duration::from_secs(5);

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

impl Answering<'_> {
    /// What changes the mail, which only the mail session has.
    fn writer(&self) -> Result<&Writer, String> {
        self.writer
            .ok_or_else(|| "mail is changed in the mail session; here it's only read".into())
    }
}

/// Answers each request on the input until it closes. Only reading the
/// mail, it has the mail session's greed-mail make the changes, and fetch
/// the bodies a thread asked for.
async fn answer(with: &Answering<'_>) {
    let reading = with.writer.is_none();
    let mut input = BufReader::new(tokio::io::stdin()).lines();
    while let Ok(Some(line)) = input.next_line().await {
        let Ok(request) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let method = request["method"].as_str().unwrap_or("");
        let answer = match request.get("id") {
            Some(id) if reading && FORWARDED.contains(&method) => Some(reply(
                id,
                forward(with.dir, method, &request["params"]).await,
            )),
            _ => reply_to(&request, with),
        };
        if let Some(answer) = answer {
            let _ = with.shared.out.send(answer);
        }
        if reading {
            let wanted = std::mem::take(&mut *with.shared.wanted.borrow_mut());
            if !wanted.is_empty() {
                let _ = forward(with.dir, "want", &json!({ "keys": wanted })).await;
            }
        }
    }
}

/// The result of request `method`, or why there's none.
fn handle(method: &str, params: &Value, with: &Answering<'_>) -> Result<Value, String> {
    let Answering { reader, shared, .. } = with;
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
        "want" => {
            let keys = keys(params).ok_or("want takes keys, messages' whose bodies to fetch")?;
            shared.wanted.borrow_mut().extend(keys);
            shared.wake.notify_one();
            Ok(json!({}))
        }
        "summaries" => {
            let keys = keys(params).ok_or("summaries takes keys, a list of the index's keys")?;
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
        "find" => {
            let id = params["message_id"]
                .as_str()
                .ok_or("find takes message_id, a Message-ID without <>")?;
            Ok(json!({ "key": reader.find(id).map_err(|e| e.0)? }))
        }
        "contacts" => {
            let typed = params["typed"].as_str().unwrap_or("");
            Ok(json!(reader.contacts(typed, CONTACTS).map_err(|e| e.0)?))
        }
        "accounts" => Ok(json!(
            with.config
                .accounts
                .iter()
                .map(|a| json!({ "name": a.name, "address": a.address, "aliases": a.aliases }))
                .collect::<Vec<_>>()
        )),
        "act" => act(params, with),
        "undo" => undo(with),
        "render" => render(params, reader),
        "browse" => browse(params, with),
        "attachment" => attachment(params, with),
        "draft" => {
            let key = params["key"]
                .as_str()
                .ok_or("draft takes key, the message to reply to")?;
            let Some((name, original)) = reader.original(key).map_err(|e| e.0)? else {
                return Err("that mail is gone".into());
            };
            let all = params["all"].as_bool().unwrap_or(false);
            let aliases = with
                .config
                .account(&name)
                .map(|a| a.aliases.as_slice())
                .unwrap_or_default();
            serde_json::to_value(send::reply(&original, key, all, aliases))
                .map_err(|e| e.to_string())
        }
        "send" => post(params, with),
        "respond" => respond(params, with),
        _ => Err(format!("no method {method}")),
    }
}

/// What putting `tag` on the mail `key` names (`on`), or taking it off,
/// is on its account's server: an IMAP keyword on a plain one, a label on
/// Gmail (X-GM-LABELS), a label on Bridge (its `Labels/` mailbox) when the
/// account says `labels = true`. Off by default there: taking one off
/// deletes the message from the label's mailbox, which on Bridge only
/// takes the label off; try it on a throwaway message first.
fn tagging(
    config: &Config,
    reader: &Reader,
    key: &str,
    tag: &str,
    on: bool,
) -> Result<Action, String> {
    let name = reader.account_of(key).map_err(|e| e.0)?;
    let account = name.as_deref().and_then(|name| config.account(name));
    let name = tag.trim().to_string();
    Ok(match account.and_then(|a| a.provider) {
        None => Action::Flag {
            flag: indexing::keyword(tag)?,
            on,
        },
        Some(Provider::Gmail) => Action::GmailLabel { name, on },
        Some(Provider::ProtonBridge) if account.is_some_and(|a| a.labels) => {
            Action::FolderLabel { name, on }
        }
        Some(Provider::ProtonBridge) => {
            return Err(
                "labels on Proton are off: `labels = true` on the account in mail.toml turns \
                 them on (try it on a message you can lose first)"
                    .into(),
            );
        }
    })
}

/// A request's `keys`. Luau writes an empty list as `{}`, so that's an
/// empty list too.
fn keys(params: &Value) -> Option<Vec<String>> {
    match &params["keys"] {
        Value::Object(empty) if empty.is_empty() => Some(Vec::new()),
        keys => serde_json::from_value(keys.clone()).ok(),
    }
}

/// A `render` request: the message `key`'s HTML laid out `width` cells
/// wide, or null when it has none.
fn render(params: &Value, reader: &Reader) -> Result<Value, String> {
    let key = params["key"]
        .as_str()
        .ok_or("render takes key, a message's")?;
    let cells = params["width"]
        .as_u64()
        .and_then(|w| usize::try_from(w).ok())
        .unwrap_or(80);
    let Some(html) = reader.html(key).map_err(|e| e.0)? else {
        return Ok(Value::Null);
    };
    serde_json::to_value(html::render(&html, cells)).map_err(|e| e.to_string())
}

/// A `browse` request: the message `key`'s HTML as a page that loads
/// nothing, written beside the store for a browser; gives where.
fn browse(params: &Value, with: &Answering<'_>) -> Result<Value, String> {
    let key = params["key"]
        .as_str()
        .ok_or("browse takes key, a message's")?;
    let html = with
        .reader
        .html(key)
        .map_err(|e| e.0)?
        .ok_or("it has no HTML to show")?;
    let path = html::page(&html, &with.dir.join("html"), key)?;
    Ok(json!({ "path": path }))
}

/// A `send` request: the draft in `params` made a message and put in the
/// outbox of the account it's from (the one of the mail it answers, else
/// `account`, else the first); the next round sends it.
fn post(params: &Value, with: &Answering<'_>) -> Result<Value, String> {
    let draft: Draft =
        serde_json::from_value(params.clone()).map_err(|e| format!("send takes a draft: {e}"))?;
    post_draft(&draft, params["account"].as_str(), with)
}

/// A `respond` request: `answer` (accepted, tentative, declined) to the
/// invite the message `key` carries, sent to its organizer as a REPLY
/// through the outbox like any mail.
fn respond(params: &Value, with: &Answering<'_>) -> Result<Value, String> {
    let key = params["key"]
        .as_str()
        .ok_or("respond takes key, the message with the invite")?;
    let answer = params["answer"]
        .as_str()
        .and_then(invite::Answer::parse)
        .ok_or("respond takes answer: accepted, tentative or declined")?;
    let (ics, me) = with
        .reader
        .calendar(key)
        .map_err(|e| e.0)?
        .ok_or("that mail has no invite")?;
    let reply = invite::reply(&ics, &me, answer, jiff::Timestamp::now())
        .ok_or("the invite names no one to answer")?;
    let draft = Draft {
        to: reply.to,
        subject: reply.subject,
        text: reply.text,
        replying: Some(key.to_string()),
        calendar: Some(reply.calendar),
        ..Draft::default()
    };
    post_draft(&draft, None, with)
}

/// `draft` made a message and put in the outbox of the account it's from:
/// the one of the mail it answers, else `account`, else the first.
fn post_draft(draft: &Draft, account: Option<&str>, with: &Answering<'_>) -> Result<Value, String> {
    let Answering { reader, shared, .. } = with;
    let writer = with.writer()?;
    let original = match &draft.replying {
        Some(key) => reader.original(key).map_err(|e| e.0)?,
        None => None,
    };
    let account = if draft.from.trim().is_empty() {
        let name = original.as_ref().map(|(name, _)| name.as_str()).or(account);
        match name {
            Some(name) => with.config.account(name),
            None => with.config.accounts.first(),
        }
        .ok_or_else(|| format!("no account {} in mail.toml", name.unwrap_or("")))?
    } else {
        with.config.sending_as(&draft.from).ok_or_else(|| {
            format!(
                "no account in mail.toml sends as {}: add it to one's aliases",
                draft.from.trim()
            )
        })?
    };
    let outgoing = send::compose(&account.address, draft, original.as_ref().map(|(_, o)| o))?;
    let (store, _) = &mut *writer.borrow_mut();
    let id = store
        .account(&account.name, &account.address)
        .map_err(|e| e.0)?;
    let replying = match &draft.replying {
        Some(key) => store.messages_of(key).map_err(|e| e.0)?.first().copied(),
        None => None,
    };
    let after = jiff::Timestamp::now().as_second() + SENDING.as_secs().cast_signed();
    let posted = store
        .post(id, &outgoing, replying, after)
        .map_err(|e| e.0)?;
    *shared.last.borrow_mut() = Some(Undoing::Sent(posted));
    shared.wake.notify_one();
    Ok(json!({ "posted": posted, "seconds": SENDING.as_secs() }))
}

/// How many people a `contacts` request gives at most.
const CONTACTS: u32 = 12;

/// How long mail waits in the outbox before it goes, to be taken back.
const SENDING: Duration = Duration::from_secs(10);

/// What undoes the last change asked for: each message's undo, or taking
/// back mail just sent.
enum Undoing {
    Changes(Vec<(i64, Undo)>),
    Sent(i64),
}

/// An `act` request: `action` on the messages `keys` name, kept to be
/// undone. Trashing what's in the trash deletes it for good, which can't
/// be: it's only done with `for_good`, and otherwise said how many are.
fn act(params: &Value, with: &Answering<'_>) -> Result<Value, String> {
    let writer = with.writer()?;
    let keys = keys(params).ok_or("act takes keys, a list of messages' or threads' keys")?;
    // A tag is a different change on each kind of server.
    let tag = match params["action"].as_str() {
        Some(word @ ("tag" | "untag")) => Some((
            params["tag"]
                .as_str()
                .ok_or("tag takes tag, the tag to set or take off")?,
            word == "tag",
        )),
        _ => None,
    };
    let given = if tag.is_none() {
        Some(action(params)?)
    } else {
        None
    };
    let for_good = params["for_good"].as_bool().unwrap_or(false);
    let (store, index) = &mut *writer.borrow_mut();
    let mut ids: Vec<(i64, Action)> = Vec::new();
    for key in &keys {
        let action = match (tag, &given) {
            (Some((tag, on)), _) => tagging(with.config, with.reader, key, tag, on)?,
            (None, Some(given)) => given.clone(),
            (None, None) => unreachable!("an action or a tag"),
        };
        for id in store.messages_of(key).map_err(|e| e.0)? {
            ids.push((id, action.clone()));
        }
    }
    if given == Some(Action::Trash) && !for_good {
        let mut in_trash = 0;
        for (id, _) in &ids {
            in_trash += usize::from(store.in_trash(*id).map_err(|e| e.0)?);
        }
        if in_trash > 0 {
            return Ok(json!({ "changed": 0, "in_trash": in_trash }));
        }
    }
    let mut undos = Vec::new();
    let mut changed = 0;
    for (id, action) in ids {
        let undo = store.undoing(id, &action).map_err(|e| e.0)?;
        if store.act(id, &action).map_err(|e| e.0)? {
            changed += 1;
            undos.extend(undo.map(|u| (id, u)));
        }
    }
    if changed > 0 {
        *with.shared.last.borrow_mut() = Some(Undoing::Changes(undos));
        indexing::catch_up(store, index).map_err(|e| e.0)?;
        with.shared.notify("changed", &json!({}));
        with.shared.wake.notify_one();
    }
    Ok(json!({ "changed": changed }))
}

/// An `undo` request: the last change asked for undone, or the mail just
/// sent taken back while it waits; says which.
fn undo(with: &Answering<'_>) -> Result<Value, String> {
    let writer = with.writer()?;
    let last = with
        .shared
        .last
        .borrow_mut()
        .take()
        .ok_or("nothing to undo")?;
    let (store, index) = &mut *writer.borrow_mut();
    match last {
        Undoing::Sent(id) => {
            if !store.unpost(id).map_err(|e| e.0)? {
                return Err("it's sent already".into());
            }
            Ok(json!({ "undone": "sent" }))
        }
        Undoing::Changes(undos) => {
            for (id, undo) in &undos {
                store.undo(*id, undo).map_err(|e| e.0)?;
            }
            indexing::catch_up(store, index).map_err(|e| e.0)?;
            with.shared.notify("changed", &json!({}));
            with.shared.wake.notify_one();
            Ok(json!({ "undone": "changes", "count": undos.len() }))
        }
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
                "no action {other:?}: read, unread, flag, unflag, archive, trash, move, tag or untag"
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
            // Mail waiting in the outbox goes once its wait is over.
            let due = store.next_due().ok().flatten().map(|at| {
                let left = at - jiff::Timestamp::now().as_second();
                Duration::from_secs(left.max(0).cast_unsigned())
            });
            tokio::select! {
                () = shared.wake.notified() => {}
                () = changed => {}
                () = tokio::time::sleep(due.unwrap_or(QUIET).min(QUIET)) => {}
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
    store.set_aliases(id, &account.aliases).map_err(|e| e.0)?;
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
        if index_telling(store, index, shared).await? > 0 {
            shared.notify("changed", &json!({}));
        }
        // Said once they're in the index, so rules searching find them.
        let arrived = store.arrived().map_err(|e| e.0)?;
        if !arrived.is_empty() {
            shared.notify("arrived", &json!({ "keys": arrived }));
        }
        if synced.fetched + synced.changed + synced.gone + fetched > 0 {
            let (messages, _) = store.counts(id).map_err(|e| e.0)?;
            shared.notify(
                "progress",
                &json!({
                    "account": account.name,
                    "mailbox": mailbox.name,
                    "fetched": synced.fetched,
                    "bodies": fetched,
                    "messages": messages,
                }),
            );
        }
    }
    asked_for(&mut connection, store, index, id, shared).await?;
    let (messages, _) = store.counts(id).map_err(|e| e.0)?;
    shared.notify(
        "synced",
        &json!({ "account": account.name, "messages": messages, "done": !more }),
    );
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

/// Brings `index` up to `store` a batch at a time, letting requests be
/// answered between batches. When there's more than a batch it says how
/// far it got (`indexing`, `done` of `of`), first before it starts, and
/// that the mail changed after each, so a list fills in as it goes. Gives
/// how many it wrote.
async fn index_telling(
    store: &mut Store,
    index: &mut Index,
    shared: &Shared,
) -> Result<usize, String> {
    let of = store.unindexed_count().map_err(|e| e.0)?;
    let telling = of > indexing::BATCH;
    if telling {
        shared.notify("indexing", &json!({ "done": 0, "of": of }));
        tokio::task::yield_now().await;
    }
    let mut done = 0;
    loop {
        let some = indexing::catch_up_some(store, index).map_err(|e| e.0)?;
        if some == 0 {
            break;
        }
        done += some;
        if telling {
            shared.notify("indexing", &json!({ "done": done.min(of), "of": of }));
            shared.notify("changed", &json!({}));
        }
        tokio::task::yield_now().await;
    }
    indexing::take_out_gone(store, index).map_err(|e| e.0)?;
    if telling {
        shared.notify("indexing", &json!({ "done": of, "of": of }));
    }
    Ok(done)
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

/// Fetches the attachments, then the bodies, asked for of account `id`'s
/// messages, from where each is, then says they're in.
async fn asked_for(
    connection: &mut Connection,
    store: &mut Store,
    index: &mut Index,
    id: i64,
    shared: &Shared,
) -> Result<(), String> {
    let prefix = format!("m:{id}:");
    let (attachments, others): (Vec<_>, Vec<_>) = shared
        .attachments
        .take()
        .into_iter()
        .partition(|(key, _, _)| key.starts_with(&prefix));
    *shared.attachments.borrow_mut() = others;
    for (key, number, to) in attachments {
        let saved = save_attachment(
            connection,
            store,
            id,
            &key[prefix.len()..],
            number,
            to,
            &shared.kept,
        )
        .await;
        // Whatever happened, the one waiting hears of it.
        let mut said = json!({ "key": key, "index": number });
        match &saved {
            Ok(Ok(path)) => said["path"] = json!(path),
            Ok(Err(why)) | Err(why) => said["error"] = json!(why),
        }
        shared.notify("attachment", &said);
        // A connection that broke ends the round, as anywhere else.
        let _ = saved?;
    }
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

/// Fetches account `id`'s message `identity` whole and saves thing number
/// `number` attached to it: at `to`, or kept beside the store. Gives where,
/// or why it couldn't; trouble is a connection that broke.
async fn save_attachment(
    connection: &mut Connection,
    store: &Store,
    id: i64,
    identity: &str,
    number: usize,
    to: Option<PathBuf>,
    kept: &Path,
) -> Result<Result<PathBuf, String>, String> {
    let Some((mailbox, place)) = store.place_of(id, identity).map_err(|e| e.0)? else {
        return Ok(Err("that mail is gone".into()));
    };
    connection.open(&mailbox).await.map_err(|e| e.0)?;
    let fetched = connection
        .bodies(&[place.uid], u32::MAX)
        .await
        .map_err(|e| e.0)?;
    let Some((_, raw)) = fetched.into_iter().next() else {
        return Ok(Err("that mail is gone from the server".into()));
    };
    let Some((name, bytes)) = body::attached(&raw, number) else {
        return Ok(Err("it has nothing attached there".into()));
    };
    let path = to.unwrap_or_else(|| {
        kept_attachment(kept, &format!("m:{id}:{identity}"), number).join(files::safe_name(&name))
    });
    // Kept before, it's there already: as good.
    if path.starts_with(kept) && path.exists() {
        return Ok(Ok(path));
    }
    Ok(files::write_new(&path, &bytes))
}

/// Where thing number `number` attached to the message `key` is kept beside
/// the store, in a folder of its own.
fn kept_attachment(kept: &Path, key: &str, number: usize) -> PathBuf {
    kept.join(files::hashed(key)).join(number.to_string())
}

/// An `attachment` request: thing number `index` attached to the message
/// `key`, saved `to` a path, or kept beside the store to open. One kept
/// already is given at once; otherwise the next step of the sync fetches
/// it and an `attachment` notification says where it went, or why not.
fn attachment(params: &Value, with: &Answering<'_>) -> Result<Value, String> {
    with.writer()?;
    let key = params["key"]
        .as_str()
        .ok_or("attachment takes key, a message's")?;
    let number = params["index"]
        .as_u64()
        .and_then(|n| usize::try_from(n).ok())
        .ok_or("attachment takes index, which of its attachments")?;
    let to = params["to"].as_str().map(files::expand_home);
    if to.is_none()
        && let Ok(mut found) = std::fs::read_dir(kept_attachment(&with.shared.kept, key, number))
        && let Some(Ok(entry)) = found.next()
    {
        return Ok(json!({ "path": entry.path() }));
    }
    with.shared
        .attachments
        .borrow_mut()
        .push((key.to_string(), number, to));
    with.shared.wake.notify_one();
    Ok(json!({ "waiting": true }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::header::Fetched;

    #[test]
    fn indexing_much_says_so_before_the_first_batch_and_after_each() {
        let dir = std::env::temp_dir().join(format!("gm-telling-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut store = Store::open(&dir).unwrap();
        let mut index = Index::open(&dir.join("index.db")).unwrap();
        let account = store.account("proton", "anna@example.com").unwrap();
        let all = store.mailbox(account, "All Mail", Some("all")).unwrap();
        let count = indexing::BATCH + 1;
        let messages: Vec<Fetched> = (1..=u32::try_from(count).unwrap())
            .map(|uid| Fetched {
                uid,
                raw: format!("Message-ID: <{uid}@x>\r\nSubject: s{uid}\r\n\r\n").into_bytes(),
                ..Fetched::default()
            })
            .collect();
        store.put(account, all.id, &messages, 1, 1).unwrap();
        let (out, mut lines) = mpsc::unbounded_channel();
        let shared = Shared {
            out,
            wanted: RefCell::new(Vec::new()),
            attachments: RefCell::new(Vec::new()),
            kept: dir.join("attachments"),
            standing: RefCell::new(BTreeMap::new()),
            wake: Notify::new(),
            copies: None,
            last: RefCell::new(None),
        };
        let written = tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap()
            .block_on(index_telling(&mut store, &mut index, &shared))
            .unwrap();
        assert_eq!(written, count);
        let mut told = Vec::new();
        while let Ok(line) = lines.try_recv() {
            let message: Value = serde_json::from_str(&line).unwrap();
            if message["method"] == "indexing" {
                told.push(message["params"]["done"].as_u64().unwrap());
            }
        }
        let batch = indexing::BATCH as u64;
        assert_eq!(told, [0, batch, batch + 1, batch + 1]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn each_failure_waits_twice_as_long_up_to_five_minutes() {
        let mut backoff = Backoff::default();
        let waits: Vec<u64> = (0..10).map(|_| backoff.next().as_secs()).collect();
        assert_eq!(waits, [2, 4, 8, 16, 32, 64, 128, 256, 300, 300]);
        backoff.reset();
        assert_eq!(backoff.next().as_secs(), 2, "from the start once it works");
    }

    #[test]
    fn no_keys_is_an_empty_list_however_its_written() {
        assert_eq!(keys(&json!({ "keys": {} })), Some(Vec::new()));
        assert_eq!(keys(&json!({ "keys": [] })), Some(Vec::new()));
        assert_eq!(
            keys(&json!({ "keys": ["m:1:a"] })),
            Some(vec!["m:1:a".into()])
        );
        assert_eq!(keys(&json!({ "keys": { "a": 1 } })), None);
        assert_eq!(keys(&json!({})), None);
    }
}
