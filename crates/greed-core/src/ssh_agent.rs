//! Your ssh agent, reached through the session: a session started by
//! `greed ssh` listens on a socket of its own, which its shells and
//! terminals have as `SSH_AUTH_SOCK`, and passes each request there on to
//! an attached client, which asks the agent on its own machine.
//!
//! What goes over the socket is the ssh agent protocol: each message is
//! its length, a big-endian u32, then its body, whose first byte is its
//! type. Requests on one connection are answered in order.

use std::io::{self, Read, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::Duration;

use crossbeam_channel::{Receiver, Sender};

/// How long a request waits for its answer: long enough to press y in the
/// editor and touch a hardware key.
pub const WAIT: Duration = Duration::from_secs(120);

/// `SSH_AGENT_FAILURE`, the body of the answer to a request that can't be
/// answered.
const FAILURE: [u8; 1] = [5];

/// `SSH2_AGENTC_SIGN_REQUEST`: a request to sign with one of your keys.
const SIGN_REQUEST: u8 = 13;

/// The longest message read or passed on, as OpenSSH's agent has it.
const MESSAGE_LIMIT: u32 = 256 * 1024;

/// The socket the session `name` listens on for its programs' agent
/// requests, in a folder of the session's own beside its socket.
pub fn socket_of(name: &str) -> PathBuf {
    crate::control::sessions_dir().join(name).join("agent.sock")
}

/// A request from a program in the session, for the editor to answer with
/// [`Request::respond`]. Dropping it answers that it failed.
#[derive(Debug)]
pub struct Request {
    /// The message's body, without its length.
    pub body: Vec<u8>,
    reply: Sender<Option<Vec<u8>>>,
}

impl Request {
    /// Whether it asks to sign with one of your keys.
    pub fn is_sign(&self) -> bool {
        self.body.first() == Some(&SIGN_REQUEST)
    }

    /// Sends back the answer's body, or with `None` that it failed.
    pub fn respond(self, answer: Option<Vec<u8>>) {
        // The program may have given up and gone; then nobody wants it.
        let _ = self.reply.send(answer);
    }
}

/// The listening agent socket. Dropping it removes the socket and its
/// folder.
pub struct Listener {
    path: PathBuf,
    requests: Receiver<Request>,
}

impl Listener {
    /// Requests from every connection, in the order they arrive.
    pub fn requests(&self) -> &Receiver<Request> {
        &self.requests
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
        if let Some(dir) = self.path.parent() {
            let _ = std::fs::remove_dir(dir);
        }
    }
}

/// Listens on `path`, in a folder only you can use, which is made if it
/// isn't there. A socket a session that ended left there is replaced; one
/// another session still answers on is left alone and this fails.
pub fn listen(path: &Path) -> io::Result<Listener> {
    let dir = path
        .parent()
        .ok_or_else(|| io::Error::other("the agent socket needs a folder"))?;
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)?;
    crate::control::check_sessions_dir(dir)?;
    if UnixStream::connect(path).is_ok() {
        return Err(io::Error::new(
            io::ErrorKind::AddrInUse,
            format!("another session answers on {}", path.display()),
        ));
    }
    let _ = std::fs::remove_file(path);
    let listener = UnixListener::bind(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    let (sender, requests) = crossbeam_channel::unbounded();
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let sender = sender.clone();
            // With no thread to spare, the connection is dropped.
            let _ = std::thread::Builder::new().spawn(move || serve(stream, &sender));
        }
    });
    Ok(Listener {
        path: path.to_owned(),
        requests,
    })
}

/// Answers one connection's requests, one at a time, until it closes.
fn serve(mut stream: UnixStream, requests: &Sender<Request>) {
    while let Ok(body) = read_message(&mut stream) {
        let (reply, answer) = crossbeam_channel::bounded(1);
        let answer = requests
            .send(Request { body, reply })
            .ok()
            .and_then(|()| answer.recv_timeout(WAIT).ok().flatten());
        if write_message(&mut stream, answer.as_deref().unwrap_or(&FAILURE)).is_err() {
            return;
        }
    }
}

/// Reads one message's body; fails at the end, or on one too long.
fn read_message(reader: &mut impl Read) -> io::Result<Vec<u8>> {
    let mut length = [0; 4];
    reader.read_exact(&mut length)?;
    let length = u32::from_be_bytes(length);
    if length == 0 || length > MESSAGE_LIMIT {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "not an ssh agent message",
        ));
    }
    let mut body = vec![0; length as usize];
    reader.read_exact(&mut body)?;
    Ok(body)
}

fn write_message(writer: &mut impl Write, body: &[u8]) -> io::Result<()> {
    let length = u32::try_from(body.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "an answer too long to send"))?;
    writer.write_all(&length.to_be_bytes())?;
    writer.write_all(body)?;
    writer.flush()
}

/// Asks the agent listening on `socket`, on this machine, the request
/// whose body is `body`, and gives back its answer's body. A client calls
/// this for the session's `Output::SshAgentRequest`.
pub fn ask(socket: &Path, body: &[u8]) -> io::Result<Vec<u8>> {
    ask_within(socket, body, WAIT)
}

/// [`ask`], waiting for the answer at most `wait`.
fn ask_within(socket: &Path, body: &[u8], wait: Duration) -> io::Result<Vec<u8>> {
    let mut stream = UnixStream::connect(socket)?;
    stream.set_read_timeout(Some(wait))?;
    write_message(&mut stream, body)?;
    read_message(&mut stream)
}

/// [`ask`] with the request and its answer in base64, as they go between
/// a session and its client; an error says why it couldn't be asked, as
/// without an agent (`socket`) or with one that doesn't answer.
pub fn ask_base64(socket: Option<&Path>, body: &str) -> Result<String, String> {
    use base64::Engine;
    let engine = &base64::engine::general_purpose::STANDARD;
    let body = engine.decode(body).map_err(|err| err.to_string())?;
    let socket = socket.ok_or("there's no ssh agent here (SSH_AUTH_SOCK isn't set)")?;
    let answer = ask(socket, &body).map_err(|err| {
        format!(
            "your ssh agent at {} doesn't answer: {err}",
            socket.display()
        )
    })?;
    Ok(engine.encode(answer))
}

/// Whether the agent at `socket` answers, asked for its keys within a
/// couple of seconds.
pub fn answers(socket: &Path) -> bool {
    /// `SSH2_AGENTC_REQUEST_IDENTITIES`, and the answer it gets.
    const LIST: u8 = 11;
    const KEYS: u8 = 12;
    ask_within(socket, &[LIST], Duration::from_secs(2))
        .is_ok_and(|answer| answer.first() == Some(&KEYS))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_message_is_its_length_then_its_body() {
        let mut sent = Vec::new();
        write_message(&mut sent, &[11]).unwrap();
        assert_eq!(sent, [0, 0, 0, 1, 11]);
        assert_eq!(read_message(&mut sent.as_slice()).unwrap(), [11]);
        assert!(
            read_message(&mut [0u8, 0, 0, 0].as_slice()).is_err(),
            "an empty message isn't one"
        );
        assert!(
            read_message(&mut [0xffu8, 0, 0, 0].as_slice()).is_err(),
            "nor is one longer than an agent reads"
        );
    }
}
