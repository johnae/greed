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
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use crossbeam_channel::{Receiver, Sender, TrySendError};
use serde_json::{Value, json};

/// The version of what attached clients and sessions send each other:
/// input, frames and deltas. It goes up when a change would break an older
/// client or session; new optional fields don't need it, since fields a
/// side doesn't know are ignored. Clients say which protocol they speak
/// when they attach, and a session refuses one that doesn't match.
pub const PROTOCOL: u32 = 15;

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

/// How often each side of an attachment with a heartbeat says it's there
/// (`Ping`) when it has nothing else to send.
pub const HEARTBEAT: Duration = Duration::from_secs(5);

/// How long without hearing anything an attachment with a heartbeat waits
/// before taking the other side for gone: three beats missed.
pub const HEARTBEAT_LOST: Duration = Duration::from_secs(15);

/// The heartbeat an attach request asks for with `heartbeat`: `true` for
/// [`HEARTBEAT`], or a number of milliseconds.
fn heartbeat_of(asked: &Value) -> Option<Duration> {
    match asked {
        Value::Bool(true) => Some(HEARTBEAT),
        Value::Number(ms) => ms.as_u64().map(Duration::from_millis),
        _ => None,
    }
}

/// Set in the environment of a session `greed ssh` started, through
/// `greed bridge`.
pub const REMOTE_ENV: &str = "GREED_SSH_SESSION";

/// Which build of greed this is, as the program set it with [`set_build`]
/// ("dev" until then): a hash of the sources it was built from, so two
/// builds of one version tell each other apart.
static BUILD: std::sync::OnceLock<String> = std::sync::OnceLock::new();

/// Says which build this is, once, as the program starts.
pub fn set_build(build: &str) {
    let _ = BUILD.set(build.to_owned());
}

/// Which build this is (see [`set_build`]).
pub fn build() -> &'static str {
    BUILD.get().map_or("dev", String::as_str)
}

/// Whether this greed was started with `--fresh`: a session it starts
/// begins without what it had open before.
static FRESH: AtomicBool = AtomicBool::new(false);

/// Says this greed was started with `--fresh`, as the program starts.
pub fn set_fresh() {
    FRESH.store(true, Ordering::Relaxed);
}

/// Whether this greed was started with `--fresh` (see [`set_fresh`]).
pub fn fresh() -> bool {
    FRESH.load(Ordering::Relaxed)
}

/// Whether a session this greed starts restores what it had open even
/// after it was quit, as `--restore` and an upgrade ask.
static RESTORE: AtomicBool = AtomicBool::new(false);

/// Says a session this greed starts is to be restored even after a quit.
pub fn set_restore() {
    RESTORE.store(true, Ordering::Relaxed);
}

/// Whether a session this greed starts is to be restored even after a
/// quit (see [`set_restore`]).
pub fn restore() -> bool {
    RESTORE.load(Ordering::Relaxed)
}

/// What each side says about itself when a client attaches: the protocol it
/// speaks, the greed version and which build of it.
pub fn handshake() -> Value {
    json!({ "protocol": PROTOCOL, "version": env!("CARGO_PKG_VERSION"), "build": build() })
}

/// What a client asks a session to show as it attaches, beside a file: a
/// terminal (`greed --terminal`) or a greed shell (`greed --shell`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Opening {
    #[default]
    Nothing,
    Terminal,
    Shell,
}

impl Opening {
    /// What an attach request's `params` ask for.
    fn asked(params: &Value) -> Self {
        if params["terminal"].as_bool() == Some(true) {
            Self::Terminal
        } else if params["shell"].as_bool() == Some(true) {
            Self::Shell
        } else {
            Self::Nothing
        }
    }

    /// Says so in the attach request's `params`.
    pub fn ask(self, params: &mut Value) {
        match self {
            Self::Terminal => params["terminal"] = Value::Bool(true),
            Self::Shell => params["shell"] = Value::Bool(true),
            Self::Nothing => {}
        }
    }
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

/// A session's refusal to let a client attach, with what it said. When it's
/// because the session runs another version of greed, which this one can't
/// show, `other_version` is set, with that version if it said.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refused {
    pub session: Option<String>,
    pub said: String,
    pub other_version: bool,
    pub version: Option<String>,
}

