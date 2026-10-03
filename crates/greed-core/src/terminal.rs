//! Terminals: a program running in a pseudo terminal, its output kept as a
//! grid of styled cells by alacritty's emulator. The terminal plugin shows
//! the grid in a buffer and sends keys; this holds the parts that need
//! threads and speed.
//!
//! Lines that scroll off the top move out of the emulator into a scrollback
//! of our own, numbered from the first line the terminal ever had, so the
//! plugin can ask for just the lines it hasn't shown yet.

use std::collections::VecDeque;
use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use alacritty_terminal::event::{Event as TermEvent, EventListener};
use alacritty_terminal::grid::{Dimensions, Row as GridRow};
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::{Cell, Flags, ImagePiece};
use alacritty_terminal::term::{Config, Term, TermMode};
use alacritty_terminal::vte::ansi::{Color as TermColor, NamedColor, Processor, Rgb};
use crossbeam_channel::Sender;
use portable_pty::{ChildKiller, CommandBuilder, MasterPty, PtySize};

use crate::image::{Image, ImageId};
use crate::keymap::{Key, KeyCode, Mods};
use crate::mouse::{Button, Mouse, MouseKind};
use crate::theme::{Color, Style, Underline};

mod graphics;

use graphics::{Graphics, Piece, Splitter};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TerminalId(pub u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Event {
    /// There's new output. Sent once until the screen is next read.
    Output(TerminalId),
    /// The program ended, with its exit code.
    Exited(TerminalId, u32),
}

#[derive(Debug, Clone)]
pub struct Options {
    /// The program and its arguments; without, the user's shell.
    pub command: Option<Vec<String>>,
    pub cwd: Option<PathBuf>,
    pub env: Vec<(String, String)>,
    pub rows: u16,
    pub cols: u16,
    /// How many lines that scrolled off the top are kept.
    pub scrollback: usize,
    /// A cell's width and height in pixels, for sizing images.
    pub cell: (u16, u16),
}

/// A line of the grid: its text, and the parts of it with a style of their
/// own as byte ranges.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Row {
    pub text: String,
    pub spans: Vec<Span>,
    /// The images on it, as runs of cells.
    pub images: Vec<RowImage>,
    /// The links on it (OSC 8): byte ranges and where they go.
    pub links: Vec<RowLink>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RowLink {
    pub from: usize,
    pub to: usize,
    pub uri: Arc<str>,
}

/// Part of an image on a row: from byte `from`, its cells from (`col`,
/// `row`) on, of an image `cols` by `rows` cells.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RowImage {
    pub from: usize,
    pub id: ImageId,
    pub col: u16,
    pub row: u16,
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Span {
    pub from: usize,
    pub to: usize,
    /// An inline style name, e.g. `=fg:red bold`.
    pub style: Arc<str>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Screen {
    pub rows: Vec<Row>,
    /// The cursor's row and byte offset in it, unless the program hid it.
    pub cursor: Option<(usize, usize)>,
    /// Whether a full screen program, like an editor or a pager, is showing.
    pub alternate: bool,
}

/// Lines of scrollback: `rows[0]` is line `first`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Scrollback {
    pub first: u64,
    pub rows: Vec<Row>,
}

/// How many lines may scroll off in one read before they move to the
/// scrollback. More than a read can hold.
const OVERFLOW: usize = 100_000;

pub struct Terminal {
    shared: Arc<Shared>,
    input: Sender<Vec<u8>>,
    master: Box<dyn MasterPty + Send>,
    killer: Box<dyn ChildKiller + Send + Sync>,
    title: Arc<Mutex<Option<String>>>,
    copied: Arc<Mutex<Option<String>>>,
    exit: Arc<Mutex<Option<u32>>>,
}

struct Shared {
    term: Mutex<Term<Listener>>,
    /// Locked after `term` when both are.
    graphics: Mutex<Graphics>,
    scrollback: Mutex<Lines>,
    unread: AtomicBool,
    /// A cell's size in pixels on the client's screen.
    cell: Mutex<(u16, u16)>,
}

struct Lines {
    first: u64,
    rows: VecDeque<Row>,
    limit: usize,
}

impl Lines {
    fn push(&mut self, row: Row) {
        self.rows.push_back(row);
        while self.rows.len() > self.limit {
            self.rows.pop_front();
            self.first += 1;
        }
    }
}

impl Terminal {
    /// Starts `options.command` in a new pseudo terminal. Output and the
    /// program's end arrive on `events`.
    pub fn spawn(id: TerminalId, options: &Options, events: Sender<Event>) -> io::Result<Self> {
        let pair = portable_pty::native_pty_system()
            .openpty(pty_size(options.rows, options.cols, options.cell))
            .map_err(io::Error::other)?;
        let mut child = pair
            .slave
            .spawn_command(command(options))
            .map_err(io::Error::other)?;
        drop(pair.slave);
        let killer = child.clone_killer();
        let reader = pair.master.try_clone_reader().map_err(io::Error::other)?;
        let mut writer = pair.master.take_writer().map_err(io::Error::other)?;

        let (input, inputs) = crossbeam_channel::unbounded::<Vec<u8>>();
        std::thread::Builder::new()
            .name("greed-terminal-in".into())
            .spawn(move || {
                for bytes in inputs {
                    if writer
                        .write_all(&bytes)
                        .and_then(|()| writer.flush())
                        .is_err()
                    {
                        break;
                    }
                }
            })?;

        let title = Arc::new(Mutex::new(None));
        let copied = Arc::new(Mutex::new(None));
        let listener = Listener {
            input: input.clone(),
            title: title.clone(),
            copied: copied.clone(),
        };
        let config = Config {
            scrolling_history: OVERFLOW,
            kitty_keyboard: true,
            ..Config::default()
        };
        let size = Size::new(options.rows, options.cols);
        let shared = Arc::new(Shared {
            term: Mutex::new(Term::new(config, &size, listener)),
            scrollback: Mutex::new(Lines {
                first: 0,
                rows: VecDeque::new(),
                limit: options.scrollback,
            }),
            graphics: Mutex::new(Graphics::default()),
            unread: AtomicBool::new(false),
            cell: Mutex::new(options.cell),
        });
        let exit = Arc::new(Mutex::new(None));
        let (pumped, ended, replies) = (shared.clone(), exit.clone(), input.clone());
        std::thread::Builder::new()
            .name("greed-terminal-out".into())
            .spawn(move || {
                pump(&pumped, reader, id, &events, &replies);
                let code = child.wait().map_or(1, |status| status.exit_code());
                *lock(&ended) = Some(code);
                let _ = events.send(Event::Exited(id, code));
            })?;
        Ok(Terminal {
            shared,
            input,
            master: pair.master,
            killer,
            title,
            copied,
            exit,
        })
    }

    /// The visible grid and the cursor.
    pub fn screen(&self) -> Screen {
        self.shared.unread.store(false, Ordering::Release);
        let term = lock(&self.shared.term);
        let graphics = lock(&self.shared.graphics);
        let grid = term.grid();
        let mode = *term.mode();
        let point = grid.cursor.point;
        let mut cursor = None;
        let rows = (0..grid.screen_lines())
            .map(|r| {
                let line = Line(i32::try_from(r).unwrap_or(i32::MAX));
                let at = (mode.contains(TermMode::SHOW_CURSOR) && point.line == line)
                    .then_some(point.column.0);
                let (row, offset) = row(&grid[line], grid.columns(), at, &graphics);
                if at.is_some() {
                    cursor = Some((r, offset));
                }
                row
            })
            .collect();
        Screen {
            rows,
            cursor,
            alternate: mode.contains(TermMode::ALT_SCREEN),
        }
    }

    /// The scrollback from line `from` on, or from the oldest line still
    /// kept if `from` is gone.
    pub fn scrollback(&self, from: u64) -> Scrollback {
        let lines = lock(&self.shared.scrollback);
        let skip = usize::try_from(from.saturating_sub(lines.first)).unwrap_or(usize::MAX);
        Scrollback {
            first: lines
                .first
                .max(from.min(lines.first + lines.rows.len() as u64)),
            rows: lines.rows.iter().skip(skip).cloned().collect(),
        }
    }

    /// Sends `bytes` to the program as if typed.
    pub fn write(&self, bytes: Vec<u8>) {
        let _ = self.input.send(bytes);
    }

    /// Sends `key` the way a terminal encodes it for the program's modes.
    pub fn key(&self, key: Key) {
        let mode = *lock(&self.shared.term).mode();
        let bytes = encode_key(key, mode);
        if !bytes.is_empty() {
            self.write(bytes);
        }
    }

    /// Whether the program asked for mouse events, as editors and `htop` do.
    pub fn wants_mouse(&self) -> bool {
        lock(&self.shared.term)
            .mode()
            .intersects(TermMode::MOUSE_MODE)
    }

    /// Sends `mouse` to the program, its `col` and `row` a cell of the
    /// program's screen, if it asked for that kind of event. Returns whether
    /// it did.
    pub fn mouse(&self, mouse: Mouse) -> bool {
        let mode = *lock(&self.shared.term).mode();
        match encode_mouse(mouse, mode) {
            Some(bytes) => {
                self.write(bytes);
                true
            }
            None => false,
        }
    }

    /// Sends pasted text, marked as a paste when the program asked for that.
    pub fn paste(&self, text: &str) {
        let bracketed = lock(&self.shared.term)
            .mode()
            .contains(TermMode::BRACKETED_PASTE);
        let bytes = if bracketed {
            format!("\x1b[200~{}\x1b[201~", text.replace('\x1b', ""))
        } else {
            text.replace("\r\n", "\r").replace('\n', "\r")
        };
        self.write(bytes.into_bytes());
    }

    /// Changes the size in cells, and the size of a cell in pixels.
    pub fn resize(&self, rows: u16, cols: u16, cell: (u16, u16)) -> io::Result<()> {
        let (rows, cols) = (rows.max(1), cols.max(1));
        *lock(&self.shared.cell) = cell;
        self.master
            .resize(pty_size(rows, cols, cell))
            .map_err(io::Error::other)?;
        lock(&self.shared.term).resize(Size::new(rows, cols));
        self.shared.unread.store(false, Ordering::Release);
        Ok(())
    }

    /// The image placed with id `id`, which rows name.
    pub fn image(&self, id: ImageId) -> Option<Arc<Image>> {
        lock(&self.shared.graphics)
            .placed
            .get(&id.0)
            .map(|placed| placed.image.clone())
    }

    /// What the program copied (OSC 52) since this was last asked, if
    /// anything.
    pub fn take_copied(&self) -> Option<String> {
        lock(&self.copied).take()
    }

    /// What the program called the window, if it did.
    pub fn title(&self) -> Option<String> {
        lock(&self.title).clone()
    }

    /// The program's exit code, once it has ended.
    pub fn exit_code(&self) -> Option<u32> {
        *lock(&self.exit)
    }

    pub fn kill(&mut self) {
        let _ = self.killer.kill();
    }
}

impl Drop for Terminal {
    fn drop(&mut self) {
        self.kill();
    }
}

fn command(options: &Options) -> CommandBuilder {
    let mut command = match options.command.as_deref() {
        Some([program, args @ ..]) => {
            let mut command = CommandBuilder::new(program);
            command.args(args);
            command
        }
        _ => CommandBuilder::new_default_prog(),
    };
    command.env("TERM", "xterm-256color");
    command.env("COLORTERM", "truecolor");
    if let Some(cwd) = &options.cwd {
        command.cwd(cwd);
    }
    for (key, value) in &options.env {
        command.env(key, value);
    }
    command
}

/// The size programs see, in cells and in pixels, which image tools ask
/// for to size what they send.
fn pty_size(rows: u16, cols: u16, cell: (u16, u16)) -> PtySize {
    PtySize {
        rows,
        cols,
        pixel_width: cols.saturating_mul(cell.0),
        pixel_height: rows.saturating_mul(cell.1),
    }
}

/// Feeds the program's output to the emulator until it ends, with images
/// cut out and placed, and the replies they call for sent to `replies`.
fn pump(
    shared: &Shared,
    mut reader: Box<dyn Read + Send>,
    id: TerminalId,
    events: &Sender<Event>,
    replies: &Sender<Vec<u8>>,
) {
    let mut processor: Processor = Processor::new();
    let mut splitter = Splitter::default();
    let mut buf = vec![0; 64 * 1024];
    loop {
        let n = match reader.read(&mut buf) {
            Ok(0) => return,
            Ok(n) => n,
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            // EIO once the program and everything it started have gone.
            Err(_) => return,
        };
        {
            let mut term = lock(&shared.term);
            let mut graphics = lock(&shared.graphics);
            let cell = *lock(&shared.cell);
            splitter.split(&buf[..n], |piece| match piece {
                Piece::Bytes(bytes) => processor.advance(&mut *term, bytes),
                Piece::Kitty(command) => {
                    if let Some(reply) = graphics.kitty(&command, &mut term, cell) {
                        let _ = replies.send(reply.into_bytes());
                    }
                }
                Piece::Iterm(command) => graphics.iterm(&command, &mut term, cell),
            });
            keep_scrollback(&mut term, &graphics, &mut lock(&shared.scrollback));
        }
        if !shared.unread.swap(true, Ordering::AcqRel) {
            let _ = events.send(Event::Output(id));
        }
    }
}

/// Moves the lines that scrolled off the emulator's screen into `lines`.
fn keep_scrollback(term: &mut Term<Listener>, graphics: &Graphics, lines: &mut Lines) {
    let grid = term.grid();
    let history = grid.history_size();
    if history == 0 {
        return;
    }
    let cols = grid.columns();
    for back in (1..=history).rev() {
        let line = Line(-i32::try_from(back).unwrap_or(i32::MAX));
        lines.push(row(&grid[line], cols, None, graphics).0);
    }
    term.grid_mut().clear_history();
}

/// The text and styles of `cells`, without trailing blanks, and the byte
/// offset of column `cursor`, which the text reaches when given.
fn row(
    cells: &GridRow<Cell>,
    cols: usize,
    cursor: Option<usize>,
    graphics: &Graphics,
) -> (Row, usize) {
    let blank = |cell: &Cell| {
        cell.c == ' '
            && cell.bg == TermColor::Named(NamedColor::Background)
            && !cell
                .flags
                .intersects(Flags::INVERSE | Flags::ALL_UNDERLINES)
            && cell.image().is_none()
    };
    let end = (0..cols)
        .rev()
        .find(|&c| !blank(&cells[Column(c)]))
        .map_or(0, |c| c + 1)
        .max(cursor.unwrap_or(0));
    let mut row = Row::default();
    let mut offset = 0;
    let mut run: Option<(Style, usize)> = None;
    for c in 0..end {
        if Some(c) == cursor {
            offset = row.text.len();
        }
        let cell = &cells[Column(c)];
        if cell
            .flags
            .intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER)
        {
            continue;
        }
        let style = cell_style(cell);
        if run.as_ref().is_none_or(|(s, _)| *s != style) {
            finish_run(&mut row, run.take());
            run = Some((style, row.text.len()));
        }
        if let Some(piece) = cell.image() {
            add_image(&mut row, piece, graphics);
        }
        let start = row.text.len();
        row.text.push(if cell.flags.contains(Flags::HIDDEN) {
            ' '
        } else {
            cell.c
        });
        row.text.extend(cell.zerowidth().unwrap_or_default());
        if let Some(link) = cell.hyperlink() {
            add_link(&mut row, start, link.uri());
        }
    }
    finish_run(&mut row, run);
    if cursor == Some(end) {
        offset = row.text.len();
    }
    (row, offset)
}

