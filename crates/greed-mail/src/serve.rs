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
//! (a draft, put in the outbox and sent in the next round, or between
//! batches of a long catch-up of the index), `respond`
//! (`answer` to the invite in the message `key`: accepted, tentative or
//! declined, sent to its organizer the same way), `render` (the
//! message `key`'s HTML laid out `width` wide), `browse` (it as a page that
//! loads nothing) and `attachment` (thing number `index` attached to it,
//! saved `to` a path or kept beside the store).
//! Notifications: `changed` (the index changed: search again), `progress`
//! (an account's mailbox synced some: how many `messages` it has here, `of`
//! how many on the server), `waiting` (an account's password command keeps
//! it waiting: its `program`, none once it's done), `trouble` (an account that can't
//! sync, and why), `refused` (a change or mail its server refused, and
//! why), `sent` (mail its server took), `arrived` (the keys of new mail,
//! once it's in the index: what came since its mailbox was all in, never
//! what a first sync brings), `attachment` (where one asked
//! for went, or why it couldn't), `indexing` (how far a long catch-up of
//! the index got: `done` of `of`) and `synced` (an account's round over:
//! how many `messages` it has, `of` how many, and whether it's all `done`).
//!
//! Other sessions reach it through the mail plugin's service, in the mail
//! session; nothing else talks to it.
//!
//! The sync goes in rounds of at most `HEADERS` headers and `BODIES` bodies
//! a mailbox, so what's asked for never waits long. After a round with
//! nothing left to do it waits in IDLE on each account's inbox, so new
//! mail comes within seconds, until asked or for `QUIET`. An account that
//! fails is tried again after a wait twice as long each time.

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use greed_index::index::Index;
use serde::Serialize;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{Notify, mpsc};

use crate::body;
use crate::config::{Account, Config, Provider};
use crate::files;
use crate::html;
use crate::imap::{Changing, Connection, Imap, Mailbox, Role};
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

/// What `progress` says: an account's mailbox synced some.
#[derive(Serialize)]
struct Progress<'a> {
    account: &'a str,
    mailbox: &'a str,
    /// Headers fetched.
    fetched: usize,
    bodies: usize,
    /// How many the account has here, of how many on the server.
    messages: i64,
    of: Option<u64>,
}

/// What `status` says of an account.
#[derive(Debug, Clone, Default, Serialize)]
struct Standing {
    name: String,
    messages: i64,
    /// How many the server has, as far as it says (see `on_server`).
    of: Option<u64>,
    /// Whether everything on the server is in, headers and bodies.
    done: bool,
    trouble: Option<String>,
}

/// What the parts share: lines to write, bodies asked for, the accounts'
/// standing, and a nudge to sync now. The sync runs on a thread of its
/// own, so what's asked is answered while it works.
struct Shared {
    out: mpsc::UnboundedSender<String>,
    wanted: Mutex<Vec<String>>,
    /// Attachments asked for: of which message, which one, and where to
    /// save it (beside the store without a place).
    attachments: Mutex<Vec<(String, usize, Option<PathBuf>)>>,
    /// Where attachments opened from the store are kept.
    kept: PathBuf,
    standing: Mutex<BTreeMap<String, Standing>>,
    wake: Notify,
    /// A nudge to fetch the bodies and attachments asked for now.
    asked: Notify,
    /// What undoes the last change asked for.
    last: Mutex<Option<Undoing>>,
}

/// What `mutex` holds, even after a thread panicked holding it: the
/// program ends then anyway (see main.rs).
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Takes out of `list` those `mine` picks, leaving the others.
fn take_from<T>(list: &Mutex<Vec<T>>, mine: impl Fn(&T) -> bool) -> Vec<T> {
    let mut list = lock(list);
    let (taken, left) = std::mem::take(&mut *list).into_iter().partition(mine);
    *list = left;
    taken
}