impl Refused {
    /// The refusal of the session `session` (if known) that said `said`.
    #[must_use]
    pub fn new(session: Option<&str>, said: &str) -> Self {
        // "the session NAME runs greed VERSION (protocol N) and ..."
        let after = |marker: &str| {
            said.split_once(marker)
                .and_then(|(_, rest)| rest.split_whitespace().next())
                .map(str::to_owned)
        };
        Self {
            session: session.map(str::to_owned).or_else(|| after("the session ")),
            said: said.to_owned(),
            other_version: said.contains("protocol"),
            version: after(" runs greed "),
        }
    }
}

impl std::fmt::Display for Refused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&refused(self.session.as_deref(), &self.said))
    }
}

impl std::error::Error for Refused {}

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
    pub(crate) reply: Reply,
}

/// Where a request's answer goes.
#[derive(Debug)]
pub(crate) enum Reply {
    /// Back to whoever waits on the channel, like the IDE connection.
    Channel(Sender<Result<Value, String>>),
    /// Into the outbox of the session socket connection it came on, in the
    /// order the editor answers and notifies.
    Outbox(Owed),
}

impl Request {
    /// Sends the answer back to the connection that asked.
    pub fn respond(self, answer: Result<Value, String>) {
        // The connection may have gone away; then nobody wants the answer.
        match self.reply {
            Reply::Channel(reply) => {
                let _ = reply.send(answer);
            }
            Reply::Outbox(mut owed) => owed.answer(answer),
        }
    }
}

/// A socket request's answer, owed to its connection: the response to
/// request `id` (none for a notification, which gets none). One dropped
/// without an answer, as when the editor gives it up, says so.
#[derive(Debug)]
pub(crate) struct Owed {
    id: Option<Value>,
    outbox: Outbox,
}

impl Owed {
    /// Owes `outbox` the answer to request `id`, counting it while it does.
    fn new(id: Option<Value>, outbox: Outbox) -> Self {
        if id.is_some() {
            outbox.owed.fetch_add(1, Ordering::Relaxed);
        }
        Self { id, outbox }
    }

    fn answer(&mut self, answer: Result<Value, String>) {
        if let Some(id) = self.id.take() {
            self.outbox.push(response(&id, answer).to_string());
            self.outbox.owed.fetch_sub(1, Ordering::Relaxed);
        }
    }
}

impl Drop for Owed {
    fn drop(&mut self) {
        self.answer(Err("the editor dropped the request".to_owned()));
    }
}

/// The JSON-RPC response to request `id`.
fn response(id: &Value, answer: Result<Value, String>) -> Value {
    match answer {
        Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
        Err(message) => error_response(id, -32000, &message),
    }
}

/// A connection's outgoing lines, written in the order they're put in by a
/// thread of the connection's own, so neither the editor thread (which
/// answers and notifies) nor the connection's reader waits on a client
/// that's slow to read. One that falls more than [`OUTBOX_LINES`] behind is
/// cut off: it hears the connection close, and starts again.
#[derive(Debug, Clone)]
pub(crate) struct Outbox {
    lines: Sender<Option<String>>,
    /// Requests passed to the editor and not answered yet.
    owed: Arc<AtomicU64>,
    open: Arc<AtomicBool>,
    stream: Arc<UnixStream>,
}

/// How many lines a connection's outbox holds before it's cut off.
const OUTBOX_LINES: usize = 10_000;

impl Outbox {
    /// An outbox for `stream`, and the thread writing it, which ends once
    /// the connection closes.
    fn start(stream: UnixStream) -> io::Result<(Self, std::thread::JoinHandle<()>)> {
        let (lines, queued) = crossbeam_channel::bounded(OUTBOX_LINES);
        let open = Arc::new(AtomicBool::new(true));
        let stream = Arc::new(stream);
        let outbox = Outbox {
            lines,
            owed: Arc::new(AtomicU64::new(0)),
            open: open.clone(),
            stream: stream.clone(),
        };
        let writer = std::thread::Builder::new().spawn(move || {
            let mut out = &*stream;
            // Lines until the stop `close` puts in, or every sender gone.
            while let Ok(Some(line)) = queued.recv() {
                if writeln!(out, "{line}").is_err() {
                    open.store(false, Ordering::Relaxed);
                    return;
                }
            }
        })?;
        Ok((outbox, writer))
    }

