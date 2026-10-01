//! The terminal client: sends key presses and resizes to the server, and
//! draws the frames it sends back.

use std::io::{self, Write};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::Duration;

use crate::graphics::{self, Graphics};
use crossbeam_channel::{Receiver, Sender};
use crossterm::cursor::{self, SetCursorStyle};
use crossterm::event::{
    self, Event, KeyCode as TermKey, KeyEvent, KeyEventKind, KeyModifiers, MouseButton, MouseEvent,
    MouseEventKind,
};
use crossterm::style::{Attribute, Color, ContentStyle, PrintStyledContent, ResetColor};
use crossterm::terminal::{self, ClearType};
use crossterm::{execute, queue};
use kern_core::CursorShape;
use kern_core::keymap::{Key, KeyCode, Mods};
use kern_core::mouse::{Button, Mouse, MouseKind};
use kern_core::render::{Frame, Row, Size, Tag};
use kern_core::server::{Input, Output};
use kern_core::theme::{Color as ThemeColor, Style, Surface, Theme, Underline};
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

type Error = Box<dyn std::error::Error>;

/// How often the key reader checks whether its run is over.
const KEY_POLL: Duration = Duration::from_millis(50);

/// Runs the terminal client until the server exits or lets it go, sending
/// keys and sizes to `input` and drawing the frames from `output`. Returns
/// how it ended.
pub fn run(input: &Sender<Input>, output: &Receiver<Output>) -> Result<Output, Error> {
    let terminal = Terminal::enter()?;
    let (width, height) = terminal::size()?;
    input.send(Input::Resize(Size { width, height }))?;
    send_cell_size(input);

    // Keys are read until this run ends, so a run that follows (after a
    // switch to another session) gets them all.
    let reading = Arc::new(AtomicBool::new(true));
    let keys = {
        let input = input.clone();
        let reading = reading.clone();
        thread::spawn(move || {
            while reading.load(Ordering::Relaxed) {
                if !event::poll(KEY_POLL).unwrap_or(false) {
                    continue;
                }
                let Ok(event) = event::read() else { break };
                let message = match event {
                    Event::Key(key) if key.kind != KeyEventKind::Release => {
                        convert(key).map(Input::Key)
                    }
                    Event::Mouse(mouse) => Some(Input::Mouse(convert_mouse(mouse))),
                    Event::Resize(width, height) => {
                        send_cell_size(&input);
                        Some(Input::Resize(Size { width, height }))
                    }
                    _ => None,
                };
                if message.is_some_and(|m| input.send(m).is_err()) {
                    break;
                }
            }
        })
    };

    let mut screen = Screen {
        graphics: Graphics::new(graphics::detect()),
        ..Screen::default()
    };
    let mut out = io::BufWriter::new(io::stdout());
    // Deltas change the last whole frame into the next.
    let mut current: Option<Frame> = None;
    let ended = loop {
        match output.recv() {
            Ok(Output::Image(image)) => screen.graphics.add(image),
            Ok(Output::Clipboard(text)) => copy_to_system(&mut out, &text)?,
            Ok(Output::Frame(frame)) => {
                screen.draw(&mut out, &frame)?;
                current = Some(frame);
            }
            Ok(Output::Delta(delta)) => {
                if let Some(frame) = &mut current {
                    delta.apply(frame);
                    screen.draw(&mut out, frame)?;
                }
            }
            Ok(other) => break other,
            Err(_) => break Output::Exit,
        }
    };
    reading.store(false, Ordering::Relaxed);
    let _ = keys.join();
    drop(terminal);
    Ok(ended)
}

/// Tells the server how big a cell is in pixels, if the terminal says, for
/// sizing images.
fn send_cell_size(input: &Sender<Input>) {
    if let Ok(size) = terminal::window_size()
        && size.columns > 0
        && size.rows > 0
        && size.width > 0
    {
        let _ = input.send(Input::CellSize(
            size.width / size.columns,
            size.height / size.rows,
        ));
    }
}

/// Puts `text` on the system clipboard through the terminal (OSC 52),
/// which works over ssh too, unless `$KERN_CLIPBOARD` is "off".
fn copy_to_system(out: &mut impl Write, text: &str) -> io::Result<()> {
    if std::env::var("KERN_CLIPBOARD").is_ok_and(|v| v == "off") {
        return Ok(());
    }
    write!(out, "{}", osc52(text))?;
    out.flush()
}

fn osc52(text: &str) -> String {
    use base64::Engine;
    let encoded = base64::engine::general_purpose::STANDARD.encode(text);
    format!("\x1b]52;c;{encoded}\x07")
}

/// Whether to take the mouse from the terminal: unless `$KERN_MOUSE` is
/// "off". Most terminals still select their own way with shift held.
fn mouse_wanted() -> bool {
    std::env::var("KERN_MOUSE").map_or(true, |v| v != "off")
}

