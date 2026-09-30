//! The terminal client: sends key presses and resizes to the server, and
//! draws the frames it sends back.

use std::io::{self, Write};
use std::thread;

use crossterm::cursor::{self, SetCursorStyle};
use crossterm::event::{self, Event, KeyCode as TermKey, KeyEvent, KeyEventKind, KeyModifiers};
use crossterm::style::{Attribute, Color, ContentStyle, PrintStyledContent, ResetColor, Stylize};
use crossterm::terminal::{self, ClearType};
use crossterm::{execute, queue};
use kern_core::keymap::{Key, KeyCode, Mods};
use kern_core::render::{Frame, Row, Size, Tag};
use kern_core::server::{Connection, Input, Output};

type Error = Box<dyn std::error::Error>;

/// Runs the terminal client until the server exits.
pub fn run(conn: Connection) -> Result<(), Error> {
    let terminal = Terminal::enter()?;
    let (width, height) = terminal::size()?;
    conn.input.send(Input::Resize(Size { width, height }))?;

    let input = conn.input.clone();
    thread::spawn(move || {
        while let Ok(event) = event::read() {
            let message = match event {
                Event::Key(key) if key.kind != KeyEventKind::Release => {
                    convert(key).map(Input::Key)
                }
                Event::Resize(width, height) => Some(Input::Resize(Size { width, height })),
                _ => None,
            };
            if message.is_some_and(|m| input.send(m).is_err()) {
                break;
            }
        }
    });

    let mut screen = Screen::default();
    let mut out = io::BufWriter::new(io::stdout());
    while let Ok(Output::Frame(frame)) = conn.output.recv() {
        screen.draw(&mut out, &frame)?;
    }
    drop(terminal);
    conn.server.join().map_err(|_| "the editor crashed")??;
    Ok(())
}

/// Converts a terminal key event into a kern key. Returns `None` for keys
/// kern doesn't know.
pub fn convert(event: KeyEvent) -> Option<Key> {
    let code = match event.code {
        TermKey::Char(c) => KeyCode::Char(c),
        TermKey::Enter => KeyCode::Enter,
        TermKey::Esc => KeyCode::Esc,
        TermKey::Tab | TermKey::BackTab => KeyCode::Tab,
        TermKey::Backspace => KeyCode::Backspace,
        TermKey::Delete => KeyCode::Delete,
        TermKey::Insert => KeyCode::Insert,
        TermKey::Up => KeyCode::Up,
        TermKey::Down => KeyCode::Down,
        TermKey::Left => KeyCode::Left,
        TermKey::Right => KeyCode::Right,
        TermKey::Home => KeyCode::Home,
        TermKey::End => KeyCode::End,
        TermKey::PageUp => KeyCode::PageUp,
        TermKey::PageDown => KeyCode::PageDown,
        TermKey::F(n) => KeyCode::F(n),
        _ => return None,
    };
    let m = event.modifiers;
    let mut mods = Mods::NONE;
    if m.contains(KeyModifiers::CONTROL) {
        mods = mods | Mods::CTRL;
    }
    if m.contains(KeyModifiers::ALT) {
        mods = mods | Mods::ALT;
    }
    // Shifted characters arrive as the character itself ("G"), so shift only
    // counts for other keys.
    let shifted = m.contains(KeyModifiers::SHIFT) || event.code == TermKey::BackTab;
    if shifted && !matches!(code, KeyCode::Char(_)) {
        mods = mods | Mods::SHIFT;
    }
    Some(Key { code, mods })
}

/// Raw mode and the alternate screen, restored when dropped or on panic.
struct Terminal;

impl Terminal {
    fn enter() -> io::Result<Self> {
        let hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            restore();
            hook(info);
        }));
        terminal::enable_raw_mode()?;
        execute!(io::stdout(), terminal::EnterAlternateScreen)?;
        Ok(Self)
    }
}

impl Drop for Terminal {
    fn drop(&mut self) {
        restore();
    }
}

fn restore() {
    let _ = execute!(
        io::stdout(),
        SetCursorStyle::DefaultUserShape,
        cursor::Show,
        terminal::LeaveAlternateScreen
    );
    let _ = terminal::disable_raw_mode();
}

/// What's on the terminal now, so only changed rows are redrawn.
#[derive(Default)]
struct Screen {
    rows: Vec<Row>,
}