    /// Puts `line` out after what's there; false if the connection has
    /// closed, or fell so far behind it was cut off.
    fn push(&self, line: String) -> bool {
        if !self.open.load(Ordering::Relaxed) {
            return false;
        }
        match self.lines.try_send(Some(line)) {
            Ok(()) => true,
            Err(TrySendError::Full(_)) => {
                self.close();
                let _ = self.stream.shutdown(std::net::Shutdown::Both);
                false
            }
            Err(TrySendError::Disconnected(_)) => false,
        }
    }

    /// Once the client has closed its side, waits for the answers to what
    /// it asked before (as `greed mcp` reads them after its input ends),
    /// but not past [`FINISHING`]: one that went away altogether gets no
    /// more, and its connection closes.
    fn finish_owed(&self) {
        let started = std::time::Instant::now();
        while self.owed.load(Ordering::Relaxed) > 0
            && self.open.load(Ordering::Relaxed)
            && started.elapsed() < FINISHING
        {
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    /// Stops taking lines; what's in already is still written.
    fn close(&self) {
        self.open.store(false, Ordering::Relaxed);
        // Wakes the writer to finish as soon as what's queued is out.
        let _ = self.lines.try_send(None);
    }
}

/// How long a connection whose client closed its side still waits for the
/// answers it's owed.
const FINISHING: Duration = Duration::from_secs(2);

/// A connection to the session socket, for sending it notifications, like
/// MCP's `notifications/tools/list_changed`, outside any request. It lets
/// go of the connection once that closes.
#[derive(Debug, Clone)]
pub struct Notifier {
    /// Unique among the session's connections.
    pub id: u64,
    outbox: Outbox,
}

impl Notifier {
    /// Sends a JSON-RPC notification of `method` with `params` (left out
    /// when null), after the answers and notifications sent before it.
    /// False if the connection has closed.
    pub fn notify(&self, method: &str, params: &Value) -> bool {
        let mut message = json!({ "jsonrpc": "2.0", "method": method });
        if !params.is_null() {
            message["params"] = params.clone();
        }
        self.outbox.push(message.to_string())
    }

    /// Whether the connection is still open.
    pub fn is_open(&self) -> bool {
        self.outbox.open.load(Ordering::Relaxed)
    }
}

static NEXT_CONNECTION: AtomicU64 = AtomicU64::new(1);

/// Numbers the temporary names sockets are bound under in [`listen`].
static NEXT_SOCKET: AtomicU64 = AtomicU64::new(0);

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

/// Makes `dir`, a sessions folder, closed to others whatever the umask
/// (Ubuntu's 002 leaves new folders open to the group), then fails as
/// [`check_sessions_dir`] does. One of yours that others can write in, as
/// greed 0.3.0 made them there, is closed again rather than refused.
pub fn make_sessions_dir(dir: &Path) -> io::Result<()> {
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)?;
    let meta = std::fs::symlink_metadata(dir)?;
    if meta.is_dir() && meta.uid() == nix::unistd::getuid().as_raw() && meta.mode() & 0o022 != 0 {
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
    }
    check_sessions_dir(dir)
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
    /// The socket its programs reach your ssh agent on, once it has one.
    ssh_agent: Option<crate::ssh_agent::Listener>,
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

    /// Listens on `path` for programs' ssh agent requests, which the
    /// session passes on to a client that relays your agent (see
    /// [`crate::ssh_agent`]).
    pub fn serve_ssh_agent(&mut self, path: &Path) -> io::Result<()> {
        self.ssh_agent = Some(crate::ssh_agent::listen(path)?);
        Ok(())
    }

    /// The ssh agent requests from the session's programs; none come when
    /// it doesn't listen for them.
    pub fn ssh_agent_requests(&self) -> Receiver<crate::ssh_agent::Request> {
        self.ssh_agent
            .as_ref()
            .map_or_else(crossbeam_channel::never, |agent| agent.requests().clone())
    }
}

/// Writes down which project the session at `socket` is for, so `greed` in
/// that project finds it and the switcher can list it.
fn describe(socket: &Path, root: &Path) -> io::Result<()> {
    let greed = std::env::current_exe().ok();
    let info = json!({ "pid": std::process::id(), "root": root, "build": build(), "greed": greed });
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
    /// The build of greed it runs, if it said.
    pub build: Option<String>,
    /// Its process, and the greed it runs, if it said.
    pub pid: Option<u32>,
    pub greed: Option<PathBuf>,
}

/// How long asking another session on this machine for its status waits for
/// its answer, so one that's stuck doesn't hold up the asking.
pub const STATUS_WAIT: Duration = Duration::from_secs(2);

/// What the session `name` on this machine says of itself, as its `status`
/// tool gives it: what needs you and its agents. It's asked as an ordinary
/// client, not a shell's, so asking can't do anything there. Why not, when
/// it can't say: it's gone, its greed has no `status`, or it didn't answer
/// within `wait`.
pub fn status_of(name: &str, wait: Duration) -> Result<Value, String> {
    check_sessions_dir(&sessions_dir()).map_err(|err| err.to_string())?;
    let (socket, token_file) = session_files(name);
    let token = std::fs::read_to_string(&token_file)
        .map_err(|err| format!("can't read its token: {err}"))?;
    let mut client = Client::connect_within(&socket, token.trim(), false, Some(wait))
        .map_err(|err| err.to_string())?;
    let result = client
        .call("tools/call", &json!({ "name": "status", "arguments": {} }))
        .map_err(|err| err.to_string())??;
    let text = result["content"][0]["text"].as_str().unwrap_or_default();
    if result["isError"].as_bool() == Some(true) {
        return Err(if text.contains("no tool called status") {
            "its greed doesn't say its status".to_owned()
        } else {
            text.to_owned()
        });
    }
    serde_json::from_str(text).map_err(|err| err.to_string())
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
            let info = std::fs::read_to_string(path.with_extension("json"))
                .ok()
                .and_then(|text| serde_json::from_str::<Value>(&text).ok())
                .unwrap_or_default();
            let root = info["root"].as_str().map(PathBuf::from);
            let build = info["build"].as_str().map(str::to_owned);
            let pid = info["pid"].as_u64().and_then(|pid| u32::try_from(pid).ok());
            let greed = info["greed"].as_str().map(PathBuf::from);
            Some(SessionInfo {
                name,
                root,
                build,
                pid,
                greed,
            })
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
    make_sessions_dir(&dir)?;
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
        ssh_agent: None,
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
    crate::luau::hash::random_hex(16)
}

/// What a client attached over `greed ssh` answers for on its own machine,
/// as it said when it attached.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Answers {
    /// It relays your ssh agent (`Output::SshAgentRequest`).
    pub ssh_agent: bool,
    /// It asks the hub there (`Output::HomeStatus`).
    pub home: bool,
}