/// Adds the image cell about to be written to the end of `row`, to the
/// run before it if it carries on from there.
fn add_image(row: &mut Row, piece: ImagePiece, graphics: &Graphics) {
    let Some(placed) = graphics.placed.get(&piece.id) else {
        return;
    };
    let width = |image: &RowImage| u16::try_from(row.text.len() - image.from).unwrap_or(u16::MAX);
    let carries_on = row.images.last().is_some_and(|last| {
        last.id.0 == piece.id && last.row == piece.row && last.col + width(last) == piece.col
    });
    if !carries_on {
        row.images.push(RowImage {
            from: row.text.len(),
            id: ImageId(piece.id),
            col: piece.col,
            row: piece.row,
            cols: placed.cols,
            rows: placed.rows,
        });
    }
}

/// Adds the cell just written, from byte `start`, to the link run before it
/// if it carries on with the same link, or starts a new one.
fn add_link(row: &mut Row, start: usize, uri: &str) {
    match row.links.last_mut() {
        Some(last) if last.to == start && &*last.uri == uri => last.to = row.text.len(),
        _ => row.links.push(RowLink {
            from: start,
            to: row.text.len(),
            uri: uri.into(),
        }),
    }
}

fn finish_run(row: &mut Row, run: Option<(Style, usize)>) {
    if let Some((style, from)) = run
        && style != Style::default()
    {
        row.spans.push(Span {
            from,
            to: row.text.len(),
            style: style.inline_name().into(),
        });
    }
}

