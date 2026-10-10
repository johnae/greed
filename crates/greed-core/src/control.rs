//! The session socket: how `greed ctl`, `greed mcp` and other programs talk to
//! a running editor.
//!
//! A connection sends JSON-RPC 2.0 requests, one per line, and gets one
//! response line per request. The first request must be
//! `{"method": "auth", "params": {"token": ...}}` with the session's token,
//! which is in a file only the user can read. Everything after that goes to
//! the editor thread as a [`Request`]; plugins decide what the methods mean.

use std::ffi::OsString;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};
use std::time::Duration;

use crossbeam_channel::{Receiver, RecvTimeoutError, Sender};
use serde_json::{Value, json};

/// The version of what attached clients and sessions send each other:
/// input, frames and deltas. It goes up when a change would break an older
/// client or session; new optional fields don't need it, since fields a
/// side doesn't know are ignored. Clients say which protocol they speak
/// when they attach, and a session refuses one that doesn't match.
pub const PROTOCOL: u32 = 9;

/// The longest line a session reads from a connection, in bytes: room for a
/// big paste, short of letting anything that can reach the socket fill the
/// memory with one endless line. A longer one ends the connection.
pub const LINE_LIMIT: u64 = 64 << 20;

/// Reads a line of at most [`LINE_LIMIT`] bytes, with its line break, onto
/// the end of `line`; the bytes read, 0 at the end.
pub(crate) fn read_line_within(reader: &mut impl BufRead, line: &mut Vec<u8>) -> io::Result<usize> {
    let read = reader.take(LINE_LIMIT + 1).read_until(b'\n', line)?;
    if read as u64 > LINE_LIMIT {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "a line longer than a session reads",
        ));
    }
    Ok(read)
}

/// Set in the environment of a session `greed ssh` started, through
/// `greed bridge`.
pub const REMOTE_ENV: &str = "GREED_SSH_SESSION";

/// What each side says about itself when a client attaches: the protocol it
/// speaks and the greed version.
pub fn handshake() -> Value {
    json!({ "protocol": PROTOCOL, "version": env!("CARGO_PKG_VERSION") })
}

/// What a client of `kind` ("tui", "gui") asks to attach with: the
/// handshake, and who it is, `kind@host`, so it gets its cursors, focus and
/// mode back when it comes back.
pub fn attach_params(kind: &str) -> Value {
    let host = gethostname::gethostname().to_string_lossy().into_owned();
    let mut params = handshake();
    params["client"] = json!({ "kind": kind, "name": format!("{kind}@{host}") });
    params
}

/// How to start over with the greed installed now when the session `name`
/// runs another version, as happens after an upgrade while it ran.
fn start_over(name: &str) -> String {
    format!(
        "if greed was upgraded while the session ran, quit it with `greed ctl quit {name}` \
         and start greed again"
    )
}

/// Why a client of greed `version` speaking protocol `theirs` can't attach
/// to the session `name`.
fn mismatch(name: &str, theirs: Option<u64>, version: Option<&str>) -> String {
    let client = match (version, theirs) {
        (Some(version), Some(protocol)) => format!("greed {version} (protocol {protocol})"),
        (None, Some(protocol)) => format!("protocol {protocol}"),
        _ => "an older greed".to_owned(),
    };
    format!(
        "the session {name} runs greed {} (protocol {PROTOCOL}) and this client is {client}, \
         and both need the same; {}",
        env!("CARGO_PKG_VERSION"),
        start_over(name)
    )
}

/// What to show when the session `session` refused to attach because it
/// speaks another protocol, saying `said`. An older session's reason
/// doesn't say how to go on, so this adds it.
pub fn refused(session: Option<&str>, said: &str) -> String {
    if !said.contains("protocol") || said.contains("greed ctl quit") {
        return said.to_owned();
    }
    format!(
        "{said}\nthis is greed {} (protocol {PROTOCOL}); {}",
        env!("CARGO_PKG_VERSION"),
        start_over(session.unwrap_or("NAME"))
    )
}

/// A request from a connection, for the editor thread to answer through
/// [`Request::respond`].
#[derive(Debug)]
pub struct Request {
    /// Who asked: "shell" for `greed ctl`, "socket" for other connections to
    /// the session socket (like `greed mcp`), "ide" for Claude Code's
    /// IDE connection.
    pub client: &'static str,
    /// The session socket connection it came on, to send notifications to
    /// later; `None` for Claude Code's IDE connection.
    pub connection: Option<Notifier>,
    pub method: String,
    pub params: Value,
    pub(crate) reply: Sender<Result<Value, String>>,
}

