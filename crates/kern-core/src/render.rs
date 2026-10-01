//! The render model: what a view looks like, described by meaning rather than
//! color.
//!
//! A [`Frame`] is rows of text spans tagged with what they are (a selection,
//! a cursor, the gutter, ...). Clients turn tags into styles with the
//! frame's theme, so a terminal and a GUI can share it. Layout happens here,
//! against a [`Measure`] the client supplies, so motions and scrolling agree
//! with what's on screen.

use std::borrow::Cow;
use std::ops::Range;
use std::sync::Arc;

use smallvec::{SmallVec, smallvec};
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

use kern_text::Rope;

use crate::syntax::Highlight;
use crate::theme::Theme;
use crate::{
    Anchor, BufferId, CursorShape, Editor, FloatOptions, Mark, Panel, Scroll, Side, View, ViewId,
};

/// Highlights and marks drawn over a buffer's text.
pub trait Decorations {
    /// Syntax highlights overlapping `range` of `buffer`.
    fn highlights(&self, _buffer: BufferId, _text: &Rope, _range: Range<usize>) -> Vec<Highlight> {
        Vec::new()
    }

    /// Diagnostics in `buffer`: a byte range and a severity, 1 (error) to 4
    /// (hint).
    fn diagnostics(&self, _buffer: BufferId) -> &[(Range<usize>, u8)] {
        &[]
    }
}

/// No highlights or marks.
pub struct Plain;

impl Decorations for Plain {}

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

/// What a span of text is: a style name, which the theme turns into a look
/// (see [`crate::theme`]). A span's tags layer in order, last on top.
#[derive(Debug, Clone)]
pub struct Tag(Name);

#[derive(Debug, Clone)]
enum Name {
    Fixed(&'static str),
    Shared(Arc<str>),
}

impl Tag {
    pub const TEXT: Tag = Tag::fixed("ui.text");
    pub const GUTTER: Tag = Tag::fixed("ui.gutter");
    pub const SELECTION: Tag = Tag::fixed("ui.selection");
    /// A cursor other than the primary one; the primary cursor is
    /// [`Frame::cursor`].
    pub const CURSOR: Tag = Tag::fixed("ui.cursor");
    pub const STATUS: Tag = Tag::fixed("ui.statusline");
    pub const MODE: Tag = Tag::fixed("ui.statusline.mode");
    pub const MESSAGE: Tag = Tag::fixed("ui.statusline.message");
    pub const FLOAT: Tag = Tag::fixed("ui.float");
    pub const FLOAT_BORDER: Tag = Tag::fixed("ui.float.border");
    pub const FLOAT_TITLE: Tag = Tag::fixed("ui.float.title");
    pub const PANEL: Tag = Tag::fixed("ui.panel");
    pub const PANEL_BORDER: Tag = Tag::fixed("ui.panel.border");
    pub const PANEL_TITLE: Tag = Tag::fixed("ui.panel.title");

    pub const fn fixed(name: &'static str) -> Self {
        Tag(Name::Fixed(name))
    }

    /// A diagnostic, by severity: 1 error, 2 warning, 3 info, 4 hint.
    pub fn diagnostic(severity: u8) -> Self {
        Tag::fixed(match severity {
            1 => "diagnostic.error",
            2 => "diagnostic.warning",
            3 => "diagnostic.info",
            _ => "diagnostic.hint",
        })
    }

    /// A line number on a line with a diagnostic of `severity`.
    pub fn gutter_diagnostic(severity: u8) -> Self {
        Tag::fixed(match severity {
            1 => "ui.gutter.diagnostic.error",
            2 => "ui.gutter.diagnostic.warning",
            3 => "ui.gutter.diagnostic.info",
            _ => "ui.gutter.diagnostic.hint",
        })
    }

