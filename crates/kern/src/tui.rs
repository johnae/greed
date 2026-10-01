//! The terminal client: sends key presses and resizes to the server, and
//! draws the frames it sends back.

use std::io::{self, Write};
use std::thread;

use crossterm::cursor::{self, SetCursorStyle};
use crossterm::event::{self, Event, KeyCode as TermKey, KeyEvent, KeyEventKind, KeyModifiers};
use crossterm::style::{Attribute, Color, ContentStyle, PrintStyledContent, ResetColor};
use crossterm::terminal::{self, ClearType};
use crossterm::{execute, queue};
use kern_core::CursorShape;
use kern_core::keymap::{Key, KeyCode, Mods};
use kern_core::render::{Frame, Row, Size, Tag};
use kern_core::server::{Connection, Input, Output};
use kern_core::theme::{Color as ThemeColor, Style, Surface, Theme, Underline};
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

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

/// One terminal cell. The second cell of a wide character has empty text.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Cell {
    text: String,
    style: ContentStyle,
}

impl Default for Cell {
    fn default() -> Self {
        Self {
            text: " ".to_owned(),
            style: ContentStyle::new(),
        }
    }
}

/// What's on the terminal now, so only changed rows are redrawn.
#[derive(Default)]
struct Screen {
    grid: Vec<Vec<Cell>>,
}

impl Screen {
    fn draw(&mut self, out: &mut impl Write, frame: &Frame) -> io::Result<()> {
        let grid = compose(frame);
        if self.grid.len() != grid.len()
            || self.grid.first().map(Vec::len) != grid.first().map(Vec::len)
        {
            self.grid.clear();
            queue!(out, terminal::Clear(ClearType::All))?;
        }
        queue!(out, cursor::Hide)?;
        for (y, row) in grid.iter().enumerate() {
            if self.grid.get(y) == Some(row) {
                continue;
            }
            queue!(out, cursor::MoveTo(0, u16::try_from(y).unwrap_or(u16::MAX)))?;
            let mut run = String::new();
            let mut run_style = ContentStyle::new();
            for cell in row.iter().filter(|c| !c.text.is_empty()) {
                if cell.style != run_style && !run.is_empty() {
                    queue!(out, PrintStyledContent(run_style.apply(run.as_str())))?;
                    run.clear();
                }
                run_style = cell.style;
                run.push_str(&cell.text);
            }
            queue!(
                out,
                PrintStyledContent(run_style.apply(run.as_str())),
                ResetColor
            )?;
        }
        self.grid = grid;
        if let Some(pos) = frame.cursor {
            let shape = match frame.cursor_shape {
                CursorShape::Block => SetCursorStyle::SteadyBlock,
                CursorShape::Bar => SetCursorStyle::SteadyBar,
                CursorShape::Underline => SetCursorStyle::SteadyUnderScore,
            };
            queue!(out, cursor::MoveTo(pos.col, pos.row), shape, cursor::Show)?;
        }
        out.flush()
    }
}

