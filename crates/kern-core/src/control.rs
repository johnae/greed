//! The session socket: how `kern ctl`, `kern mcp` and other programs talk to
//! a running editor.
//!
//! A connection sends JSON-RPC 2.0 requests, one per line, and gets one
//! response line per request. The first request must be
//! `{"method": "auth", "params": {"token": ...}}` with the session's token,
//! which is in a file only the user can read. Everything after that goes to
//! the editor thread as a [`Request`]; plugins decide what the methods mean.

use std::ffi::OsString;
use std::fmt::Write as _;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};

use crossbeam_channel::{Receiver, Sender};
use serde_json::{Value, json};

/// The version of what attached clients and sessions send each other:
/// input, frames and deltas. It goes up when a change would break an older
/// client or session; new optional fields don't need it, since fields a
/// side doesn't know are ignored. Clients say which protocol they speak
/// when they attach, and a session refuses one that doesn't match.
pub const PROTOCOL: u32 = 3;

/// What each side says about itself when a client attaches: the protocol it
/// speaks and the kern version.
pub fn handshake() -> Value {
    json!({ "protocol": PROTOCOL, "version": env!("CARGO_PKG_VERSION") })
}

/// Why a client speaking protocol `theirs` can't attach.
fn mismatch(theirs: Option<u64>) -> String {
    let theirs = theirs.map_or_else(
        || "an older protocol".to_owned(),
        |p| format!("protocol {p}"),
    );
    format!(
        "this session runs kern {} and speaks protocol {PROTOCOL}, the client speaks {theirs}; \
         use the same kern version on both ends",
        env!("CARGO_PKG_VERSION")
    )
}

/// A request from a connection, for the editor thread to answer through
/// [`Request::respond`].
#[derive(Debug)]
pub struct Request {
    /// Who asked: "socket" for the session socket, "ide" for Claude Code's
    /// IDE connection.
    pub client: &'static str,
    pub method: String,
    pub params: Value,
    pub(crate) reply: Sender<Result<Value, String>>,
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

/// Where sessions keep their sockets: `kern` in the runtime directory, or a
/// folder for the user in the temporary directory.
pub fn sessions_dir() -> PathBuf {
    runtime_dir().map_or_else(
        || {
            let user = std::env::var("USER").unwrap_or_else(|_| "user".to_owned());
            std::env::temp_dir().join(format!("kern-{user}"))
        },
        |dir| dir.join("kern"),
    )
}

/// The user's runtime directory: `$XDG_RUNTIME_DIR`, or `/run/user/<uid>`
/// when it isn't set but that is there and theirs, as with commands run
/// over ssh on some systems. Sessions started then get it too, so their
/// sockets and their terminals' programs find the same one a login would.
pub fn runtime_dir() -> Option<PathBuf> {
    // Without /proc (macOS) there's no uid to look for, only the variable.
    let uid = std::fs::metadata("/proc/self").ok().map(|meta| meta.uid());
    pick_runtime_dir(
        std::env::var_os("XDG_RUNTIME_DIR"),
        uid,
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
}

/// Writes down which project the session at `socket` is for, so `kern` in
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

/// A running session, as `kern ls` and the switcher see it.
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
    // Editors that crashed leave sockets behind, which would also stop a
    // new one with the same name from binding.
    prune(&dir);
    let (socket, token_file) = session_files(name);
    // Unix socket paths have to fit in about a hundred bytes.
    if socket.as_os_str().len() > MAX_SOCKET_PATH {
        return Err(io::Error::other(format!(
            "the session's socket path is too long: {}; use a shorter name or set \
             XDG_RUNTIME_DIR to a shorter folder",
            socket.display()
        )));
    }
    // A live session already there keeps its description; binding fails below.
    if let Some(root) = root
        && !socket.exists()
    {
        describe(&socket, root)?;
    }
    let listener = UnixListener::bind(&socket)?;
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600))?;
    let token = new_token()?;
    std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&token_file)?
        .write_all(token.as_bytes())?;

    let (sender, requests) = crossbeam_channel::unbounded();
    let incoming = sender.clone();
    let (attach, attachments) = crossbeam_channel::unbounded();
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let sender = incoming.clone();
            let attach = attach.clone();
            let token = token.clone();
            std::thread::spawn(move || serve_connection(stream, &token, &sender, &attach));
        }
    });
    Ok(Session {
        name: name.to_owned(),
        socket,
        token_file,
        requests,
        sender,
        attachments,
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
    Ok(bytes.iter().fold(String::new(), |mut hex, b| {
        let _ = write!(hex, "{b:02x}");
        hex
    }))
}

/// A connection that asked to attach, for the server to send frames to and
/// read input from: one JSON message per line each way.
pub struct Attachment {
    pub reader: BufReader<UnixStream>,
    pub writer: UnixStream,
    /// A file or folder the client asked to open, e.g. from `kern FILE`.
    pub open: Option<String>,
    /// Whether the client asked for a terminal, e.g. `kern ssh HOST
    /// --terminal`.
    pub terminal: bool,
}

/// Answers one connection's requests until it closes, or hands it to the
/// server as an [`Attachment`] once it asks to attach.
fn serve_connection(
    stream: UnixStream,
    token: &str,
    requests: &Sender<Request>,
    attachments: &Sender<Attachment>,
) {
    let Ok(mut writer) = stream.try_clone() else {
        return;
    };
    let mut reader = BufReader::new(stream);
    let mut authed = false;
    let mut line = String::new();
    loop {
        line.clear();
        if !matches!(reader.read_line(&mut line), Ok(n) if n > 0) {
            return;
        }
        if line.trim().is_empty() {
            continue;
        }
        let response = match serde_json::from_str::<Value>(&line) {
            Ok(message) if authed && message["method"] == "attach" => {
                let theirs = message["params"]["protocol"].as_u64();
                if theirs != Some(u64::from(PROTOCOL)) {
                    let refused = error_response(&message["id"], -32001, &mismatch(theirs));
                    let _ = writeln!(writer, "{refused}");
                    return;
                }
                let ok = json!({ "jsonrpc": "2.0", "id": message["id"], "result": handshake() });
                if writeln!(writer, "{ok}").is_ok() {
                    let open = message["params"]["open"].as_str().map(str::to_owned);
                    let terminal = message["params"]["terminal"].as_bool() == Some(true);
                    let _ = attachments.send(Attachment {
                        reader,
                        writer,
                        open,
                        terminal,
                    });
                }
                return;
            }
            Ok(message) => answer(&message, token, &mut authed, requests),
            Err(err) => Some(error_response(&Value::Null, -32700, &err.to_string())),
        };
        let Some(response) = response else { continue };
        if writeln!(writer, "{response}").is_err() {
            return;
        }
    }
}

/// The response to one message, or `None` for a notification.
fn answer(
    message: &Value,
    token: &str,
    authed: &mut bool,
    requests: &Sender<Request>,
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
        client: "socket",
        method: method.to_owned(),
        params,
        reply,
    };
    if requests.send(request).is_err() {
        return respond(Err("the editor has stopped".to_owned()));
    }
    let result = answered
        .recv()
        .unwrap_or_else(|_| Err("the editor dropped the request".to_owned()));
    respond(result)
}