/// A connection to the session socket, for sending it notifications, like
/// MCP's `notifications/tools/list_changed`, outside any request. It lets
/// go of the connection once that closes.
#[derive(Debug, Clone)]
pub struct Notifier {
    /// Unique among the session's connections.
    pub id: u64,
    writer: Weak<Mutex<UnixStream>>,
}

impl Notifier {
    /// Sends a JSON-RPC notification of `method` with `params` (left out
    /// when null). False if the connection has closed.
    pub fn notify(&self, method: &str, params: &Value) -> bool {
        let Some(writer) = self.writer.upgrade() else {
            return false;
        };
        let mut message = json!({ "jsonrpc": "2.0", "method": method });
        if !params.is_null() {
            message["params"] = params.clone();
        }
        // A client that stops reading mustn't hold up the editor thread,
        // which sends these; answers, sent from the connection's own
        // thread, can wait as long as they need.
        let mut writer = lock(&writer);
        let _ = writer.set_write_timeout(Some(NOTIFY_TIMEOUT));
        let sent = writeln!(writer, "{message}").is_ok();
        let _ = writer.set_write_timeout(None);
        sent
    }

    /// Whether the connection is still open.
    pub fn is_open(&self) -> bool {
        self.writer.strong_count() > 0
    }
}

static NEXT_CONNECTION: AtomicU64 = AtomicU64::new(1);

/// Numbers the temporary names sockets are bound under in [`listen`].
static NEXT_SOCKET: AtomicU64 = AtomicU64::new(0);

/// How long a write to a connection may wait for it to read.
const NOTIFY_TIMEOUT: Duration = Duration::from_secs(1);

/// A connection's shared writer, held for one whole line.
fn lock(writer: &Mutex<UnixStream>) -> MutexGuard<'_, UnixStream> {
    writer.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Request {
    /// Sends the answer back to the connection that asked.
    pub fn respond(self, answer: Result<Value, String>) {
        // The connection may have gone away; then nobody wants the answer.
        let _ = self.reply.send(answer);
    }
}

/// The longest socket path that fits in a Unix socket address.
const MAX_SOCKET_PATH: usize = 100;

/// The folder [`use_sessions_dir`] set, if any.
static SESSIONS_DIR: Mutex<Option<PathBuf>> = Mutex::new(None);

/// Keeps this process's sessions in `dir` from now on, instead of the
/// user's sessions folder. Tests use it so they never touch the sessions
/// the user is running, or another checkout's tests. Programs this process
/// starts don't inherit it; give those `XDG_RUNTIME_DIR` instead.
pub fn use_sessions_dir(dir: PathBuf) {
    *SESSIONS_DIR.lock().unwrap_or_else(PoisonError::into_inner) = Some(dir);
}

/// Where sessions keep their sockets: `greed` in the runtime directory, or a
/// folder for the user in the temporary directory, unless
/// [`use_sessions_dir`] said otherwise.
pub fn sessions_dir() -> PathBuf {
    if let Some(dir) = &*SESSIONS_DIR.lock().unwrap_or_else(PoisonError::into_inner) {
        return dir.clone();
    }
    // GREED_RUN_DIR, or a profile's own.
    if let Some(dir) = crate::dirs::sessions() {
        return dir;
    }
    runtime_dir().map_or_else(
        || {
            let user = std::env::var("USER").unwrap_or_else(|_| "user".to_owned());
            socket_temp_dir().join(format!("greed-{user}"))
        },
        |dir| dir.join("greed"),
    )
}

/// A temporary folder short enough to keep sockets in. macOS's own
/// (`/var/folders/…/T/`) leaves too little of the 104 bytes a socket's path
/// may have, so there it's `/tmp`, as tmux has it; a sessions folder made
/// there is checked to be yours and closed to others like any other.
pub fn socket_temp_dir() -> PathBuf {
    if cfg!(target_os = "macos") {
        PathBuf::from("/tmp")
    } else {
        std::env::temp_dir()
    }
}

