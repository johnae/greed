use std::path::Path;
use std::time::Duration;

use kern_core::Editor;
use kern_core::keymap::Key;
use kern_core::luau::Host;
use kern_core::render::{Frame, Size};
use kern_core::server::{self, Connection, Input, Output};
use kern_text::ClientId;

fn start(text: &'static str, path: Option<&'static Path>) -> Connection {
    server::spawn(move || {
        let mut editor = Editor::new(ClientId(1));
        editor.open("file", text, path.map(Path::to_owned));
        let host = Host::new(editor)?;
        host.load_dir(&Path::new(env!("CARGO_MANIFEST_DIR")).join("../../runtime/plugins/core"))?;
        Ok(host)
    })
}

fn next(conn: &Connection) -> Output {
    conn.output
        .recv_timeout(Duration::from_secs(5))
        .expect("server answered")
}

fn frame(conn: &Connection) -> Frame {
    match next(conn) {
        Output::Frame(frame) => frame,
        other => panic!("expected a frame, got {other:?}"),
    }
}

fn keys(conn: &Connection, keys: &str) {
    for key in Key::parse_sequence(keys).unwrap() {
        conn.input.send(Input::Key(key)).unwrap();
    }
}

#[test]
fn renders_after_resize_and_after_input() {
    let conn = start("hello", None);
    conn.input
        .send(Input::Resize(Size {
            width: 20,
            height: 3,
        }))
        .unwrap();
    let f = frame(&conn);
    assert_eq!(f.rows[0].text(), "1 hello");

    keys(&conn, "i > esc");
    // Input may be batched, so read frames until the edit shows up.
    let mut f = frame(&conn);
    while f.rows[0].text() != "1 >hello" {
        f = frame(&conn);
    }
    assert_eq!(f.cursor_shape, kern_core::CursorShape::Block);
}

#[test]
fn errors_and_messages_show_on_the_status_line() {
    let conn = start("hi", None);
    conn.input
        .send(Input::Resize(Size {
            width: 60,
            height: 2,
        }))
        .unwrap();
    frame(&conn);
    keys(&conn, "ctrl-s");
    let f = frame(&conn);
    assert!(
        f.rows[1].text().contains("this buffer has no file"),
        "{:?}",
        f.rows[1].text()
    );
}

#[test]
fn saving_writes_the_file_and_says_so() {
    let path: &'static Path = Box::leak(
        std::env::temp_dir()
            .join(format!("kern-server-save-{}.txt", std::process::id()))
            .into_boxed_path(),
    );
    let conn = start("draft", Some(path));
    conn.input
        .send(Input::Resize(Size {
            width: 80,
            height: 2,
        }))
        .unwrap();
    frame(&conn);
    keys(&conn, "ctrl-s");
    let f = frame(&conn);
    assert!(
        f.rows[1].text().contains("wrote "),
        "{:?}",
        f.rows[1].text()
    );
    assert_eq!(std::fs::read_to_string(path).unwrap(), "draft");
    std::fs::remove_file(path).unwrap();
}

#[test]
fn quitting_stops_the_server() {
    let conn = start("", None);
    conn.input
        .send(Input::Resize(Size {
            width: 20,
            height: 2,
        }))
        .unwrap();
    frame(&conn);
    keys(&conn, "ctrl-q");
    assert_eq!(next(&conn), Output::Exit);
    conn.server.join().unwrap().unwrap();

    let conn = start("", None);
    conn.input.send(Input::Quit).unwrap();
    assert_eq!(next(&conn), Output::Exit);
}

#[test]
fn setup_errors_are_returned() {
    let conn = server::spawn(|| {
        let host = Host::new(Editor::new(ClientId(1)))?;
        host.load_str("broken", "error('nope')")?;
        Ok(host)
    });
    assert_eq!(next(&conn), Output::Exit);
    let err = conn.server.join().unwrap().unwrap_err();
    assert!(err.to_string().contains("nope"), "{err}");
}

#[test]
fn the_server_wakes_up_for_timers() {
    let conn = server::spawn(|| {
        let mut editor = Editor::new(ClientId(1));
        editor.open("file", "", None);
        let host = Host::new(editor)?;
        host.load_str(
            "sleepy",
            "local kern = require('@kern')\nkern.command { name = 'later', run = function(ctx) kern.sleep(20) ctx.buffer:edit(function(e) e:insert(0, 'woke') end) end }\nkern.keymap.bind('normal', { z = 'later' })",
        )?;
        Ok(host)
    });
    conn.input
        .send(Input::Resize(Size {
            width: 20,
            height: 2,
        }))
        .unwrap();
    frame(&conn);
    keys(&conn, "z");
    let mut f = frame(&conn);
    while f.rows[0].text() != "1 woke" {
        f = frame(&conn);
    }
}
