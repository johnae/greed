use std::io::{BufRead, Write};
use std::path::Path;

use greed_core::Editor;
use greed_core::control::{self, Attachment, Client};
use greed_core::keymap::Key;
use greed_core::luau::Host;
use greed_core::render::{Frame, Size};
use greed_core::server::{self, Connection, Input, Output};
use greed_text::ClientId;

mod sessions;

const SIZE: Size = Size {
    width: 20,
    height: 4,
};

/// A headless editor with the core plugin and a session socket, and a way
/// to attach to it, and to attach by a name, maybe taking over.
fn start(
    label: &str,
) -> (
    Connection,
    impl Fn() -> Attached,
    impl Fn(&str, bool) -> Attached,
) {
    sessions::private();
    let name = format!("attach-{label}-{}", std::process::id());
    let session = control::listen(&name, None).unwrap();
    let socket = session.socket.clone();
    let token = std::fs::read_to_string(control::session_files(&name).1).unwrap();
    let png = picture();
    let conn = server::spawn_with_session(
        move || {
            let mut editor = Editor::new(ClientId(1));
            editor.open("file", "hello", None);
            let host = Host::new(editor)?;
            let runtime = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../runtime/plugins");
            host.load_dir(&runtime.join("core"))?;
            host.load_dir(&runtime.join("helix"))?;
            host.load_str(
                "user/keys",
                "local greed = require('@greed')
                 greed.command({ name = 'go', run = function() greed.session.switch({ name = 'elsewhere' }) end })
                 greed.command({ name = 'ping', run = function() greed.client.notify('Reminder', 'call the bank') end })
                 greed.command({ name = 'slow', run = function() greed.sleep(10000) end })
                 greed.command({ name = 'tab', run = function() greed.tab.new() end })
                 greed.command({ name = 'clip', run = function(ctx)
                     local png = greed.clipboard.image()
                     ctx.buffer:edit(function(e) e:replace(0, ctx.buffer:len(), if png then 'got ' .. #png else 'none') end)
                 end })
                 greed.keymap.bind('helix', { ['ctrl-d'] = 'detach', ['ctrl-o'] = 'go', ['ctrl-n'] = 'ping', ['ctrl-s'] = 'slow', ['ctrl-t'] = 'tab', ['ctrl-b'] = 'clip' })",
            )?;
            // ctrl-p shows a 2 by 1 pixel image over the first two cells.
            host.load_str(
                "picture",
                &format!(
                    "local greed = require('@greed')
                     greed.command({{ name = 'picture', run = function(ctx)
                         local id = assert(greed.image.load('{png}'))
                         ctx.buffer:decorate('pic', {{ {{ from = 0, to = 1, style = 'x',
                             image = {{ id = id, cols = 2, rows = 1 }} }} }})
                     end }})
                     greed.keymap.bind('helix', {{ ['ctrl-p'] = 'picture' }})",
                    png = png.display()
                ),
            )?;
            // ctrl-g places a scene over the first three cells, and ctrl-e
            // changes it.
            host.load_str(
                "sketch",
                "local greed = require('@greed')
                 local spec = { alt = 'a bar', items = { { kind = 'rect', at = { 0, 0 }, size = { 2, 1 }, fill = 'x' } } }
                 local id = greed.scene.new(spec)
                 greed.command({ name = 'sketch', run = function(ctx)
                     ctx.buffer:decorate('sketch', { { from = 0, to = 1, style = 'x',
                         scene = { id = id, cols = 3, rows = 1 } } })
                 end })
                 greed.command({ name = 'sketch-more', run = function()
                     spec.items[1].size = { 3, 1 }
                     greed.scene.set(id, spec)
                 end })
                 greed.keymap.bind('helix', { ['ctrl-g'] = 'sketch', ['ctrl-e'] = 'sketch-more' })",
            )?;
            Ok(host)
        },
        Some(session),
    );
    let (socket2, token2) = (socket.clone(), token.clone());
    let attach = move || {
        Attached(
            Client::connect(&socket, &token).unwrap().attach().unwrap(),
            None,
        )
    };
    let attach_as = move |name: &str, takeover: bool| {
        let mut params = control::handshake();
        params["client"] = serde_json::json!({ "kind": "tui", "name": name });
        params["takeover"] = serde_json::Value::Bool(takeover);
        let client = Client::connect(&socket2, &token2).unwrap();
        Attached(client.attach_with(&params).unwrap(), None)
    };
    (conn, attach, attach_as)
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
            Output::Delta(delta) => assert!(
                delta.apply(self.1.as_mut().expect("a whole frame came first")),
                "it fits the frame before"
            ),
            other => panic!("expected a frame, got {other:?}"),
        }
        greed_core::render::grid::text_rows(self.1.as_ref().unwrap()).swap_remove(0)
    }

    /// Reads frames until one's first row is `row`, returning what else
    /// came on the way.
    fn until_row(&mut self, row: &str) -> Vec<Output> {
        self.until_row_is(|r| r == row)
    }

    /// Reads frames until `wanted` says yes to one's first row, returning
    /// what else came on the way.
    fn until_row_is(&mut self, wanted: impl Fn(&str) -> bool) -> Vec<Output> {
        let mut others = Vec::new();
        loop {
            match self.next() {
                Output::Frame(frame) => self.1 = Some(frame),
                Output::Delta(delta) => assert!(
                    delta.apply(self.1.as_mut().expect("a whole frame first")),
                    "it fits the frame before"
                ),
                Output::Exit => panic!("the editor ended"),
                other => {
                    others.push(other);
                    continue;
                }
            }
            if wanted(&greed_core::render::grid::text_rows(self.1.as_ref().unwrap())[0]) {
                return others;
            }
        }
    }

    /// Where the primary cursor is in the latest frame.
    fn cursor_col(&self) -> u16 {
        self.1.as_ref().unwrap().cursor.unwrap().col
    }

    /// Reads until `wanted` says yes to what came, skipping frames.
    fn until(&mut self, wanted: impl Fn(&Output) -> bool) -> Output {
        loop {
            let next = self.next();
            if wanted(&next) {
                return next;
            }
            match next {
                Output::Frame(frame) => self.1 = Some(frame),
                Output::Delta(delta) => assert!(
                    delta.apply(self.1.as_mut().expect("a whole frame first")),
                    "it fits the frame before"
                ),
                Output::Exit => panic!("the editor ended"),
                _ => {}
            }
        }
    }
}