/// A connection that asked to attach, for the server to send frames to and
/// read input from: one JSON message per line each way.
pub struct Attachment {
    pub reader: BufReader<UnixStream>,
    pub writer: UnixStream,
    /// A file or folder the client asked to open, e.g. from `greed FILE`.
    pub open: Option<String>,
    /// What the client asked to be shown beside a file: a terminal (`greed
    /// ssh HOST --terminal`) or a greed shell (`greed --shell`).
    pub opening: Opening,
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
    /// The build of greed it is, when it said.
    pub build: Option<String>,
    /// What it answers for on its own machine.
    pub answers: Answers,
    /// How often it and the session say they're there (`Ping`) when they
    /// have nothing else to send, if it asked for a heartbeat ([`HEARTBEAT`]).
    pub heartbeat: Option<Duration>,
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
            opening: Opening::asked(params),
            remote: params["remote"].as_bool() == Some(true),
            kind,
            name,
            layout: params["layout"]
                .as_str()
                .and_then(crate::ClientLayout::parse),
            takeover: params["takeover"].as_bool() == Some(true),
            build: params["build"].as_str().map(str::to_owned),
            answers: Answers {
                ssh_agent: params["ssh_agent"].as_bool() == Some(true),
                home: params["home"].as_bool() == Some(true),
            },
            heartbeat: heartbeat_of(&params["heartbeat"]),
        }
    }
}