/// The user's runtime directory: `$XDG_RUNTIME_DIR`, or `/run/user/<uid>`
/// when it isn't set but that is there and theirs, as with commands run
/// over ssh on some systems. Sessions started then get it too, so their
/// sockets and their terminals' programs find the same one a login would.
pub fn runtime_dir() -> Option<PathBuf> {
    pick_runtime_dir(
        std::env::var_os("XDG_RUNTIME_DIR"),
        Some(nix::unistd::getuid().as_raw()),
        Path::new("/run/user"),
    )
}

fn pick_runtime_dir(set: Option<OsString>, uid: Option<u32>, run_user: &Path) -> Option<PathBuf> {
    if let Some(dir) = set.filter(|dir| !dir.is_empty()) {
        return Some(dir.into());
    }
    let uid = uid?;
    let dir = run_user.join(uid.to_string());
    let meta = std::fs::metadata(&dir).ok()?;
    (meta.is_dir() && meta.uid() == uid).then_some(dir)
}

/// Fails unless `dir`, a sessions folder, is a folder only you can use: not
/// a link, yours, and no one else can write in it. In a shared temporary
/// folder, another user could make it first and catch sessions and tokens.
pub fn check_sessions_dir(dir: &Path) -> io::Result<()> {
    let meta = std::fs::symlink_metadata(dir)?;
    let yours = meta.uid() == nix::unistd::getuid().as_raw();
    if !meta.is_dir() || !yours || meta.mode() & 0o022 != 0 {
        return Err(io::Error::other(format!(
            "the sessions folder {} isn't a folder only you can use; remove it, or set \
             GREED_RUN_DIR to one that is",
            dir.display()
        )));
    }
    Ok(())
}

/// The socket and token files of the session called `name`.
pub fn session_files(name: &str) -> (PathBuf, PathBuf) {
    let dir = sessions_dir();
    (
        dir.join(format!("{name}.sock")),
        dir.join(format!("{name}.token")),
    )
}

/// A listening session socket. Dropping it removes the socket and token
/// files.
pub struct Session {
    pub name: String,
    pub socket: PathBuf,
    token_file: PathBuf,
    requests: Receiver<Request>,
    sender: Sender<Request>,
    attachments: Receiver<Attachment>,
    closed: Receiver<u64>,
}

impl Session {
    /// Requests from every connection, in the order they arrive.
    pub fn requests(&self) -> &Receiver<Request> {
        &self.requests
    }

    /// Where other transports, like the IDE connection, send their requests
    /// so they arrive with the socket's.
    pub fn sender(&self) -> &Sender<Request> {
        &self.sender
    }

    /// Connections that asked to attach, newest last.
    pub fn attachments(&self) -> &Receiver<Attachment> {
        &self.attachments
    }

    /// The ids of connections that closed, each sent after every request
    /// that came on it. A connection handed over to attach doesn't close.
    pub fn closed(&self) -> &Receiver<u64> {
        &self.closed
    }
}

/// Writes down which project the session at `socket` is for, so `greed` in
/// that project finds it and the switcher can list it.
fn describe(socket: &Path, root: &Path) -> io::Result<()> {
    let info = json!({ "pid": std::process::id(), "root": root });
    std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(socket.with_extension("json"))?
        .write_all(info.to_string().as_bytes())
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.socket);
        let _ = std::fs::remove_file(&self.token_file);
        let _ = std::fs::remove_file(self.socket.with_extension("json"));
    }
}

/// A running session, as `greed ls` and the switcher see it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionInfo {
    pub name: String,
    /// The project it was started for, if it said.
    pub root: Option<PathBuf>,
}

/// The sessions running on this machine, by name.
pub fn sessions() -> io::Result<Vec<SessionInfo>> {
    let entries = match std::fs::read_dir(sessions_dir()) {
        Ok(entries) => entries,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(err) => return Err(err),
    };
    let mut found: Vec<SessionInfo> = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension().is_some_and(|ext| ext == "sock") && UnixStream::connect(path).is_ok()
        })
        .filter_map(|path| {
            let name = path.file_stem()?.to_string_lossy().into_owned();
            let root = std::fs::read_to_string(path.with_extension("json"))
                .ok()
                .and_then(|text| serde_json::from_str::<Value>(&text).ok())
                .and_then(|info| info["root"].as_str().map(PathBuf::from));
            Some(SessionInfo { name, root })
        })
        .collect();
    found.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(found)
}

