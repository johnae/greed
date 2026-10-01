use std::io::{BufRead, Write};
use std::path::Path;

use kern_core::Editor;
use kern_core::control::{self, Attachment, Client};
use kern_core::keymap::Key;
use kern_core::luau::Host;
use kern_core::render::Size;
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
                "require('@kern').keymap.bind('normal', { ['ctrl-d'] = 'detach' })",
            )?;
            Ok(host)
        },
        Some(session),
    );
    let attach = move || Attached(Client::connect(&socket, &token).unwrap().attach().unwrap());
    (conn, attach)
}

struct Attached(Attachment);

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
            Output::Frame(frame) => frame.rows[0].text(),
            other => panic!("expected a frame, got {other:?}"),
        }
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
            Output::Frame(_) => {}
            Output::Exit => panic!("the editor stopped"),
        }
    }
    let mut again = attach();
    again.send(&Input::Resize(SIZE));
    assert_eq!(again.first_row(), "1 Zhello", "the editor kept the edit");
    conn.input.send(Input::Quit).unwrap();
}
