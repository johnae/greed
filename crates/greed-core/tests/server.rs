use std::path::Path;
use std::time::Duration;

use greed_core::Editor;
use greed_core::keymap::Key;
use greed_core::luau::Host;
use greed_core::render::{Frame, Size};
use greed_core::server::{self, Connection, Input, Output};
use greed_text::ClientId;

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
    assert_eq!(f.cursor_shape, greed_core::CursorShape::Block);
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

    // The message goes with the next key.
    keys(&conn, "l");
    let mut f = frame(&conn);
    while f.rows[1].text().contains("this buffer has no file") {
        f = frame(&conn);
    }
}

#[test]
fn saving_writes_the_file_and_says_so() {
    let path: &'static Path = Box::leak(
        std::env::temp_dir()
            .join(format!("greed-server-save-{}.txt", std::process::id()))
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
            "local greed = require('@greed')\ngreed.command { name = 'later', run = function(ctx) greed.sleep(20) ctx.buffer:edit(function(e) e:insert(0, 'woke') end) end }\ngreed.keymap.bind('normal', { z = 'later' })",
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

#[test]
fn frames_come_at_most_once_a_redraw_while_work_keeps_waking_the_server() {
    // A command that changes the text every millisecond for a while: each
    // wake-up is work, but frames come at a screen's pace.
    let conn = server::spawn(|| {
        let mut editor = Editor::new(ClientId(1));
        editor.open("file", "", None);
        let host = Host::new(editor)?;
        host.load_str(
            "busy",
            "local greed = require('@greed')\ngreed.command { name = 'busy', run = function(ctx) for i = 1, 200 do greed.sleep(1) ctx.buffer:edit(function(e) e:replace(0, #ctx.buffer:text(), tostring(i)) end) end end }\ngreed.keymap.bind('normal', { z = 'busy' })",
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
    let started = std::time::Instant::now();
    keys(&conn, "z");
    let mut frames = 0;
    loop {
        frames += 1;
        if frame(&conn).rows[0].text() == "1 200" {
            break;
        }
    }
    let elapsed = started.elapsed();
    // A frame every 8ms at most, and one more for the key.
    let most = elapsed.as_millis() / 8 + 2;
    assert!(
        frames <= most,
        "{frames} frames in {elapsed:?}, more than {most}"
    );
}