/// Starts listening as the session called `name`, writing a fresh token
/// next to the socket, and which project it's for (`root`) before anyone can
/// find it.
pub fn listen(name: &str, root: Option<&Path>) -> io::Result<Session> {
    let dir = sessions_dir();
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&dir)?;
    check_sessions_dir(&dir)?;
    // Editors that crashed leave sockets behind, which would also stop a
    // new one with the same name from taking their place.
    prune(&dir);
    let (socket, token_file) = session_files(name);
    // Unix socket paths have to fit in about a hundred bytes.
    if socket.as_os_str().len() > MAX_SOCKET_PATH {
        return Err(io::Error::other(format!(
            "the session's socket path is too long: {}; use a shorter name or set \
             GREED_RUN_DIR to a shorter folder",
            socket.display()
        )));
    }
    // A live session already there keeps its description; linking fails below.
    if let Some(root) = root
        && !socket.exists()
    {
        describe(&socket, root)?;
    }
    // Bound under a temporary name and linked into place once it listens:
    // between binding and listening a socket refuses connections, and
    // another session starting would prune it as one a crash left.
    let bound = dir.join(format!(
        ".new-{}-{}",
        std::process::id(),
        NEXT_SOCKET.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_file(&bound);
    // The token is written beside it and renamed into place once the socket
    // is ours, so a client never reads it half-written and a live session's
    // is never overwritten. It appears just after the socket does.
    let token = new_token()?;
    let new_token_file = bound.with_extension("token");
    std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&new_token_file)?
        .write_all(token.as_bytes())?;
    let listener = UnixListener::bind(&bound)?;
    let linked = std::fs::set_permissions(&bound, std::fs::Permissions::from_mode(0o600))
        .and_then(|()| std::fs::hard_link(&bound, &socket));
    let _ = std::fs::remove_file(&bound);
    if let Err(err) = linked {
        let _ = std::fs::remove_file(&new_token_file);
        return Err(match err.kind() {
            io::ErrorKind::AlreadyExists => io::Error::new(
                io::ErrorKind::AddrInUse,
                format!("a session called {name} is already running"),
            ),
            _ => err,
        });
    }
    std::fs::rename(&new_token_file, &token_file)?;

    let (sender, requests) = crossbeam_channel::unbounded();
    let incoming = sender.clone();
    let (attach, attachments) = crossbeam_channel::unbounded();
    let (gone, closed) = crossbeam_channel::unbounded();
    let session: Arc<str> = name.into();
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let sender = incoming.clone();
            let attach = attach.clone();
            let gone = gone.clone();
            let token = token.clone();
            let session = session.clone();
            // With no thread to spare, the connection is dropped.
            let _ = std::thread::Builder::new().spawn(move || {
                serve_connection(stream, &session, &token, &sender, &attach, &gone);
            });
        }
    });
    Ok(Session {
        name: name.to_owned(),
        socket,
        token_file,
        requests,
        sender,
        attachments,
        closed,
    })
}

/// Removes what sessions that are no longer running left behind: sockets
/// nothing answers on, with their tokens and logs.
fn prune(dir: &Path) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for path in entries.flatten().map(|entry| entry.path()) {
        if path.extension().is_some_and(|ext| ext == "sock") && UnixStream::connect(&path).is_err()
        {
            for ext in ["sock", "token", "log", "json"] {
                let _ = std::fs::remove_file(path.with_extension(ext));
            }
        }
    }
}

/// 32 random hex digits from the system's random source.
pub(crate) fn new_token() -> io::Result<String> {
    let mut bytes = [0u8; 16];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    Ok(crate::luau::hash::hex(&bytes))
}

/// A connection that asked to attach, for the server to send frames to and
/// read input from: one JSON message per line each way.
pub struct Attachment {
    pub reader: BufReader<UnixStream>,
    pub writer: UnixStream,
    /// A file or folder the client asked to open, e.g. from `greed FILE`.
    pub open: Option<String>,
    /// Whether the client asked for a terminal, e.g. `greed ssh HOST
    /// --terminal`.
    pub terminal: bool,
    /// Whether it came over `greed ssh`, through `greed bridge`.
    pub remote: bool,
    /// What sort of client it is: "tui" or "gui".
    pub kind: String,
    /// Who it is, like "tui@laptop"; a client coming back by the same name
    /// gets its state back.
    pub name: String,
    /// "follow" or "independent", if it asked to be laid out one way: a
    /// client coming back otherwise keeps the layout it had, and a new one
    /// follows.
    pub layout: Option<crate::ClientLayout>,
    /// Whether it asked to be the only client, letting the others go.
    pub takeover: bool,
}

