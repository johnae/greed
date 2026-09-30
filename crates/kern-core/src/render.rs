//! The render model: what a view looks like, described by meaning rather than
//! color.
//!
//! A [`Frame`] is rows of text spans tagged with what they are (a selection,
//! a cursor, the gutter, ...). Clients turn tags into styles, so a terminal
//! and a GUI can share it. Layout happens here, against a [`Measure`] the
//! client supplies, so motions and scrolling agree with what's on screen.

use std::borrow::Cow;

use smallvec::{SmallVec, smallvec};
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

use crate::{Editor, Scroll, View};

/// How wide text is on screen.
pub trait Measure {
    /// The width of one grapheme cluster, in cells.
    fn width(&self, grapheme: &str) -> usize;
}

/// Terminal cell widths: 1 for most characters, 2 for wide ones.
#[derive(Debug, Clone, Copy, Default)]
pub struct CellWidth;

impl Measure for CellWidth {
    fn width(&self, grapheme: &str) -> usize {
        grapheme.width()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Size {
    pub width: u16,
    pub height: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Position {
    pub col: u16,
    pub row: u16,
}

/// What a span of text is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Tag {
    Gutter,
    Selection,
    /// A cursor other than the primary one; the primary cursor is
    /// [`Frame::cursor`].
    Cursor,
    Status,
    Mode,
    Message,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Span {
    pub text: String,
    pub tags: SmallVec<[Tag; 2]>,
}

/// One screen row.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Row {
    pub spans: Vec<Span>,
}

impl Row {
    pub fn text(&self) -> String {
        self.spans.iter().map(|s| s.text.as_str()).collect()
    }

    fn push(&mut self, text: &str, tags: SmallVec<[Tag; 2]>) {
        match self.spans.last_mut() {
            Some(last) if last.tags == tags => last.text.push_str(text),
            _ => self.spans.push(Span {
                text: text.to_owned(),
                tags,
            }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub size: Size,
    /// Exactly `size.height` rows; the last is the status line.
    pub rows: Vec<Row>,
    /// Where the primary cursor is, if it's on screen.
    pub cursor: Option<Position>,
    pub mode: String,
}

/// One grapheme placed on screen.
#[derive(Debug, Clone)]
struct Cell {
    /// Byte offset in the buffer.
    byte: usize,
    text: String,
    width: usize,
    /// The space after the end of a line, where a cursor can sit.
    end_of_line: bool,
}

pub struct Renderer<M> {
    measure: M,
    pub tab_width: usize,
}

impl<M: Measure> Renderer<M> {
    pub fn new(measure: M) -> Self {
        Self {
            measure,
            tab_width: 4,
        }
    }

    /// Lays out the focused view, scrolling it to keep the primary cursor
    /// visible.
    pub fn frame(&self, editor: &mut Editor, size: Size, message: Option<&str>) -> Frame {
        let view_id = editor.focus();
        let text_rows = usize::from(size.height.saturating_sub(1));
        let gutter = gutter_width(editor, editor.view(view_id));
        let text_width = usize::from(size.width).saturating_sub(gutter).max(1);

        let scroll = self.scroll_to_cursor(editor, editor.view(view_id), text_width, text_rows);
        editor.view_mut(view_id).scroll = scroll;

        let view = editor.view(view_id);
        let text = editor.buffer(view.buffer).text();
        let head = view.selection.primary().head;
        let mut rows = Vec::with_capacity(usize::from(size.height));
        let mut cursor = None;

        'lines: for line in scroll.line..text.len_lines() {
            let skip = if line == scroll.line { scroll.row } else { 0 };
            for (i, cells) in self
                .layout(editor, view, line, text_width)
                .into_iter()
                .enumerate()
                .skip(skip)
            {
                if rows.len() == text_rows {
                    break 'lines;
                }
                let mut row = Row::default();
                let number = if i == 0 {
                    format!("{:>w$} ", line + 1, w = gutter - 1)
                } else {
                    " ".repeat(gutter)
                };
                row.push(&number, smallvec![Tag::Gutter]);
                let mut x = gutter;
                for cell in &cells {
                    if cell.byte == head {
                        cursor = Some(Position {
                            col: u16::try_from(x.min(usize::from(size.width) - 1))
                                .unwrap_or(u16::MAX),
                            row: u16::try_from(rows.len()).unwrap_or(u16::MAX),
                        });
                    }
                    let cell_tags = cell_tags(view, cell);
                    if !(cell.end_of_line && cell_tags.is_empty()) {
                        row.push(&cell.text, cell_tags);
                    }
                    x += cell.width;
                }
                rows.push(row);
            }
        }
        rows.resize_with(text_rows, Row::default);
        rows.push(self.status(editor, view, size, message));

        Frame {
            size,
            rows,
            cursor,
            mode: editor.mode().to_owned(),
        }
    }

    /// Splits `line` into screen rows of at most `width` cells, breaking
    /// after whitespace where it can.
    fn layout(&self, editor: &Editor, view: &View, line: usize, width: usize) -> Vec<Vec<Cell>> {
        let text = editor.buffer(view.buffer).text();
        let start = text.line_to_byte(line);
        let content: Cow<str> = text.line(line).into();
        let content = content.trim_end_matches(['\n', '\r']);

        let mut rows = vec![Vec::new()];
        let mut x = 0;
        // Where the current row may break: just after its last whitespace.
        let mut last_break = 0;
        for (offset, grapheme) in content.grapheme_indices(true) {
            let (text, w) = if grapheme == "\t" {
                let w = self.tab_width - x % self.tab_width;
                (" ".repeat(w), w)
            } else {
                (grapheme.to_owned(), self.measure.width(grapheme))
            };
            let row = rows.last_mut().expect("at least one row");
            if x + w > width && !row.is_empty() {
                let carried = if last_break > 0 && last_break < row.len() {
                    row.split_off(last_break)
                } else {
                    Vec::new()
                };
                x = carried.iter().map(|c: &Cell| c.width).sum();
                rows.push(carried);
                last_break = 0;
            }
            let row = rows.last_mut().expect("at least one row");
            row.push(Cell {
                byte: start + offset,
                text,
                width: w,
                end_of_line: false,
            });
            x += w;
            if grapheme.chars().all(char::is_whitespace) {
                last_break = row.len();
            }
        }
        if x < width {
            rows.last_mut().expect("at least one row").push(Cell {
                byte: start + content.len(),
                text: " ".to_owned(),
                width: 1,
                end_of_line: true,
            });
        }
        rows
    }

    /// Which row of its line `pos` is on.
    fn row_of(&self, editor: &Editor, view: &View, line: usize, pos: usize, width: usize) -> usize {
        let rows = self.layout(editor, view, line, width);
        rows.iter()
            .position(|cells| cells.last().is_some_and(|c| c.byte >= pos))
            .unwrap_or(rows.len() - 1)
    }

    /// The scroll position that keeps the primary cursor on screen, moving
    /// as little as possible from the current one.
    fn scroll_to_cursor(
        &self,
        editor: &Editor,
        view: &View,
        width: usize,
        height: usize,
    ) -> Scroll {
        let text = editor.buffer(view.buffer).text();
        let head = view.selection.primary().head.min(text.len_bytes());
        let line = text.byte_to_line(head);
        let cursor = Scroll {
            line,
            row: self.row_of(editor, view, line, head, width),
        };
        let current = view.scroll;
        if (cursor.line, cursor.row) < (current.line, current.row) || height == 0 {
            return cursor;
        }

        // Is the cursor within `height` rows of the current scroll?
        let mut seen = 0;
        for l in current.line..=cursor.line {
            let rows = if l == cursor.line {
                cursor.row + 1
            } else {
                self.layout(editor, view, l, width).len()
            };
            let skip = if l == current.line { current.row } else { 0 };
            seen += rows.saturating_sub(skip);
            if seen > height {
                break;
            }
        }
        if seen <= height {
            return current;
        }

        // Scroll so the cursor's row is the last one on screen.
        let mut top = cursor;
        let mut above = height - 1;
        while above > 0 {
            if top.row >= above {
                top.row -= above;
                break;
            }
            above -= top.row + 1;
            if top.line == 0 {
                top.row = 0;
                break;
            }
            top.line -= 1;
            top.row = self.layout(editor, view, top.line, width).len() - 1;
        }
        top
    }

    fn text_width(&self, text: &str) -> usize {
        text.graphemes(true).map(|g| self.measure.width(g)).sum()
    }

    /// `text` if it fits in `room` cells, or as much of its end as fits after
    /// an ellipsis. The end of a path is the part that tells files apart.
    fn keep_end(&self, text: &str, room: usize) -> String {
        if self.text_width(text) <= room {
            return text.to_owned();
        }
        if room == 0 {
            return String::new();
        }
        let mut kept = 0;
        let mut start = text.len();
        for (offset, grapheme) in text.grapheme_indices(true).rev() {
            let w = self.measure.width(grapheme);
            if kept + w + 1 > room {
                break;
            }
            kept += w;
            start = offset;
        }
        format!("…{}", &text[start..])
    }

    fn status(&self, editor: &Editor, view: &View, size: Size, message: Option<&str>) -> Row {
        let buffer = editor.buffer(view.buffer);
        let text = buffer.text();
        let head = view.selection.primary().head;
        let line = text.byte_to_line(head);
        let column = text.byte_to_char(head) - text.line_to_char(line) + 1;

        let mode = format!(" {} ", editor.mode().to_uppercase());
        let (middle, middle_tag) = match message {
            Some(message) => (message.to_owned(), Tag::Message),
            None => (
                buffer
                    .path()
                    .map_or_else(|| "[scratch]".to_owned(), |p| p.display().to_string()),
                Tag::Status,
            ),
        };
        let position = format!("{}:{column} ", line + 1);
        let room = usize::from(size.width)
            .saturating_sub(self.text_width(&mode) + 2 + self.text_width(&position));
        let middle = self.keep_end(&middle, room);
        // At least one space between the middle and the position.
        let padding = " ".repeat(room - self.text_width(&middle) + 1);

        let mut row = Row::default();
        row.push(&mode, smallvec![Tag::Mode]);
        row.push(" ", smallvec![Tag::Status]);
        row.push(&middle, smallvec![middle_tag]);
        row.push(&padding, smallvec![Tag::Status]);
        row.push(&position, smallvec![Tag::Status]);
        row
    }
}

/// Line numbers plus one space.
fn gutter_width(editor: &Editor, view: &View) -> usize {
    editor
        .buffer(view.buffer)
        .text()
        .len_lines()
        .to_string()
        .len()
        + 1
}

/// Selection and cursor tags for one cell.
fn cell_tags(view: &View, cell: &Cell) -> SmallVec<[Tag; 2]> {
    let mut out = SmallVec::new();
    let primary = view.selection.primary_index();
    for (i, range) in view.selection.ranges().iter().enumerate() {
        if !cell.end_of_line && range.from() <= cell.byte && cell.byte < range.to() {
            out.push(Tag::Selection);
        }
        if range.is_empty() && range.head == cell.byte && i != primary {
            out.push(Tag::Cursor);
        }
    }
    out
}