/// Sends a connection's id to `closed` when dropped, unless it was handed
/// over to attach.
struct Closing<'a> {
    id: u64,
    closed: &'a Sender<u64>,
    attached: bool,
    outbox: Outbox,
}

impl Drop for Closing<'_> {
    fn drop(&mut self) {
        // What's queued still goes out; answers that come later don't.
        self.outbox.close();
        if !self.attached {
            let _ = self.closed.send(self.id);
        }
    }
}

/// Answers one connection's requests until it closes, then says so on
/// `closed`, or hands it to the server as an [`Attachment`] once it asks to
/// attach. Requests go to the editor as they come, without waiting for the
/// ones before to be answered; answers and notifications go out through the
/// connection's [`Outbox`] in the order the editor gives them.
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
    let Ok(out) = stream.try_clone() else {
        return;
    };
    let Ok((outbox, writing)) = Outbox::start(out) else {
        return;
    };
    let notifier = Notifier {
        id: NEXT_CONNECTION.fetch_add(1, Ordering::Relaxed),
        outbox: outbox.clone(),
    };
    let mut closing = Closing {
        id: notifier.id,
        closed,
        attached: false,
        outbox: outbox.clone(),
    };
    let mut reader = BufReader::new(stream);
    let mut authed = false;
    // Whether the connection said at its first auth that it's a shell's.
    let mut shell: Option<bool> = None;
    let mut line = Vec::new();
    loop {
        line.clear();
        if !matches!(read_line_within(&mut reader, &mut line), Ok(n) if n > 0) {
            outbox.finish_owed();
            return;
        }
        if line.trim_ascii().is_empty() {
            continue;
        }
        match serde_json::from_slice::<Value>(&line) {
            Ok(message) if authed && message["method"] == "attach" => {
                let theirs = message["params"]["protocol"].as_u64();
                if theirs != Some(u64::from(PROTOCOL)) {
                    let version = message["params"]["version"].as_str();
                    let why = mismatch(session, theirs, version);
                    outbox.push(error_response(&message["id"], -32001, &why).to_string());
                    outbox.close();
                    let _ = writing.join();
                    return;
                }
                // Its name, for a client that came over `greed ssh` without
                // knowing which session it would get, to come back to.
                let mut result = handshake();
                result["session"] = Value::from(session);
                let attachment = Attachment::asked(reader, writer, &message["params"]);
                // A client that asks for a heartbeat hears that it has one.
                if attachment.heartbeat.is_some() {
                    result["heartbeat"] = Value::Bool(true);
                }
                let ok = json!({ "jsonrpc": "2.0", "id": message["id"], "result": result });
                // The attachment writes to the connection from here on, once
                // what's queued, this answer last, has gone out.
                outbox.push(ok.to_string());
                outbox.close();
                let _ = writing.join();
                closing.attached = true;
                let _ = attachments.send(attachment);
                return;
            }
            Ok(message) => answer(
                &message,
                token,
                &mut authed,
                &mut shell,
                requests,
                &notifier,
            ),
            Err(err) => {
                outbox.push(error_response(&Value::Null, -32700, &err.to_string()).to_string());
            }
        }
    }
}