fn cell_style(cell: &Cell) -> Style {
    let flag = |f: Flags| cell.flags.contains(f).then_some(true);
    let underline = [
        (Flags::UNDERLINE, Underline::Line),
        (Flags::DOUBLE_UNDERLINE, Underline::Double),
        (Flags::UNDERCURL, Underline::Curl),
        (Flags::DOTTED_UNDERLINE, Underline::Dotted),
        (Flags::DASHED_UNDERLINE, Underline::Dashed),
    ]
    .into_iter()
    .find_map(|(f, kind)| cell.flags.contains(f).then_some(kind));
    Style {
        fg: color(cell.fg),
        bg: color(cell.bg),
        underline,
        underline_color: cell.underline_color().and_then(color),
        bold: flag(Flags::BOLD),
        italic: flag(Flags::ITALIC),
        dim: flag(Flags::DIM),
        reverse: flag(Flags::INVERSE),
        strikethrough: flag(Flags::STRIKEOUT),
    }
}

/// A terminal color as a theme color; the default colors are left out so
/// the editor's own show.
fn color(color: TermColor) -> Option<Color> {
    match color {
        TermColor::Spec(Rgb { r, g, b }) => Some(Color::Rgb(r, g, b)),
        TermColor::Indexed(i) => Some(indexed(i)),
        TermColor::Named(named) => {
            let n = named as usize;
            let dim = NamedColor::DimBlack as usize;
            match n {
                0..16 => u8::try_from(n).ok().map(Color::Ansi),
                _ if (dim..dim + 8).contains(&n) => u8::try_from(n - dim).ok().map(Color::Ansi),
                _ => None,
            }
        }
    }
}

