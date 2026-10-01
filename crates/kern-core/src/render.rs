//! The render model: what a view looks like, described by meaning rather than
//! color.
//!
//! A [`Frame`] is rows of text spans tagged with what they are (a selection,
//! a cursor, the gutter, ...). Clients turn tags into styles with the
//! frame's theme, so a terminal and a GUI can share it. Layout happens here,
//! against a [`Measure`] the client supplies, so motions and scrolling agree
//! with what's on screen.

use std::borrow::Cow;
use std::cell::RefCell;
use std::ops::Range;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use smallvec::{SmallVec, smallvec};
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

use kern_text::Rope;

use crate::image::ImageId;
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Size {
    pub width: u16,
    pub height: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
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
    /// The line between two panes.
    pub const PANE_BORDER: Tag = Tag::fixed("ui.pane.border");
    /// Under every row of a pane other than the active one.
    pub const PANE_INACTIVE: Tag = Tag::fixed("ui.pane.inactive");
    pub const TABLINE: Tag = Tag::fixed("ui.tabline");
    pub const TABLINE_ACTIVE: Tag = Tag::fixed("ui.tabline.active");

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

// Tags travel to clients as their names.
impl Serialize for Tag {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.name())
    }
}

impl<'de> Deserialize<'de> for Tag {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(Tag::from(Arc::<str>::deserialize(deserializer)?))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Span {
    pub text: String,
    pub tags: SmallVec<[Tag; 2]>,
}

/// One screen row.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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
    /// Images to draw over the rows, after them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub images: Vec<ImagePlacement>,
    /// Where the primary cursor is, if it's on screen.
    pub cursor: Option<Position>,
    pub cursor_shape: CursorShape,
    /// What the tags look like.
    pub theme: Arc<Theme>,
}

/// A panel: its rows fill `rect`. The client draws a line down column
/// `separator`, between the panel and the main view, and the title (if any)
/// on the row above `rect`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PanelFrame {
    pub rect: Rect,
    pub separator: u16,
    pub title: Option<String>,
    pub rows: Vec<Row>,
}

/// Part of an image on screen: the image is `cols` by `rows` cells, and
/// the part from its cell (`col`, `row`), `rect` wide and high, goes in
/// `rect`. A client crops the image to that part and scales it to fit.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImagePlacement {
    pub id: ImageId,
    pub rect: Rect,
    pub col: u16,
    pub row: u16,
    pub cols: u16,
    pub rows: u16,
}

/// A floating view: its rows fill `rect`, and the client draws a border
/// around it, one cell wide.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FloatFrame {
    pub rect: Rect,
    pub title: Option<String>,
    pub rows: Vec<Row>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
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
    /// Images placed while laying out the frame being drawn.
    images: RefCell<Vec<ImagePlacement>>,
}

