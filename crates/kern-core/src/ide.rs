//! Claude Code's IDE connection: a WebSocket on localhost that Claude Code
//! finds through a lock file in `~/.claude/ide`, the way it finds VS Code
//! and `JetBrains` editors. It speaks MCP; its requests reach plugins like
//! the session socket's, marked as coming from "ide", and plugins can send
//! it notifications such as `selection_changed`.

use std::io::{self, ErrorKind, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crossbeam_channel::{Receiver, Sender};
use serde_json::{Value, json};
use tungstenite::handshake::server::{ErrorResponse, Request as Handshake, Response};
use tungstenite::http::HeaderValue;
use tungstenite::{Message, WebSocket};

use crate::control::{Request, new_token};

/// The header Claude Code sends the lock file's token in.
const AUTH_HEADER: &str = "x-claude-code-ide-authorization";

/// The header a WebSocket client asks for subprotocols in, and the server
/// says which it speaks.
const PROTOCOL_HEADER: &str = "sec-websocket-protocol";

/// How often a connection checks for notifications to send while it waits
/// for messages.
const POLL: Duration = Duration::from_millis(20);

/// Where Claude Code looks for editors: `$CLAUDE_CONFIG_DIR/ide`, or
/// `~/.claude/ide`.
pub fn lock_dir() -> Option<PathBuf> {
    match std::env::var_os("CLAUDE_CONFIG_DIR") {
        Some(dir) => Some(PathBuf::from(dir).join("ide")),
        None => Some(PathBuf::from(std::env::var_os("HOME")?).join(".claude/ide")),
    }
}

/// A listening IDE connection. Dropping it removes the lock file, so Claude
/// Code stops offering this editor.
pub struct Ide {
    pub port: u16,
    lock_file: PathBuf,
    clients: Arc<Mutex<Vec<Sender<String>>>>,
}

impl Ide {
    /// Sends a JSON-RPC notification to every connected Claude Code.
    pub fn notify(&self, method: &str, params: &Value) {
        let message = json!({ "jsonrpc": "2.0", "method": method, "params": params }).to_string();
        self.clients
            .lock()
            .expect("no panics while held")
            .retain(|client| client.send(message.clone()).is_ok());
    }
}

impl Drop for Ide {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.lock_file);
    }
}

/// Starts listening on a free localhost port and writes the lock file in
/// `dir` naming `workspace` as the folders this editor has open. Requests
/// go to `requests`.
pub fn listen(dir: &Path, workspace: &[String], requests: Sender<Request>) -> io::Result<Ide> {
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let port = listener.local_addr()?.port();
    let token = new_token()?;
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)?;
    let lock_file = dir.join(format!("{port}.lock"));
    let lock = json!({
        "pid": std::process::id(),
        "workspaceFolders": workspace,
        "ideName": "Kern",
        "transport": "ws",
        "authToken": token,
    });
    std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&lock_file)?
        .write_all(lock.to_string().as_bytes())?;

    let clients: Arc<Mutex<Vec<Sender<String>>>> = Arc::default();
    let registry = clients.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let (outgoing, queued) = crossbeam_channel::unbounded();
            registry
                .lock()
                .expect("no panics while held")
                .push(outgoing.clone());
            let token = token.clone();
            let requests = requests.clone();
            std::thread::spawn(move || {
                let _ = serve(stream, &token, &requests, &outgoing, &queued);
            });
        }
    });
    Ok(Ide {
        port,
        lock_file,
        clients,
    })
}

/// Handles one Claude Code connection until it closes. Requests are
/// answered as they finish, so a slow one (a diff waiting for review)
/// doesn't hold up the rest.
fn serve(
    stream: TcpStream,
    token: &str,
    requests: &Sender<Request>,
    outgoing: &Sender<String>,
    queued: &Receiver<String>,
) -> tungstenite::Result<()> {
    #[expect(
        clippy::result_large_err,
        reason = "tungstenite decides the callback's type"
    )]
    let check = |request: &Handshake, mut response: Response| -> Result<Response, ErrorResponse> {
        let headers = request.headers();
        let given = headers
            .get(AUTH_HEADER)
            .and_then(|value| value.to_str().ok());
        if given == Some(token) {
            // Claude Code asks for the "mcp" subprotocol and waits forever
            // on a connection that doesn't agree to it.
            let wants_mcp = headers
                .get_all(PROTOCOL_HEADER)
                .iter()
                .filter_map(|value| value.to_str().ok())
                .flat_map(|value| value.split(','))
                .any(|protocol| protocol.trim() == "mcp");
            if wants_mcp {
                response
                    .headers_mut()
                    .insert(PROTOCOL_HEADER, HeaderValue::from_static("mcp"));
            }
            Ok(response)
        } else {
            let mut refused = ErrorResponse::new(Some("wrong or missing token".to_owned()));
            *refused.status_mut() = tungstenite::http::StatusCode::UNAUTHORIZED;
            Err(refused)
        }
    };
    let mut socket = tungstenite::accept_hdr(stream, check).map_err(|err| match err {
        tungstenite::HandshakeError::Failure(err) => err,
        tungstenite::HandshakeError::Interrupted(_) => {
            tungstenite::Error::Io(io::Error::from(ErrorKind::WouldBlock))
        }
    })?;
    socket.get_mut().set_read_timeout(Some(POLL))?;
    loop {
        for message in queued.try_iter() {
            socket.send(Message::text(message))?;
        }
        match socket.read() {
            Ok(Message::Text(text)) => forward(&text, requests, outgoing),
            Ok(Message::Close(_)) => return Ok(()),
            Ok(_) => {}
            Err(err) if timed_out(&err) => flush(&mut socket)?,
            Err(err) => return Err(err),
        }
    }
}

fn flush(socket: &mut WebSocket<TcpStream>) -> tungstenite::Result<()> {
    match socket.flush() {
        Err(err) if timed_out(&err) => Ok(()),
        other => other,
    }
}

/// Whether `err` only means the read timeout passed with nothing to do.
fn timed_out(err: &tungstenite::Error) -> bool {
    matches!(err, tungstenite::Error::Io(err)
        if matches!(err.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut))
}

/// Passes one JSON-RPC message to the editor, and queues the response once
/// there is one. Notifications get no response.
fn forward(text: &str, requests: &Sender<Request>, outgoing: &Sender<String>) {
    let Ok(message) = serde_json::from_str::<Value>(text) else {
        return;
    };
    let id = message.get("id").cloned();
    let (reply, answered) = crossbeam_channel::bounded(1);
    let request = Request {
        client: "ide",
        method: message
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned(),
        params: message.get("params").cloned().unwrap_or(Value::Null),
        reply,
    };
    if requests.send(request).is_err() {
        return;
    }
    let outgoing = outgoing.clone();
    std::thread::spawn(move || {
        let Ok(answer) = answered.recv() else { return };
        let Some(id) = id else { return };
        let response = match answer {
            Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
            Err(message) => json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": { "code": -32000, "message": message },
            }),
        };
        let _ = outgoing.send(response.to_string());
    });
}