#[test]
fn clients_attach_over_the_socket_and_see_frames_and_edits() {
    let (conn, attach, _) = start("frames");
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
fn notifications_go_to_the_attached_client() {
    let (conn, attach, _) = start("notify");
    let mut client = attach();
    client.send(&Input::Resize(SIZE));
    client.first_row();
    client.keys("ctrl-n");
    loop {
        match client.next() {
            Output::Notify(notice) => {
                assert_eq!(
                    (notice.title.as_str(), notice.body.as_str()),
                    ("Reminder", "call the bank")
                );
                break;
            }
            Output::Frame(_) | Output::Delta(_) => {}
            other => panic!("expected a notification, got {other:?}"),
        }
    }
    conn.input.send(Input::Quit).unwrap();
}

#[test]
fn a_client_taking_over_lets_the_others_go() {
    let (conn, _, attach_as) = start("takeover");
    let mut first = attach_as("tui@a", false);
    first.send(&Input::Resize(SIZE));
    assert_eq!(first.first_row(), "1 hello");
    let mut second = attach_as("tui@b", true);
    first.until(|o| matches!(o, Output::Detached));
    second.send(&Input::Resize(SIZE));
    assert_eq!(second.first_row(), "1 hello");
    conn.input.send(Input::Quit).unwrap();
}

#[test]
fn a_client_whose_frame_lost_track_asks_and_gets_a_whole_one() {
    let (conn, attach, _) = start("refresh");
    let mut client = attach();
    client.send(&Input::Resize(SIZE));
    let Output::Frame(first) = client.next() else {
        panic!("a whole frame first");
    };
    assert_eq!(first.seq, 1);
    let next_delta = |client: &mut Attached, keys: &str| {
        client.keys(keys);
        let Output::Delta(delta) = client.until(|o| matches!(o, Output::Delta(_))) else {
            unreachable!()
        };
        delta
    };
    let insert = next_delta(&mut client, "i");
    assert_eq!((insert.base, insert.seq), (1, 2));
    // As if that delta was lost on the way: the next doesn't fit frame 1.
    let typed = next_delta(&mut client, "X");
    let mut behind = first.clone();
    assert!(!typed.apply(&mut behind));
    client.send(&Input::Refresh);
    let Output::Frame(whole) = client.next() else {
        panic!("a whole frame after asking");
    };
    assert_eq!(whole.seq, 4);
    assert_eq!(greed_core::render::grid::text_rows(&whole)[0], "1 Xhello");
    client.keys("esc");
    conn.input.send(Input::Quit).unwrap();
}

/// Two clients attached, each having drawn its first frame.
fn two(attach_as: &impl Fn(&str, bool) -> Attached) -> (Attached, Attached) {
    let mut a = attach_as("tui@a", false);
    a.send(&Input::Resize(SIZE));
    assert_eq!(a.first_row(), "1 hello");
    let mut b = attach_as("tui@b", false);
    b.send(&Input::Resize(SIZE));
    assert_eq!(b.first_row(), "1 hello");
    (a, b)
}

#[test]
fn two_clients_both_get_frames_and_one_edit_shows_in_both() {
    let (conn, _, attach_as) = start("two");
    let (mut a, mut b) = two(&attach_as);
    // B's cursor on the first "l".
    b.keys("l l");
    b.until_row("1 hello");
    while b.cursor_col() != 4 {
        b.until_row("1 hello");
    }
    a.keys("i X esc");
    a.until_row("1 Xhello");
    b.until_row("1 Xhello");
    assert_eq!(b.cursor_col(), 5, "B's cursor stays on the same letter");
    conn.input.send(Input::Quit).unwrap();
}

#[test]
fn one_client_leaving_leaves_the_other() {
    let (conn, _, attach_as) = start("leave");
    let (mut a, mut b) = two(&attach_as);
    a.keys("ctrl-d");
    a.until(|o| matches!(o, Output::Detached));
    b.keys("i Y esc");
    b.until_row("1 Yhello");
    // A client other than the one in this process quitting only leaves.
    b.send(&Input::Quit);
    b.until(|o| matches!(o, Output::Detached));
    let mut c = attach_as("tui@c", false);
    c.send(&Input::Resize(SIZE));
    assert_eq!(c.first_row(), "1 Yhello", "the editor goes on");
    conn.input.send(Input::Quit).unwrap();
}

#[test]
fn a_copy_goes_to_the_client_that_copied_only() {
    let (conn, _, attach_as) = start("copy");
    let (mut a, mut b) = two(&attach_as);
    a.keys("x y");
    let Output::Clipboard(text) = a.until(|o| matches!(o, Output::Clipboard(_))) else {
        unreachable!()
    };
    assert_eq!(text, "hello");
    // B's next frame comes after everything sent for the copy.
    b.keys("i Q esc");
    let others = b.until_row("1 Qhello");
    assert!(
        !others.iter().any(|o| matches!(o, Output::Clipboard(_))),
        "{others:?}"
    );
    conn.input.send(Input::Quit).unwrap();
}

#[test]
fn switching_sends_only_the_client_that_asked() {
    let (conn, _, attach_as) = start("switch-one");
    let (mut a, mut b) = two(&attach_as);
    a.keys("ctrl-o");
    a.until(|o| matches!(o, Output::Switch(_)));
    b.keys("i S esc");
    let others = b.until_row("1 Shello");
    assert!(
        !others
            .iter()
            .any(|o| matches!(o, Output::Switch(_) | Output::Detached)),
        "{others:?}"
    );
    conn.input.send(Input::Quit).unwrap();
}

#[test]
fn keys_waiting_for_one_clients_slow_command_dont_hold_up_anothers() {
    let (conn, _, attach_as) = start("held");
    let (mut a, mut b) = two(&attach_as);
    // A's keys wait for its command, which sleeps.
    a.keys("ctrl-s i A esc");
    b.keys("i B esc");
    b.until_row("1 Bhello");
    // A's come through once they've waited long enough.
    let others = a.until_row_is(|row| row.contains('A'));
    assert!(others.is_empty(), "{others:?}");
    conn.input.send(Input::Quit).unwrap();
}

#[test]
fn a_client_coming_back_by_its_name_gets_its_cursor_back() {
    let (conn, _, attach_as) = start("return");
    let mut a = attach_as("tui@a", false);
    a.send(&Input::Resize(SIZE));
    a.first_row();
    a.keys("l l");
    while a.cursor_col() != 4 {
        a.first_row();
    }
    a.keys("ctrl-d");
    a.until(|o| matches!(o, Output::Detached));
    // Another, new, starts where A was and moves on.
    let mut b = attach_as("tui@b", false);
    b.send(&Input::Resize(SIZE));
    b.first_row();
    assert_eq!(b.cursor_col(), 4, "a new client follows the last one");
    b.keys("h");
    while b.cursor_col() != 3 {
        b.first_row();
    }
    let mut back = attach_as("tui@a", false);
    back.send(&Input::Resize(SIZE));
    back.first_row();
    assert_eq!(back.cursor_col(), 4, "A's own cursor");
    conn.input.send(Input::Quit).unwrap();
}

#[test]
fn detaching_lets_the_client_go_and_the_editor_keeps_running() {
    let (conn, attach, _) = start("detach");
    let mut client = attach();
    client.send(&Input::Resize(SIZE));
    client.first_row();
    client.keys("i Z esc ctrl-d");
    loop {
        match client.next() {
            Output::Detached => break,
            Output::Frame(_)
            | Output::Delta(_)
            | Output::Image(_)
            | Output::Scene(_)
            | Output::Clipboard(_)
            | Output::ReadClipboardImage(_)
            | Output::SshAgentRequest(..)
            | Output::Notify(_) => {}
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
    let (conn, attach, _) = start("deltas");
    let mut client = attach();
    client.send(&Input::Resize(SIZE));
    assert!(
        matches!(client.next(), Output::Frame(_)),
        "a whole frame first"
    );
    client.keys("i");
    match client.next() {
        Output::Delta(delta) => {
            let changed: Vec<_> = (delta.surfaces.iter())
                .map(|s| (s.id, s.rows.iter().map(|(i, _)| *i).collect::<Vec<_>>()))
                .collect();
            assert_eq!(
                changed,
                [(greed_core::render::SurfaceId::Status, vec![0])],
                "only the status line changed: {changed:?}"
            );
        }
        other => panic!("expected a delta, got {other:?}"),
    }
    conn.input.send(Input::Quit).unwrap();
}

#[test]
fn clients_speaking_another_protocol_are_refused_clearly() {
    sessions::private();
    let name = format!("attach-protocol-{}", std::process::id());
    let session = control::listen(&name, None).unwrap();
    let socket = session.socket.clone();
    let token = std::fs::read_to_string(control::session_files(&name).1).unwrap();
    let conn = server::spawn_with_session(|| Host::new(Editor::new(ClientId(1))), Some(session));
    let mut old = Client::connect(&socket, &token).unwrap();
    let refused = old
        .call(
            "attach",
            &serde_json::json!({ "protocol": 7, "version": "0.1.0" }),
        )
        .unwrap()
        .unwrap_err();
    // Both sides' versions, and how to start over with this greed.
    let ours = format!(
        "greed {} (protocol {})",
        env!("CARGO_PKG_VERSION"),
        control::PROTOCOL
    );
    for said in [
        &ours,
        "greed 0.1.0 (protocol 7)",
        &format!("the session {name}"),
        &format!("`greed ctl quit {name}`"),
    ] {
        assert!(refused.contains(said), "{said:?} in {refused}");
    }
    let mut older = Client::connect(&socket, &token).unwrap();
    let refused = older
        .call("attach", &serde_json::json!({}))
        .unwrap()
        .unwrap_err();
    assert!(refused.contains("an older greed"), "{refused}");
    let mut current = Client::connect(&socket, &token).unwrap();
    let hello = current
        .call("attach", &control::handshake())
        .unwrap()
        .unwrap();
    assert_eq!(hello["protocol"], control::PROTOCOL);
    conn.input.send(Input::Quit).unwrap();
}

#[test]
fn a_session_of_an_older_greed_says_how_to_start_over() {
    use std::io::BufReader;
    use std::os::unix::net::UnixListener;
    sessions::private();
    // A session started before an upgrade: it answers auth, then refuses
    // to attach with the reason older sessions give.
    let name = format!("attach-older-{}", std::process::id());
    let socket = control::session_files(&name).0;
    std::fs::create_dir_all(socket.parent().unwrap()).unwrap();
    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(&socket).unwrap();
    let older = std::thread::spawn(move || {
        let authed = r#"{"jsonrpc":"2.0","id":1,"result":{}}"#;
        let refused = r#"{"jsonrpc":"2.0","id":2,"error":{"code":-32001,"message":"this session runs greed 0.1.0 and speaks protocol 7, the client speaks protocol 8; use the same greed version on both ends"}}"#;
        // Other tests starting sessions connect to see what's still
        // running, and say nothing or ask something else.
        for stream in listener.incoming() {
            let stream = stream.unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut writer = stream;
            let mut line = String::new();
            if reader.read_line(&mut line).unwrap_or(0) == 0 {
                continue;
            }
            let _ = writeln!(writer, "{authed}");
            line.clear();
            if reader.read_line(&mut line).unwrap_or(0) == 0 || !line.contains("\"attach\"") {
                continue;
            }
            writeln!(writer, "{refused}").unwrap();
            return;
        }
    });
    let Err(refused) = Client::connect(&socket, "token").unwrap().attach() else {
        panic!("an older session can't take this client")
    };
    older.join().unwrap();
    let _ = std::fs::remove_file(&socket);
    let refused = refused.to_string();
    for said in [
        "this session runs greed 0.1.0",
        &format!("protocol {}", control::PROTOCOL),
        &format!("`greed ctl quit {name}`"),
    ] {
        assert!(refused.contains(said), "{said:?} in {refused}");
    }
    // A newer session's reason already says it all.
    let full = "the session x runs greed 9 (protocol 9) ... `greed ctl quit x` ...";
    assert_eq!(control::refused(Some("x"), full), full);
}

#[test]
fn a_session_can_send_its_client_to_another_session() {
    let (conn, attach, _) = start("switch");
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
            Output::Frame(_)
            | Output::Delta(_)
            | Output::Image(_)
            | Output::Scene(_)
            | Output::Clipboard(_)
            | Output::ReadClipboardImage(_)
            | Output::SshAgentRequest(..)
            | Output::Notify(_) => {}
            other => panic!("expected a switch, got {other:?}"),
        }
    }
    // The session lets the client go, like a detach, and keeps running.
    let mut again = attach();
    again.send(&Input::Resize(SIZE));
    again.first_row();
    conn.input.send(Input::Quit).unwrap();
}

/// A tiny PNG in a file for the picture command; the image test removes it.
fn picture() -> std::path::PathBuf {
    let image = greed_core::image::Image::from_pixels(2, 1, 3, &[255, 0, 0, 0, 0, 255]).unwrap();
    let path = std::env::temp_dir().join(format!("greed-attach-{}.png", std::process::id()));
    // Every test's session writes it as it starts, while another test may
    // be reading it: written beside and renamed, it's never seen half done.
    let beside = path.with_extension(format!("{:?}.part", std::thread::current().id()));
    std::fs::write(&beside, &image.png).unwrap();
    std::fs::rename(&beside, &path).unwrap();
    path
}

#[test]
fn an_image_is_sent_once_before_the_frame_that_shows_it() {
    let (conn, attach, _) = start("image");
    let mut client = attach();
    client.send(&Input::Resize(SIZE));
    client.first_row();
    client.keys("ctrl-p");
    // Other updates may come first on a busy machine, but none placing it.
    let image = loop {
        match client.next() {
            Output::Image(image) => break image,
            Output::Delta(delta) => assert!(delta.images.is_none(), "placed before it was sent"),
            other => panic!("expected the image first, got {other:?}"),
        }
    };
    assert_eq!((image.width, image.height), (2, 1));
    match client.next() {
        Output::Delta(delta) => {
            let images = delta.images.expect("the frame places it");
            assert_eq!(images.len(), 1);
            assert_eq!(images[0].id, image.id);
        }
        other => panic!("expected a delta, got {other:?}"),
    }
    // Drawn again, it isn't sent again.
    client.keys("l");
    assert!(matches!(client.next(), Output::Delta(_)));
    conn.input.send(Input::Quit).unwrap();
    let _ = std::fs::remove_file(picture());
}

#[test]
fn a_scene_is_sent_before_the_frame_that_places_it_and_again_as_it_changes() {
    let (conn, attach, _) = start("scene");
    let mut client = attach();
    client.send(&Input::Resize(SIZE));
    client.first_row();
    client.keys("ctrl-g");
    let scene = loop {
        match client.next() {
            Output::Scene(scene) => break scene,
            Output::Delta(delta) => assert!(delta.scenes.is_none(), "placed before it was sent"),
            other => panic!("expected the scene first, got {other:?}"),
        }
    };
    assert_eq!(scene.version, 1);
    assert_eq!(scene.spec["alt"], "a bar");
    match client.next() {
        Output::Delta(delta) => {
            let scenes = delta.scenes.expect("the frame places it");
            assert_eq!(scenes.len(), 1);
            assert_eq!((scenes[0].id, scenes[0].version), (scene.id, 1));
            assert_eq!((scenes[0].cols, scenes[0].rows), (3, 1));
        }
        other => panic!("expected a delta, got {other:?}"),
    }
    // Changed, it's sent again, at its next version.
    client.keys("ctrl-e");
    let changed = loop {
        match client.next() {
            Output::Scene(scene) => break scene,
            Output::Delta(_) => {}
            other => panic!("expected the scene again, got {other:?}"),
        }
    };
    assert_eq!((changed.id, changed.version), (scene.id, 2));
    conn.input.send(Input::Quit).unwrap();
}

#[test]
fn copies_go_to_the_client_for_the_system_clipboard() {
    let (conn, attach, _) = start("clipboard");
    let mut client = attach();
    client.send(&Input::Resize(SIZE));
    client.first_row();
    client.keys("x y");
    loop {
        match client.next() {
            Output::Clipboard(text) => {
                assert_eq!(text, "hello");
                break;
            }
            Output::Frame(_) | Output::Delta(_) => {}
            other => panic!("expected the copy, got {other:?}"),
        }
    }
    conn.input.send(Input::Quit).unwrap();
}

/// Attaches to the session `start(label)` runs as `name`, asking for
/// `layout`.
fn attach_laid_out(label: &str, name: &str, layout: &str) -> Attached {
    let session = format!("attach-{label}-{}", std::process::id());
    let (socket, token) = control::session_files(&session);
    let token = std::fs::read_to_string(token).unwrap();
    let mut params = control::attach_params("tui");
    params["client"] = serde_json::json!({ "kind": "tui", "name": name });
    params["layout"] = serde_json::Value::from(layout);
    let client = Client::connect(&socket, &token).unwrap();
    Attached(client.attach_with(&params).unwrap(), None)
}

#[test]
fn a_client_asking_to_be_independent_gets_tabs_of_its_own() {
    let (conn, _, attach_as) = start("independent");
    let mut a = attach_as("tui@a", false);
    a.send(&Input::Resize(SIZE));
    assert_eq!(a.first_row(), "1 hello");
    let mut b = attach_laid_out("independent", "tui@b", "independent");
    b.send(&Input::Resize(SIZE));
    assert_eq!(b.first_row(), "1 hello");
    // A's new tab shows the tab line to A alone.
    a.keys("ctrl-t");
    a.until_row_is(|row| row != "1 hello");
    b.keys("i B esc");
    b.until_row("1 Bhello");
    // A follower would be shown it.
    let mut c = attach_laid_out("independent", "tui@c", "follow");
    c.send(&Input::Resize(SIZE));
    assert_ne!(c.first_row(), "1 Bhello", "the new tab's line");
    conn.input.send(Input::Quit).unwrap();
}

#[test]
fn each_window_gets_its_own_font_size_in_its_frames() {
    let (conn, _, attach_as) = start("font");
    let (mut a, mut b) = two(&attach_as);
    let size = |c: &Attached| c.1.as_ref().unwrap().gui["gui-font-size"].clone();
    a.keys("ctrl-= ctrl-=");
    while size(&a) != "17" {
        a.first_row();
    }
    b.keys("i B esc");
    b.until_row("1 Bhello");
    assert_eq!(size(&b), "15", "the other window's stays");
    conn.input.send(Input::Quit).unwrap();
}

#[test]
fn the_clipboards_image_is_read_by_the_client_that_asked() {
    use base64::Engine;
    let (conn, attach, _) = start("clipimage");
    let mut client = attach();
    client.send(&Input::Resize(SIZE));
    client.first_row();
    client.keys("ctrl-b");
    let Output::ReadClipboardImage(ask) =
        client.until(|o| matches!(o, Output::ReadClipboardImage(_)))
    else {
        unreachable!()
    };
    // The client reads its own clipboard, on its own machine, and answers.
    let png = base64::engine::general_purpose::STANDARD.encode(b"\x89PNG\r\n\x1a\nimage");
    client.send(&Input::ClipboardImage(ask, Some(png)));
    client.until_row("1 got 13");
    // A client with none says so.
    client.keys("ctrl-b");
    let Output::ReadClipboardImage(ask) =
        client.until(|o| matches!(o, Output::ReadClipboardImage(_)))
    else {
        unreachable!()
    };
    client.send(&Input::ClipboardImage(ask, None));
    client.until_row("1 none");
    conn.input.send(Input::Quit).unwrap();
}

#[test]
fn a_client_of_another_build_is_told_which_build_the_session_runs() {
    let (conn, _, _) = start("build");
    let session = format!("attach-build-{}", std::process::id());
    let (socket, token) = control::session_files(&session);
    let token = std::fs::read_to_string(token).unwrap();
    let attach_built = |build: &str| {
        let mut params = control::attach_params("tui");
        params["build"] = serde_json::Value::from(build);
        let client = Client::connect(&socket, &token).unwrap();
        Attached(client.attach_with(&params).unwrap(), None)
    };
    let status = |client: &mut Attached| {
        client.send(&Input::Resize(SIZE));
        client.first_row();
        greed_core::render::grid::text_rows(client.1.as_ref().unwrap())
            .pop()
            .unwrap()
    };
    let mut other = attach_built("0123456789ab");
    let said = status(&mut other);
    assert!(
        said.contains("attached with build 0123456789ab") && said.contains("greed --new"),
        "{said}"
    );
    let mut same = attach_built(control::build());
    let said = status(&mut same);
    assert!(!said.contains("attached with build"), "{said}");
    conn.input.send(Input::Quit).unwrap();
}