impl<M: Measure> Renderer<M> {
    pub fn new(measure: M) -> Self {
        Self {
            measure,
            tab_width: 4,
            images: RefCell::default(),
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
        self.images.borrow_mut().clear();
        let main = editor.main();
        let screen = Rect {
            x: 0,
            y: 0,
            width: size.width,
            height: size.height.saturating_sub(1),
        };
        let (area, placed) = layout_panels(editor.panels(), screen);
        let (mut rows, main_cursor) = self.pane_rows(editor, area, decorations);
        let status = match status {
            Status::Default { message } => {
                Self::default_status(editor, editor.view(main), *message)
            }
            Status::Line(line) => line.clone(),
        };
        rows.push(self.status_row(&status, usize::from(size.width)));

        let mut cursor = main_cursor;
        let mut panels = Vec::new();
        for (view, mut panel) in placed {
            let (rows, panel_cursor) = self.view_rows(editor, view, panel.rect, false, decorations);
            if editor.focus() == view {
                cursor = panel_cursor;
            }
            panel.rows = rows;
            panels.push(panel);
        }
        // Images under a floating view are left out rather than drawn over
        // it.
        let mut images = self.images.take();
        let mut floats = Vec::new();
        for float in editor.floats().to_vec() {
            let rect = place(&float.options, screen, cursor);
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
        images.retain(|image| {
            !floats
                .iter()
                .any(|f| overlaps(image.rect, bordered(f.rect)))
        });
        images.extend(self.images.take());

        Frame {
            size,
            main: area,
            rows,
            panels,
            floats,
            images,
            cursor,
            cursor_shape: editor.cursor_shape(),
            theme: editor.theme().clone(),
        }
    }

    /// Places the images `marks` show in `view`, cut to `text_area`, the
    /// part of the screen its text takes. An image goes over whole cells
    /// from its mark's start, whatever text is under it.
    fn place_images(
        &self,
        editor: &Editor,
        view: &View,
        marks: &[&Mark],
        text_area: Rect,
        hidden: &[Range<usize>],
    ) {
        let text = editor.buffer(view.buffer).text();
        let width = usize::from(text_area.width);
        let rows_of = |lines: Range<usize>| -> i64 {
            lines
                .map(|l| self.line_rows(editor, view, l, width, hidden))
                .sum::<usize>()
                .try_into()
                .unwrap_or(i64::MAX)
        };
        let scroll_row = i64::try_from(view.scroll.row).unwrap_or(0);
        for (mark, image) in marks.iter().filter_map(|m| Some((m, m.image?))) {
            if !editor.images().contains(image.id) {
                continue;
            }
            let start = mark.range.start.min(text.len_bytes());
            let line = text.byte_to_line(start);
            // The screen row of the mark's line, counting from the top of the
            // view, so negative above it.
            let row = if line >= view.scroll.line {
                rows_of(view.scroll.line..line)
            } else {
                -rows_of(line..view.scroll.line)
            } - scroll_row;
            let x = self
                .layout(editor, view, line, width)
                .first()
                .map_or(0, |cells| {
                    cells
                        .iter()
                        .take_while(|c| c.byte < start)
                        .map(|c| c.width)
                        .sum::<usize>()
                });
            let left = i64::try_from(x).unwrap_or(0) - i64::from(image.col);
            let top = row - i64::from(image.row);
            let (x0, y0) = (left.max(0), top.max(0));
            let x1 = (left + i64::from(image.cols)).min(i64::from(text_area.width));
            let y1 = (top + i64::from(image.rows)).min(i64::from(text_area.height));
            if x1 <= x0 || y1 <= y0 {
                continue;
            }
            let cell = |n: i64| u16::try_from(n).unwrap_or(u16::MAX);
            self.images.borrow_mut().push(ImagePlacement {
                id: image.id,
                rect: Rect {
                    x: text_area.x + cell(x0),
                    y: text_area.y + cell(y0),
                    width: cell(x1 - x0),
                    height: cell(y1 - y0),
                },
                col: cell(x0 - left),
                row: cell(y0 - top),
                cols: image.cols,
                rows: image.rows,
            });
        }
    }

    /// Lays out the shown tab's panes in `area`, with lines between them
    /// and the tabs above when there's more than one. Returns the rows and
    /// where the focused pane's cursor is, if a pane has focus.
    fn pane_rows(
        &self,
        editor: &mut Editor,
        area: Rect,
        decorations: &dyn Decorations,
    ) -> (Vec<Row>, Option<Position>) {
        let tabline = (editor.tabs().len() > 1).then(|| Self::tabline(editor));
        let panes_area = match tabline {
            Some(_) => Rect {
                y: area.y + 1,
                height: area.height.saturating_sub(1),
                ..area
            },
            None => area,
        };
        editor.set_tab_area(panes_area);
        let (panes, lines) = editor.current_tab().place(panes_area);
        let active = editor.current_tab().active();
        let mut cursor = None;
        let mut drawn = Vec::with_capacity(panes.len());
        for (view, rect) in panes {
            let numbers = editor.buffer(editor.view(view).buffer).line_numbers();
            let (rows, pane_cursor) = self.view_rows(editor, view, rect, numbers, decorations);
            if editor.focus() == view {
                cursor = pane_cursor;
            }
            drawn.push((view, rect, rows));
        }
        if tabline.is_none() && drawn.len() == 1 {
            let (_, _, rows) = drawn.pop().expect("one pane");
            return (rows, cursor);
        }
        // Each screen row, as the pieces on it from left to right.
        let mut pieces: Vec<Vec<(u16, u16, Row)>> = vec![Vec::new(); usize::from(area.height)];
        let index = |y: u16| usize::from(y - area.y);
        if let Some(tabline) = tabline {
            pieces[0].push((area.x, area.width, tabline));
        }
        for (view, rect, rows) in drawn {
            for (i, mut row) in rows.into_iter().enumerate() {
                if view != active {
                    row.tags.insert(0, Tag::PANE_INACTIVE);
                }
                pieces[index(rect.y) + i].push((rect.x, rect.width, row));
            }
        }
        let border = |text: String| Row {
            spans: vec![Span {
                text,
                tags: smallvec![Tag::PANE_BORDER],
            }],
            tags: SmallVec::new(),
        };
        for line in lines {
            if line.down {
                for y in line.y..line.y + line.len {
                    pieces[index(y)].push((line.x, 1, border("│".to_owned())));
                }
            } else {
                let text = "─".repeat(usize::from(line.len));
                pieces[index(line.y)].push((line.x, line.len, border(text)));
            }
        }
        let rows = pieces
            .into_iter()
            .map(|mut row_pieces| {
                row_pieces.sort_by_key(|(x, _, _)| *x);
                let mut row = Row::default();
                let mut at = area.x;
                for (x, width, piece) in row_pieces {
                    if x > at {
                        row.push(&" ".repeat(usize::from(x - at)), SmallVec::new());
                    }
                    self.append(&mut row, piece, usize::from(width));
                    at = x + width;
                }
                row
            })
            .collect();
        (rows, cursor)
    }

    /// Adds `piece` to the end of `row`, padded to `width` cells, with its
    /// row-wide tags on each of its spans so they stay within its width.
    fn append(&self, row: &mut Row, piece: Row, width: usize) {
        let mut used = 0;
        for span in piece.spans {
            used += self.text_width(&span.text);
            let tags = piece.tags.iter().chain(&span.tags).cloned().collect();
            row.push(&span.text, tags);
        }
        if used < width {
            row.push(&" ".repeat(width - used), piece.tags.into_iter().collect());
        }
    }

    /// The row of tabs above the panes: each tab's number and name, the
    /// shown one marked.
    fn tabline(editor: &Editor) -> Row {
        let mut row = Row {
            tags: smallvec![Tag::TABLINE],
            ..Row::default()
        };
        let shown = editor.current_tab().id();
        for (i, tab) in editor.tabs().iter().enumerate() {
            let name = tab
                .name()
                .map_or_else(|| tab_title(editor, tab.active()), str::to_owned);
            let mut tags = smallvec![Tag::TABLINE];
            if tab.id() == shown {
                tags.push(Tag::TABLINE_ACTIVE);
            }
            row.push(&format!(" {} {name} ", i + 1), tags);
        }
        row
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
        let hidden = hidden_lines(editor, view);
        let visible = visible_bytes(text, scroll, text_rows, &hidden);
        let syntax = paint(
            decorations.highlights(view.buffer, text, visible.clone()),
            &visible,
        );
        let (marks, styled) = marks_in(editor, view.buffer, decorations, &visible);
        let head = view.selection.primary().head;
        let mut rows = Vec::with_capacity(text_rows);
        let mut cursor = None;
        let (mut first_shown, mut last_shown) = (None, None);

        'lines: for line in scroll.line..text.len_lines() {
            if is_hidden(&hidden, line) {
                continue;
            }
            let skip = if line == scroll.line { scroll.row } else { 0 };
            let layout = self.layout(editor, view, line, text_width);
            let last = layout.len() - 1;
            // The line's bytes; an empty last line still counts as one.
            let start = text.line_to_byte(line);
            let lines = start..text.line_to_byte(line + 1).max(start + 1);
            let on_line = |m: &&&Mark| m.range.start < lines.end && m.range.end >= lines.start;
            let line_gutter = Gutter::for_line(gutter, signs, &styled, &marks, &lines);
            let mut overlay = Overlay::default();
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
                    first_shown = first_shown.or(Some(cell.byte));
                    if !cell.end_of_line {
                        last_shown = Some(cell.byte);
                    }
                    if cell.byte == head {
                        cursor = Some(screen_position(area, x, rows.len()));
                    }
                    if let Some((text, tag)) = overlay.over(&styled, cell) {
                        row.push(&text, smallvec![tag]);
                        x += cell.width;
                        continue;
                    }
                    let capture = cell
                        .byte
                        .checked_sub(visible.start)
                        .and_then(|i| syntax.get(i)?.clone());
                    let cell_tags = cell_tags(view, cell, capture, &styled, &marks);
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
            let room = usize::from(area.width).saturating_sub(gutter);
            let lines = virtual_lines(editor, view, line);
            let gutter = line_numbers.then_some(&line_gutter);
            if !self.push_virtual_lines(&mut rows, text_rows, lines, gutter, room) {
                break 'lines;
            }
        }
        let text_area = text_area(area, gutter, text_width);
        self.place_images(editor, view, &styled, text_area, &hidden);
        let shown = shown_bytes(text, first_shown, last_shown);
        editor.view_mut(view_id).drawn(shown, area, text_width);
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

        let (revealed, concealed) = concealed(buffer, view, line, start..end);
        // Text from marks, shown before the character at its position.
        let mut inserted: Vec<(&Mark, &str)> = buffer
            .all_marks()
            .filter(|m| !m.eol && !m.overlay && (start..=end).contains(&m.range.start))
            .filter(|m| !m.conceal || !revealed)
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
            if concealed.iter().any(|m| m.range.contains(&byte)) {
                continue;
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
        let hidden = hidden_lines(editor, view);
        let mut seen = 0;
        for l in current.line..=cursor.line {
            let rows = if l == cursor.line {
                cursor.row + 1
            } else {
                self.line_rows(editor, view, l, width, &hidden)
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

        // Scroll so the cursor's row is the last one on screen: take whole
        // lines above it while they fit, then as many rows of the next one
        // as are left, after its virtual lines.
        if cursor.row >= height - 1 {
            return Scroll {
                line: cursor.line,
                row: cursor.row - (height - 1),
            };
        }
        let mut top = Scroll {
            line: cursor.line,
            row: 0,
        };
        let mut above = height - 1 - cursor.row;
        let mut l = cursor.line;
        while above > 0 && l > 0 {
            l -= 1;
            if is_hidden(&hidden, l) {
                continue;
            }
            let layout = self.layout(editor, view, l, width).len();
            let total = layout + virtual_lines(editor, view, l).count();
            if total <= above {
                above -= total;
                top = Scroll { line: l, row: 0 };
                continue;
            }
            let room = above.saturating_sub(total - layout);
            if room > 0 {
                top = Scroll {
                    line: l,
                    row: layout - room,
                };
            }
            break;
        }
        top
    }

    /// How many screen rows `line` takes: none when a fold hides it, or its
    /// wrapped rows and the virtual lines under it.
    fn line_rows(
        &self,
        editor: &Editor,
        view: &View,
        line: usize,
        width: usize,
        hidden: &[Range<usize>],
    ) -> usize {
        if is_hidden(hidden, line) {
            return 0;
        }
        self.layout(editor, view, line, width).len() + virtual_lines(editor, view, line).count()
    }

    fn text_width(&self, text: &str) -> usize {
        text.graphemes(true).map(|g| self.measure.width(g)).sum()
    }

    /// Adds virtual lines to `rows`, each cut to `room` cells after a blank
    /// gutter. Returns false if `rows` filled up to `limit` first.
    fn push_virtual_lines<'a>(
        &self,
        rows: &mut Vec<Row>,
        limit: usize,
        lines: impl Iterator<Item = (&'a Mark, &'a str)>,
        gutter: Option<&Gutter>,
        room: usize,
    ) -> bool {
        for (mark, text) in lines {
            if rows.len() == limit {
                return false;
            }
            let mut row = Row::default();
            if let Some(gutter) = gutter {
                gutter.push(&mut row, None);
            }
            row.push(
                &self.keep_start(text, room),
                smallvec![Tag::from(mark.style.clone())],
            );
            rows.push(row);
        }
        true
    }

    /// As much of `text` as fits in `room` cells.
    fn keep_start(&self, text: &str, room: usize) -> String {
        let mut kept = String::new();
        let mut used = 0;
        for g in text.graphemes(true) {
            let w = self.measure.width(g);
            if used + w > room {
                break;
            }
            used += w;
            kept.push_str(g);
        }
        kept
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

/// Overlay text still to draw, one grapheme per cell it covers.
#[derive(Default)]
struct Overlay {
    /// What's left, last grapheme first.
    left: Vec<String>,
    style: Option<Arc<str>>,
}

impl Overlay {
    /// What to draw instead of `cell`, if an overlay covers it: one starting
    /// there among `marks`, or one carried on from earlier cells.
    fn over(&mut self, marks: &[&Mark], cell: &Cell) -> Option<(String, Tag)> {
        if let Some(mark) = marks
            .iter()
            .find(|m| m.overlay && m.range.start == cell.byte)
        {
            let text = mark.text.as_deref().unwrap_or_default();
            self.left = text.graphemes(true).rev().map(str::to_owned).collect();
            self.style = Some(mark.style.clone());
        }
        let grapheme = self.left.pop()?;
        Some((grapheme, Tag::from(self.style.clone()?)))
    }
}

/// Where column `x` of row `row` in `area` is on screen, kept inside the
/// area so a cursor past the end of a full row still shows.
fn screen_position(area: Rect, x: usize, row: usize) -> Position {
    let col = x.min(usize::from(area.width).saturating_sub(1));
    Position {
        col: area.x + u16::try_from(col).unwrap_or(u16::MAX),
        row: area.y + u16::try_from(row).unwrap_or(u16::MAX),
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

impl<'a> Gutter<'a> {
    /// The gutter for the line spanning `lines`: the first mark with a sign
    /// on it, and its worst diagnostic.
    fn for_line(
        width: usize,
        signs: bool,
        styled: &[&'a Mark],
        diagnostics: &[(Range<usize>, u8)],
        lines: &Range<usize>,
    ) -> Self {
        let touches = |r: &Range<usize>| r.start < lines.end && r.end >= lines.start;
        Gutter {
            width,
            signs,
            sign: styled
                .iter()
                .find(|m| m.sign.is_some() && touches(&m.range))
                .copied(),
            severity: worst(diagnostics, touches),
        }
    }

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
    diagnostics: &[(Range<usize>, u8)],
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
    let at_cell =
        |r: &Range<usize>| r.contains(&cell.byte) || (r.is_empty() && r.start == cell.byte);
    if let Some(severity) = worst(diagnostics, at_cell) {
        tags.push(Tag::diagnostic(severity));
    }
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
/// row, and more for the lines folds hide, which take no rows.
fn visible_bytes(
    text: &Rope,
    scroll: Scroll,
    rows: usize,
    hidden: &[Range<usize>],
) -> Range<usize> {
    let folded: usize = hidden
        .iter()
        .filter(|h| h.end > scroll.line)
        .map(ExactSizeIterator::len)
        .sum();
    let end_line = (scroll.line + rows + folded + 1).min(text.len_lines());
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

/// What a tab is called when it has no name: the file name of what its
/// active pane shows, "untitled" for a file not saved yet, or the kind of
/// buffer, like "terminal".
fn tab_title(editor: &Editor, pane: ViewId) -> String {
    let buffer = editor.buffer(editor.view(pane).buffer);
    match buffer.path().and_then(|p| p.file_name()) {
        Some(name) => name.to_string_lossy().into_owned(),
        None if buffer.kind() == "file" => "untitled".to_owned(),
        None => buffer.kind().to_owned(),
    }
}

/// The part of a view's `area` its text takes, right of a `gutter` cells
/// wide.
fn text_area(area: Rect, gutter: usize, width: usize) -> Rect {
    Rect {
        x: area.x + u16::try_from(gutter).unwrap_or(0),
        width: u16::try_from(width).unwrap_or(u16::MAX),
        ..area
    }
}

fn overlaps(a: Rect, b: Rect) -> bool {
    a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
}

/// `rect` with the one-cell border a client draws around a floating view.
fn bordered(rect: Rect) -> Rect {
    Rect {
        x: rect.x.saturating_sub(1),
        y: rect.y.saturating_sub(1),
        width: rect.width + 2,
        height: rect.height + 2,
    }
}

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
/// for the border. `cursor` is where the focused view's cursor is, for
/// floats anchored to it.
fn place(options: &FloatOptions, area: Rect, cursor: Option<Position>) -> Rect {
    let outer_width = options.width.resolve(area.width).max(3);
    let outer_height = options.height.resolve(area.height).max(3);
    if options.anchor == Anchor::Cursor
        && let Some(cursor) = cursor
    {
        // The text inside starts under the cursor, on the row below it, or
        // ends on the row above it when it doesn't fit below.
        let below = cursor.row + 1;
        let y = if below + outer_height <= area.y + area.height {
            below
        } else {
            cursor.row.saturating_sub(outer_height)
        };
        let x = cursor
            .col
            .saturating_sub(1)
            .min((area.x + area.width).saturating_sub(outer_width));
        return Rect {
            x: x + 1,
            y: y + 1,
            width: outer_width - 2,
            height: outer_height - 2,
        };
    }
    // Whatever the position, the box stays on screen.
    let x = match options.x {
        Some(x) => x.resolve(area.width),
        None => area.width.saturating_sub(outer_width) / 2,
    }
    .min(area.width.saturating_sub(outer_width));
    let y = match (options.y, options.anchor) {
        (Some(y), _) => y.resolve(area.height),
        (None, Anchor::Top) => 0,
        // With no cursor on screen, a cursor float centers.
        (None, Anchor::Center | Anchor::Cursor) => area.height.saturating_sub(outer_height) / 2,
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

/// The diagnostics and marks of `buffer` that touch `visible`.
fn marks_in<'a>(
    editor: &'a Editor,
    buffer: BufferId,
    decorations: &dyn Decorations,
    visible: &Range<usize>,
) -> (Vec<(Range<usize>, u8)>, Vec<&'a Mark>) {
    let touches = |range: &Range<usize>| range.start <= visible.end && range.end >= visible.start;
    let diagnostics = decorations
        .diagnostics(buffer)
        .iter()
        .filter(|(range, _)| touches(range))
        .cloned()
        .collect();
    let marks = editor
        .buffer(buffer)
        .all_marks()
        .filter(|m| touches(&m.range))
        .collect();
    (diagnostics, marks)
}

/// The bytes from the `first` drawn to just past the `last` character drawn
/// (empty when nothing was).
fn shown_bytes(text: &Rope, first: Option<usize>, last: Option<usize>) -> Range<usize> {
    let first = first.unwrap_or(0);
    last.map_or(first..first, |last| {
        first..text.char_to_byte(text.byte_to_char(last) + 1)
    })
}

/// The lines folds hide in `view`: each fold's lines after its first, unless
/// a cursor is in them.
pub(crate) fn hidden_lines(editor: &Editor, view: &View) -> Vec<Range<usize>> {
    let buffer = editor.buffer(view.buffer);
    let text = buffer.text();
    let cursors: Vec<usize> = cursor_lines(text, view).collect();
    buffer
        .all_marks()
        .filter(|m| m.fold)
        .filter_map(|m| {
            let first = text.byte_to_line(m.range.start.min(text.len_bytes()));
            let hidden = first + 1..last_line(text, &m.range) + 1;
            (!hidden.is_empty() && !cursors.iter().any(|c| hidden.contains(c))).then_some(hidden)
        })
        .collect()
}

/// The virtual lines shown under `line`, with the mark each comes from.
fn virtual_lines<'a>(
    editor: &'a Editor,
    view: &View,
    line: usize,
) -> impl Iterator<Item = (&'a Mark, &'a str)> {
    let buffer = editor.buffer(view.buffer);
    let text = buffer.text();
    buffer
        .all_marks()
        .filter(move |m| !m.lines.is_empty() && last_line(text, &m.range) == line)
        .flat_map(|m| m.lines.iter().map(move |l| (m, &**l)))
}

/// Whether a cursor is on `line`, which shows concealed text, and otherwise
/// the marks concealing parts of it (`bytes`).
fn concealed<'a>(
    buffer: &'a crate::Buffer,
    view: &View,
    line: usize,
    bytes: Range<usize>,
) -> (bool, Vec<&'a Mark>) {
    if cursor_lines(buffer.text(), view).any(|l| l == line) {
        return (true, Vec::new());
    }
    let marks = buffer
        .all_marks()
        .filter(|m| m.conceal && m.range.start < bytes.end && m.range.end > bytes.start)
        .collect();
    (false, marks)
}

/// The lines `view`'s cursors are on.
fn cursor_lines<'a>(text: &'a Rope, view: &'a View) -> impl Iterator<Item = usize> + 'a {
    let len = text.len_bytes();
    view.selection
        .ranges()
        .iter()
        .map(move |r| text.byte_to_line(r.head.min(len)))
}

/// The line `range` ends on, not counting a line it ends at the start of.
fn last_line(text: &Rope, range: &Range<usize>) -> usize {
    let last = range.end.saturating_sub(1).max(range.start);
    text.byte_to_line(last.min(text.len_bytes()))
}

fn is_hidden(hidden: &[Range<usize>], line: usize) -> bool {
    hidden.iter().any(|h| h.contains(&line))
}