impl Attachment {
    /// The attachment `params` of an "attach" request ask for, over
    /// `reader` and `writer`. A client that doesn't say what it is counts
    /// as a terminal.
    fn asked(reader: BufReader<UnixStream>, writer: UnixStream, params: &Value) -> Self {
        let client = &params["client"];
        let kind = client["kind"].as_str().unwrap_or("tui").to_owned();
        let name = client["name"]
            .as_str()
            .map_or_else(|| kind.clone(), str::to_owned);
        Self {
            reader,
            writer,
            open: params["open"].as_str().map(str::to_owned),
            terminal: params["terminal"].as_bool() == Some(true),
            remote: params["remote"].as_bool() == Some(true),
            kind,
            name,
            layout: params["layout"]
                .as_str()
                .and_then(crate::ClientLayout::parse),
            takeover: params["takeover"].as_bool() == Some(true),
        }
    }
}

/// Sends a connection's id to `closed` when dropped, unless it was handed
/// over to attach.
struct Closing<'a> {
    id: u64,
    closed: &'a Sender<u64>,
    attached: bool,
}

impl Drop for Closing<'_> {
    fn drop(&mut self) {
        if !self.attached {
            let _ = self.closed.send(self.id);
        }
    }
}

/// Answers one connection's requests until it closes, then says so on
/// `closed`, or hands it to the server as an [`Attachment`] once it asks to
/// attach.
fn serve_connection(
    stream: UnixStream,
    session: &str,
    token: &str,
    requests: &Sender<Request>,
    attachments: &Sender<Attachment>,
    closed: &Sender<u64>,
) {
    let Ok(writer) = stream.try_clone() else {
        return;
    };
    // Answers and notifications from the editor share the connection, a
    // line at a time.
    let Ok(shared) = stream.try_clone() else {
        return;
    };
    let shared = Arc::new(Mutex::new(shared));
    let notifier = Notifier {
        id: NEXT_CONNECTION.fetch_add(1, Ordering::Relaxed),
        writer: Arc::downgrade(&shared),
    };
    let mut closing = Closing {
        id: notifier.id,
        closed,
        attached: false,
    };
    let mut reader = BufReader::new(stream);
    let mut authed = false;
    // Whether the connection said at its first auth that it's a shell's.
    let mut shell: Option<bool> = None;
    let mut line = Vec::new();
    loop {
        line.clear();
        if !matches!(read_line_within(&mut reader, &mut line), Ok(n) if n > 0) {
            return;
        }
        if line.trim_ascii().is_empty() {
            continue;
        }
        let response = match serde_json::from_slice::<Value>(&line) {
            Ok(message) if authed && message["method"] == "attach" => {
                let theirs = message["params"]["protocol"].as_u64();
                if theirs != Some(u64::from(PROTOCOL)) {
                    let version = message["params"]["version"].as_str();
                    let why = mismatch(session, theirs, version);
                    let refused = error_response(&message["id"], -32001, &why);
                    let _ = writeln!(lock(&shared), "{refused}");
                    return;
                }
                let ok = json!({ "jsonrpc": "2.0", "id": message["id"], "result": handshake() });
                if writeln!(lock(&shared), "{ok}").is_ok() {
                    closing.attached = true;
                    let _ = attachments.send(Attachment::asked(reader, writer, &message["params"]));
                }
                return;
            }
            Ok(message) => answer(
                &message,
                token,
                &mut authed,
                &mut shell,
                requests,
                &notifier,
                &mut reader,
            ),
            Err(err) => Some(error_response(&Value::Null, -32700, &err.to_string())),
        };
        let Some(response) = response else { continue };
        if writeln!(lock(&shared), "{response}").is_err() {
            return;
        }
    }
}