    pub fn name(&self) -> &str {
        match &self.0 {
            Name::Fixed(name) => name,
            Name::Shared(name) => name,
        }
    }
}

impl From<Arc<str>> for Tag {
    fn from(name: Arc<str>) -> Self {
        Tag(Name::Shared(name))
    }
}

impl From<&str> for Tag {
    fn from(name: &str) -> Self {
        Tag(Name::Shared(name.into()))
    }
}

impl PartialEq for Tag {
    fn eq(&self, other: &Self) -> bool {
        self.name() == other.name()
    }
}

impl Eq for Tag {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Span {
    pub text: String,
    pub tags: SmallVec<[Tag; 2]>,
}

/// One screen row.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Row {
    pub spans: Vec<Span>,
    /// Styles for the whole row, under its spans and across its empty end.
    pub tags: SmallVec<[Tag; 1]>,
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
    /// Where the main view's rows go; panels take the rest of the width.
    pub main: Rect,
    /// The main view's rows, then the status line, which spans the screen.
    pub rows: Vec<Row>,
    /// Panels beside the main view.
    pub panels: Vec<PanelFrame>,
    /// Floating views to draw over the rows, bottom first.
    pub floats: Vec<FloatFrame>,
    /// Where the primary cursor is, if it's on screen.
    pub cursor: Option<Position>,
    pub cursor_shape: CursorShape,
    /// What the tags look like.
    pub theme: Arc<Theme>,
}

/// A panel: its rows fill `rect`. The client draws a line down column
/// `separator`, between the panel and the main view, and the title (if any)
/// on the row above `rect`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PanelFrame {
    pub rect: Rect,
    pub separator: u16,
    pub title: Option<String>,
    pub rows: Vec<Row>,
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

/// A status line: segments on the left and on the right, with the space
/// between them padded.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct StatusLine {
    pub left: Vec<Span>,
    pub right: Vec<Span>,
}