/// One of the 256 colors: the 16 terminal colors, a 6x6x6 cube, then 24
/// greys.
fn indexed(i: u8) -> Color {
    match i {
        0..16 => Color::Ansi(i),
        16..232 => {
            let level = |v: u8| if v == 0 { 0 } else { 55 + v * 40 };
            let i = i - 16;
            Color::Rgb(level(i / 36), level(i / 6 % 6), level(i % 6))
        }
        _ => {
            let grey = 8 + (i - 232) * 10;
            Color::Rgb(grey, grey, grey)
        }
    }
}

/// The bytes a terminal sends for `key` under the program's `mode`: in the
/// kitty protocol if it asked for that, otherwise as xterm does.
fn encode_key(key: Key, mode: TermMode) -> Vec<u8> {
    if let Some(bytes) = encode_kitty_key(key, mode) {
        return bytes;
    }
    let app_cursor = mode.contains(TermMode::APP_CURSOR);
    let ctrl = key.mods.contains(Mods::CTRL);
    let alt = key.mods.contains(Mods::ALT);
    let shift = key.mods.contains(Mods::SHIFT);
    let m = 1 + u8::from(shift) + 2 * u8::from(alt) + 4 * u8::from(ctrl);
    let letter = |end: char, app: bool| {
        if m > 1 {
            format!("\x1b[1;{m}{end}")
        } else if app {
            format!("\x1bO{end}")
        } else {
            format!("\x1b[{end}")
        }
        .into_bytes()
    };
    let tilde = |n: u8| {
        if m > 1 {
            format!("\x1b[{n};{m}~")
        } else {
            format!("\x1b[{n}~")
        }
        .into_bytes()
    };
    let bytes: Vec<u8> = match key.code {
        KeyCode::Up => return letter('A', app_cursor),
        KeyCode::Down => return letter('B', app_cursor),
        KeyCode::Right => return letter('C', app_cursor),
        KeyCode::Left => return letter('D', app_cursor),
        KeyCode::Home => return letter('H', app_cursor),
        KeyCode::End => return letter('F', app_cursor),
        KeyCode::Insert => return tilde(2),
        KeyCode::Delete => return tilde(3),
        KeyCode::PageUp => return tilde(5),
        KeyCode::PageDown => return tilde(6),
        KeyCode::F(n @ 1..=4) => return letter(char::from(b"PQRS"[usize::from(n - 1)]), true),
        KeyCode::F(n) => {
            return match n {
                5 => tilde(15),
                6..=10 => tilde(n + 11),
                11 | 12 => tilde(n + 12),
                _ => Vec::new(),
            };
        }
        KeyCode::Enter => b"\r".to_vec(),
        KeyCode::Tab if shift => return b"\x1b[Z".to_vec(),
        KeyCode::Tab => b"\t".to_vec(),
        KeyCode::Backspace if ctrl => b"\x08".to_vec(),
        KeyCode::Backspace => b"\x7f".to_vec(),
        KeyCode::Esc => b"\x1b".to_vec(),
        KeyCode::Char(c) if ctrl => control(c),
        KeyCode::Char(c) => c.to_string().into_bytes(),
    };
    if alt {
        [b"\x1b".as_slice(), &bytes].concat()
    } else {
        bytes
    }
}