impl Shared {
    fn new(out: mpsc::UnboundedSender<String>, kept: PathBuf) -> Shared {
        Shared {
            out,
            wanted: Mutex::new(Vec::new()),
            attachments: Mutex::new(Vec::new()),
            kept,
            standing: Mutex::new(BTreeMap::new()),
            wake: Notify::new(),
            asked: Notify::new(),
            last: Mutex::new(None),
        }
    }

    fn notify(&self, method: &str, params: &Value) {
        let message = json!({ "jsonrpc": "2.0", "method": method, "params": params });
        let _ = self.out.send(message.to_string());
    }

    /// Tells, as `waiting`, while `account`'s password command keeps it
    /// waiting (its program), and when that's over (none).
    fn waiting<'a>(&'a self, account: &'a Account) -> impl Fn(Option<&str>) + 'a {
        move |program| {
            self.notify(
                "waiting",
                &json!({ "account": account.name, "program": program }),
            );
        }
    }
}

/// Which requests and notifications this greed-mail speaks, as `hello`
/// says: the mail plugin checks it's the one it speaks before anything
/// else. It goes up whenever one of them changes so that the other side
/// would misread it; new requests, and new fields left out of old ones,
/// don't need it.
pub const PROTOCOL: u32 = 1;

/// Serves `config`'s accounts from the store in `dir` until its input
/// closes.
pub async fn serve(config: Config, dir: PathBuf) -> Result<(), String> {
    let mut store = Store::open(&dir).map_err(|e| e.0)?;
    let index = indexing::open(&mut store, &dir.join("index.db")).map_err(|e| e.0)?;
    // Changes asked for, and fetches, are made with a store and index of
    // their own, as the sync holds its own while it waits on a server.
    let beside = || -> Result<(Store, Index), String> {
        let store = store.beside(&dir).map_err(|e| e.0)?;
        let index = Index::open(&dir.join("index.db")).map_err(|e| e.0)?;
        Ok((store, index))
    };
    let writer = RefCell::new(beside()?);
    let (fetch_store, fetch_index) = beside()?;
    let reader =
        Reader::open(&dir).map_err(|_| format!("there's no mail in {} yet", dir.display()))?;
    let (out, mut lines) = mpsc::unbounded_channel::<String>();
    let shared = Arc::new(Shared::new(out, dir.join("attachments")));
    // The sync's long writes and waits on servers hold up nothing asked of
    // it. It runs as long as the program does.
    let syncing = Arc::clone(&shared);
    let accounts = config.clone();
    background("sync", async move || {
        keep_syncing(&accounts, store, index, &syncing).await;
    })?;
    // Nor does it hold up what you open: bodies and attachments asked for
    // come on a connection of their own, while a long catch-up goes on.
    let fetching = Arc::clone(&shared);
    let accounts = config.clone();
    background("fetch", async move || {
        keep_fetching(&accounts, fetch_store, fetch_index, &fetching).await;
    })?;
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
        writer: &writer,
        dir: &dir,
        shared: &shared,
    };
    // Its input closed, it's done; the sync goes with the program.
    tokio::select! {
        () = answer(&with) => {}
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

/// What changes are made with: a store and an index.
type Writer = RefCell<(Store, Index)>;

/// What requests are answered from.
struct Answering<'a> {
    config: &'a Config,
    reader: &'a Reader,
    writer: &'a Writer,
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
        if let Some(answer) = reply_to(&request, with) {
            let _ = with.shared.out.send(answer);
        }
    }
}