/// What goes on the status line.
pub enum Status<'a> {
    /// The built-in line, showing `message` in place of the file name.
    Default { message: Option<&'a str> },
    /// A line a plugin built.
    Line(StatusLine),
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
    /// Text a mark shows that isn't in the buffer, with the mark's style.
    /// The cursor never sits on it.
    inserted: Option<Arc<str>>,
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
        status: &Status,
        decorations: &dyn Decorations,
    ) -> Frame {
        let main = editor.main();
        let screen = Rect {
            x: 0,
            y: 0,
            width: size.width,
            height: size.height.saturating_sub(1),
        };
        let (area, placed) = layout_panels(editor.panels(), screen);
        let (mut rows, main_cursor) = self.view_rows(editor, main, area, true, decorations);
        let status = match status {
            Status::Default { message } => {
                Self::default_status(editor, editor.view(main), *message)
            }
            Status::Line(line) => line.clone(),
        };
        rows.push(self.status_row(&status, usize::from(size.width)));

        let mut cursor = main_cursor.filter(|_| editor.focus() == main);
        let mut panels = Vec::new();
        for (view, mut panel) in placed {
            let (rows, panel_cursor) = self.view_rows(editor, view, panel.rect, false, decorations);
            if editor.focus() == view {
                cursor = panel_cursor;
            }
            panel.rows = rows;
            panels.push(panel);
        }
        let mut floats = Vec::new();
        for float in editor.floats().to_vec() {
            let rect = place(&float.options, screen);
            let (rows, float_cursor) = self.view_rows(editor, float.view, rect, false, decorations);
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
            main: area,
            rows,
            panels,
            floats,
            cursor,
            cursor_shape: editor.cursor_shape(),
            theme: editor.theme().clone(),
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
        decorations: &dyn Decorations,
    ) -> (Vec<Row>, Option<Position>) {
        let text_rows = usize::from(area.height);
        let (gutter, signs) = if line_numbers {
            gutter_width(editor, editor.view(view_id))
        } else {
            (0, false)
        };
        let text_width = usize::from(area.width).saturating_sub(gutter).max(1);

        let scroll = self.scroll_to_cursor(editor, editor.view(view_id), text_width, text_rows);
        editor.view_mut(view_id).scroll = scroll;

        let view = editor.view(view_id);
        let text = editor.buffer(view.buffer).text();
        let visible = visible_bytes(text, scroll, text_rows);
        let syntax = paint(
            decorations.highlights(view.buffer, text, visible.clone()),
            &visible,
        );
        let marks: Vec<_> = decorations
            .diagnostics(view.buffer)
            .iter()
            .filter(|(range, _)| range.start <= visible.end && range.end >= visible.start)
            .cloned()
            .collect();
        let styled: Vec<&Mark> = editor
            .buffer(view.buffer)
            .all_marks()
            .filter(|m| m.range.start <= visible.end && m.range.end >= visible.start)
            .collect();
        let head = view.selection.primary().head;
        let mut rows = Vec::with_capacity(text_rows);
        let mut cursor = None;

        'lines: for line in scroll.line..text.len_lines() {
            let skip = if line == scroll.line { scroll.row } else { 0 };
            let layout = self.layout(editor, view, line, text_width);
            let last = layout.len() - 1;
            // The line's bytes; an empty last line still counts as one.
            let start = text.line_to_byte(line);
            let lines = start..text.line_to_byte(line + 1).max(start + 1);
            let on_line = |m: &&&Mark| m.range.start < lines.end && m.range.end >= lines.start;
            let line_gutter = Gutter {
                width: gutter,
                signs,
                sign: styled
                    .iter()
                    .filter(on_line)
                    .find(|m| m.sign.is_some())
                    .copied(),
                severity: worst(&marks, |r| r.start < lines.end && r.end >= lines.start),
            };
            for (i, cells) in layout.into_iter().enumerate().skip(skip) {
                if rows.len() == text_rows {
                    break 'lines;
                }
                let mut row = Row {
                    tags: styled
                        .iter()
                        .filter(|m| m.line && on_line(m))
                        .map(|m| Tag::from(m.style.clone()))
                        .collect(),
                    ..Row::default()
                };
                if line_numbers {
                    line_gutter.push(&mut row, (i == 0).then_some(line + 1));
                }
                let mut x = gutter;
                for cell in &cells {
                    if let Some(style) = &cell.inserted {
                        row.push(&cell.text, smallvec![Tag::from(style.clone())]);
                        x += cell.width;
                        continue;
                    }
                    if cell.byte == head {
                        let col = x.min(usize::from(area.width).saturating_sub(1));
                        cursor = Some(Position {
                            col: area.x + u16::try_from(col).unwrap_or(u16::MAX),
                            row: area.y + u16::try_from(rows.len()).unwrap_or(u16::MAX),
                        });
                    }
                    let capture = cell
                        .byte
                        .checked_sub(visible.start)
                        .and_then(|i| syntax.get(i)?.clone());
                    let mut cell_tags = cell_tags(view, cell, capture, &styled);
                    if let Some(severity) = worst(&marks, |r| {
                        r.contains(&cell.byte) || (r.is_empty() && r.start == cell.byte)
                    }) {
                        cell_tags.push(Tag::diagnostic(severity));
                    }
                    if !(cell.end_of_line && cell_tags.is_empty()) {
                        row.push(&cell.text, cell_tags);
                    }
                    x += cell.width;
                }
                if i == last {
                    let eol = styled.iter().filter(on_line).filter(|m| m.eol);
                    self.push_eol_text(&mut row, usize::from(area.width).saturating_sub(x), eol);
                }
                rows.push(row);
            }
        }
        rows.resize_with(text_rows, Row::default);
        (rows, cursor)
    }

    /// Adds each mark's text after the end of a line, a space before each,
    /// cut off at `room` cells rather than wrapped.
    fn push_eol_text<'a>(
        &self,
        row: &mut Row,
        mut room: usize,
        marks: impl Iterator<Item = &'a &'a Mark>,
    ) {
        for mark in marks {
            let Some(text) = &mark.text else { continue };
            let mut shown = String::new();
            for g in std::iter::once(" ").chain(text.graphemes(true)) {
                let w = self.measure.width(g);
                if w > room {
                    room = 0;
                    break;
                }
                room -= w;
                shown.push_str(g);
            }
            if !shown.is_empty() {
                row.push(&shown, smallvec![Tag::from(mark.style.clone())]);
            }
        }
    }

    /// Splits `line` into screen rows of at most `width` cells, breaking
    /// after whitespace where it can.
    fn layout(&self, editor: &Editor, view: &View, line: usize, width: usize) -> Vec<Vec<Cell>> {
        let buffer = editor.buffer(view.buffer);
        let text = buffer.text();
        let start = text.line_to_byte(line);
        let content: Cow<str> = text.line(line).into();
        let content = content.trim_end_matches(['\n', '\r']);
        let end = start + content.len();

        // Text from marks, shown before the character at its position.
        let mut inserted: Vec<(&Mark, &str)> = buffer
            .all_marks()
            .filter(|m| !m.eol && (start..=end).contains(&m.range.start))
            .filter_map(|m| Some((m, m.text.as_deref()?)))
            .collect();
        inserted.sort_by_key(|(m, _)| m.range.start);
        let mut inserted = inserted.into_iter().peekable();

        let mut cells = Vec::new();
        let mut x = 0;
        for (offset, grapheme) in content
            .grapheme_indices(true)
            .chain(std::iter::once((content.len(), "")))
        {
            let byte = start + offset;
            while let Some((mark, extra)) = inserted.next_if(|(m, _)| m.range.start <= byte) {
                for g in extra.graphemes(true) {
                    let w = self.measure.width(g);
                    cells.push(Cell {
                        byte,
                        text: g.to_owned(),
                        width: w,
                        end_of_line: false,
                        inserted: Some(mark.style.clone()),
                    });
                    x += w;
                }
            }
            if grapheme.is_empty() {
                break;
            }
            let (text, w) = if grapheme == "\t" {
                let w = self.tab_width - x % self.tab_width;
                (" ".repeat(w), w)
            } else {
                (grapheme.to_owned(), self.measure.width(grapheme))
            };
            cells.push(Cell {
                byte,
                text,
                width: w,
                end_of_line: false,
                inserted: None,
            });
            x += w;
        }

        let mut rows = vec![Vec::new()];
        let mut x = 0;
        // Where the current row may break: just after its last whitespace.
        let mut last_break = 0;
        for cell in cells {
            let row = rows.last_mut().expect("at least one row");
            if x + cell.width > width && !row.is_empty() {
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
            let breaks = cell.inserted.is_none() && cell.text.chars().all(char::is_whitespace);
            x += cell.width;
            row.push(cell);
            if breaks {
                last_break = row.len();
            }
        }
        if x < width {
            rows.last_mut().expect("at least one row").push(Cell {
                byte: end,
                text: " ".to_owned(),
                width: 1,
                end_of_line: true,
                inserted: None,
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

    /// The built-in status line: mode, file or message, and position.
    fn default_status(editor: &Editor, view: &View, message: Option<&str>) -> StatusLine {
        let buffer = editor.buffer(view.buffer);
        let text = buffer.text();
        let head = view.selection.primary().head;
        let line = text.byte_to_line(head);
        let column = text.byte_to_char(head) - text.line_to_char(line) + 1;
        let middle = match message {
            Some(message) => span(message, Tag::MESSAGE),
            None => span(
                &buffer
                    .path()
                    .map_or_else(|| "[scratch]".to_owned(), |p| p.display().to_string()),
                Tag::STATUS,
            ),
        };
        StatusLine {
            left: vec![
                span(&format!(" {} ", editor.mode().to_uppercase()), Tag::MODE),
                span(" ", Tag::STATUS),
                middle,
            ],
            right: vec![span(&format!("{}:{column} ", line + 1), Tag::STATUS)],
        }
    }

    /// Lays out a status line across `width` cells. If it doesn't fit, the
    /// last segment on the left keeps only its end.
    fn status_row(&self, status: &StatusLine, width: usize) -> Row {
        let widths = |spans: &[Span]| {
            spans
                .iter()
                .map(|s| self.text_width(&s.text))
                .sum::<usize>()
        };
        let mut left = status.left.clone();
        let right = widths(&status.right);
        if let Some((last, rest)) = left.split_last_mut() {
            // Leave at least one space between the two sides.
            let room = width.saturating_sub(widths(rest) + right + 1);
            last.text = self.keep_end(&last.text, room);
        }
        let padding = width.saturating_sub(widths(&left) + right);

        let mut row = Row::default();
        for s in &left {
            row.push(&s.text, s.tags.clone());
        }
        row.push(&" ".repeat(padding), smallvec![Tag::STATUS]);
        for s in &status.right {
            row.push(&s.text, s.tags.clone());
        }
        row
    }
}

fn span(text: &str, tag: Tag) -> Span {
    Span {
        text: text.to_owned(),
        tags: smallvec![tag],
    }
}

/// The sign column, when any mark in the buffer has a sign.
const SIGN_WIDTH: usize = 2;

/// What goes in the gutter beside one buffer line.
struct Gutter<'a> {
    /// The whole gutter, sign column included.
    width: usize,
    signs: bool,
    sign: Option<&'a Mark>,
    /// The worst diagnostic on the line.
    severity: Option<u8>,
}

impl Gutter<'_> {
    /// Adds the gutter to one of the line's rows: the sign and number on its
    /// first row (`number` is set), blanks on the rows it wraps onto.
    fn push(&self, row: &mut Row, number: Option<usize>) {
        if self.signs {
            match self.sign.filter(|_| number.is_some()) {
                Some(mark) => {
                    let symbol = mark.sign.as_deref().unwrap_or_default();
                    let text = format!("{symbol:<SIGN_WIDTH$}");
                    row.push(&text, smallvec![Tag::GUTTER, Tag::from(mark.style.clone())]);
                }
                None => row.push(&" ".repeat(SIGN_WIDTH), smallvec![Tag::GUTTER]),
            }
        }
        let width = self.width - if self.signs { SIGN_WIDTH } else { 0 };
        let text = match number {
            Some(n) => format!("{n:>w$} ", w = width - 1),
            None => " ".repeat(width),
        };
        let mut tags: SmallVec<[Tag; 2]> = smallvec![Tag::GUTTER];
        if let Some(severity) = self.severity {
            tags.push(Tag::gutter_diagnostic(severity));
        }
        row.push(&text, tags);
    }
}

/// The gutter's width: line numbers plus one space, after a sign column if
/// any mark in the buffer has a sign. Also whether there is a sign column.
fn gutter_width(editor: &Editor, view: &View) -> (usize, bool) {
    let buffer = editor.buffer(view.buffer);
    let numbers = buffer.text().len_lines().to_string().len() + 1;
    let signs = buffer.all_marks().any(|m| m.sign.is_some());
    (numbers + if signs { SIGN_WIDTH } else { 0 }, signs)
}

/// The tags for one cell, bottom first: its syntax capture, the marks on it,
/// then selections and cursors, then marks drawn above them.
fn cell_tags(
    view: &View,
    cell: &Cell,
    capture: Option<Arc<str>>,
    marks: &[&Mark],
) -> SmallVec<[Tag; 2]> {
    let on_cell = |above: bool| {
        marks
            .iter()
            .filter(move |m| {
                !cell.end_of_line && !m.line && m.above == above && m.range.contains(&cell.byte)
            })
            .map(|m| Tag::from(m.style.clone()))
    };
    let mut tags: SmallVec<[Tag; 2]> = capture.map(Tag::from).into_iter().collect();
    tags.extend(on_cell(false));
    tags.extend(selection_tags(view, cell));
    tags.extend(on_cell(true));
    tags
}

/// Selection and cursor tags for one cell.
fn selection_tags(view: &View, cell: &Cell) -> SmallVec<[Tag; 2]> {
    let mut out = SmallVec::new();
    let primary = view.selection.primary_index();
    for (i, range) in view.selection.ranges().iter().enumerate() {
        if !cell.end_of_line && range.from() <= cell.byte && cell.byte < range.to() {
            out.push(Tag::SELECTION);
        }
        if range.is_empty() && range.head == cell.byte && i != primary {
            out.push(Tag::CURSOR);
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

/// The main view keeps at least this many columns; panels shrink to leave it.
const MIN_MAIN_WIDTH: u16 = 10;

/// Where panels go: each one takes its width from its side of `screen`,
/// plus a column for the line between it and the main view, and a row for
/// its title if it has one. Returns the main view's area and, for each
/// panel shown, its view and its frame, still without rows.
fn layout_panels(panels: &[Panel], screen: Rect) -> (Rect, Vec<(ViewId, PanelFrame)>) {
    let mut left = screen.x;
    let mut right = screen.x + screen.width;
    let mut placed = Vec::new();
    for panel in panels {
        let room = (right - left).saturating_sub(MIN_MAIN_WIDTH + 1);
        let width = panel.options.width.resolve(screen.width).min(room);
        if width == 0 {
            continue;
        }
        let (x, separator) = match panel.options.side {
            Side::Left => {
                let x = left;
                left += width + 1;
                (x, x + width)
            }
            Side::Right => {
                right -= width + 1;
                (right + 1, right)
            }
        };
        let title_rows = u16::from(panel.options.title.is_some());
        let rect = Rect {
            x,
            y: screen.y + title_rows,
            width,
            height: screen.height.saturating_sub(title_rows),
        };
        let frame = PanelFrame {
            rect,
            separator,
            title: panel.options.title.as_deref().map(str::to_owned),
            rows: Vec::new(),
        };
        placed.push((panel.view, frame));
    }
    let main = Rect {
        x: left,
        y: screen.y,
        width: right - left,
        height: screen.height,
    };
    (main, placed)
}

/// Where a floating view's rows go within `area`, leaving a cell around them
/// for the border.
fn place(options: &FloatOptions, area: Rect) -> Rect {
    let outer_width = options.width.resolve(area.width).max(3);
    let outer_height = options.height.resolve(area.height).max(3);
    // Whatever the position, the box stays on screen.
    let x = match options.x {
        Some(x) => x.resolve(area.width),
        None => area.width.saturating_sub(outer_width) / 2,
    }
    .min(area.width.saturating_sub(outer_width));
    let y = match (options.y, options.anchor) {
        (Some(y), _) => y.resolve(area.height),
        (None, Anchor::Top) => 0,
        (None, Anchor::Center) => area.height.saturating_sub(outer_height) / 2,
        (None, Anchor::Bottom) => area.height.saturating_sub(outer_height),
    }
    .min(area.height.saturating_sub(outer_height));
    Rect {
        x: area.x + x + 1,
        y: area.y + y + 1,
        width: outer_width - 2,
        height: outer_height - 2,
    }
}

/// The most severe mark (lowest number) whose range matches.
fn worst(marks: &[(Range<usize>, u8)], matches: impl Fn(&Range<usize>) -> bool) -> Option<u8> {
    marks
        .iter()
        .filter(|(r, _)| matches(r))
        .map(|(_, s)| *s)
        .min()
}