/// `key` in the kitty keyboard protocol, for a program that turned it on,
/// or `None` where it's sent as xterm sends it. Only presses are sent, and
/// a shifted symbol is reported as itself: which key types it depends on
/// the keyboard layout, which keys don't carry.
fn encode_kitty_key(key: Key, mode: TermMode) -> Option<Vec<u8>> {
    if !mode.intersects(TermMode::KITTY_KEYBOARD_PROTOCOL) {
        return None;
    }
    let all = mode.contains(TermMode::REPORT_ALL_KEYS_AS_ESC);
    let ctrl = key.mods.contains(Mods::CTRL);
    let alt = key.mods.contains(Mods::ALT);
    let (code, shifted) = match key.code {
        KeyCode::Char(c) => {
            let lower = c.to_lowercase().next().filter(|l| *l != c);
            (u32::from(lower.unwrap_or(c)), lower.map(|_| c))
        }
        KeyCode::Enter => (13, None),
        KeyCode::Tab => (9, None),
        KeyCode::Backspace => (127, None),
        KeyCode::Esc => (27, None),
        _ => return None,
    };
    let shift = key.mods.contains(Mods::SHIFT) || shifted.is_some();
    let m = 1 + u8::from(shift) + 2 * u8::from(alt) + 4 * u8::from(ctrl);
    let types_text = matches!(key.code, KeyCode::Char(_)) && !ctrl && !alt;
    let plain = key.code != KeyCode::Esc && (m == 1 || types_text);
    if plain && !all {
        return None;
    }
    let alternate = shifted
        .filter(|_| mode.contains(TermMode::REPORT_ALTERNATE_KEYS))
        .map(|c| format!(":{}", u32::from(c)))
        .unwrap_or_default();
    let rest = match key.code {
        KeyCode::Char(c) if types_text && mode.contains(TermMode::REPORT_ASSOCIATED_TEXT) => {
            format!(";{m};{}", u32::from(c))
        }
        _ if m > 1 => format!(";{m}"),
        _ => String::new(),
    };
    Some(format!("\x1b[{code}{alternate}{rest}u").into_bytes())
}