/// The result of request `method`, or why there's none.
fn handle(method: &str, params: &Value, with: &Answering<'_>) -> Result<Value, String> {
    let Answering { reader, shared, .. } = with;
    match method {
        "status" => {
            let standing: Vec<Standing> = lock(&shared.standing).values().cloned().collect();
            Ok(json!({ "accounts": standing }))
        }
        "hello" => Ok(json!({ "protocol": PROTOCOL, "version": env!("CARGO_PKG_VERSION") })),
        "index" => Ok(json!({ "path": with.dir.join("index.db") })),
        "sync" => {
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
                lock(&shared.wanted).extend(bodiless);
                shared.asked.notify_one();
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
                .map(|a| json!({ "name": a.name, "address": a.address, "aliases": a.aliases, "identities": with.config.identities(a) }))
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
    crate::json::list(&params["keys"]).ok()
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
    let Answering {
        reader,
        writer,
        shared,
        ..
    } = with;
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
    *lock(&shared.last) = Some(Undoing::Sent(posted));
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
    let (store, index) = &mut *with.writer.borrow_mut();
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
    let mut changed = Vec::new();
    for (id, action) in ids {
        let undo = store.undoing(id, &action).map_err(|e| e.0)?;
        if store.act(id, &action).map_err(|e| e.0)? {
            changed.push(id);
            undos.extend(undo.map(|u| (id, u)));
        }
    }
    if !changed.is_empty() {
        *lock(&with.shared.last) = Some(Undoing::Changes(undos));
        // Only what changed: a long catch-up going on mustn't hold it up.
        indexing::catch_up_on(store, index, &changed).map_err(|e| e.0)?;
        with.shared.notify("changed", &json!({}));
        with.shared.wake.notify_one();
    }
    Ok(json!({ "changed": changed.len() }))
}

/// An `undo` request: the last change asked for undone, or the mail just
/// sent taken back while it waits; says which.
fn undo(with: &Answering<'_>) -> Result<Value, String> {
    let last = lock(&with.shared.last).take().ok_or("nothing to undo")?;
    let (store, index) = &mut *with.writer.borrow_mut();
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
            let ids: Vec<i64> = undos.iter().map(|(id, _)| *id).collect();
            indexing::catch_up_on(store, index, &ids).map_err(|e| e.0)?;
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
                    troubled(shared, account, trouble);
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
                futures::future::select_all(
                    config.accounts.iter().map(|a| Box::pin(watch(a, shared))),
                )
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

/// Runs what `make` gives on a thread of its own, named `name`, for as
/// long as the program runs.
fn background<F>(name: &str, make: impl FnOnce() -> F + Send + 'static) -> Result<(), String>
where
    F: Future<Output = ()>,
{
    std::thread::Builder::new()
        .name(name.into())
        .spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("a runtime to run on");
            runtime.block_on(make());
        })
        .map(|_| ())
        .map_err(|e| format!("couldn't start the {name} thread: {e}"))
}

/// Says what went wrong with `account`, and keeps it for `status`.
fn troubled(shared: &Shared, account: &Account, trouble: String) {
    shared.notify(
        "trouble",
        &json!({ "account": account.name, "message": trouble }),
    );
    lock(&shared.standing)
        .entry(account.name.clone())
        .or_insert_with(|| Standing {
            name: account.name.clone(),
            ..Standing::default()
        })
        .trouble = Some(trouble);
}

/// Fetches the bodies and attachments asked for as they're asked, each
/// account's on a connection of its own, so a long sync round doesn't keep
/// you waiting on the message you opened. When the server can't be
/// reached, what's asked waits for the sync's next round.
async fn keep_fetching(config: &Config, mut store: Store, mut index: Index, shared: &Shared) {
    loop {
        shared.asked.notified().await;
        for account in &config.accounts {
            let Ok(id) = store.account(&account.name, &account.address) else {
                continue;
            };
            let prefix = format!("m:{id}:");
            let asked = lock(&shared.wanted).iter().any(|k| k.starts_with(&prefix))
                || lock(&shared.attachments)
                    .iter()
                    .any(|(k, _, _)| k.starts_with(&prefix));
            if !asked {
                continue;
            }
            let fetched = async {
                let mut connection = Connection::to(account, &shared.waiting(account)).await?;
                asked_for(&mut connection, &mut store, &mut index, id, shared).await?;
                let _ = connection.close().await;
                Ok::<(), String>(())
            };
            if let Err(trouble) = fetched.await {
                troubled(shared, account, trouble);
                shared.wake.notify_one();
            }
        }
    }
}

/// Waits until `account`'s inbox changes, as its server says in IDLE, or
/// for `POLL` when its server can't IDLE. A connection that breaks ends
/// the wait a little later, so the next round finds out why.
async fn watch(account: &Account, shared: &Shared) {
    let Ok(connection) = Connection::to(account, &shared.waiting(account)).await else {
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
    let mut connection = Connection::to(account, &shared.waiting(account)).await?;
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
    let chosen = sync::chosen(account.provider, &mailboxes);
    arrived_first(&mut connection, store, index, account, id, &chosen, shared).await?;
    let of = on_server(&mut connection, &chosen).await;
    // Where it stands, said at once while it isn't all in, rather than once
    // the round's first mailbox has done some.
    let (messages, _) = store.counts(id).map_err(|e| e.0)?;
    if of.is_some_and(|of| u64::try_from(messages).unwrap_or(0) < of) {
        shared.notify(
            "progress",
            &json!({ "account": account.name, "messages": messages, "of": of }),
        );
    }
    let mut more = false;
    // Every mailbox's headers before any bodies: with headers the mail
    // shows in lists and searches, while bodies, slow to fetch from some
    // servers (Bridge decrypts each), can come after, and one opened
    // comes first anyway. Bodies wait for a round with no headers left.
    let mut headers_left = false;
    for bodies_now in [false, true] {
        if bodies_now && headers_left {
            break;
        }
        for mailbox in &chosen {
            send_changes(&mut connection, store, index, account, id, shared).await?;
            asked_for(&mut connection, store, index, id, shared).await?;
            let (synced, fetched) = if bodies_now {
                let fetched = sync::bodies(&mut connection, store, id, &mailbox.name, bodies)
                    .await
                    .map_err(|e| format!("{}: {e}", mailbox.name))?;
                (sync::Synced::default(), fetched)
            } else {
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
                (synced, 0)
            };
            headers_left |= !bodies_now && !synced.done;
            more |= headers_left || fetched >= BODIES;
            // Mail coming due while a long catch-up goes on is sent between
            // its batches, not once it's over.
            let sending = async |store: &mut Store| {
                send_mail(&mut connection, store, account, id, shared).await
            };
            if index_telling(store, index, shared, sending).await? > 0 {
                shared.notify("changed", &json!({}));
            }
            // Said once they're in the index, so rules searching find them.
            let arrived = store.arrived().map_err(|e| e.0)?;
            if !arrived.is_empty() {
                shared.notify("arrived", &json!({ "keys": arrived }));
            }
            if synced.fetched + synced.changed + synced.gone + fetched > 0 {
                let (messages, _) = store.counts(id).map_err(|e| e.0)?;
                let progress = Progress {
                    account: &account.name,
                    mailbox: &mailbox.name,
                    fetched: synced.fetched,
                    bodies: fetched,
                    messages,
                    of,
                };
                shared.notify("progress", &json!(progress));
            }
        }
    }
    // A change that waited for a UID this round found, like trashing what
    // was just archived, goes now rather than a round later.
    send_changes(&mut connection, store, index, account, id, shared).await?;
    asked_for(&mut connection, store, index, id, shared).await?;
    // Once what's asked for is done; what's asked meanwhile waits a round.
    // Attachments, like bodies, wait until every header is in.
    if !headers_left {
        more |= fetch_ahead(&mut connection, store, id, &shared.kept).await?;
    }
    let (messages, _) = store.counts(id).map_err(|e| e.0)?;
    synced(shared, account, messages, of, !more);
    let _ = connection.close().await;
    Ok(more)
}

/// Says a round of `account` is over, with how many `messages` are in of
/// how many the server has (`of`), and whether that's all (`done`), and
/// keeps it as where the account stands.
fn synced(shared: &Shared, account: &Account, messages: i64, of: Option<u64>, done: bool) {
    shared.notify(
        "synced",
        &json!({ "account": account.name, "messages": messages, "of": of, "done": done }),
    );
    lock(&shared.standing).insert(
        account.name.clone(),
        Standing {
            name: account.name.clone(),
            messages,
            of,
            done,
            trouble: None,
        },
    );
}

/// How many messages the account has on the server, for a sync to say how
/// far it got: All Mail's where there is one (it holds each once), else
/// every mailbox's together. None when the server won't say.
async fn on_server(connection: &mut Connection, mailboxes: &[&Mailbox]) -> Option<u64> {
    let counted = match mailboxes.iter().find(|m| m.role == Some(Role::All)) {
        Some(all) => std::slice::from_ref(all),
        None => mailboxes,
    };
    let mut total = 0;
    for mailbox in counted {
        total += u64::from(connection.status(&mailbox.name).await.ok()?.messages);
    }
    Some(total)
}

/// Fetches what arrived in each of `mailboxes`, before anything slow (all
/// of a mailbox's flags without CONDSTORE, bodies), so new mail shows in
/// each of its places at once, the inbox too, not when the round gets
/// there; and says so, rules on new mail included.
async fn arrived_first(
    connection: &mut Connection,
    store: &mut Store,
    index: &mut Index,
    account: &Account,
    id: i64,
    mailboxes: &[&Mailbox],
    shared: &Shared,
) -> Result<(), String> {
    let arrived = Options {
        limit: Some(HEADERS),
        arrived_only: true,
        ..Options::default()
    };
    let mut came = 0;
    for mailbox in mailboxes {
        came += sync::mailbox(connection, store, id, &mailbox.name, mailbox.role, arrived)
            .await
            .map_err(|e| format!("{}: {e}", mailbox.name))?
            .fetched;
    }
    if came == 0 {
        return Ok(());
    }
    index_telling(store, index, shared, async |_: &mut Store| Ok(())).await?;
    shared.notify("changed", &json!({}));
    let keys = store.arrived().map_err(|e| e.0)?;
    if !keys.is_empty() {
        shared.notify("arrived", &json!({ "keys": keys }));
    }
    let (messages, _) = store.counts(id).map_err(|e| e.0)?;
    lock(&shared.standing)
        .entry(account.name.clone())
        .or_insert_with(|| Standing {
            name: account.name.clone(),
            ..Standing::default()
        })
        .messages = messages;
    Ok(())
}

/// Brings `index` up to `store` a batch at a time, letting requests be
/// answered between batches. When there's more than a batch it says how
/// far it got (`indexing`, `done` of `of`), first before it starts, and
/// that the mail changed after each, so a list fills in as it goes.
/// `between` runs after each batch. Gives how many it wrote.
async fn index_telling(
    store: &mut Store,
    index: &mut Index,
    shared: &Shared,
    mut between: impl AsyncFnMut(&mut Store) -> Result<(), String>,
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
        between(store).await?;
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
    index_telling(store, index, shared, async |_: &mut Store| Ok(())).await?;
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
        match send::deliver(account, &posted.outgoing, &shared.waiting(account)).await {
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
    let attachments = take_from(&shared.attachments, |(key, _, _)| key.starts_with(&prefix));
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
    let keys = take_from(&shared.wanted, |key| key.starts_with(&prefix));
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
    let mut fetched = Vec::new();
    for (mailbox, wanting) in by_mailbox {
        connection.open(&mailbox).await.map_err(|e| e.0)?;
        sync::fetch_bodies(connection, store, &wanting)
            .await
            .map_err(|e| format!("{mailbox}: {e}"))?;
        fetched.extend(wanting.iter().map(|w| w.message));
    }
    // Someone's waiting on these, not on whatever else waits to be indexed.
    indexing::catch_up_on(store, index, &fetched).map_err(|e| e.0)?;
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
    let raw = match whole(connection, store, id, identity).await? {
        Ok(raw) => raw,
        Err(why) => return Ok(Err(why)),
    };
    let Some((name, bytes)) = body::attached(&raw, number) else {
        return Ok(Err("it has nothing attached there".into()));
    };
    let path = to.unwrap_or_else(|| kept_path(kept, id, identity, number, &name));
    // Kept before, it's there already: as good.
    if path.starts_with(kept) && path.exists() {
        return Ok(Ok(path));
    }
    Ok(files::write_new(&path, &bytes))
}

/// Account `id`'s message `identity`, all of it, from its server; or why
/// it isn't there. Trouble is a connection that broke.
async fn whole(
    connection: &mut Connection,
    store: &Store,
    id: i64,
    identity: &str,
) -> Result<Result<Vec<u8>, String>, String> {
    let Some((mailbox, place)) = store.place_of(id, identity).map_err(|e| e.0)? else {
        return Ok(Err("that mail is gone".into()));
    };
    connection.open(&mailbox).await.map_err(|e| e.0)?;
    let fetched = connection
        .bodies(&[place.uid], u32::MAX)
        .await
        .map_err(|e| e.0)?;
    Ok(fetched
        .into_iter()
        .next()
        .map(|(_, raw)| raw)
        .ok_or_else(|| "that mail is gone from the server".to_string()))
}

/// Where thing number `number` attached to account `id`'s message
/// `identity`, called `name`, is kept beside the store.
fn kept_path(kept: &Path, id: i64, identity: &str, number: usize, name: &str) -> PathBuf {
    kept_attachment(kept, &format!("m:{id}:{identity}"), number).join(files::safe_name(name))
}

/// How far back what's attached is fetched ahead, so opening it is at
/// once and works without a connection; flagged mail any age.
const AHEAD_DAYS: i64 = 14;

/// The biggest message whose attachments are fetched ahead.
const AHEAD_BYTES: u32 = 10 * 1024 * 1024;

/// How many messages' attachments a round fetches ahead.
const AHEAD: usize = 10;

/// Fetches what's attached to account `id`'s recent and flagged mail
/// ahead (`AHEAD` messages a round, each once), keeping it where opening
/// it looks. Gives whether there's more to fetch.
async fn fetch_ahead(
    connection: &mut Connection,
    store: &mut Store,
    id: i64,
    kept: &Path,
) -> Result<bool, String> {
    let since = jiff::Timestamp::now()
        .checked_sub(jiff::SignedDuration::from_hours(24 * AHEAD_DAYS))
        .map_err(|e| e.to_string())?
        .strftime("%Y-%m-%d")
        .to_string();
    let ahead = store
        .ahead(id, &since, AHEAD_BYTES, AHEAD)
        .map_err(|e| e.0)?;
    for (message, identity) in &ahead {
        if let Ok(raw) = whole(connection, store, id, identity).await? {
            for (number, (name, bytes)) in body::all_attached(&raw).into_iter().enumerate() {
                let path = kept_path(kept, id, identity, number, &name);
                if !path.exists() {
                    let _ = files::write_new(&path, &bytes);
                }
            }
        }
        store.fetched_ahead(*message).map_err(|e| e.0)?;
    }
    Ok(ahead.len() == AHEAD)
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
    lock(&with.shared.attachments).push((key.to_string(), number, to));
    with.shared.asked.notify_one();
    Ok(json!({ "waiting": true }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::header::Fetched;

    #[test]
    fn the_mail_plugin_speaks_the_protocol_this_does() {
        let plugin = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../runtime/plugins/mail/backend.luau"
        ))
        .unwrap();
        assert!(
            plugin.contains(&format!("\nM.PROTOCOL = {PROTOCOL}\n")),
            "backend.luau's M.PROTOCOL must be {PROTOCOL}: bump both together"
        );
    }

    #[test]
    fn indexing_much_says_so_before_the_first_batch_and_sends_after_each() {
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
        let shared = Shared::new(out, dir.join("attachments"));
        let mut left_between = Vec::new();
        let between = async |store: &mut Store| {
            left_between.push(store.unindexed_count().unwrap());
            Ok(())
        };
        let written = tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap()
            .block_on(index_telling(&mut store, &mut index, &shared, between))
            .unwrap();
        assert_eq!(written, count);
        assert_eq!(left_between, [1, 0], "after each batch, mail is sent");
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