impl Screen {
    fn draw(&mut self, out: &mut impl Write, frame: &Frame) -> io::Result<()> {
        if self.rows.len() != frame.rows.len() {
            self.rows.clear();
            queue!(out, terminal::Clear(ClearType::All))?;
        }
        queue!(out, cursor::Hide)?;
        for (y, row) in frame.rows.iter().enumerate() {
            if self.rows.get(y) == Some(row) {
                continue;
            }
            queue!(out, cursor::MoveTo(0, u16::try_from(y).unwrap_or(u16::MAX)))?;
            for span in &row.spans {
                queue!(
                    out,
                    PrintStyledContent(style(&span.tags).apply(span.text.as_str()))
                )?;
            }
            queue!(out, ResetColor, terminal::Clear(ClearType::UntilNewLine))?;
        }
        self.rows.clone_from(&frame.rows);
        if let Some(pos) = frame.cursor {
            let shape = if frame.mode == "insert" {
                SetCursorStyle::SteadyBar
            } else {
                SetCursorStyle::SteadyBlock
            };
            queue!(out, cursor::MoveTo(pos.col, pos.row), shape, cursor::Show)?;
        }
        out.flush()
    }
}

/// The default theme.
fn style(tags: &[Tag]) -> ContentStyle {
    let mut style = ContentStyle::new();
    for tag in tags {
        style = match tag {
            Tag::Gutter => style.dark_grey(),
            Tag::Selection => style.on(Color::DarkBlue),
            Tag::Cursor => style.reverse(),
            Tag::Status => style.on(Color::DarkGrey).white(),
            Tag::Mode => style.on(Color::Blue).black().attribute(Attribute::Bold),
            Tag::Message => style.on(Color::DarkGrey).yellow(),
            Tag::Syntax(capture) => syntax_style(style, capture),
        };
    }
    style
}

/// Colors for tree-sitter captures, chosen by the first part of the name
/// ("function" for "function.macro").
fn syntax_style(style: ContentStyle, capture: &str) -> ContentStyle {
    if capture == "text.title" {
        return style.blue().attribute(Attribute::Bold);
    }
    match capture.split('.').next().unwrap_or(capture) {
        "keyword" | "conditional" | "repeat" | "include" | "exception" => style.magenta(),
        "string" | "character" => style.green(),
        "comment" => style.dark_grey().attribute(Attribute::Italic),
        "function" | "method" | "constructor" => style.blue(),
        "type" | "attribute" | "label" => style.yellow(),
        "constant" | "number" | "boolean" | "float" | "escape" => style.cyan(),
        _ => style,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(code: TermKey, mods: KeyModifiers) -> Option<String> {
        convert(KeyEvent::new(code, mods)).map(|k| k.to_string())
    }

    #[test]
    fn keys_convert_to_kern_names() {
        assert_eq!(
            key(TermKey::Char('g'), KeyModifiers::NONE).as_deref(),
            Some("g")
        );
        assert_eq!(
            key(TermKey::Char('G'), KeyModifiers::SHIFT).as_deref(),
            Some("G")
        );
        assert_eq!(
            key(TermKey::Char('s'), KeyModifiers::CONTROL).as_deref(),
            Some("ctrl-s")
        );
        assert_eq!(
            key(TermKey::Char(';'), KeyModifiers::ALT).as_deref(),
            Some("alt-;")
        );
        assert_eq!(
            key(TermKey::Char(' '), KeyModifiers::NONE).as_deref(),
            Some("space")
        );
        assert_eq!(
            key(TermKey::Esc, KeyModifiers::NONE).as_deref(),
            Some("esc")
        );
        assert_eq!(
            key(TermKey::BackTab, KeyModifiers::SHIFT).as_deref(),
            Some("shift-tab")
        );
        assert_eq!(
            key(TermKey::F(5), KeyModifiers::NONE).as_deref(),
            Some("f5")
        );
        assert_eq!(key(TermKey::CapsLock, KeyModifiers::NONE), None);
    }

    #[test]
    fn only_changed_rows_are_redrawn() {
        let frame = |text: &str| Frame {
            size: Size {
                width: 10,
                height: 2,
            },
            rows: vec![Row::default(), plain(text)],
            cursor: None,
            mode: "normal".into(),
        };
        let mut screen = Screen::default();
        let mut out = Vec::new();
        screen.draw(&mut out, &frame("one")).unwrap();
        assert!(String::from_utf8_lossy(&out).contains("one"));

        out.clear();
        screen.draw(&mut out, &frame("one")).unwrap();
        assert!(!String::from_utf8_lossy(&out).contains("one"));

        out.clear();
        screen.draw(&mut out, &frame("two")).unwrap();
        assert!(String::from_utf8_lossy(&out).contains("two"));
    }

    fn plain(text: &str) -> Row {
        Row {
            spans: vec![kern_core::render::Span {
                text: text.into(),
                tags: std::iter::empty().collect(),
            }],
        }
    }
}