/// The bytes a terminal reports `mouse` with, in the encoding the program
/// asked for (SGR, UTF-8 or the original), or `None` if it didn't ask for
/// that kind of event.
fn encode_mouse(mouse: Mouse, mode: TermMode) -> Option<Vec<u8>> {
    if !mode.intersects(TermMode::MOUSE_MODE) {
        return None;
    }
    let sgr = mode.contains(TermMode::SGR_MOUSE);
    let button = |b: Button| match b {
        Button::Left => 0,
        Button::Middle => 1,
        Button::Right => 2,
    };
    let base: u32 = match mouse.kind {
        MouseKind::Press(b) => button(b),
        MouseKind::Release(b) if sgr => button(b),
        MouseKind::Release(_) => 3,
        MouseKind::Drag(b) if mode.intersects(TermMode::MOUSE_DRAG | TermMode::MOUSE_MOTION) => {
            32 + button(b)
        }
        MouseKind::Move if mode.contains(TermMode::MOUSE_MOTION) => 35,
        MouseKind::Drag(_) | MouseKind::Move => return None,
        MouseKind::ScrollUp => 64,
        MouseKind::ScrollDown => 65,
        MouseKind::ScrollLeft => 66,
        MouseKind::ScrollRight => 67,
    };
    let code =
        base + 4 * u32::from(mouse.shift) + 8 * u32::from(mouse.alt) + 16 * u32::from(mouse.ctrl);
    let (x, y) = (u32::from(mouse.col) + 1, u32::from(mouse.row) + 1);
    if sgr {
        let end = if matches!(mouse.kind, MouseKind::Release(_)) {
            'm'
        } else {
            'M'
        };
        return Some(format!("\x1b[<{code};{x};{y}{end}").into_bytes());
    }
    let mut bytes = b"\x1b[M".to_vec();
    for n in [code, x, y] {
        if mode.contains(TermMode::UTF8_MOUSE) {
            bytes.extend(char::from_u32(32 + n)?.to_string().bytes());
        } else {
            bytes.push(u8::try_from(32 + n).ok()?);
        }
    }
    Some(bytes)
}