/// The response to one message, or `None` for a notification. A
/// connection that says `"shell": true` at its first auth is a shell's,
/// like `greed ctl`'s, and its requests come from "shell"; one that later
/// sends more, like what `greed mcp` passes on from an agent, can't become
/// one.
fn answer(
    message: &Value,
    token: &str,
    authed: &mut bool,
    shell: &mut Option<bool>,
    requests: &Sender<Request>,
    notifier: &Notifier,
    reader: &mut BufReader<UnixStream>,
) -> Option<Value> {
    let id = message.get("id").cloned();
    let method = message.get("method").and_then(Value::as_str).unwrap_or("");
    let params = message.get("params").cloned().unwrap_or(Value::Null);
    let respond = |result: Result<Value, String>| {
        let id = id.clone()?;
        Some(match result {
            Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
            Err(message) => error_response(&id, -32000, &message),
        })
    };
    if method == "auth" {
        // Settled by the first auth, right or wrong, so a connection can't
        // fail once and come back as a shell's.
        if shell.is_none() {
            *shell = Some(params.get("shell").and_then(Value::as_bool) == Some(true));
        }
        *authed = params.get("token").and_then(Value::as_str) == Some(token);
        return respond(if *authed {
            Ok(Value::Bool(true))
        } else {
            Err("wrong token".to_owned())
        });
    }
    if !*authed {
        return respond(Err("send auth with the session's token first".to_owned()));
    }
    let (reply, answered) = crossbeam_channel::bounded(1);
    let request = Request {
        client: if *shell == Some(true) {
            "shell"
        } else {
            "socket"
        },
        connection: Some(notifier.clone()),
        method: method.to_owned(),
        params,
        reply,
    };
    if requests.send(request).is_err() {
        return respond(Err("the editor has stopped".to_owned()));
    }
    // A request can wait long, e.g. for the user to review an edit; a
    // client that gives up meanwhile closes the connection.
    let result = loop {
        match answered.recv_timeout(HANG_UP_CHECK) {
            Ok(result) => break result,
            Err(RecvTimeoutError::Disconnected) => {
                break Err("the editor dropped the request".to_owned());
            }
            Err(RecvTimeoutError::Timeout) if hung_up(reader) => return None,
            Err(RecvTimeoutError::Timeout) => {}
        }
    };
    respond(result)
}

/// How often a connection waiting for an answer looks whether the client
/// hung up.
const HANG_UP_CHECK: Duration = Duration::from_millis(200);

/// Whether the client on the other end of `reader` hung up. Anything it
/// sent meanwhile stays in `reader` to be read.
fn hung_up(reader: &mut BufReader<UnixStream>) -> bool {
    if !reader.buffer().is_empty() {
        return false;
    }
    // macOS refuses the timeout once the other end has closed, which is the
    // answer; an open socket always takes it.
    if reader
        .get_ref()
        .set_read_timeout(Some(Duration::from_millis(1)))
        .is_err()
    {
        return true;
    }
    let gone = match reader.fill_buf() {
        Ok(sent) => sent.is_empty(),
        Err(err) => !matches!(
            err.kind(),
            io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut | io::ErrorKind::Interrupted
        ),
    };
    let _ = reader.get_ref().set_read_timeout(None);
    gone
}

fn error_response(id: &Value, code: i64, message: &str) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } })
}

/// A connection to a session, for clients like `greed ctl`.
pub struct Client {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next_id: u64,
    /// Notifications that came while waiting for answers.
    notifications: Vec<Value>,
    /// The session's name, from its socket's.
    session: Option<String>,
}

impl Client {
    /// Connects to the socket at `socket` and authenticates with `token`.
    pub fn connect(socket: &Path, token: &str) -> io::Result<Self> {
        Self::connect_as(socket, token, false)
    }

    /// Like [`Client::connect`], saying with `shell` that it's a shell's
    /// connection, like `greed ctl`'s: whoever runs it can run anything
    /// already, so the editor treats its requests as yours.
    pub fn connect_as(socket: &Path, token: &str, shell: bool) -> io::Result<Self> {
        let writer = UnixStream::connect(socket)?;
        let reader = BufReader::new(writer.try_clone()?);
        let mut client = Self {
            reader,
            writer,
            next_id: 0,
            notifications: Vec::new(),
            session: socket
                .file_stem()
                .map(|name| name.to_string_lossy().into_owned()),
        };
        client
            .call("auth", &json!({ "token": token, "shell": shell }))?
            .map_err(io::Error::other)?;
        Ok(client)
    }

