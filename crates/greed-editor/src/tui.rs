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
use greed_core::CursorShape;
use greed_core::keymap::{Key, KeyCode, Mods};
use greed_core::mouse::{Button, Mouse, MouseKind};
use greed_core::render::{Frame, Size, grid};
use greed_core::server::{Input, Output};
use greed_core::theme::{Color as ThemeColor, Medium, Style, Underline};
use unicode_width::UnicodeWidthStr;

type Error = Box<dyn std::error::Error>;

/// How often the key reader checks whether its run is over.
const KEY_POLL: Duration = Duration::from_millis(50);

/// Runs the terminal client until the server exits or lets it go, sending
/// keys and sizes to `input` and drawing the frames from `output`. Returns
/// how it ended.
pub fn run(input: &Sender<Input>, output: &Receiver<Output>) -> Result<Output, Error> {
    let mut painter = Painter::new();
    let terminal = Terminal::enter()?;
    let (width, height) = terminal::size()?;
    input.send(Input::Resize(Size { width, height }))?;
    send_cell_size(input);

    // Keys are read until this run ends, so a run that follows (after a
    // switch to another session) gets them all.
    let reading = Arc::new(AtomicBool::new(true));
    // Terminals that don't report focus count as focused.
    let focused = Arc::new(AtomicBool::new(true));
    let keys = {
        let input = input.clone();
        let reading = reading.clone();
        let focused = focused.clone();
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
                    Event::Paste(text) => Some(Input::Paste(text)),
                    Event::Resize(width, height) => {
                        send_cell_size(&input);
                        Some(Input::Resize(Size { width, height }))
                    }
                    Event::FocusGained => {
                        focused.store(true, Ordering::Relaxed);
                        None
                    }
                    Event::FocusLost => {
                        focused.store(false, Ordering::Relaxed);
                        None
                    }
                    Event::Key(_) => None,
                };
                if message.is_some_and(|m| input.send(m).is_err()) {
                    break;
                }
            }
        })
    };

    let screen = &mut painter.0;
    let mut out = io::BufWriter::new(io::stdout());
    // Deltas change the last whole frame into the next.
    let mut current: Option<Frame> = None;
    let ended = loop {
        let Ok(first) = output.recv() else {
            break Output::Exit;
        };
        // Frames that queued up while the terminal was busy are drawn as
        // the last of them, once.
        let mut changed = false;
        let mut ended = None;
        for message in std::iter::once(first).chain(output.try_iter()) {
            match message {
                Output::Image(image) => screen.graphics.add(image),
                Output::Clipboard(text) => copy_to_system(&mut out, &text)?,
                Output::Notify(notice) => {
                    if !focused.load(Ordering::Relaxed) {
                        let term = std::env::var("TERM").unwrap_or_default();
                        write!(out, "{}", notification(&term, &notice.title, &notice.body))?;
                        out.flush()?;
                    }
                }
                Output::Frame(frame) => {
                    current = Some(frame);
                    changed = true;
                }
                Output::Delta(delta) => {
                    if let Some(frame) = &mut current {
                        delta.apply(frame);
                        changed = true;
                    }
                }
                other => {
                    ended = Some(other);
                    break;
                }
            }
        }
        if changed && let Some(frame) = &current {
            screen.draw(&mut out, frame)?;
        }
        if let Some(ended) = ended {
            break ended;
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
/// which works over ssh too, unless `$GREED_CLIPBOARD` is "off".
fn copy_to_system(out: &mut impl Write, text: &str) -> io::Result<()> {
    if std::env::var("GREED_CLIPBOARD").is_ok_and(|v| v == "off") {
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

/// A desktop notification as the terminal `term` takes it, then a bell:
/// OSC 777 for foot and urxvt, OSC 9 for the rest. Control characters are
/// left out, and in OSC 777 the semicolons that separate its fields.
fn notification(term: &str, title: &str, body: &str) -> String {
    let fields = term.starts_with("foot") || term.starts_with("rxvt");
    let clean = |text: &str| -> String {
        text.chars()
            .filter(|&c| !(c.is_control() || (fields && c == ';')))
            .collect()
    };
    let (title, body) = (clean(title), clean(body));
    if fields {
        format!("\x1b]777;notify;{title};{body}\x07\x07")
    } else if body.is_empty() {
        format!("\x1b]9;{title}\x07\x07")
    } else {
        format!("\x1b]9;{title}: {body}\x07\x07")
    }
}

/// Whether to take the mouse from the terminal: unless `$GREED_MOUSE` is
/// "off". Most terminals still select their own way with shift held.
fn mouse_wanted() -> bool {
    std::env::var("GREED_MOUSE").map_or(true, |v| v != "off")
}

/// Converts a terminal mouse event into a greed one.
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

/// Whether the terminal sends keys in the kitty keyboard protocol, which
/// tells apart keys that otherwise send the same bytes (`tab` and `ctrl-i`,
/// `enter` and `shift-enter`) and `esc` from the start of a sequence.
static KITTY_KEYS: AtomicBool = AtomicBool::new(false);

/// Whether `#rrggbb` colors go out as they are, rather than as the nearest
/// of the 256 every terminal has.
static TRUECOLOR: AtomicBool = AtomicBool::new(true);

/// Whether the terminal shows 24-bit color: `$GREED_COLORS` ("truecolor" or
/// "24bit", or "256") says, or else `$COLORTERM` does ("truecolor", "24bit"), or a
/// `$TERM` ending in "-direct".
fn truecolor(greed_colors: Option<&str>, colorterm: Option<&str>, term: Option<&str>) -> bool {
    match greed_colors {
        Some("truecolor" | "24bit") => true,
        Some("256") => false,
        _ => {
            matches!(colorterm, Some("truecolor" | "24bit"))
                || term.is_some_and(|t| t.ends_with("-direct"))
        }
    }
}

/// The nearest of the 256 colors to `r`, `g`, `b`: from the 6x6x6 cube or
/// the gray ramp.
fn nearest_256(r: u8, g: u8, b: u8) -> u8 {
    const LEVELS: [u8; 6] = [0, 95, 135, 175, 215, 255];
    let level = |c: u8| (0..6).min_by_key(|&i| LEVELS[i].abs_diff(c)).unwrap_or(0);
    let distance = |(r2, g2, b2): (u8, u8, u8)| {
        [(r, r2), (g, g2), (b, b2)]
            .iter()
            .map(|&(from, to)| u32::from(from.abs_diff(to)).pow(2))
            .sum::<u32>()
    };
    let (ri, gi, bi) = (level(r), level(g), level(b));
    let cube = (LEVELS[ri], LEVELS[gi], LEVELS[bi]);
    let average = (u16::from(r) + u16::from(g) + u16::from(b)) / 3;
    let step = u8::try_from((average.saturating_sub(3) / 10).min(23)).unwrap_or(23);
    let gray = 8 + 10 * step;
    if distance((gray, gray, gray)) < distance(cube) {
        232 + step
    } else {
        u8::try_from(16 + 36 * ri + 6 * gi + bi).unwrap_or(16)
    }
}

/// Whether to ask for the kitty keyboard protocol: unless `$GREED_KEYS` is
/// "legacy".
fn kitty_keys_wanted() -> bool {
    std::env::var("GREED_KEYS").map_or(true, |v| v != "legacy")
}

/// Converts a terminal key event into a greed key. Returns `None` for keys
/// greed doesn't know.
pub fn convert(event: KeyEvent) -> Option<Key> {
    let ctrl = event.modifiers.contains(KeyModifiers::CONTROL);
    let code = match event.code {
        // Without the kitty protocol, terminals send ctrl-\ ] ^ _ as the
        // bytes crossterm reads as ctrl-4 to ctrl-7.
        TermKey::Char(c @ '4'..='7') if ctrl && !KITTY_KEYS.load(Ordering::Relaxed) => {
            KeyCode::Char(match c {
                '4' => '\\',
                '5' => ']',
                '6' => '^',
                _ => '_',
            })
        }
        // ... and with it, shifted letters as the letter with shift held.
        TermKey::Char(c) if event.modifiers.contains(KeyModifiers::SHIFT) => {
            let mut upper = c.to_uppercase();
            KeyCode::Char(match (upper.next(), upper.next()) {
                (Some(u), None) => u,
                _ => c,
            })
        }
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
pub(crate) struct Terminal;

impl Terminal {
    pub(crate) fn enter() -> io::Result<Self> {
        let hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            // A panic the editor catches leaves the screen as it is.
            if !greed_core::panics::caught_here() {
                restore();
            }
            hook(info);
        }));
        terminal::enable_raw_mode()?;
        execute!(
            io::stdout(),
            terminal::EnterAlternateScreen,
            event::EnableBracketedPaste,
            event::EnableFocusChange
        )?;
        if mouse_wanted() {
            execute!(io::stdout(), event::EnableMouseCapture)?;
        }
        if kitty_keys_wanted() && terminal::supports_keyboard_enhancement().unwrap_or(false) {
            execute!(
                io::stdout(),
                event::PushKeyboardEnhancementFlags(
                    event::KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES
                )
            )?;
            KITTY_KEYS.store(true, Ordering::Relaxed);
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
    if KITTY_KEYS.swap(false, Ordering::Relaxed) {
        let _ = execute!(io::stdout(), event::PopKeyboardEnhancementFlags);
    }
    let _ = execute!(
        io::stdout(),
        SetCursorStyle::DefaultUserShape,
        cursor::Show,
        event::DisableMouseCapture,
        event::DisableBracketedPaste,
        event::DisableFocusChange,
        terminal::LeaveAlternateScreen
    );
    let _ = terminal::disable_raw_mode();
}

/// One terminal cell. The second cell of a wide character has empty text,
/// and so do the cells scaled text takes after its first.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Cell {
    text: String,
    style: ContentStyle,
    /// How many times bigger its text is, in a terminal that can draw it so.
    scale: u8,
}

impl Default for Cell {
    fn default() -> Self {
        Self {
            text: " ".to_owned(),
            style: ContentStyle::new(),
            scale: 1,
        }
    }
}

/// What's on the terminal now, so only changed rows are redrawn.
#[derive(Default)]
struct Screen {
    grid: Vec<Vec<Cell>>,
    graphics: Graphics,
    /// Whether the terminal draws text bigger (kitty's text sizing).
    sized: bool,
}

/// Draws frames as the terminal client does, for `greed bench --draw`.
pub(crate) struct Painter(Screen);

impl Painter {
    pub(crate) fn new() -> Self {
        let var = |name| std::env::var(name).ok();
        TRUECOLOR.store(
            truecolor(
                var("GREED_COLORS").as_deref(),
                var("COLORTERM").as_deref(),
                var("TERM").as_deref(),
            ),
            Ordering::Relaxed,
        );
        Painter(Screen {
            graphics: Graphics::new(graphics::detect()),
            sized: text_sizing(
                var("GREED_TEXT_SIZING").as_deref(),
                var("TERM").as_deref(),
                std::env::var_os("KITTY_WINDOW_ID").is_some(),
            ),
            ..Screen::default()
        })
    }

    pub(crate) fn paint(&mut self, out: &mut impl Write, frame: &Frame) -> io::Result<()> {
        self.0.draw(out, frame)
    }
}

impl Screen {
    fn draw(&mut self, out: &mut impl Write, frame: &Frame) -> io::Result<()> {
        let grid = compose(frame, self.sized);
        // The terminal shows the frame whole once it's written, never half drawn;
        // terminals without synchronized output ignore this.
        queue!(out, terminal::BeginSynchronizedUpdate)?;
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
            write_row(out, u16::try_from(y).unwrap_or(u16::MAX), row)?;
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
        queue!(out, terminal::EndSynchronizedUpdate)?;
        out.flush()
    }
}

/// Whether the terminal draws text bigger, with kitty's text sizing
/// protocol: as `$GREED_TEXT_SIZING` says ("on" or "off"), or in kitty.
fn text_sizing(setting: Option<&str>, term: Option<&str>, in_kitty: bool) -> bool {
    match setting {
        Some("on") => true,
        Some("off") => false,
        _ => in_kitty || term.is_some_and(|t| t.contains("kitty")),
    }
}

/// The frame's shared cell grid, with terminal styles; scaled text drawn
/// big when the terminal can (`sized`).
fn compose(frame: &Frame, sized: bool) -> Vec<Vec<Cell>> {
    grid::compose_with(frame, Medium::Tui, sized)
        .into_iter()
        .map(|row| {
            row.into_iter()
                .map(|cell| Cell {
                    text: cell.text,
                    style: terminal_style(cell.style),
                    scale: cell.scale,
                })
                .collect()
        })
        .collect()
}

/// Whether terminals may disagree about how many cells `grapheme` takes:
/// emoji, sequences with a variation selector or joiner, symbols some draw
/// wide, and private-use icons like Nerd Font glyphs.
fn uncertain_width(grapheme: &str) -> bool {
    grapheme.chars().count() > 1
        || grapheme.chars().any(|c| {
            matches!(u32::from(c),
                0x2300..=0x23FF | 0x2600..=0x27BF | 0x2B00..=0x2BFF
                | 0xE000..=0xF8FF | 0x1F000..=0x1FAFF | 0xF0000..)
        })
        || grapheme.width() > 1
}

/// Writes row `y` of the screen. Text goes out in runs of one style, except
/// that after a grapheme of uncertain width the cursor is put where the
/// next cell starts, with the grapheme's cells blanked first, so a terminal
/// drawing it narrower or wider than Greed counted doesn't shift the rest of
/// the row (like a float's border). Scaled text goes out with kitty's text
/// sizing, and the cursor skips the cells scaled text above covers.
fn write_row(out: &mut impl Write, y: u16, row: &[Cell]) -> io::Result<()> {
    queue!(out, cursor::MoveTo(0, y))?;
    let mut run = String::new();
    let mut run_style = ContentStyle::new();
    // Where the terminal's cursor is once `run` is out.
    let mut col = 0;
    for (x, cell) in row.iter().enumerate() {
        if cell.text.is_empty() {
            continue;
        }
        if x != col {
            queue!(
                out,
                PrintStyledContent(run_style.apply(run.as_str())),
                cursor::MoveTo(cursor_col(x), y)
            )?;
            run.clear();
        }
        let wide = cell.text.width().max(1) * usize::from(cell.scale.max(1));
        col = x + wide;
        if cell.scale > 1 {
            let sized = format!("\x1b]66;s={};{}\x07", cell.scale, cell.text);
            queue!(
                out,
                PrintStyledContent(run_style.apply(run.as_str())),
                PrintStyledContent(cell.style.apply(sized)),
            )?;
            run.clear();
            continue;
        }
        if !uncertain_width(&cell.text) {
            if cell.style != run_style && !run.is_empty() {
                queue!(out, PrintStyledContent(run_style.apply(run.as_str())))?;
                run.clear();
            }
            run_style = cell.style;
            run.push_str(&cell.text);
            continue;
        }
        queue!(out, PrintStyledContent(run_style.apply(run.as_str())))?;
        run.clear();
        let cells = 1 + row[x + 1..]
            .iter()
            .take_while(|c| c.text.is_empty())
            .count();
        let (at, next) = (cursor_col(x), cursor_col(x + cells));
        col = x + cells;
        queue!(
            out,
            cursor::MoveTo(at, y),
            PrintStyledContent(cell.style.apply(" ".repeat(cells))),
            cursor::MoveTo(at, y),
            PrintStyledContent(cell.style.apply(cell.text.as_str())),
            cursor::MoveTo(next, y),
        )?;
    }
    queue!(
        out,
        PrintStyledContent(run_style.apply(run.as_str())),
        ResetColor
    )
}

fn cursor_col(x: usize) -> u16 {
    u16::try_from(x).unwrap_or(u16::MAX)
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
        ThemeColor::Rgb(r, g, b) if TRUECOLOR.load(Ordering::Relaxed) => Color::Rgb { r, g, b },
        ThemeColor::Rgb(r, g, b) => Color::AnsiValue(nearest_256(r, g, b)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use greed_core::ViewId;
    use greed_core::render::{Rect, Role, Row, Surface, SurfaceId, Tag};
    use greed_core::theme::Theme;

    #[test]
    fn notifications_use_the_escape_the_terminal_takes() {
        assert_eq!(
            notification("xterm-kitty", "Reminder", "call the bank"),
            "\x1b]9;Reminder: call the bank\x07\x07"
        );
        assert_eq!(notification("", "Done", ""), "\x1b]9;Done\x07\x07");
        assert_eq!(
            notification("foot", "Reminder", "a; b"),
            "\x1b]777;notify;Reminder;a b\x07\x07",
            "semicolons would split the fields"
        );
        assert_eq!(
            notification("rxvt-unicode-256color", "x\x1b]", "y\n"),
            "\x1b]777;notify;x];y\x07\x07",
            "control characters are left out"
        );
    }

    #[test]
    fn truecolor_is_what_greed_colors_or_the_terminal_says() {
        assert!(truecolor(None, Some("truecolor"), Some("xterm")));
        assert!(truecolor(None, Some("24bit"), None));
        assert!(truecolor(None, None, Some("xterm-direct")));
        assert!(
            !truecolor(None, None, Some("xterm-256color")),
            "unsaid is 256"
        );
        assert!(
            !truecolor(Some("256"), Some("truecolor"), None),
            "GREED_COLORS wins"
        );
        assert!(truecolor(Some("truecolor"), None, Some("screen")));
    }

    #[test]
    fn colors_without_truecolor_are_the_nearest_of_256() {
        assert_eq!(nearest_256(0, 0, 0), 16);
        assert_eq!(nearest_256(255, 255, 255), 231);
        assert_eq!(nearest_256(255, 0, 0), 196);
        assert_eq!(nearest_256(128, 128, 128), 244, "grays come from the ramp");
        assert_eq!(nearest_256(0x2e, 0x34, 0x40), 237, "nord's background");
        assert_eq!(nearest_256(0x5f, 0x87, 0xaf), 67, "a cube color exactly");
    }

    /// A row of plain cells for `text`: each grapheme in its cells, a wide
    /// one's later cells empty.
    fn cells(text: &str, width: usize) -> Vec<Cell> {
        use unicode_segmentation::UnicodeSegmentation;
        let mut line = Vec::new();
        for grapheme in text.graphemes(true) {
            line.push(Cell {
                text: grapheme.to_owned(),
                style: ContentStyle::new(),
                scale: 1,
            });
            for _ in 1..grapheme.width().max(1) {
                line.push(Cell {
                    text: String::new(),
                    style: ContentStyle::new(),
                    scale: 1,
                });
            }
        }
        line.resize(width, Cell::default());
        line
    }

    fn written(row: &[Cell]) -> String {
        let mut out = Vec::new();
        write_row(&mut out, 3, row).unwrap();
        String::from_utf8(out).unwrap()
    }

    #[test]
    fn after_a_grapheme_of_uncertain_width_the_cursor_goes_where_the_next_cell_is() {
        // "❄️" is two cells to Greed; a terminal drawing it as one would
        // shift "x|" left without the move after it.
        let out = written(&cells("a❄\u{fe0f}x|", 6));
        // Cursor positions are 1-based: row 4, column 2 is cell 1.
        let blank_then_draw = "\u{1b}[4;2H  \u{1b}[4;2H❄\u{fe0f}\u{1b}[4;4H";
        assert!(out.contains(blank_then_draw), "{out:?}");
        let moved = out.find(blank_then_draw).unwrap() + blank_then_draw.len();
        assert!(
            out[moved..].contains("x|"),
            "the rest follows the move: {out:?}"
        );
    }

    #[test]
    fn scaled_text_goes_out_with_kitty_text_sizing_and_the_rest_keeps_its_column() {
        // "H" twice the size takes cells 0-1, then "x".
        let mut row = cells("H x ", 4);
        row[0].scale = 2;
        row[1].text = String::new();
        let out = written(&row);
        assert!(out.contains("\u{1b}]66;s=2;H\u{7}"), "{out:?}");
        let sized = out.find("\u{1b}]66").unwrap();
        assert!(out[sized..].contains('x'), "x follows: {out:?}");
        assert_eq!(
            out.matches("\u{1b}[4;").count(),
            1,
            "no extra moves: {out:?}"
        );
    }

    #[test]
    fn rows_under_scaled_text_skip_the_cells_it_covers() {
        // Cells 0-1 belong to the scaled text above; "ab" starts at cell 2.
        let mut row = cells("  ab", 4);
        row[0].text = String::new();
        row[1].text = String::new();
        let out = written(&row);
        assert!(out.contains("\u{1b}[4;3Hab"), "{out:?}");
    }

    #[test]
    fn text_sizing_is_for_kitty_unless_greed_text_sizing_says() {
        assert!(text_sizing(None, Some("xterm-kitty"), false));
        assert!(
            text_sizing(None, Some("xterm-256color"), true),
            "KITTY_WINDOW_ID"
        );
        assert!(!text_sizing(None, Some("xterm-ghostty"), false));
        assert!(!text_sizing(Some("off"), Some("xterm-kitty"), true));
        assert!(text_sizing(Some("on"), Some("screen"), false));
    }

    #[test]
    fn plain_text_and_box_drawing_go_out_in_one_run() {
        let out = written(&cells("ab │ é", 6));
        assert_eq!(
            out.matches("\u{1b}[4;").count(),
            1,
            "only the row's start: {out:?}"
        );
    }

    fn key(code: TermKey, mods: KeyModifiers) -> Option<String> {
        convert(KeyEvent::new(code, mods)).map(|k| k.to_string())
    }

    #[test]
    fn copies_go_to_the_system_clipboard_as_osc_52() {
        assert_eq!(osc52("hi"), "\x1b]52;c;aGk=\x07");
    }

    #[test]
    fn keys_convert_to_greed_names() {
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
        // Terminals speaking the kitty protocol send the unshifted letter.
        assert_eq!(
            key(
                TermKey::Char('a'),
                KeyModifiers::CONTROL | KeyModifiers::SHIFT
            )
            .as_deref(),
            Some("ctrl-A")
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
        let frame = |text: &str| frame_of(10, 2, vec![Row::default()], plain(text), Vec::new());
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
        let float = Surface::new(
            SurfaceId::View(ViewId(2)),
            Role::Float {
                border: true,
                title: Some("hi".into()),
                label: Vec::new(),
                footer: Vec::new(),
            },
            Rect {
                x: 2,
                y: 1,
                width: 6,
                height: 2,
            },
            vec![plain("one"), plain("日本語")],
        );
        let line = plain("abcdefghijkl");
        let frame = frame_of(12, 5, vec![line.clone(); 4], line, vec![float]);
        let text: Vec<String> = compose(&frame, false)
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

    /// A frame `width` by `height` cells: `rows` in one pane above the
    /// status line, with `more` surfaces over them.
    fn frame_of(width: u16, height: u16, rows: Vec<Row>, status: Row, more: Vec<Surface>) -> Frame {
        let rect = |y, height| Rect {
            x: 0,
            y,
            width,
            height,
        };
        let pane = Surface::new(
            SurfaceId::View(ViewId(1)),
            Role::Pane { active: true },
            rect(0, height.saturating_sub(1)),
            rows,
        );
        let status = Surface::new(
            SurfaceId::Status,
            Role::Status,
            rect(height.saturating_sub(1), 1),
            vec![status],
        );
        let mut surfaces = vec![pane, status];
        surfaces.extend(more);
        Frame {
            size: Size { width, height },
            surfaces,
            lines: Vec::new(),
            images: Vec::new(),
            cursor: None,
            cursor_shape: CursorShape::Block,
            theme: std::sync::Arc::default(),
            gui: std::collections::BTreeMap::new(),
            menus: Vec::new(),
        }
    }

    #[test]
    fn panels_get_a_line_beside_them_and_a_title() {
        let panel = Surface::new(
            SurfaceId::View(ViewId(2)),
            Role::Panel {
                separator: 4,
                title: Some("Tree".into()),
            },
            Rect {
                x: 0,
                y: 1,
                width: 4,
                height: 2,
            },
            vec![plain("a/"), plain("b")],
        );
        let rows = vec![plain("main"), Row::default(), Row::default()];
        let mut frame = frame_of(10, 4, rows, plain("status"), vec![panel]);
        frame.surfaces[0].rect = Rect {
            x: 5,
            y: 0,
            width: 5,
            height: 3,
        };
        let text: Vec<String> = compose(&frame, false)
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
            spans: vec![greed_core::render::Span::new(
                text,
                std::iter::empty().collect(),
            )],
            ..Row::default()
        }
    }

    #[test]
    fn cells_take_their_look_from_the_theme() {
        use greed_core::render::Span;
        use greed_core::theme::{Entry, Style};
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
        let row = Row {
            spans: vec![Span::new(
                "fn",
                [Tag::from("keyword.function"), Tag::SELECTION]
                    .into_iter()
                    .collect(),
            )],
            tags: [Tag::from("current")].into_iter().collect(),
            covers: 0,
        };
        let mut frame = frame_of(4, 1, Vec::new(), row, Vec::new());
        frame.theme = std::sync::Arc::new(theme);
        let cell = &compose(&frame, false)[0][0];
        assert_eq!(cell.style.foreground_color, Some(Color::Magenta));
        assert_eq!(
            cell.style.background_color,
            Some(Color::Rgb { r: 1, g: 2, b: 3 })
        );
        assert!(cell.style.attributes.has(Attribute::Bold));
        // The row's own style fills past its text.
        let end = &compose(&frame, false)[0][3];
        assert_eq!(end.style.background_color, Some(Color::DarkGrey));
    }
}
