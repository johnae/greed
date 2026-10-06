//! Images from programs in a terminal: the kitty graphics protocol
//! (`ESC _ G ... ESC \`) and iTerm2's inline images (`OSC 1337;File=...`).
//!
//! The emulator never sees these sequences: [`Splitter`] cuts them out of
//! the program's output, in order, and [`Graphics`] places each image on
//! the cells under the cursor, as an [`ImagePiece`] on every cell it
//! covers. From there the emulator treats them like text: they scroll with
//! their rows, and text written over them or an erase removes them.
//!
//! The splitter also cuts out the marks shells put around prompts and
//! commands (`OSC 133`), which the emulator doesn't know.

use std::collections::HashMap;
use std::sync::Arc;

use alacritty_terminal::event::EventListener;
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::Term;
use alacritty_terminal::term::cell::{Cell, ImagePiece};
use alacritty_terminal::vte::ansi::Handler;
use base64::Engine;

use crate::image::{Image, ImageId};

/// The most an image sequence may hold before it's dropped.
const LIMIT: usize = 64 << 20;

/// A piece of a program's output: bytes for the emulator, or an image
/// sequence without its framing.
#[derive(Debug, PartialEq, Eq)]
pub enum Piece<'a> {
    Bytes(&'a [u8]),
    /// What came between `ESC _ G` and `ESC \`.
    Kitty(Vec<u8>),
    /// What came after `OSC 1337;File=`.
    Iterm(Vec<u8>),
    /// A place the shell marked (`OSC 133`): what came after `133;`, like
    /// `A` where a prompt starts or `D;1` where a command ended with 1.
    Prompt(Vec<u8>),
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
enum State {
    #[default]
    Text,
    /// After an `ESC`.
    Escape,
    Apc,
    /// After an `ESC` inside an APC string.
    ApcEscape,
    Osc,
    /// After an `ESC` inside an OSC string.
    OscEscape,
}

/// Cuts image sequences out of a stream of output, which may split them
/// anywhere.
#[derive(Debug, Default)]
pub struct Splitter {
    state: State,
    held: Vec<u8>,
    /// The sequence being held grew past `LIMIT`, and is dropped at its end.
    overflow: bool,
}

impl Splitter {
    /// Calls `emit` with each piece of `bytes`, in order.
    pub fn split(&mut self, bytes: &[u8], mut emit: impl FnMut(Piece<'_>)) {
        let mut start = 0;
        for (i, &byte) in bytes.iter().enumerate() {
            match self.state {
                State::Text => {
                    if byte == 0x1b {
                        emit(Piece::Bytes(&bytes[start..i]));
                        self.state = State::Escape;
                    }
                }
                State::Escape => match byte {
                    b'_' => self.begin(State::Apc),
                    b']' => self.begin(State::Osc),
                    0x1b => emit(Piece::Bytes(b"\x1b")),
                    _ => {
                        emit(Piece::Bytes(b"\x1b"));
                        self.state = State::Text;
                        start = i;
                    }
                },
                State::Apc => match byte {
                    0x1b => self.state = State::ApcEscape,
                    _ => self.hold(&[byte]),
                },
                State::ApcEscape => {
                    if byte == b'\\' {
                        self.end_apc(&mut emit);
                        start = i + 1;
                    } else {
                        self.hold(&[0x1b, byte]);
                        self.state = State::Apc;
                    }
                }
                State::Osc => match byte {
                    0x07 => {
                        self.end_osc(&mut emit, b"\x07");
                        start = i + 1;
                    }
                    0x1b => self.state = State::OscEscape,
                    _ => self.hold(&[byte]),
                },
                State::OscEscape => {
                    if byte == b'\\' {
                        self.end_osc(&mut emit, b"\x1b\\");
                        start = i + 1;
                    } else {
                        self.hold(&[0x1b, byte]);
                        self.state = State::Osc;
                    }
                }
            }
        }
        if self.state == State::Text && start < bytes.len() {
            emit(Piece::Bytes(&bytes[start..]));
        }
    }

    fn begin(&mut self, state: State) {
        self.state = state;
        self.held.clear();
        self.overflow = false;
    }

    fn hold(&mut self, bytes: &[u8]) {
        if self.held.len() + bytes.len() > LIMIT {
            self.overflow = true;
        } else if !self.overflow {
            self.held.extend_from_slice(bytes);
        }
    }

    /// Kitty's are the APC strings starting with G; the emulator ignores
    /// the rest anyway.
    fn end_apc(&mut self, emit: &mut impl FnMut(Piece<'_>)) {
        self.state = State::Text;
        let held = std::mem::take(&mut self.held);
        if !self.overflow && held.first() == Some(&b'G') {
            emit(Piece::Kitty(held[1..].to_vec()));
        }
    }

    /// iTerm2's images and the shell's marks come out; every other OSC goes
    /// on to the emulator, as it came.
    fn end_osc(&mut self, emit: &mut impl FnMut(Piece<'_>), terminator: &[u8]) {
        self.state = State::Text;
        let held = std::mem::take(&mut self.held);
        if self.overflow {
            return;
        }
        if let Some(rest) = held.strip_prefix(b"1337;File=") {
            emit(Piece::Iterm(rest.to_vec()));
        } else if let Some(rest) = held.strip_prefix(b"133;") {
            emit(Piece::Prompt(rest.to_vec()));
        } else {
            let whole = [b"\x1b]", held.as_slice(), terminator].concat();
            emit(Piece::Bytes(&whole));
        }
    }
}

/// An image placed in the terminal: what it shows, and over how many cells.
#[derive(Debug, Clone)]
pub struct Placed {
    pub image: Arc<Image>,
    pub cols: u16,
    pub rows: u16,
    /// The kitty image id the program gave it, if any.
    client: Option<u32>,
}

/// The images programs sent and placed in one terminal.
#[derive(Debug, Default)]
pub struct Graphics {
    /// Images a program sent with kitty's protocol, by the id it gave.
    images: HashMap<u32, Arc<Image>>,
    /// A kitty image arriving in chunks: its keys and the data so far.
    pending: Option<(Keys, Vec<u8>)>,
    /// What's placed, by the id on its cells (an [`ImageId`] of its own).
    pub placed: HashMap<u64, Placed>,
}

/// The keys of a kitty command, like `a=T,f=100,i=3`.
#[derive(Debug, Clone, Default)]
struct Keys(HashMap<u8, Vec<u8>>);

impl Keys {
    fn parse(control: &[u8]) -> Self {
        Keys(
            control
                .split(|&b| b == b',')
                .filter_map(|pair| {
                    let (key, value) = pair.split_at_checked(1)?;
                    Some((key[0], value.strip_prefix(b"=")?.to_vec()))
                })
                .collect(),
        )
    }

    fn char(&self, key: u8) -> Option<u8> {
        self.0.get(&key).and_then(|v| v.first().copied())
    }

    fn number(&self, key: u8) -> Option<u32> {
        std::str::from_utf8(self.0.get(&key)?).ok()?.parse().ok()
    }
}

fn decode_base64(data: &[u8]) -> Option<Vec<u8>> {
    let data: Vec<u8> = data
        .iter()
        .copied()
        .filter(|b| !b.is_ascii_whitespace())
        .collect();
    base64::engine::general_purpose::STANDARD
        .decode(&data)
        .or_else(|_| base64::engine::general_purpose::STANDARD_NO_PAD.decode(&data))
        .ok()
}

impl Graphics {
    /// Carries out a kitty command at the cursor. Returns the reply for the
    /// program, if it wants one.
    pub fn kitty<T: EventListener>(
        &mut self,
        command: &[u8],
        term: &mut Term<T>,
        cell: (u16, u16),
    ) -> Option<String> {
        let (control, data) = match command.iter().position(|&b| b == b';') {
            Some(at) => (&command[..at], &command[at + 1..]),
            None => (command, &[][..]),
        };
        let keys = Keys::parse(control);
        // Later chunks carry only m=; the first one's keys hold for all.
        let (keys, data) = match self.pending.take() {
            Some((first, mut so_far)) => {
                so_far.extend_from_slice(data);
                (Keys(first.0.into_iter().chain(keys.0).collect()), so_far)
            }
            None => (keys, data.to_vec()),
        };
        if keys.number(b'm') == Some(1) {
            self.pending = Some((keys, data));
            return None;
        }
        let action = keys.char(b'a').unwrap_or(b't');
        let result = match action {
            b'd' => {
                self.delete(&keys, term);
                return None;
            }
            b'p' => keys
                .number(b'i')
                .and_then(|id| self.images.get(&id).cloned())
                .ok_or_else(|| "ENOENT:no such image".to_owned())
                .map(|image| self.place(&image, &keys, term, cell)),
            b't' | b'T' | b'q' => image(&keys, &data).map(|image| {
                let image = Arc::new(image);
                if action == b'T' {
                    self.place(&image, &keys, term, cell);
                }
                if action != b'q'
                    && let Some(id) = keys.number(b'i')
                {
                    self.images.insert(id, image);
                }
            }),
            _ => Err("EINVAL:unknown action".to_owned()),
        };
        reply(&keys, result)
    }

    /// Places `image` at the cursor, `c` by `r` cells if the keys say,
    /// moving the cursor past it unless `C=1`.
    fn place<T: EventListener>(
        &mut self,
        image: &Image,
        keys: &Keys,
        term: &mut Term<T>,
        cell: (u16, u16),
    ) {
        let (natural_cols, natural_rows) = image.cells(cell);
        let cells = |key, natural| {
            keys.number(key)
                .and_then(|n| u16::try_from(n).ok())
                .unwrap_or(natural)
        };
        let (cols, rows) = (cells(b'c', natural_cols), cells(b'r', natural_rows));
        self.put(
            image,
            cols.max(1),
            rows.max(1),
            keys.number(b'C') != Some(1),
            keys.number(b'i'),
            term,
        );
    }

    /// Covers `cols` by `rows` cells from the cursor with `image`. Moving,
    /// the cursor ends after the image on its last row, scrolling as text
    /// would; otherwise it stays, and rows below the screen are left off.
    fn put<T: EventListener>(
        &mut self,
        image: &Image,
        cols: u16,
        rows: u16,
        moving: bool,
        client: Option<u32>,
        term: &mut Term<T>,
    ) {
        let id = ImageId::next().0;
        let start = term.grid().cursor.point;
        let width = term.columns().saturating_sub(start.column.0);
        let shown = usize::from(cols).min(width);
        for row in 0..rows {
            let line = if moving {
                term.grid().cursor.point.line
            } else {
                let line = start.line + i32::from(row);
                if line.0 >= i32::try_from(term.screen_lines()).unwrap_or(i32::MAX) {
                    break;
                }
                line
            };
            for col in 0..shown {
                let cell = &mut term.grid_mut()[line][start.column + col];
                *cell = Cell::default();
                cell.set_image(Some(ImagePiece {
                    id,
                    col: u16::try_from(col).unwrap_or(u16::MAX),
                    row,
                }));
            }
            if moving && row + 1 < rows {
                term.linefeed();
            }
        }
        if moving {
            term.goto_col((start.column.0 + shown).min(term.columns() - 1));
        }
        let image = Arc::new(Image {
            id: ImageId(id),
            ..image.clone()
        });
        self.placed.insert(
            id,
            Placed {
                image,
                cols,
                rows,
                client,
            },
        );
    }

    /// `d=a` and `d=A` remove every image on the screen, `d=i` and `d=I`
    /// those of image `i`; the capital forms forget the image too.
    fn delete<T: EventListener>(&mut self, keys: &Keys, term: &mut Term<T>) {
        let what = keys.char(b'd').unwrap_or(b'a');
        let id = keys.number(b'i');
        let doomed: Vec<u64> = self
            .placed
            .iter()
            .filter(|(_, p)| match what {
                b'i' | b'I' => p.client.is_some() && p.client == id,
                _ => true,
            })
            .map(|(id, _)| *id)
            .collect();
        let lines = term.screen_lines();
        let cols = term.columns();
        for line in 0..lines {
            for col in 0..cols {
                let cell =
                    &mut term.grid_mut()[Line(i32::try_from(line).unwrap_or(0))][Column(col)];
                if cell.image().is_some_and(|piece| doomed.contains(&piece.id)) {
                    cell.set_image(None);
                }
            }
        }
        match what {
            b'A' => self.images.clear(),
            b'I' => {
                if let Some(id) = id {
                    self.images.remove(&id);
                }
            }
            _ => {}
        }
    }

    /// Carries out an iTerm2 inline image: `args:base64` after `File=`.
    pub fn iterm<T: EventListener>(
        &mut self,
        command: &[u8],
        term: &mut Term<T>,
        cell: (u16, u16),
    ) {
        let Some(at) = command.iter().position(|&b| b == b':') else {
            return;
        };
        let (args, data) = (&command[..at], &command[at + 1..]);
        let args: HashMap<&[u8], &[u8]> = args
            .split(|&b| b == b';')
            .filter_map(|pair| {
                let at = pair.iter().position(|&b| b == b'=')?;
                Some((&pair[..at], &pair[at + 1..]))
            })
            .collect();
        if args.get(&b"inline"[..]) != Some(&&b"1"[..]) {
            return;
        }
        let Some(image) = decode_base64(data).and_then(|bytes| Image::from_file_bytes(&bytes).ok())
        else {
            return;
        };
        let (cols, rows) = iterm_size(&image, &args, cell, term.columns(), term.screen_lines());
        self.put(&image, cols, rows, true, None, term);
    }
}

/// The image a kitty command transmits: PNG, or raw RGB or RGBA pixels
/// (`f=24`, `f=32` with `s` and `v`), sent in the command (`t=d`) or in a
/// file (`t=f`, or `t=t` for a temporary file, removed after).
fn image(keys: &Keys, data: &[u8]) -> Result<Image, String> {
    if keys.char(b'o').is_some() {
        return Err("EINVAL:compression isn't supported".to_owned());
    }
    let decoded = decode_base64(data).ok_or_else(|| "EINVAL:bad base64".to_owned())?;
    let bytes = match keys.char(b't').unwrap_or(b'd') {
        b'd' => decoded,
        medium @ (b'f' | b't') => {
            let path = String::from_utf8(decoded).map_err(|_| "EINVAL:bad path".to_owned())?;
            let bytes = std::fs::read(&path).map_err(|e| format!("EBADF:{e}"))?;
            if medium == b't' && path.contains("tty-graphics-protocol") {
                let _ = std::fs::remove_file(&path);
            }
            bytes
        }
        _ => return Err("EINVAL:only direct and file transmission are supported".to_owned()),
    };
    let format = keys.number(b'f').unwrap_or(32);
    let size = || {
        keys.number(b's')
            .zip(keys.number(b'v'))
            .ok_or_else(|| "EINVAL:no size".to_owned())
    };
    match format {
        100 => Image::from_file_bytes(&bytes),
        24 | 32 => {
            let (width, height) = size()?;
            Image::from_pixels(width, height, if format == 24 { 3 } else { 4 }, &bytes)
        }
        _ => return Err("EINVAL:unknown format".to_owned()),
    }
    .map_err(|e| format!("EINVAL:{e}"))
}

/// The reply kitty sends: OK or the error, for commands with an image id,
/// unless `q` asks for quiet (1: no OK, 2: nothing).
fn reply(keys: &Keys, result: Result<(), String>) -> Option<String> {
    let id = keys.number(b'i')?;
    let quiet = keys.number(b'q').unwrap_or(0);
    let message = match result {
        Ok(()) if quiet == 0 => "OK".to_owned(),
        Err(e) if quiet < 2 => e,
        _ => return None,
    };
    Some(format!("\x1b_Gi={id};{message}\x1b\\"))
}

/// How many cells an iTerm2 image covers: `width` and `height` in cells,
/// `Npx` or `N%`, or from the image's own size, keeping its shape when
/// only one is given.
fn iterm_size(
    image: &Image,
    args: &HashMap<&[u8], &[u8]>,
    cell: (u16, u16),
    columns: usize,
    lines: usize,
) -> (u16, u16) {
    let cells = |key: &[u8], pixel: u16, whole: usize| -> Option<u16> {
        let value = std::str::from_utf8(args.get(key)?).ok()?;
        let n = |s: &str| s.parse::<u32>().ok();
        let cells = if let Some(px) = value.strip_suffix("px") {
            n(px)?.div_ceil(u32::from(pixel.max(1)))
        } else if let Some(percent) = value.strip_suffix('%') {
            n(percent)? * u32::try_from(whole).ok()? / 100
        } else {
            n(value)?
        };
        u16::try_from(cells.max(1)).ok()
    };
    let (natural_cols, natural_rows) = image.cells(cell);
    let ratio = f64::from(natural_rows) / f64::from(natural_cols);
    let size = match (
        cells(b"width", cell.0, columns),
        cells(b"height", cell.1, lines),
    ) {
        (Some(c), Some(r)) => (c, r),
        (Some(c), None) => (c, scale(f64::from(c) * ratio)),
        (None, Some(r)) => (scale(f64::from(r) / ratio), r),
        (None, None) => (natural_cols, natural_rows),
    };
    (size.0.max(1), size.1.max(1))
}

#[expect(
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    reason = "clamped first"
)]
fn scale(cells: f64) -> u16 {
    cells.round().clamp(1.0, f64::from(u16::MAX)) as u16
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pieces(splitter: &mut Splitter, bytes: &[u8]) -> Vec<String> {
        let mut out = Vec::new();
        splitter.split(bytes, |piece| {
            out.push(match piece {
                Piece::Bytes(b) => format!("text {}", String::from_utf8_lossy(b)),
                Piece::Kitty(k) => format!("kitty {}", String::from_utf8_lossy(&k)),
                Piece::Iterm(i) => format!("iterm {}", String::from_utf8_lossy(&i)),
                Piece::Prompt(p) => format!("prompt {}", String::from_utf8_lossy(&p)),
            });
        });
        out.retain(|p| p != "text ");
        out
    }

    #[test]
    fn image_sequences_come_out_and_the_rest_goes_on() {
        let mut s = Splitter::default();
        assert_eq!(
            pieces(&mut s, b"hi\x1b_Ga=T;AAAA\x1b\\ there\x1b[31m!"),
            [
                "text hi",
                "kitty a=T;AAAA",
                "text  there",
                "text \x1b",
                "text [31m!"
            ]
        );
        // A title is an OSC the emulator wants, as it came.
        assert_eq!(
            pieces(&mut s, b"\x1b]0;title\x07"),
            ["text \x1b]0;title\x07"]
        );
        assert_eq!(
            pieces(&mut s, b"\x1b]1337;File=inline=1:AA\x1b\\"),
            ["iterm inline=1:AA"]
        );
    }

    #[test]
    fn the_shells_marks_come_out() {
        let mut s = Splitter::default();
        assert_eq!(
            pieces(
                &mut s,
                b"\x1b]133;A\x07$ \x1b]133;B\x1b\\ls\n\x1b]133;D;1\x07"
            ),
            ["prompt A", "text $ ", "prompt B", "text ls\n", "prompt D;1"]
        );
    }

    #[test]
    fn a_sequence_can_be_split_anywhere() {
        let mut s = Splitter::default();
        let mut got = pieces(&mut s, b"a\x1b");
        got.extend(pieces(&mut s, b"_Gm=1;AB"));
        got.extend(pieces(&mut s, b"CD\x1b"));
        got.extend(pieces(&mut s, b"\\b"));
        assert_eq!(got, ["text a", "kitty m=1;ABCD", "text b"]);
    }

    #[test]
    fn kitty_keys_are_read() {
        let keys = Keys::parse(b"a=T,f=100,i=31,q=2");
        assert_eq!(keys.char(b'a'), Some(b'T'));
        assert_eq!(keys.number(b'f'), Some(100));
        assert_eq!(keys.number(b'i'), Some(31));
        assert_eq!(keys.number(b'x'), None);
    }

    #[test]
    fn replies_say_ok_or_why_not_unless_asked_to_be_quiet() {
        let ok = |control: &[u8]| reply(&Keys::parse(control), Ok(()));
        assert_eq!(ok(b"i=7").as_deref(), Some("\x1b_Gi=7;OK\x1b\\"));
        assert_eq!(ok(b"i=7,q=1"), None);
        assert_eq!(ok(b"a=T"), None, "no id, no reply");
        let failed = reply(&Keys::parse(b"i=7,q=1"), Err("ENOENT:gone".into()));
        assert_eq!(failed.as_deref(), Some("\x1b_Gi=7;ENOENT:gone\x1b\\"));
    }
}