fn error_response(id: &Value, code: i64, message: &str) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } })
}

/// A connection to a session, for clients like `kern ctl`.
pub struct Client {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next_id: u64,
}

impl Client {
    /// Connects to the socket at `socket` and authenticates with `token`.
    pub fn connect(socket: &Path, token: &str) -> io::Result<Self> {
        let writer = UnixStream::connect(socket)?;
        let reader = BufReader::new(writer.try_clone()?);
        let mut client = Self {
            reader,
            writer,
            next_id: 0,
        };
        client
            .call("auth", &json!({ "token": token }))?
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
        let mut line = String::new();
        if self.reader.read_line(&mut line)? == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "the session closed the connection",
            ));
        }
        let response: Value = serde_json::from_str(&line).map_err(io::Error::other)?;
        Ok(match response.get("error") {
            Some(error) => Err(error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("unknown error")
                .to_owned()),
            None => Ok(response.get("result").cloned().unwrap_or(Value::Null)),
        })
    }

    /// Attaches to the editor: from now on the connection carries input
    /// one way and frames the other, one JSON message per line.
    pub fn attach(self) -> io::Result<Attachment> {
        self.attach_opening(None, false)
    }

    /// Like [`Client::attach`], asking the session to open `path` too, and
    /// with `terminal`, a terminal.
    pub fn attach_opening(mut self, path: Option<&Path>, terminal: bool) -> io::Result<Attachment> {
        let mut params = handshake();
        if let Some(path) = path {
            params["open"] = Value::from(path.to_string_lossy());
        }
        if terminal {
            params["terminal"] = Value::Bool(true);
        }
        self.call("attach", &params)?.map_err(io::Error::other)?;
        Ok(Attachment {
            reader: self.reader,
            writer: self.writer,
            open: None,
            terminal: false,
        })
    }

    /// Copies JSON-RPC lines from `input` to the session, and the session's
    /// answers to `output`, until `input` ends. This is all a bridge like
    /// `kern mcp` needs: plugins speak the protocol.
    pub fn pipe(
        self,
        input: impl BufRead,
        mut output: impl Write + Send + 'static,
    ) -> io::Result<()> {
        let Client {
            mut reader,
            mut writer,
            ..
        } = self;
        let answers = std::thread::spawn(move || -> io::Result<()> {
            let mut line = String::new();
            while reader.read_line(&mut line)? > 0 {
                output.write_all(line.as_bytes())?;
                output.flush()?;
                line.clear();
            }
            Ok(())
        });
        for line in input.lines() {
            writeln!(writer, "{}", line?)?;
        }
        // The session answers what's pending, then closes its end.
        writer.shutdown(std::net::Shutdown::Write)?;
        answers
            .join()
            .map_err(|_| io::Error::other("the thread copying answers panicked"))?
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_runtime_dir_is_the_variable_or_the_users_own_folder_in_run_user() {
        let run_user = std::env::temp_dir().join(format!("kern-run-user-{}", std::process::id()));
        let uid = std::fs::metadata("/proc/self").unwrap().uid();
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