/// Lays the frame out as cells: the main view, then each floating view in a
/// box on top, styled by the frame's theme.
fn compose(frame: &Frame) -> Vec<Vec<Cell>> {
    let theme = &frame.theme;
    let look = |tag: &Tag| theme.style(tag.name(), Surface::Tui);
    let width = usize::from(frame.size.width);
    let text = look(&Tag::TEXT);
    let blank = Cell {
        text: " ".to_owned(),
        style: terminal_style(text),
    };
    let mut grid = vec![vec![blank; width]; usize::from(frame.size.height)];
    for (line, row) in grid.iter_mut().zip(&frame.rows) {
        put_row(line, 0, width, row, text, theme);
    }
    for float in &frame.floats {
        let r = float.rect;
        let (x, y, w, h) = (
            usize::from(r.x),
            usize::from(r.y),
            usize::from(r.width),
            usize::from(r.height),
        );
        let body = text.patch(&look(&Tag::FLOAT));
        let border = body.patch(&look(&Tag::FLOAT_BORDER));
        for (dy, line) in grid.iter_mut().enumerate().skip(y - 1).take(h + 2) {
            let (left, fill, right) = match dy {
                d if d == y - 1 => ('┌', '─', '┐'),
                d if d == y + h => ('└', '─', '┘'),
                _ => ('│', ' ', '│'),
            };
            let mut cells = std::iter::once(left)
                .chain(std::iter::repeat_n(fill, w))
                .chain(std::iter::once(right));
            for cell in line.iter_mut().skip(x - 1).take(w + 2) {
                let c = cells.next().unwrap_or(' ');
                let style = if c == ' ' { body } else { border };
                *cell = Cell {
                    text: c.to_string(),
                    style: terminal_style(style),
                };
            }
        }
        if let (Some(title), Some(top)) = (&float.title, grid.get_mut(y - 1))
            && !title.is_empty()
        {
            let style = terminal_style(border.patch(&look(&Tag::FLOAT_TITLE)));
            put(
                top,
                x + 1,
                w.saturating_sub(2),
                &format!(" {title} "),
                style,
            );
        }
        for (line, row) in grid.iter_mut().skip(y).take(h).zip(&float.rows) {
            put_row(line, x, w, row, body, theme);
        }
    }
    grid
}

/// Draws `row` over `base`, each span styled by the row's tags and then its
/// own, in order. A row with tags of its own fills its whole width.
fn put_row(line: &mut [Cell], x: usize, width: usize, row: &Row, base: Style, theme: &Theme) {
    let layer = |style: Style, tags: &[Tag]| {
        tags.iter().fold(style, |style, tag| {
            style.patch(&theme.style(tag.name(), Surface::Tui))
        })
    };
    let base = layer(base, &row.tags);
    let mut used = 0;
    for span in &row.spans {
        let style = layer(base, &span.tags);
        used += put(
            line,
            x + used,
            width - used,
            &span.text,
            terminal_style(style),
        );
    }
    if !row.tags.is_empty() {
        let fill = " ".repeat(width - used);
        put(line, x + used, width - used, &fill, terminal_style(base));
    }
}

/// Writes `text` into `line` from cell `x`, within `width` cells. Returns how
/// many cells it used.
fn put(line: &mut [Cell], x: usize, width: usize, text: &str, style: ContentStyle) -> usize {
    let mut used = 0;
    for grapheme in text.graphemes(true) {
        let w = grapheme.width().max(1);
        if used + w > width || x + used + w > line.len() {
            break;
        }
        line[x + used] = Cell {
            text: grapheme.to_owned(),
            style,
        };
        for extra in 1..w {
            line[x + used + extra] = Cell {
                text: String::new(),
                style,
            };
        }
        used += w;
    }
    used
}

/// A theme style as the terminal draws it.
fn terminal_style(style: Style) -> ContentStyle {
    let mut out = ContentStyle::new();
    out.foreground_color = style.fg.map(terminal_color);
    out.background_color = style.bg.map(terminal_color);
    out.underline_color = style.underline_color.map(terminal_color);
    let flags = [
        (style.bold, Attribute::Bold),
        (style.italic, Attribute::Italic),
        (style.dim, Attribute::Dim),
        (style.reverse, Attribute::Reverse),
        (style.strikethrough, Attribute::CrossedOut),
    ];
    for (on, attribute) in flags {
        if on == Some(true) {
            out.attributes.set(attribute);
        }
    }
    if let Some(underline) = style.underline {
        out.attributes.set(match underline {
            Underline::Line => Attribute::Underlined,
            Underline::Curl => Attribute::Undercurled,
            Underline::Dotted => Attribute::Underdotted,
            Underline::Dashed => Attribute::Underdashed,
            Underline::Double => Attribute::DoubleUnderlined,
        });
    }
    out
}