    /// Sends a request and waits for its answer: the result, or the error
    /// message.
    pub fn call(&mut self, method: &str, params: &Value) -> io::Result<Result<Value, String>> {
        self.next_id += 1;
        let request =
            json!({ "jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params });
        writeln!(self.writer, "{request}")?;
        let response = loop {
            let mut line = String::new();
            if self.reader.read_line(&mut line)? == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "the session closed the connection",
                ));
            }
            let message: Value = serde_json::from_str(&line).map_err(io::Error::other)?;
            if message.get("id").is_some() {
                break message;
            }
            self.notifications.push(message);
        };
        Ok(match response.get("error") {
            Some(error) => Err(error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("unknown error")
                .to_owned()),
            None => Ok(response.get("result").cloned().unwrap_or(Value::Null)),
        })
    }

    /// The notifications the session sent since last asked, oldest first.
    pub fn take_notifications(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.notifications)
    }

    /// Attaches to the editor: from now on the connection carries input
    /// one way and frames the other, one JSON message per line.
    pub fn attach(self) -> io::Result<Attachment> {
        self.attach_opening("tui", None, false)
    }

    /// Like [`Client::attach`] as a client of `kind` ("tui", "gui"), asking
    /// the session to open `path` too, and with `terminal`, a terminal.
    pub fn attach_opening(
        self,
        kind: &str,
        path: Option<&Path>,
        terminal: bool,
    ) -> io::Result<Attachment> {
        let mut params = attach_params(kind);
        if let Some(path) = path {
            params["open"] = Value::from(path.to_string_lossy());
        }
        if terminal {
            params["terminal"] = Value::Bool(true);
        }
        self.attach_with(&params)
    }

    /// Attaches asking with `params` as they are: [`attach_params`] and
    /// whatever else, like "open", "terminal" or "takeover".
    pub fn attach_with(mut self, params: &Value) -> io::Result<Attachment> {
        self.call("attach", params)?
            .map_err(|said| io::Error::other(refused(self.session.as_deref(), &said)))?;
        Ok(Attachment::asked(self.reader, self.writer, params))
    }

    /// Copies JSON-RPC lines from `input` to the session, and the session's
    /// answers to `output`, until the session closes its end: after `input`
    /// ends and it has answered what's pending, or when it goes away. This
    /// is all a bridge like `greed mcp` needs: plugins speak the protocol.
    ///
    /// When the session goes first, the thread copying `input` is left
    /// waiting on it; the process exiting ends it.
    pub fn pipe(
        self,
        input: impl BufRead + Send + 'static,
        mut output: impl Write,
    ) -> io::Result<()> {
        let Client {
            mut reader,
            mut writer,
            ..
        } = self;
        std::thread::spawn(move || -> io::Result<()> {
            for line in input.lines() {
                writeln!(writer, "{}", line?)?;
            }
            writer.shutdown(std::net::Shutdown::Write)
        });
        let mut line = String::new();
        while reader.read_line(&mut line)? > 0 {
            output.write_all(line.as_bytes())?;
            output.flush()?;
            line.clear();
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_runtime_dir_is_the_variable_or_the_users_own_folder_in_run_user() {
        let run_user = std::env::temp_dir().join(format!("greed-run-user-{}", std::process::id()));
        let uid = nix::unistd::getuid().as_raw();
        std::fs::create_dir_all(run_user.join(uid.to_string())).unwrap();
        let set = Some(OsString::from("/somewhere"));
        assert_eq!(
            pick_runtime_dir(set, Some(uid), &run_user),
            Some(PathBuf::from("/somewhere"))
        );
        assert_eq!(
            pick_runtime_dir(None, Some(uid), &run_user),
            Some(run_user.join(uid.to_string())),
            "unset: the user's folder, as a login would have"
        );
        assert_eq!(
            pick_runtime_dir(Some(OsString::new()), Some(uid), &run_user),
            Some(run_user.join(uid.to_string())),
            "empty counts as unset"
        );
        assert_eq!(
            pick_runtime_dir(None, Some(uid + 1), &run_user),
            None,
            "no folder for that user"
        );
        assert_eq!(
            pick_runtime_dir(Some(OsString::from("/somewhere")), None, &run_user),
            Some(PathBuf::from("/somewhere")),
            "without a uid (no /proc) the variable still counts"
        );
        assert_eq!(pick_runtime_dir(None, None, &run_user), None);
        std::fs::remove_dir_all(&run_user).unwrap();
    }
}