/// What ctrl and `c` send: a control character where there is one.
fn control(c: char) -> Vec<u8> {
    let byte = match c.to_ascii_lowercase() {
        ' ' | '@' | '2' => 0,
        c @ 'a'..='z' => c as u8 - b'a' + 1,
        '[' | '3' => 27,
        '\\' | '4' => 28,
        ']' | '5' => 29,
        '^' | '6' => 30,
        '_' | '-' | '/' | '7' => 31,
        '?' | '8' => 127,
        _ => return c.to_string().into_bytes(),
    };
    vec![byte]
}

/// Answers the emulator's requests to write to the program, and keeps the
/// window title.
struct Listener {
    input: Sender<Vec<u8>>,
    title: Arc<Mutex<Option<String>>>,
    /// What the program last copied (OSC 52), until it's taken.
    copied: Arc<Mutex<Option<String>>>,
}

impl EventListener for Listener {
    fn send_event(&self, event: TermEvent) {
        match event {
            TermEvent::PtyWrite(text) => {
                let _ = self.input.send(text.into_bytes());
            }
            TermEvent::Title(title) => *lock(&self.title) = Some(title),
            TermEvent::ResetTitle => *lock(&self.title) = None,
            TermEvent::ClipboardStore(_, text) => *lock(&self.copied) = Some(text),
            _ => {}
        }
    }
}

struct Size {
    rows: usize,
    cols: usize,
}

impl Size {
    fn new(rows: u16, cols: u16) -> Self {
        Size {
            rows: usize::from(rows.max(1)),
            cols: usize::from(cols.max(1)),
        }
    }
}

impl Dimensions for Size {
    fn total_lines(&self) -> usize {
        self.rows
    }

    fn screen_lines(&self) -> usize {
        self.rows
    }

