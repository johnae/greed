use std::path::Path;
use std::time::Duration;

use greed_core::keymap::Key;
use greed_core::luau::Host;
use greed_core::render::grid::screen_rows;
use greed_core::render::{Frame, Size};
use greed_core::server::{self, Connection, Input, Output};
use greed_core::{Editor, FIRST_CLIENT};
use greed_text::ClientId;

fn start(text: &'static str, path: Option<&'static Path>) -> Connection {
    server::spawn(move || {
        let mut editor = Editor::new(ClientId(1));
        editor.open("file", text, path.map(Path::to_owned));
        let host = Host::new(editor)?;
        let runtime = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../runtime/plugins");
        host.load_dir(&runtime.join("core"))?;
        host.load_dir(&runtime.join("helix"))?;
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
    assert_eq!(screen_rows(&f)[0].text(), "1 hello");

    keys(&conn, "i > esc");
    // Input may be batched, so read frames until the edit shows up.
    let mut f = frame(&conn);
    while screen_rows(&f)[0].text() != "1 >hello" {
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
    keys(&conn, "n");
    let f = frame(&conn);
    assert!(
        screen_rows(&f)[1]
            .text()
            .contains("nothing searched for yet"),
        "{:?}",
        screen_rows(&f)[1].text()
    );
    // The message goes with the next key.
    keys(&conn, "l");
    let mut f = frame(&conn);
    while screen_rows(&f)[1]
        .text()
        .contains("nothing searched for yet")
    {
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
        screen_rows(&f)[1].text().contains("wrote "),
        "{:?}",
        screen_rows(&f)[1].text()
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
            "local greed = require('@greed')\ngreed.command { name = 'later', run = function(ctx) greed.sleep(20) ctx.buffer:edit(function(e) e:insert(0, 'woke') end) end }\ngreed.keymap.bind('helix', { z = 'later' })",
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
    while screen_rows(&f)[0].text() != "1 woke" {
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
            "local greed = require('@greed')\ngreed.command { name = 'busy', run = function(ctx) for i = 1, 200 do greed.sleep(1) ctx.buffer:edit(function(e) e:replace(0, #ctx.buffer:text(), tostring(i)) end) end end }\ngreed.keymap.bind('helix', { z = 'busy' })",
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
        if screen_rows(&frame(&conn))[0].text() == "1 200" {
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

#[test]
fn frames_carry_the_options_a_window_reads() {
    let conn = start("", None);
    conn.input
        .send(Input::Resize(Size {
            width: 20,
            height: 2,
        }))
        .unwrap();
    let f = frame(&conn);
    assert_eq!(f.gui.get("gui-font-size").map(String::as_str), Some("15"));
    assert_eq!(f.gui.get("gui-font").map(String::as_str), Some(""));
    assert!(f.gui.keys().all(|k| k.starts_with("gui-")), "{:?}", f.gui);
}

#[test]
fn frames_carry_the_menus_and_a_window_runs_their_commands() {
    let conn = start("hello", None);
    conn.input
        .send(Input::Resize(Size {
            width: 20,
            height: 2,
        }))
        .unwrap();
    let f = frame(&conn);
    let file = f
        .menus
        .iter()
        .find(|m| m.title == "File")
        .expect("a File menu");
    assert!(file.items.iter().any(|i| i.command == "save"), "{file:?}");
    conn.input
        .send(Input::Run("select-all".to_owned()))
        .unwrap();
    let mut f = frame(&conn);
    while !screen_rows(&f)[0]
        .spans
        .iter()
        .any(|s| s.text == "hello" && s.tags.contains(&greed_core::render::Tag::SELECTION))
    {
        f = frame(&conn);
    }
}

#[test]
fn an_option_key_runs_what_its_alt_key_is_bound_to_or_types_its_character() {
    let conn = server::spawn(|| {
        let mut editor = Editor::new(ClientId(1));
        editor.open("file", "", None);
        let host = Host::new(editor)?;
        let runtime = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../runtime/plugins");
        host.load_dir(&runtime.join("core"))?;
        host.load_dir(&runtime.join("helix"))?;
        host.load_str(
            "option",
            "local greed = require('@greed')
            greed.command { name = 'mark', run = function()
                local b = greed.view():buffer()
                b:edit(function(e) e:insert(#b:text(), 'M') end)
            end }
            greed.keymap.bind({}, { ['alt-q'] = 'mark', ['alt-8'] = 'mark' })",
        )?;
        Ok(host)
    });
    conn.input
        .send(Input::Resize(Size {
            width: 30,
            height: 2,
        }))
        .unwrap();
    frame(&conn);
    keys(&conn, "i");
    let alt = |c: char| Key {
        code: greed_core::keymap::KeyCode::Char(c),
        mods: greed_core::keymap::Mods::ALT,
    };
    // Bound: the command runs. Not bound, or typing plain ASCII, as `[` on
    // a Swedish keyboard (though alt-8 is bound here): what Option typed
    // goes in.
    conn.input
        .send(Input::KeyOrText(alt('q'), "œ".into()))
        .unwrap();
    conn.input
        .send(Input::KeyOrText(alt('8'), "[".into()))
        .unwrap();
    conn.input
        .send(Input::KeyOrText(alt('z'), "Ω".into()))
        .unwrap();
    let mut f = frame(&conn);
    while !screen_rows(&f)[0].text().contains("M[Ω") {
        f = frame(&conn);
    }
}

#[test]
fn a_command_a_client_runs_with_a_bang_is_forced() {
    let conn = server::spawn(|| {
        let mut editor = Editor::new(ClientId(1));
        editor.open("file", "", None);
        let host = Host::new(editor)?;
        host.load_str(
            "forced",
            "local greed = require('@greed')
            greed.command { name = 'say', run = function(ctx)
                local b = greed.view():buffer()
                b:edit(function(e) e:insert(#b:text(), if ctx.force then 'forced ' else 'asked ') end)
            end }",
        )?;
        Ok(host)
    });
    conn.input
        .send(Input::Resize(Size {
            width: 30,
            height: 2,
        }))
        .unwrap();
    conn.input.send(Input::Run("say".into())).unwrap();
    conn.input.send(Input::Run("say!".into())).unwrap();
    let mut f = frame(&conn);
    while !screen_rows(&f)[0].text().contains("asked forced") {
        f = frame(&conn);
    }
}

/// Commands that take a while, and quick ones, each adding a letter at the
/// end: `z` sleeps 150ms then adds "a", `x` adds "b" at once, `y` waits 3s
/// then adds "c", `Z` sleeps 300ms then adds "c", `esc` adds "e", `q` adds
/// the next key pressed, `j` adds "j" after a program that runs 200ms, `s`
/// asks with a signal another key answers, `w` runs `z` and waits for it,
/// and a paste adds its text.
const KEYS_PLUGIN: &str = r"
local greed = require('@greed')
local function add(text)
    local b = greed.view():buffer()
    b:edit(function(e) e:insert(#b:text(), text) end)
end
local asked = nil
greed.command { name = 'slow', run = function() greed.sleep(150) add('a') end }
greed.command { name = 'quick', run = function() add('b') end }
greed.command { name = 'stuck', run = function() greed.sleep(3000) add('c') end }
greed.command { name = 'slowish', run = function() greed.sleep(300) add('c') end }
greed.command { name = 'cancel', run = function() add('e') end }
greed.command { name = 'ask', run = function() add(greed.next_key()) end }
greed.command { name = 'job', run = function() greed.process.run({ 'sleep', '0.2' }) add('j') end }
greed.command { name = 'signal', run = function()
    asked = greed.signal()
    add(asked:wait())
end }
greed.command { name = 'answer', run = function() if asked then asked:send('s') end end }
greed.command { name = 'waits', run = function() greed.run('slow', { wait = true }) end }
greed.on('client.paste', function(event) add(event.text) end)
greed.keymap.bind('helix', {
    z = 'slow', x = 'quick', y = 'stuck', Z = 'slowish', esc = 'cancel', q = 'ask',
    j = 'job', s = 'signal', S = 'answer', w = 'waits',
})
";

fn start_keys() -> Connection {
    let conn = server::spawn(|| {
        let mut editor = Editor::new(ClientId(1));
        editor.open("file", "", None);
        let host = Host::new(editor)?;
        host.load_str("keys", KEYS_PLUGIN)?;
        Ok(host)
    });
    conn.input
        .send(Input::Resize(Size {
            width: 20,
            height: 2,
        }))
        .unwrap();
    frame(&conn);
    conn
}

/// Reads frames until the first line is `1 TEXT`.
fn until_text(conn: &Connection, text: &str) {
    let want = format!("1 {text}");
    let mut f = frame(conn);
    while screen_rows(&f)[0].text() != want {
        f = frame(conn);
    }
}

#[test]
fn keys_typed_while_a_command_works_run_after_it_in_order() {
    let conn = start_keys();
    keys(&conn, "z x z x");
    until_text(&conn, "abab");

    // Waiting on a program holds keys up the same way.
    let conn = start_keys();
    keys(&conn, "j x");
    until_text(&conn, "jb");

    // So does a paste, after the key before it.
    let conn = start_keys();
    keys(&conn, "z");
    conn.input.send(Input::Paste("p".into())).unwrap();
    until_text(&conn, "ap");
}

#[test]
fn esc_gets_through_while_a_command_works() {
    let conn = start_keys();
    keys(&conn, "Z esc x");
    until_text(&conn, "ecb");

    // Behind keys already waiting, it keeps its place, so typing ahead
    // "x esc" still ends with what esc does.
    let conn = start_keys();
    keys(&conn, "Z x esc");
    until_text(&conn, "cbe");
}

#[test]
fn keys_wait_at_most_half_a_second_for_a_command() {
    let conn = start_keys();
    let started = std::time::Instant::now();
    keys(&conn, "y x");
    until_text(&conn, "b");
    let waited = started.elapsed();
    assert!(
        waited >= Duration::from_millis(400) && waited < Duration::from_millis(2500),
        "{waited:?}"
    );
    // The stuck command doesn't hold up the keys after either.
    let started = std::time::Instant::now();
    keys(&conn, "x");
    until_text(&conn, "bb");
    assert!(
        started.elapsed() < Duration::from_millis(400),
        "{:?}",
        started.elapsed()
    );
}

#[test]
fn commands_waiting_for_a_key_or_an_answer_get_the_next_keys_at_once() {
    let conn = start_keys();
    let started = std::time::Instant::now();
    keys(&conn, "q k x s S");
    until_text(&conn, "kbs");
    assert!(
        started.elapsed() < Duration::from_millis(400),
        "{:?}",
        started.elapsed()
    );
}

#[test]
fn a_keys_command_is_at_work_until_it_finishes_or_waits_for_the_user() {
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", "", None);
    let host = Host::new(editor).unwrap();
    host.load_str("keys", KEYS_PLUGIN).unwrap();
    assert!(!host.key_command_at_work(FIRST_CLIENT));

    // Sleeping, and still the one keys wait for after a quick key.
    host.press_keys("z").unwrap();
    assert!(host.key_command_at_work(FIRST_CLIENT));
    host.press_keys("x").unwrap();
    assert!(host.key_command_at_work(FIRST_CLIENT));
    host.let_keys_through(FIRST_CLIENT);
    assert!(!host.key_command_at_work(FIRST_CLIENT));

    host.press_keys("x").unwrap();
    assert!(!host.key_command_at_work(FIRST_CLIENT), "finished at once");
    host.press_keys("q").unwrap();
    assert!(!host.key_command_at_work(FIRST_CLIENT), "waits for a key");
    host.press_keys("k s").unwrap();
    assert!(
        !host.key_command_at_work(FIRST_CLIENT),
        "waits for an answer"
    );
    host.press_keys("S").unwrap();
    host.press_keys("j").unwrap();
    assert!(host.key_command_at_work(FIRST_CLIENT), "waits on a program");
    host.let_keys_through(FIRST_CLIENT);
    host.press_keys("w").unwrap();
    assert!(
        host.key_command_at_work(FIRST_CLIENT),
        "waits for a command at work"
    );
}

#[test]
fn odd_sizes_and_clicks_far_off_screen_dont_stop_the_server() {
    use greed_core::mouse::{Button, Mouse, MouseKind};
    let conn = server::spawn(|| {
        let mut editor = Editor::new(ClientId(1));
        editor.open("file", "hello\nwörld 日本\n", None);
        let host = Host::new(editor)?;
        let runtime = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../runtime/plugins");
        let plugins = [
            "core",
            "helix",
            "picker",
            "terminal",
            "panes",
            "statusline",
            "tree",
        ];
        host.load_dirs(&plugins.map(|p| runtime.join(p)))?;
        Ok(host)
    });
    let sizes = [
        (0, 0),
        (1, 0),
        (0, 1),
        (1, 1),
        (3, 2),
        (u16::MAX, 2),
        (2, 300),
    ];
    let kinds = [
        MouseKind::Press(Button::Left),
        MouseKind::Drag(Button::Left),
        MouseKind::Release(Button::Left),
        MouseKind::Press(Button::Right),
        MouseKind::Move,
        MouseKind::ScrollUp,
        MouseKind::ScrollDown,
        MouseKind::ScrollLeft,
        MouseKind::ScrollRight,
    ];
    let cells = [
        (0, 0),
        (1, 1),
        (5, 0),
        (0, 1),
        (u16::MAX, u16::MAX),
        (u16::MAX, 0),
        (0, u16::MAX),
    ];
    // A split, a second tab and a floating view, so clicks land on borders,
    // the tab line and edges too.
    for command in ["split", "tab-new", "split", "tree", "command-palette"] {
        conn.input.send(Input::Run(command.to_owned())).unwrap();
    }
    for (width, height) in sizes {
        conn.input
            .send(Input::Resize(Size { width, height }))
            .unwrap();
        conn.input.send(Input::CellSize(0, 0)).unwrap();
        frame_sized(&conn, width, height);
        for kind in kinds {
            for (col, row) in cells {
                let mouse = Mouse {
                    kind,
                    col,
                    row,
                    ctrl: false,
                    alt: false,
                    shift: false,
                };
                conn.input.send(Input::Mouse(mouse)).unwrap();
            }
        }
        conn.input
            .send(Input::Paste("\u{0}\r\n\u{feff}".to_owned()))
            .unwrap();
        conn.input
            .send(Input::Run("no such command".to_owned()))
            .unwrap();
        // Drawn at this size, after the clicks, with the server still going.
        conn.input
            .send(Input::Resize(Size { width, height }))
            .unwrap();
        frame_sized(&conn, width, height);
    }
}

/// The next frame `width` by `height`, after any others; past the biggest
/// screen the editor draws, that size.
fn frame_sized(conn: &Connection, width: u16, height: u16) {
    let size = Size { width, height }.limited();
    while frame(conn).size != size {}
}

#[test]
fn a_refusal_shows_as_plain_words() {
    let conn = start("hi", None);
    conn.input
        .send(Input::Resize(Size {
            width: 100,
            height: 2,
        }))
        .unwrap();
    frame(&conn);
    keys(&conn, "i x esc ctrl-q");
    let mut f = frame(&conn);
    while !screen_rows(&f)[1].text().contains("unsaved changes") {
        f = frame(&conn);
    }
    let line = screen_rows(&f)[1].text();
    assert!(!line.contains("runtime error"), "{line:?}");
}

/// The status line once it shows `want`, from a session with the command
/// line plugin too.
fn command_line_says(text: &'static str, typed: &str, want: &str) -> String {
    let conn = server::spawn(move || {
        let mut editor = Editor::new(ClientId(1));
        editor.open("file", text, None);
        let host = Host::new(editor)?;
        let runtime = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../runtime/plugins");
        for plugin in ["core", "helix", "cmdline"] {
            host.load_dir(&runtime.join(plugin))?;
        }
        host.load_str(
            "buggy",
            "require('@greed').command { name = 'buggy', run = function() local t = nil; t.x = 1 end }",
        )?;
        Ok(host)
    });
    conn.input
        .send(Input::Resize(Size {
            width: 120,
            height: 4,
        }))
        .unwrap();
    frame(&conn);
    keys(&conn, typed);
    loop {
        let f = frame(&conn);
        let line = screen_rows(&f)[3].text();
        if line.contains(want) {
            return line;
        }
    }
}

#[test]
fn refusals_and_unknown_commands_from_the_command_line_are_plain() {
    let line = command_line_says("hi", "i x esc : q enter", "unsaved changes");
    assert!(!line.contains("runtime error"), "{line:?}");
    assert!(!line.contains("command-line-run"), "{line:?}");
    let line = command_line_says("hi", ": n o p e enter", "no command called nope");
    assert!(!line.contains("cmdline"), "{line:?}");
    // A bug still says which plugin it's in and doing what.
    let line = command_line_says("hi", ": b u g g y enter", "attempt to");
    assert!(
        line.contains("cmdline (command-line-run): buggy:1:"),
        "{line:?}"
    );
    assert!(!line.contains("runtime error"), "{line:?}");
}
