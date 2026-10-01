use std::io::{BufRead, Write};
use std::path::Path;

use kern_core::Editor;
use kern_core::control::{self, Attachment, Client};
use kern_core::keymap::Key;
use kern_core::luau::Host;
use kern_core::render::{Frame, Size};
use kern_core::server::{self, Connection, Input, Output};
use kern_text::ClientId;

const SIZE: Size = Size {
    width: 20,
    height: 4,
};

/// A headless editor with the core plugin and a session socket, and a way
/// to attach to it.
fn start(label: &str) -> (Connection, impl Fn() -> Attached) {
    let name = format!("attach-{label}-{}", std::process::id());
    let session = control::listen(&name).unwrap();
    let socket = session.socket.clone();
    let token = std::fs::read_to_string(control::session_files(&name).1).unwrap();
    let conn = server::spawn_with_session(
        || {
            let mut editor = Editor::new(ClientId(1));
            editor.open("file", "hello", None);
            let host = Host::new(editor)?;
            host.load_dir(
                &Path::new(env!("CARGO_MANIFEST_DIR")).join("../../runtime/plugins/core"),
            )?;
            host.load_str(
                "keys",
                "local kern = require('@kern')
                 kern.command({ name = 'go', run = function() kern.session.switch({ name = 'elsewhere' }) end })
                 kern.keymap.bind('normal', { ['ctrl-d'] = 'detach', ['ctrl-o'] = 'go' })",
            )?;
            Ok(host)
        },
        Some(session),
    );
    let attach = move || {
        Attached(
            Client::connect(&socket, &token).unwrap().attach().unwrap(),
            None,
        )
    };
    (conn, attach)
}

/// A client: its connection, and the frame it has so far.
struct Attached(Attachment, Option<Frame>);

impl Attached {
    fn send(&mut self, input: &Input) {
        writeln!(self.0.writer, "{}", serde_json::to_string(input).unwrap()).unwrap();
    }

    fn keys(&mut self, keys: &str) {
        for key in Key::parse_sequence(keys).unwrap() {
            self.send(&Input::Key(key));
        }
    }

    fn next(&mut self) -> Output {
        let mut line = String::new();
        self.0.reader.read_line(&mut line).unwrap();
        serde_json::from_str(&line).unwrap()
    }

    /// The first row of the next frame.
    fn first_row(&mut self) -> String {
        match self.next() {
            Output::Frame(frame) => self.1 = Some(frame),
            Output::Delta(delta) => delta.apply(self.1.as_mut().expect("a whole frame came first")),
            other => panic!("expected a frame, got {other:?}"),
        }
        self.1.as_ref().unwrap().rows[0].text()
    }
}

#[test]
fn clients_attach_over_the_socket_and_see_frames_and_edits() {
    let (conn, attach) = start("frames");
    let mut client = attach();
    client.send(&Input::Resize(SIZE));
    assert_eq!(client.first_row(), "1 hello");
    client.keys("i X");
    // A frame comes after each batch of input; the last one has both keys.
    let mut row = client.first_row();
    while row != "1 Xhello" {
        row = client.first_row();
    }
    client.keys("esc");
    conn.input.send(Input::Quit).unwrap();
    loop {
        if let Output::Exit = client.next() {
            break;
        }
    }
}

#[test]
fn a_new_client_takes_over_from_the_one_before() {
    let (conn, attach) = start("takeover");
    let mut first = attach();
    first.send(&Input::Resize(SIZE));
    assert_eq!(first.first_row(), "1 hello");
    let mut second = attach();
    loop {
        if let Output::Detached = first.next() {
            break;
        }
    }
    second.send(&Input::Resize(SIZE));
    assert_eq!(second.first_row(), "1 hello");
    conn.input.send(Input::Quit).unwrap();
}

#[test]
fn detaching_lets_the_client_go_and_the_editor_keeps_running() {
    let (conn, attach) = start("detach");
    let mut client = attach();
    client.send(&Input::Resize(SIZE));
    client.first_row();
    client.keys("i Z esc ctrl-d");
    loop {
        match client.next() {
            Output::Detached => break,
            Output::Frame(_) | Output::Delta(_) => {}
            other @ (Output::Exit | Output::Switch(_)) => {
                panic!("expected a detach, got {other:?}")
            }
        }
    }
    let mut again = attach();
    again.send(&Input::Resize(SIZE));
    assert_eq!(again.first_row(), "1 Zhello", "the editor kept the edit");
    conn.input.send(Input::Quit).unwrap();
}

#[test]
fn after_the_first_frame_clients_get_what_changed() {
    let (conn, attach) = start("deltas");
    let mut client = attach();
    client.send(&Input::Resize(SIZE));
    assert!(
        matches!(client.next(), Output::Frame(_)),
        "a whole frame first"
    );
    client.keys("i");
    match client.next() {
        Output::Delta(delta) => {
            let rows: Vec<u16> = delta.rows.iter().map(|(i, _)| *i).collect();
            assert_eq!(rows, [3], "only the status line changed: {rows:?}");
        }
        other => panic!("expected a delta, got {other:?}"),
    }
    conn.input.send(Input::Quit).unwrap();
}

#[test]
fn clients_speaking_another_protocol_are_refused_clearly() {
    let name = format!("attach-protocol-{}", std::process::id());
    let session = control::listen(&name).unwrap();
    let socket = session.socket.clone();
    let token = std::fs::read_to_string(control::session_files(&name).1).unwrap();
    let conn = server::spawn_with_session(|| Host::new(Editor::new(ClientId(1))), Some(session));
    let mut old = Client::connect(&socket, &token).unwrap();
    let refused = old
        .call("attach", &serde_json::json!({ "protocol": 999 }))
        .unwrap()
        .unwrap_err();
    assert!(refused.contains("protocol 999"), "{refused}");
    let mut current = Client::connect(&socket, &token).unwrap();
    let hello = current
        .call("attach", &control::handshake())
        .unwrap()
        .unwrap();
    assert_eq!(hello["protocol"], control::PROTOCOL);
    conn.input.send(Input::Quit).unwrap();
}

#[test]
fn a_session_can_send_its_client_to_another_session() {
    let (conn, attach) = start("switch");
    let mut client = attach();
    client.send(&Input::Resize(SIZE));
    client.first_row();
    client.keys("ctrl-o");
    loop {
        match client.next() {
            Output::Switch(to) => {
                assert_eq!(to.session.as_deref(), Some("elsewhere"));
                assert_eq!(to.path, None);
                break;
            }
            Output::Frame(_) | Output::Delta(_) => {}
            other => panic!("expected a switch, got {other:?}"),
        }
    }
    // The session lets the client go, like a detach, and keeps running.
    let mut again = attach();
    again.send(&Input::Resize(SIZE));
    again.first_row();
    conn.input.send(Input::Quit).unwrap();
}