    fn columns(&self) -> usize {
        self.cols
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(name: &str) -> Key {
        Key::parse(name).unwrap()
    }

    #[test]
    fn keys_are_sent_as_xterm_sends_them() {
        let sent = |name: &str| encode_key(key(name), TermMode::empty());
        assert_eq!(sent("a"), b"a");
        assert_eq!(sent("ctrl-c"), [3]);
        assert_eq!(sent("alt-b"), b"\x1bb");
        assert_eq!(sent("enter"), b"\r");
        assert_eq!(sent("backspace"), [0x7f]);
        assert_eq!(sent("up"), b"\x1b[A");
        assert_eq!(encode_key(key("up"), TermMode::APP_CURSOR), b"\x1bOA");
        assert_eq!(sent("ctrl-right"), b"\x1b[1;5C");
        assert_eq!(sent("shift-tab"), b"\x1b[Z");
        assert_eq!(sent("delete"), b"\x1b[3~");
        assert_eq!(sent("f1"), b"\x1bOP");
        assert_eq!(sent("f5"), b"\x1b[15~");
        assert_eq!(sent("f12"), b"\x1b[24~");
        assert_eq!(sent("ctrl-space"), [0]);
        assert_eq!(sent("é"), "é".as_bytes());
    }

    #[test]
    fn keys_are_sent_as_kitty_sends_them_to_programs_that_ask() {
        let sent = |name: &str, mode| String::from_utf8(encode_key(key(name), mode)).unwrap();
        let plain = TermMode::DISAMBIGUATE_ESC_CODES;
        // Text stays text; keys that collide with others get their own.
        assert_eq!(sent("a", plain), "a");
        assert_eq!(sent("A", plain), "A");
        assert_eq!(sent("enter", plain), "\r");
        assert_eq!(sent("esc", plain), "\x1b[27u");
        assert_eq!(sent("ctrl-c", plain), "\x1b[99;5u");
        assert_eq!(sent("ctrl-i", plain), "\x1b[105;5u");
        assert_eq!(sent("alt-b", plain), "\x1b[98;3u");
        assert_eq!(sent("ctrl-space", plain), "\x1b[32;5u");
        assert_eq!(sent("shift-enter", plain), "\x1b[13;2u");
        assert_eq!(sent("shift-tab", plain), "\x1b[9;2u");
        assert_eq!(sent("ctrl-backspace", plain), "\x1b[127;5u");
        assert_eq!(sent("ctrl-up", plain), "\x1b[1;5A");
        assert_eq!(sent("f5", plain), "\x1b[15~");
        // Every key, with the shifted key and the text it types if asked.
        let all = plain | TermMode::REPORT_ALL_KEYS_AS_ESC;
        assert_eq!(sent("a", all), "\x1b[97u");
        assert_eq!(sent("A", all), "\x1b[97;2u");
        assert_eq!(sent("enter", all), "\x1b[13u");
        let alternate = all | TermMode::REPORT_ALTERNATE_KEYS;
        assert_eq!(sent("A", alternate), "\x1b[97:65;2u");
        assert_eq!(sent("ctrl-a", alternate), "\x1b[97;5u");
        let text = all | TermMode::REPORT_ASSOCIATED_TEXT;
        assert_eq!(sent("A", text), "\x1b[97;2;65u");
        assert_eq!(sent("ctrl-a", text), "\x1b[97;5u");
    }

    #[test]
    fn the_mouse_is_reported_as_the_program_asked() {
        let at = |kind| Mouse {
            kind,
            col: 4,
            row: 2,
            ctrl: false,
            alt: false,
            shift: false,
        };
        let press = at(MouseKind::Press(Button::Left));
        assert_eq!(encode_mouse(press, TermMode::empty()), None, "not asked");
        let sgr = TermMode::MOUSE_REPORT_CLICK | TermMode::SGR_MOUSE;
        assert_eq!(encode_mouse(press, sgr).unwrap(), b"\x1b[<0;5;3M");
        let release = at(MouseKind::Release(Button::Left));
        assert_eq!(encode_mouse(release, sgr).unwrap(), b"\x1b[<0;5;3m");
        let scroll = at(MouseKind::ScrollDown);
        assert_eq!(encode_mouse(scroll, sgr).unwrap(), b"\x1b[<65;5;3M");
        // Drags only when asked for them; the original encoding adds 32.
        let drag = at(MouseKind::Drag(Button::Left));
        assert_eq!(encode_mouse(drag, sgr), None);
        let legacy = TermMode::MOUSE_DRAG;
        assert_eq!(encode_mouse(drag, legacy).unwrap(), b"\x1b[M@%#");
        let ctrl = Mouse {
            ctrl: true,
            ..press
        };
        assert_eq!(encode_mouse(ctrl, sgr).unwrap(), b"\x1b[<16;5;3M");
    }

    #[test]
    fn the_256_colors_are_the_usual_ones() {
        assert_eq!(indexed(1), Color::Ansi(1));
        assert_eq!(indexed(16), Color::Rgb(0, 0, 0));
        assert_eq!(indexed(196), Color::Rgb(255, 0, 0));
        assert_eq!(indexed(255), Color::Rgb(238, 238, 238));
        assert_eq!(color(TermColor::Named(NamedColor::Foreground)), None);
        assert_eq!(
            color(TermColor::Named(NamedColor::BrightRed)),
            Some(Color::Ansi(9))
        );
    }
}
