//! Terminals running real programs.

use std::time::{Duration, Instant};

use crossbeam_channel::Receiver;
use kern_core::keymap::Key;
use kern_core::terminal::{Event, Options, Screen, Terminal, TerminalId};

fn start(command: &[&str], rows: u16, cols: u16) -> (Terminal, Receiver<Event>) {
    let (events, received) = crossbeam_channel::unbounded();
    let options = Options {
        command: Some(command.iter().map(ToString::to_string).collect()),
        cwd: None,
        env: vec![("PS1".into(), "$ ".into())],
        rows,
        cols,
        scrollback: 1000,
        cell: (10, 20),
    };
    let terminal = Terminal::spawn(TerminalId(1), &options, events).unwrap();
    (terminal, received)
}

/// Waits until the program has ended, returning its exit code.
fn exited(events: &Receiver<Event>) -> u32 {
    loop {
        match events
            .recv_timeout(Duration::from_secs(10))
            .expect("the program ends")
        {
            Event::Exited(_, code) => return code,
            Event::Output(_) => {}
        }
    }
}

/// Waits until the screen shows something `done` accepts.
fn until(terminal: &Terminal, done: impl Fn(&Screen) -> bool) -> Screen {
    let start = Instant::now();
    loop {
        let screen = terminal.screen();
        if done(&screen) {
            return screen;
        }
        assert!(
            start.elapsed() < Duration::from_secs(10),
            "gave up waiting: {screen:#?}"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn text(screen: &Screen) -> Vec<&str> {
    screen.rows.iter().map(|row| row.text.as_str()).collect()
}

#[test]
fn output_lands_on_the_screen_with_its_colors() {
    let (terminal, events) = start(
        &["printf", "plain \\033[31mred\\033[1;44m both\\033[0m"],
        5,
        40,
    );
    assert_eq!(exited(&events), 0);
    let screen = terminal.screen();
    let row = &screen.rows[0];
    assert_eq!(row.text, "plain red both");
    let styles: Vec<_> = row
        .spans
        .iter()
        .map(|s| (&row.text[s.from..s.to], &*s.style))
        .collect();
    assert_eq!(
        styles,
        [("red", "=fg:red"), (" both", "=fg:red bg:blue bold")]
    );
    assert_eq!(text(&screen)[1..], ["", "", "", ""]);
}

#[test]
fn the_exit_code_comes_with_the_end() {
    let (terminal, events) = start(&["sh", "-c", "exit 3"], 5, 40);
    assert_eq!(exited(&events), 3);
    assert_eq!(terminal.exit_code(), Some(3));
}

#[test]
fn typed_keys_reach_the_program_and_the_cursor_follows() {
    let (terminal, _events) = start(&["cat"], 5, 40);
    terminal.write(b"hi".to_vec());
    terminal.key(Key::parse("enter").unwrap());
    let screen = until(&terminal, |s| s.rows[1].text == "hi");
    assert_eq!(screen.rows[0].text, "hi");
    // The cursor is at the start of the empty line after the echo.
    assert_eq!(screen.cursor, Some((2, 0)));
    terminal.write(b"ab".to_vec());
    let screen = until(&terminal, |s| s.rows[2].text == "ab");
    assert_eq!(screen.cursor, Some((2, 2)));
}

#[test]
fn lines_scrolling_off_the_top_move_to_the_scrollback() {
    let (terminal, events) = start(&["seq", "1", "30"], 10, 20);
    exited(&events);
    let scrollback = terminal.scrollback(0);
    assert_eq!(scrollback.first, 0);
    let lines: Vec<_> = scrollback.rows.iter().map(|r| r.text.as_str()).collect();
    // 30 lines and the empty one after them fill 10 rows; 21 scrolled off.
    assert_eq!(lines.len(), 21);
    assert_eq!(lines[0], "1");
    assert_eq!(lines[20], "21");
    assert_eq!(text(&terminal.screen())[0], "22");
    let later = terminal.scrollback(18);
    assert_eq!(later.first, 18);
    assert_eq!(later.rows[0].text, "19");
    assert_eq!(terminal.scrollback(99).rows, []);
}

#[test]
fn only_so_much_scrollback_is_kept() {
    let (events, received) = crossbeam_channel::unbounded();
    let options = Options {
        command: Some(vec!["seq".into(), "1".into(), "100".into()]),
        cwd: None,
        env: Vec::new(),
        rows: 5,
        cols: 20,
        scrollback: 10,
        cell: (10, 20),
    };
    let terminal = Terminal::spawn(TerminalId(1), &options, events).unwrap();
    exited(&received);
    let scrollback = terminal.scrollback(0);
    assert_eq!(scrollback.first, 86);
    assert_eq!(scrollback.rows.len(), 10);
    assert_eq!(scrollback.rows[0].text, "87");
}

#[test]
fn resizing_tells_the_program() {
    let (terminal, _events) = start(&["sh", "-c", "read x; stty size"], 5, 40);
    terminal.resize(12, 60, (10, 20)).unwrap();
    terminal.write(b"\r".to_vec());
    until(&terminal, |s| {
        s.rows.len() == 12 && text(s).contains(&"12 60")
    });
}

#[test]
fn wide_characters_take_one_place_in_the_text() {
    let (terminal, events) = start(&["printf", "日本 x"], 3, 20);
    exited(&events);
    assert_eq!(terminal.screen().rows[0].text, "日本 x");
}

#[test]
fn the_title_programs_set_is_kept() {
    let (terminal, events) = start(&["printf", "\\033]0;building\\007"], 3, 20);
    exited(&events);
    assert_eq!(terminal.title().as_deref(), Some("building"));
}

/// A red and a blue pixel, as kitty's raw RGB in base64.
const PIXELS: &str = "/wAAAAD/";

/// A 1 by 1 PNG, in base64.
const PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

/// An image run on a row: (byte, column, row, columns, rows).
type Run = (usize, u16, u16, u16, u16);

/// Each row's images.
fn images(rows: &[kern_core::terminal::Row]) -> Vec<Vec<Run>> {
    rows.iter()
        .map(|row| {
            row.images
                .iter()
                .map(|i| (i.from, i.col, i.row, i.cols, i.rows))
                .collect()
        })
        .collect()
}

#[test]
fn kitty_images_cover_cells_and_the_cursor_moves_past_them() {
    let shown = format!("\\033_Ga=T,f=24,s=2,v=1,c=4,r=2,q=2;{PIXELS}\\033\\\\after");
    let (terminal, events) = start(&["printf", &shown], 4, 20);
    exited(&events);
    let screen = terminal.screen();
    assert_eq!(
        images(&screen.rows)[..2],
        [vec![(0, 0, 0, 4, 2)], vec![(0, 0, 1, 4, 2)]]
    );
    assert_eq!(text(&screen)[..2], ["    ", "    after"]);
    let id = screen.rows[0].images[0].id;
    let image = terminal.image(id).expect("the image is there to show");
    assert_eq!((image.width, image.height), (2, 1));
}

#[test]
fn text_written_over_an_image_takes_its_place() {
    let shown = format!("\\033_Ga=T,f=24,s=2,v=1,c=4,r=1,q=2;{PIXELS}\\033\\\\\\rxy");
    let (terminal, events) = start(&["printf", &shown], 3, 20);
    exited(&events);
    let screen = terminal.screen();
    assert_eq!(screen.rows[0].text, "xy  ");
    assert_eq!(images(&screen.rows)[0], [(2, 2, 0, 4, 1)]);
}

#[test]
fn images_scroll_into_the_scrollback_with_their_rows() {
    let shown = format!("\\033_Ga=T,f=24,s=2,v=1,c=2,r=2,q=2;{PIXELS}\\033\\\\\\n1\\n2\\n3\\n");
    let (terminal, events) = start(&["printf", &shown], 3, 20);
    exited(&events);
    let scrollback = terminal.scrollback(0);
    assert_eq!(
        images(&scrollback.rows)[..2],
        [vec![(0, 0, 0, 2, 2)], vec![(0, 0, 1, 2, 2)]]
    );
}

#[test]
fn kitty_can_delete_images_again() {
    let shown = format!(
        "\\033_Ga=T,f=24,s=2,v=1,c=2,r=1,i=5,q=2;{PIXELS}\\033\\\\\\033_Ga=d,d=i,i=5,q=2\\033\\\\"
    );
    let (terminal, events) = start(&["printf", &shown], 3, 20);
    exited(&events);
    assert_eq!(images(&terminal.screen().rows)[0], []);
}

#[test]
fn iterm_images_are_sized_in_cells_or_by_their_pixels() {
    let shown = format!("\\033]1337;File=inline=1;width=3;height=2:{PNG}\\a");
    let (terminal, events) = start(&["printf", &shown], 4, 20);
    exited(&events);
    assert_eq!(images(&terminal.screen().rows)[0], [(0, 0, 0, 3, 2)]);
}

mod from_luau {
    use std::time::Duration;

    use kern_core::Editor;
    use kern_core::luau::Host;
    use kern_text::ClientId;

    fn host() -> Host {
        let mut editor = Editor::new(ClientId(1));
        editor.open("file", "", None);
        Host::new(editor).unwrap()
    }

    /// Passes terminal events to the plugins until `done` is true in Luau.
    fn pump(host: &Host, done: &str) {
        let events = host.terminal_events();
        for _ in 0..500 {
            if host.eval(done).unwrap() == "true" {
                return;
            }
            if let Ok(event) = events.recv_timeout(Duration::from_millis(20)) {
                host.handle_terminal(event).unwrap();
            }
        }
        panic!("{done} never became true");
    }

    #[test]
    fn plugins_hear_about_output_and_the_end() {
        let h = host();
        h.load_str(
            "term",
            r#"
            local kern = require("@kern")
            local seen: { text: string?, code: number? } = {}
            local t = kern.terminal.spawn({ command = { "sh", "-c", "printf hello; exit 4" }, rows = 3, cols = 20 })
            kern.on("terminal.output", function(e)
                seen.text = e.terminal:screen().rows[1].text
            end)
            kern.on("terminal.exited", function(e)
                seen.code = e.code
                assert(e.terminal:id() == t:id())
            end)
            return seen
            "#,
        )
        .unwrap();
        pump(
            &h,
            "require(\"@term\").code ~= nil and require(\"@term\").text ~= nil",
        );
        assert_eq!(h.eval("require(\"@term\").text").unwrap(), "hello");
        assert_eq!(h.eval("require(\"@term\").code").unwrap(), "4");
    }

    #[test]
    fn unloading_the_plugin_ends_its_terminals() {
        let h = host();
        h.load_str(
            "term",
            r#"
            local kern = require("@kern")
            return kern.terminal.spawn({ command = { "sleep", "30" }, rows = 3, cols = 20 })
            "#,
        )
        .unwrap();
        h.eval("t = require(\"@term\")").unwrap();
        h.unload("term").unwrap();
        let err = h.eval("t:screen()").unwrap_err().to_string();
        assert!(err.contains("closed"), "{err}");
    }
}
