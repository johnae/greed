//! Programs in a session reaching your ssh agent through an attached
//! client that relays it.

use std::io::{BufRead, Read, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use greed_core::Editor;
use greed_core::control::{self, Attachment, Client};
use greed_core::luau::Host;
use greed_core::render::Size;
use greed_core::server::{self, Connection, Input, Output};
use greed_core::ssh_agent;
use greed_text::ClientId;

mod sessions;

const LIST_KEYS: [u8; 1] = [11];
/// What the fake agent answers to listing keys: none.
const NO_KEYS: [u8; 5] = [12, 0, 0, 0, 0];
const SIGN: [u8; 3] = [13, 1, 2];
/// What the fake agent answers to signing.
const SIGNED: [u8; 3] = [14, 9, 9];
const FAILURE: [u8; 1] = [5];

/// A session listening for agent requests, with `plugin` loaded if given,
/// and its agent socket and a way to attach to it, relaying an agent or not.
struct Session {
    conn: Connection,
    agent: PathBuf,
    socket: PathBuf,
    token: String,
}

impl Session {
    fn start(label: &str, plugin: Option<&'static str>) -> Self {
        sessions::private();
        let name = format!("agent-{label}-{}", std::process::id());
        let mut session = control::listen(&name, None).unwrap();
        let agent = ssh_agent::socket_of(&name);
        session.serve_ssh_agent(&agent).unwrap();
        let socket = session.socket.clone();
        let token = std::fs::read_to_string(control::session_files(&name).1).unwrap();
        let conn = server::spawn_with_session(
            move || {
                let mut editor = Editor::new(ClientId(1));
                editor.open("file", "hello", None);
                let host = Host::new(editor)?;
                if let Some(plugin) = plugin {
                    host.load_str("user/agent", plugin)?;
                }
                Ok(host)
            },
            Some(session),
        );
        Self {
            conn,
            agent,
            socket,
            token,
        }
    }

    /// Attaches a client, which relays the agent at `relays` if given, once
    /// the session has it: after its first frame. Counts the requests it
    /// gets.
    fn attach(&self, relays: Option<PathBuf>) -> Arc<AtomicUsize> {
        let got = Arc::new(AtomicUsize::new(0));
        let count = got.clone();
        let mut params = control::attach_params("tui");
        params["ssh_agent"] = serde_json::Value::Bool(relays.is_some());
        let Attachment {
            mut reader,
            mut writer,
            ..
        } = Client::connect(&self.socket, &self.token)
            .unwrap()
            .attach_with(&params)
            .unwrap();
        let resize = Input::Resize(Size {
            width: 20,
            height: 4,
        });
        writeln!(writer, "{}", serde_json::to_string(&resize).unwrap()).unwrap();
        let mut line = String::new();
        while !matches!(
            serde_json::from_str(&line),
            Ok(Output::Frame(_) | Output::Delta(_))
        ) {
            line.clear();
            reader.read_line(&mut line).unwrap();
        }
        std::thread::spawn(move || {
            for line in reader.lines() {
                let Ok(line) = line else { return };
                let Ok(Output::SshAgentRequest(id, body)) = serde_json::from_str(&line) else {
                    continue;
                };
                count.fetch_add(1, Ordering::SeqCst);
                let answer = ssh_agent::ask_base64(relays.as_deref(), &body).ok();
                let reply = serde_json::to_string(&Input::SshAgentReply(id, answer)).unwrap();
                if writeln!(writer, "{reply}").is_err() {
                    return;
                }
            }
        });
        got
    }

    /// What a program in the session gets for `request`.
    fn ask(&self, request: &[u8]) -> Vec<u8> {
        ssh_agent::ask(&self.agent, request).unwrap()
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.conn.input.send(Input::Quit);
    }
}

/// A fake ssh agent on this machine, answering listing keys and signing,
/// and how many requests it got.
fn fake_agent(label: &str) -> (PathBuf, Arc<AtomicUsize>) {
    let dir = std::env::temp_dir().join(format!("greed-fake-agent-{label}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("agent.sock");
    let listener = UnixListener::bind(&path).unwrap();
    let asked = Arc::new(AtomicUsize::new(0));
    let count = asked.clone();
    std::thread::spawn(move || {
        for mut stream in listener.incoming().flatten() {
            let mut length = [0; 4];
            if stream.read_exact(&mut length).is_err() {
                continue;
            }
            let mut body = vec![0; u32::from_be_bytes(length) as usize];
            stream.read_exact(&mut body).unwrap();
            count.fetch_add(1, Ordering::SeqCst);
            let answer: &[u8] = match body[0] {
                11 => &NO_KEYS,
                13 => &SIGNED,
                _ => &FAILURE,
            };
            let mut message = u32::try_from(answer.len()).unwrap().to_be_bytes().to_vec();
            message.extend_from_slice(answer);
            stream.write_all(&message).unwrap();
        }
    });
    (path, asked)
}

fn remove(agent: &Path) {
    let _ = std::fs::remove_dir_all(agent.parent().unwrap());
}

#[test]
fn a_request_goes_to_the_agent_of_the_client_that_relays_it() {
    let (agent, asked) = fake_agent("list");
    let session = Session::start("list", None);
    let relaying = session.attach(Some(agent.clone()));
    let other = session.attach(None);
    assert_eq!(session.ask(&LIST_KEYS), NO_KEYS);
    assert_eq!(
        session.ask(&LIST_KEYS),
        NO_KEYS,
        "again on a new connection"
    );
    assert_eq!(asked.load(Ordering::SeqCst), 2);
    assert_eq!(relaying.load(Ordering::SeqCst), 2);
    assert_eq!(
        other.load(Ordering::SeqCst),
        0,
        "one that doesn't relay isn't asked"
    );
    remove(&agent);
}

#[test]
fn with_no_client_relaying_an_agent_a_request_fails_at_once() {
    let session = Session::start("none", None);
    assert_eq!(session.ask(&LIST_KEYS), FAILURE, "nobody attached");
    let other = session.attach(None);
    assert_eq!(session.ask(&LIST_KEYS), FAILURE, "one that doesn't relay");
    assert_eq!(other.load(Ordering::SeqCst), 0);
}

#[test]
fn signing_with_no_plugin_to_ask_is_refused() {
    let (agent, asked) = fake_agent("unasked");
    let session = Session::start("unasked", None);
    session.attach(Some(agent.clone()));
    assert_eq!(session.ask(&SIGN), FAILURE);
    assert_eq!(asked.load(Ordering::SeqCst), 0, "the agent never saw it");
    remove(&agent);
}

#[test]
fn signing_goes_on_once_a_plugin_allows_it() {
    let (agent, asked) = fake_agent("allowed");
    let session = Session::start(
        "allowed",
        Some(
            "local greed = require('@greed')
             greed.on('ssh_agent.use', function(event)
                 greed.ssh_agent.answer(event.id, event.host ~= nil)
             end)",
        ),
    );
    session.attach(Some(agent.clone()));
    assert_eq!(session.ask(&SIGN), SIGNED);
    assert_eq!(asked.load(Ordering::SeqCst), 1);
    remove(&agent);
}

#[test]
fn signing_a_plugin_refuses_is_refused() {
    let (agent, asked) = fake_agent("refused");
    let session = Session::start(
        "refused",
        Some(
            "local greed = require('@greed')
             greed.on('ssh_agent.use', function(event)
                 greed.sleep(10)
                 greed.ssh_agent.answer(event.id, false)
             end)",
        ),
    );
    session.attach(Some(agent.clone()));
    assert_eq!(session.ask(&SIGN), FAILURE);
    assert_eq!(asked.load(Ordering::SeqCst), 0);
    remove(&agent);
}

#[test]
fn an_agent_that_answers_is_told_from_one_whose_socket_is_gone() {
    let (agent, _) = fake_agent("answers");
    assert!(ssh_agent::answers(&agent));
    let gone = agent.with_file_name("gone.sock");
    assert!(!ssh_agent::answers(&gone));
    // Asked through it, it says why, naming the socket.
    let why = ssh_agent::ask_base64(Some(&gone), "Cw==").unwrap_err();
    assert!(
        why.contains("doesn't answer") && why.contains("gone.sock"),
        "{why}"
    );
    remove(&agent);
}