/// Answers `auth` itself and passes anything else to the editor, whose
/// answer goes to the connection's outbox. A connection that says
/// `"shell": true` at its first auth is a shell's, like `greed ctl`'s, and
/// its requests come from "shell"; one that later sends more, like what
/// `greed mcp` passes on from an agent, can't become one.
fn answer(
    message: &Value,
    token: &str,
    authed: &mut bool,
    shell: &mut Option<bool>,
    requests: &Sender<Request>,
    notifier: &Notifier,
) {
    let id = message.get("id").cloned();
    let method = message.get("method").and_then(Value::as_str).unwrap_or("");
    let params = message.get("params").cloned().unwrap_or(Value::Null);
    let respond = |result: Result<Value, String>| {
        if let Some(id) = &id {
            notifier.outbox.push(response(id, result).to_string());
        }
    };
    if method == "auth" {
        // Settled by the first auth, right or wrong, so a connection can't
        // fail once and come back as a shell's.
        if shell.is_none() {
            *shell = Some(params.get("shell").and_then(Value::as_bool) == Some(true));
        }
        *authed = params.get("token").and_then(Value::as_str) == Some(token);
        respond(if *authed {
            Ok(Value::Bool(true))
        } else {
            Err("wrong token".to_owned())
        });
        return;
    }
    if !*authed {
        respond(Err("send auth with the session's token first".to_owned()));
        return;
    }
    let request = Request {
        client: if *shell == Some(true) {
            "shell"
        } else {
            "socket"
        },
        connection: Some(notifier.clone()),
        method: method.to_owned(),
        params,
        reply: Reply::Outbox(Owed::new(id.clone(), notifier.outbox.clone())),
    };
    // One the editor can't take is dropped, which answers it.
    let _ = requests.send(request);
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
        Self::connect_within(socket, token, shell, None)
    }

    /// Like [`Client::connect_as`], giving up on an answer, the first one
    /// included, that takes longer than `wait`.
    pub fn connect_within(
        socket: &Path,
        token: &str,
        shell: bool,
        wait: Option<Duration>,
    ) -> io::Result<Self> {
        let writer = UnixStream::connect(socket)?;
        writer.set_read_timeout(wait)?;
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
            let message = self.read_message()?;
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

    /// Gives up on an answer or notification that takes longer than `wait`
    /// from now on; none waits for ever.
    pub fn set_wait(&self, wait: Option<Duration>) -> io::Result<()> {
        self.writer.set_read_timeout(wait)
    }

    /// Waits for the next notification the session sends, like a watched
    /// status changing; one that came while a request waited comes first.
    /// Fails when the connection closes, or nothing comes within the wait
    /// it was made with.
    pub fn next_notification(&mut self) -> io::Result<Value> {
        if !self.notifications.is_empty() {
            return Ok(self.notifications.remove(0));
        }
        loop {
            let message = self.read_message()?;
            if message.get("id").is_none() {
                return Ok(message);
            }
        }
    }

    /// Reads the next message the session sends, an answer or a
    /// notification.
    fn read_message(&mut self) -> io::Result<Value> {
        let mut line = String::new();
        if self.reader.read_line(&mut line)? == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "the session closed the connection",
            ));
        }
        serde_json::from_str(&line).map_err(io::Error::other)
    }

    /// The notifications the session sent since last asked, oldest first.
    pub fn take_notifications(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.notifications)
    }

    /// Attaches to the editor: from now on the connection carries input
    /// one way and frames the other, one JSON message per line.
    pub fn attach(self) -> io::Result<Attachment> {
        self.attach_opening("tui", None, Opening::Nothing)
    }

    /// Like [`Client::attach`] as a client of `kind` ("tui", "gui"), asking
    /// the session to open `path` too, and what `opening` says.
    pub fn attach_opening(
        self,
        kind: &str,
        path: Option<&Path>,
        opening: Opening,
    ) -> io::Result<Attachment> {
        let mut params = attach_params(kind);
        if let Some(path) = path {
            params["open"] = Value::from(path.to_string_lossy());
        }
        opening.ask(&mut params);
        self.attach_with(&params)
    }

    /// Attaches asking with `params` as they are: [`attach_params`] and
    /// whatever else, like "open", "terminal" or "takeover".
    pub fn attach_with(mut self, params: &Value) -> io::Result<Attachment> {
        self.call("attach", params)?
            .map_err(|said| io::Error::other(Refused::new(self.session.as_deref(), &said)))?;
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
    fn a_refusal_says_when_its_another_version_and_which() {
        // As 0.1.1 says it.
        let said = "the session john runs greed 0.1.1 (protocol 9) and this client is greed \
                    0.1.2 (protocol 10), and both need the same; if greed was upgraded while \
                    the session ran, quit it with `greed ctl quit john` and start greed again";
        let refused = Refused::new(None, said);
        assert!(refused.other_version);
        assert_eq!(refused.session.as_deref(), Some("john"));
        assert_eq!(refused.version.as_deref(), Some("0.1.1"));
        assert_eq!(refused.to_string(), said, "it reads as the session said it");
        let other = Refused::new(Some("work"), "this terminal is in session work");
        assert!(!other.other_version);
        assert_eq!(other.session.as_deref(), Some("work"));
        assert_eq!(other.version, None);
    }

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