/// The 16 terminal colors are the terminal's own palette, so themes follow
/// it.
fn terminal_color(color: ThemeColor) -> Color {
    const ANSI: [Color; 16] = [
        Color::Black,
        Color::DarkRed,
        Color::DarkGreen,
        Color::DarkYellow,
        Color::DarkBlue,
        Color::DarkMagenta,
        Color::DarkCyan,
        Color::Grey,
        Color::DarkGrey,
        Color::Red,
        Color::Green,
        Color::Yellow,
        Color::Blue,
        Color::Magenta,
        Color::Cyan,
        Color::White,
    ];
    match color {
        ThemeColor::Default => Color::Reset,
        ThemeColor::Ansi(n) => ANSI[usize::from(n % 16)],
        ThemeColor::Rgb(r, g, b) => Color::Rgb { r, g, b },
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
            floats: Vec::new(),
            cursor: None,
            cursor_shape: CursorShape::Block,
            theme: std::sync::Arc::default(),
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

    #[test]
    fn floats_are_drawn_in_a_box_over_the_rows() {
        use kern_core::render::{FloatFrame, Rect};
        let frame = Frame {
            size: Size {
                width: 12,
                height: 5,
            },
            rows: vec![plain("abcdefghijkl"); 5],
            floats: vec![FloatFrame {
                rect: Rect {
                    x: 2,
                    y: 1,
                    width: 6,
                    height: 2,
                },
                title: Some("hi".into()),
                rows: vec![plain("one"), plain("日本語")],
            }],
            cursor: None,
            cursor_shape: CursorShape::Block,
            theme: std::sync::Arc::default(),
        };
        let text: Vec<String> = compose(&frame)
            .iter()
            .map(|row| row.iter().map(|c| c.text.as_str()).collect())
            .collect();
        assert_eq!(
            text,
            [
                "a┌─ hi ─┐jkl",
                "a│one   │jkl",
                "a│日本語│jkl",
                "a└──────┘jkl",
                "abcdefghijkl",
            ]
        );
    }

    fn plain(text: &str) -> Row {
        Row {
            spans: vec![kern_core::render::Span {
                text: text.into(),
                tags: std::iter::empty().collect(),
            }],
            ..Row::default()
        }
    }

    #[test]
    fn cells_take_their_look_from_the_theme() {
        use kern_core::render::Span;
        use kern_core::theme::{Entry, Style};
        let mut theme = Theme::default();
        theme.set(
            "keyword",
            Entry {
                style: Style {
                    fg: Some(ThemeColor::Ansi(5)),
                    bold: Some(true),
                    ..Style::default()
                },
                tui: Style {
                    fg: Some(ThemeColor::Ansi(13)),
                    ..Style::default()
                },
                gui: Style::default(),
            },
        );
        theme.set(
            "ui.selection",
            Entry::new(Style {
                bg: Some(ThemeColor::Rgb(1, 2, 3)),
                ..Style::default()
            }),
        );
        theme.set(
            "current",
            Entry::new(Style {
                bg: Some(ThemeColor::Ansi(8)),
                ..Style::default()
            }),
        );
        let frame = Frame {
            size: Size {
                width: 4,
                height: 1,
            },
            rows: vec![Row {
                spans: vec![Span {
                    text: "fn".into(),
                    tags: [Tag::from("keyword.function"), Tag::SELECTION]
                        .into_iter()
                        .collect(),
                }],
                tags: [Tag::from("current")].into_iter().collect(),
            }],
            floats: Vec::new(),
            cursor: None,
            cursor_shape: CursorShape::Block,
            theme: std::sync::Arc::new(theme),
        };
        let cell = &compose(&frame)[0][0];
        assert_eq!(cell.style.foreground_color, Some(Color::Magenta));
        assert_eq!(
            cell.style.background_color,
            Some(Color::Rgb { r: 1, g: 2, b: 3 })
        );
        assert!(cell.style.attributes.has(Attribute::Bold));
        // The row's own style fills past its text.
        let end = &compose(&frame)[0][3];
        assert_eq!(end.style.background_color, Some(Color::DarkGrey));
    }
}