/// Converts a terminal mouse event into a kern one.
fn convert_mouse(event: MouseEvent) -> Mouse {
    let button = |b: MouseButton| match b {
        MouseButton::Left => Button::Left,
        MouseButton::Right => Button::Right,
        MouseButton::Middle => Button::Middle,
    };
    let kind = match event.kind {
        MouseEventKind::Down(b) => MouseKind::Press(button(b)),
        MouseEventKind::Up(b) => MouseKind::Release(button(b)),
        MouseEventKind::Drag(b) => MouseKind::Drag(button(b)),
        MouseEventKind::Moved => MouseKind::Move,
        MouseEventKind::ScrollUp => MouseKind::ScrollUp,
        MouseEventKind::ScrollDown => MouseKind::ScrollDown,
        MouseEventKind::ScrollLeft => MouseKind::ScrollLeft,
        MouseEventKind::ScrollRight => MouseKind::ScrollRight,
    };
    Mouse {
        kind,
        col: event.column,
        row: event.row,
        ctrl: event.modifiers.contains(KeyModifiers::CONTROL),
        alt: event.modifiers.contains(KeyModifiers::ALT),
        shift: event.modifiers.contains(KeyModifiers::SHIFT),
    }
}

/// Converts a terminal key event into a kern key. Returns `None` for keys
/// kern doesn't know.
pub fn convert(event: KeyEvent) -> Option<Key> {
    let ctrl = event.modifiers.contains(KeyModifiers::CONTROL);
    let code = match event.code {
        // Terminals send ctrl-\ ] ^ _ as the bytes crossterm reads as
        // ctrl-4 to ctrl-7.
        TermKey::Char(c @ '4'..='7') if ctrl => KeyCode::Char(match c {
            '4' => '\\',
            '5' => ']',
            '6' => '^',
            _ => '_',
        }),
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
    if ctrl {
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
        if mouse_wanted() {
            execute!(io::stdout(), event::EnableMouseCapture)?;
        }
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
        event::DisableMouseCapture,
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
    graphics: Graphics,
}

impl Screen {
    fn draw(&mut self, out: &mut impl Write, frame: &Frame) -> io::Result<()> {
        let grid = compose(frame);
        if self.grid.len() != grid.len()
            || self.grid.first().map(Vec::len) != grid.first().map(Vec::len)
        {
            self.grid.clear();
            self.graphics.cleared();
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
        self.graphics.draw(out, &frame.images)?;
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
    if let Some((status, rows)) = frame.rows.split_last() {
        let (x, w) = (usize::from(frame.main.x), usize::from(frame.main.width));
        for (line, row) in grid.iter_mut().zip(rows) {
            put_row(line, x, w, row, text, theme);
        }
        if let Some(line) = grid.get_mut(rows.len()) {
            put_row(line, 0, width, status, text, theme);
        }
    }
    let panel = text.patch(&look(&Tag::PANEL));
    let separator = terminal_style(panel.patch(&look(&Tag::PANEL_BORDER)));
    for p in &frame.panels {
        let (x, w) = (usize::from(p.rect.x), usize::from(p.rect.width));
        let top = usize::from(p.rect.y) - usize::from(p.title.is_some());
        for line in grid.iter_mut().skip(top).take(frame.rows.len() - 1 - top) {
            put(line, usize::from(p.separator), 1, "│", separator);
        }
        if let (Some(title), Some(line)) = (&p.title, grid.get_mut(top)) {
            let style = terminal_style(panel.patch(&look(&Tag::PANEL_TITLE)));
            put(line, x, w, &format!("{title:<w$}"), style);
        }
        for (line, row) in grid.iter_mut().skip(usize::from(p.rect.y)).zip(&p.rows) {
            put_row(line, x, w, row, panel, theme);
        }
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
    fn copies_go_to_the_system_clipboard_as_osc_52() {
        assert_eq!(osc52("hi"), "\x1b]52;c;aGk=\x07");
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
        assert_eq!(
            key(TermKey::Char('4'), KeyModifiers::CONTROL).as_deref(),
            Some("ctrl-\\")
        );
        assert_eq!(
            key(TermKey::Char('4'), KeyModifiers::NONE).as_deref(),
            Some("4")
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
            main: main_rect(10, 1),
            panels: Vec::new(),
            rows: vec![Row::default(), plain(text)],
            floats: Vec::new(),
            images: Vec::new(),
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
            main: main_rect(12, 4),
            panels: Vec::new(),
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
            images: Vec::new(),
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

    /// The main view's area when there are no panels.
    fn main_rect(width: u16, height: u16) -> kern_core::render::Rect {
        kern_core::render::Rect {
            x: 0,
            y: 0,
            width,
            height,
        }
    }

    #[test]
    fn panels_get_a_line_beside_them_and_a_title() {
        use kern_core::render::{PanelFrame, Rect};
        let frame = Frame {
            size: Size {
                width: 10,
                height: 4,
            },
            main: Rect {
                x: 5,
                y: 0,
                width: 5,
                height: 3,
            },
            rows: vec![
                plain("main"),
                Row::default(),
                Row::default(),
                plain("status"),
            ],
            panels: vec![PanelFrame {
                rect: Rect {
                    x: 0,
                    y: 1,
                    width: 4,
                    height: 2,
                },
                separator: 4,
                title: Some("Tree".into()),
                rows: vec![plain("a/"), plain("b")],
            }],
            floats: Vec::new(),
            images: Vec::new(),
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
            ["Tree│main ", "a/  │     ", "b   │     ", "status    "]
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
            main: main_rect(4, 0),
            panels: Vec::new(),
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
            images: Vec::new(),
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
