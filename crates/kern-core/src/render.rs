//! The render model: what a view looks like, described by meaning rather than
//! color.
//!
//! A [`Frame`] is rows of text spans tagged with what they are (a selection,
//! a cursor, the gutter, ...). Clients turn tags into styles, so a terminal
//! and a GUI can share it. Layout happens here, against a [`Measure`] the
//! client supplies, so motions and scrolling agree with what's on screen.

use std::borrow::Cow;
use std::ops::Range;
use std::sync::Arc;

use smallvec::{SmallVec, smallvec};
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

use kern_text::Rope;

use crate::syntax::Highlight;
use crate::{Anchor, BufferId, Editor, FloatOptions, Scroll, View, ViewId};

/// Finds the highlights overlapping a byte range of a buffer.
pub type Highlighter<'a> = dyn Fn(BufferId, &Rope, Range<usize>) -> Vec<Highlight> + 'a;

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
    /// Syntax, named by a tree-sitter capture such as "keyword" or
    /// "function.macro".
    Syntax(Arc<str>),
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
    /// The main view: exactly `size.height` rows, the last being the status
    /// line.
    pub rows: Vec<Row>,
    /// Floating views to draw over the rows, bottom first.
    pub floats: Vec<FloatFrame>,
    /// Where the primary cursor is, if it's on screen.
    pub cursor: Option<Position>,
    pub mode: String,
}

/// A floating view: its rows fill `rect`, and the client draws a border
/// around it, one cell wide.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FloatFrame {
    pub rect: Rect,
    pub title: Option<String>,
    pub rows: Vec<Row>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rect {
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub height: u16,
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
    pub fn frame(
        &self,
        editor: &mut Editor,
        size: Size,
        message: Option<&str>,
        highlighter: &Highlighter,
    ) -> Frame {
        let main = editor.main();
        let area = Rect {
            x: 0,
            y: 0,
            width: size.width,
            height: size.height.saturating_sub(1),
        };
        let (mut rows, main_cursor) = self.view_rows(editor, main, area, true, highlighter);
        rows.push(self.status(editor, editor.view(main), size, message));

        let mut cursor = main_cursor.filter(|_| editor.focus() == main);
        let mut floats = Vec::new();
        for float in editor.floats().to_vec() {
            let rect = place(&float.options, area);
            let (rows, float_cursor) = self.view_rows(editor, float.view, rect, false, highlighter);
            if editor.focus() == float.view {
                cursor = float_cursor;
            }
            floats.push(FloatFrame {
                rect,
                title: float.options.title.as_deref().map(str::to_owned),
                rows,
            });
        }

        Frame {
            size,
            rows,
            floats,
            cursor,
            mode: editor.mode().to_owned(),
        }
    }

    /// Lays out one view to fill `area`, scrolling it to keep its primary
    /// cursor visible. Returns its rows and where that cursor is on screen.
    fn view_rows(
        &self,
        editor: &mut Editor,
        view_id: ViewId,
        area: Rect,
        line_numbers: bool,
        highlighter: &Highlighter,
    ) -> (Vec<Row>, Option<Position>) {
        let text_rows = usize::from(area.height);
        let gutter = if line_numbers {
            gutter_width(editor, editor.view(view_id))
        } else {
            0
        };
        let text_width = usize::from(area.width).saturating_sub(gutter).max(1);

        let scroll = self.scroll_to_cursor(editor, editor.view(view_id), text_width, text_rows);
        editor.view_mut(view_id).scroll = scroll;

        let view = editor.view(view_id);
        let text = editor.buffer(view.buffer).text();
        let visible = visible_bytes(text, scroll, text_rows);
        let syntax = paint(highlighter(view.buffer, text, visible.clone()), &visible);
        let head = view.selection.primary().head;
        let mut rows = Vec::with_capacity(text_rows);
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
                if line_numbers {
                    let number = if i == 0 {
                        format!("{:>w$} ", line + 1, w = gutter - 1)
                    } else {
                        " ".repeat(gutter)
                    };
                    row.push(&number, smallvec![Tag::Gutter]);
                }
                let mut x = gutter;
                for cell in &cells {
                    if cell.byte == head {
                        let col = x.min(usize::from(area.width).saturating_sub(1));
                        cursor = Some(Position {
                            col: area.x + u16::try_from(col).unwrap_or(u16::MAX),
                            row: area.y + u16::try_from(rows.len()).unwrap_or(u16::MAX),
                        });
                    }
                    let mut cell_tags = cell_tags(view, cell);
                    if let Some(capture) = cell
                        .byte
                        .checked_sub(visible.start)
                        .and_then(|i| syntax.get(i)?.clone())
                    {
                        cell_tags.insert(0, Tag::Syntax(capture));
                    }
                    if !(cell.end_of_line && cell_tags.is_empty()) {
                        row.push(&cell.text, cell_tags);
                    }
                    x += cell.width;
                }
                rows.push(row);
            }
        }
        rows.resize_with(text_rows, Row::default);
        (rows, cursor)
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

/// The bytes the rows from `scroll` can show: whole lines, at most one per
/// row.
fn visible_bytes(text: &Rope, scroll: Scroll, rows: usize) -> Range<usize> {
    let end_line = (scroll.line + rows + 1).min(text.len_lines());
    text.line_to_byte(scroll.line)..text.line_to_byte(end_line)
}

/// The capture that applies to each byte of `range`. Inner captures win over
/// the ones around them, and for the same text the first capture wins, which
/// is how tree-sitter highlight queries are written.
fn paint(mut highlights: Vec<Highlight>, range: &Range<usize>) -> Vec<Option<Arc<str>>> {
    highlights.sort_by_key(|h| (h.range.start, std::cmp::Reverse(h.range.end)));
    let mut painted = vec![None; range.len()];
    let mut previous: Option<Range<usize>> = None;
    for highlight in highlights {
        if previous.as_ref() == Some(&highlight.range) {
            continue;
        }
        let start = highlight.range.start.clamp(range.start, range.end) - range.start;
        let end = highlight.range.end.clamp(range.start, range.end) - range.start;
        for byte in &mut painted[start..end] {
            *byte = Some(highlight.capture.clone());
        }
        previous = Some(highlight.range);
    }
    painted
}

/// Where a floating view's rows go within `area`, leaving a cell around them
/// for the border.
fn place(options: &FloatOptions, area: Rect) -> Rect {
    let outer_width = options.width.resolve(area.width).max(3);
    let outer_height = options.height.resolve(area.height).max(3);
    let x = area.width.saturating_sub(outer_width) / 2;
    let y = match options.anchor {
        Anchor::Top => 0,
        Anchor::Center => area.height.saturating_sub(outer_height) / 2,
        Anchor::Bottom => area.height.saturating_sub(outer_height),
    };
    Rect {
        x: area.x + x + 1,
        y: area.y + y + 1,
        width: outer_width - 2,
        height: outer_height - 2,
    }
}
