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
use std::collections::BTreeMap;
use std::ops::Range;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use smallvec::{SmallVec, smallvec};
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

use greed_text::Rope;

mod hit;
pub use hit::Hit;
pub mod grid;

use crate::image::ImageId;
use crate::syntax::Highlight;
use crate::theme::Theme;
use crate::{
    Anchor, BufferId, CursorShape, Editor, Float, FloatOptions, LineNumbers, Mark, Panel, Reveal,
    Scroll, Side, View, ViewId, VirtualLine,
};

/// Syntax highlights drawn over a buffer's text, under its marks.
pub trait Decorations {
    /// Syntax highlights overlapping `range` of `buffer`.
    fn highlights(&self, _buffer: BufferId, _text: &Rope, _range: Range<usize>) -> Vec<Highlight> {
        Vec::new()
    }
}

/// No highlights.
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

/// How many columns apart tab stops are.
pub const TAB_WIDTH: usize = 4;

/// The width of `grapheme` at column `x`: a tab reaches the next tab stop.
fn width_at(measure: &impl Measure, grapheme: &str, x: usize, tab_width: usize) -> usize {
    if grapheme == "\t" {
        tab_width - x % tab_width
    } else {
        measure.width(grapheme)
    }
}

/// The screen column of byte `pos` in its line, counting wide characters
/// and tabs as they're drawn (but not folds, concealed or scaled text).
pub fn display_column(text: &Rope, pos: usize, tab_width: usize) -> usize {
    let start = text.line_to_byte(text.byte_to_line(pos));
    let before = text.byte_slice(start..pos).to_string();
    before
        .graphemes(true)
        .fold(0, |x, g| x + width_at(&CellWidth, g, x, tab_width))
}

/// The position in `line` drawn at screen column `col`: the start of the
/// character covering it, or the line's end if the line is shorter.
pub fn at_display_column(text: &Rope, line: usize, col: usize, tab_width: usize) -> usize {
    let start = text.line_to_byte(line);
    let content = text.line(line).to_string();
    let content = content.trim_end_matches(['\n', '\r']);
    let mut x = 0;
    for (offset, g) in content.grapheme_indices(true) {
        let w = width_at(&CellWidth, g, x, tab_width);
        if col < x + w {
            return start + offset;
        }
        x += w;
    }
    start + content.len()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Size {
    pub width: u16,
    pub height: u16,
}

impl Size {
    /// The largest screen drawn, in cells: past any real screen, and small
    /// enough that a frame's rows fit in memory and its sums in a `u16`.
    pub const MAX: Size = Size {
        width: 2048,
        height: 1024,
    };

    /// This size, cut to [`Size::MAX`].
    #[must_use]
    pub fn limited(self) -> Size {
        Size {
            width: self.width.min(Self::MAX.width),
            height: self.height.min(Self::MAX.height),
        }
    }
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
    /// How many times bigger the text is drawn: each character takes that
    /// many times its cells across, and the row takes `scale` rows down.
    #[serde(default = "one", skip_serializing_if = "is_one")]
    pub scale: u8,
}

impl Span {
    /// `text` at the normal size.
    pub fn new(text: impl Into<String>, tags: SmallVec<[Tag; 2]>) -> Self {
        Span {
            text: text.into(),
            tags,
            scale: 1,
        }
    }
}

const fn one() -> u8 {
    1
}

#[expect(
    clippy::trivially_copy_pass_by_ref,
    reason = "serde passes a reference"
)]
fn is_one(n: &u8) -> bool {
    *n == 1
}

const fn yes() -> bool {
    true
}

#[expect(
    clippy::trivially_copy_pass_by_ref,
    reason = "serde passes a reference"
)]
fn is_true(b: &bool) -> bool {
    *b
}

/// One screen row.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Row {
    pub spans: Vec<Span>,
    /// Styles for the whole row, under its spans and across its empty end.
    pub tags: SmallVec<[Tag; 1]>,
    /// How many rows below this one its scaled text also takes; those rows
    /// come empty.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub covers: u8,
}

#[expect(
    clippy::trivially_copy_pass_by_ref,
    reason = "serde passes a reference"
)]
fn is_zero(n: &u8) -> bool {
    *n == 0
}

impl Row {
    pub fn text(&self) -> String {
        self.spans.iter().map(|s| s.text.as_str()).collect()
    }

    fn push(&mut self, text: &str, tags: SmallVec<[Tag; 2]>) {
        self.push_scaled(text, tags, 1);
    }

    fn push_scaled(&mut self, text: &str, tags: SmallVec<[Tag; 2]>, scale: u8) {
        match self.spans.last_mut() {
            Some(last) if last.tags == tags && last.scale == scale => last.text.push_str(text),
            _ => self.spans.push(Span {
                text: text.to_owned(),
                tags,
                scale,
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
    /// The options for a window to read, those named `gui-...`, as text.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub gui: BTreeMap<String, String>,
    /// The menus plugins set, for a window to show as its menu bar.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub menus: Vec<Menu>,
}

/// A menu in a window's menu bar: its title and what's in it, in order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Menu {
    pub title: String,
    pub items: Vec<MenuItem>,
}

/// An item in a menu: what it says, and the command it runs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MenuItem {
    pub label: String,
    pub command: String,
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
/// around it, one cell wide, unless `border` is false.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FloatFrame {
    pub rect: Rect,
    pub title: Option<String>,
    pub rows: Vec<Row>,
    /// Drawn at the right end of the top border.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub label: Vec<Span>,
    /// Drawn in the middle of the bottom border.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub footer: Vec<Span>,
    #[serde(default = "yes", skip_serializing_if = "is_true")]
    pub border: bool,
}

/// `line` as spans: its styled parts tagged with their style.
fn border_spans(line: Option<&VirtualLine>) -> Vec<Span> {
    let Some(line) = line else {
        return Vec::new();
    };
    let mut spans = Vec::new();
    let mut at = 0;
    for (range, style) in &line.styles {
        if at < range.start {
            spans.push(Span::new(&line.text[at..range.start], SmallVec::new()));
        }
        spans.push(Span::new(
            &line.text[range.clone()],
            smallvec![Tag::from(style.clone())],
        ));
        at = range.end;
    }
    if at < line.text.len() {
        spans.push(Span::new(&line.text[at..], SmallVec::new()));
    }
    spans
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
    /// The command a click on each segment runs, by its place in `left`
    /// and then `right`; segments past the end have none.
    pub actions: Vec<Option<Arc<str>>>,
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
    /// For inserted text: the mark's action and where the mark starts.
    action: Option<(Arc<str>, usize)>,
    /// How many times bigger it's drawn; `width` already counts it.
    scale: u8,
}

/// Adds `row`, `height` screen rows tall as far as `limit` rows allow, and
/// the empty rows its scaled text covers, which keep the line's styles so
/// a whole-line background still fills them.
fn push_covering(rows: &mut Vec<Row>, mut row: Row, height: usize, limit: usize) {
    let height = height.min(limit - rows.len());
    let covered = Row {
        tags: row.tags.clone(),
        ..Row::default()
    };
    row.covers = u8::try_from(height - 1).unwrap_or(u8::MAX);
    rows.push(row);
    rows.extend(std::iter::repeat_n(covered, height - 1));
}

/// How many screen rows a row of cells takes: as many as its largest scale.
fn row_height(cells: &[Cell]) -> usize {
    cells
        .iter()
        .map(|c| usize::from(c.scale))
        .max()
        .unwrap_or(1)
}

/// Where a mark with an action drew its text, so a click there finds it.
#[derive(Debug, Clone)]
struct ActionArea {
    view: ViewId,
    row: u16,
    cols: Range<u16>,
    action: Arc<str>,
    /// The start of the mark's range.
    at: usize,
}

pub struct Renderer<M> {
    measure: M,
    pub tab_width: usize,
    /// Images placed while laying out the frame being drawn.
    images: RefCell<Vec<ImagePlacement>>,
    /// Where marks with actions are on screen, as last drawn.
    actions: RefCell<Vec<ActionArea>>,
    /// Where status line segments with actions are, as last drawn.
    status_actions: RefCell<Vec<StatusArea>>,
}

/// Where a status line segment with an action is on screen.
#[derive(Debug, Clone)]
struct StatusArea {
    row: u16,
    cols: Range<u16>,
    action: Arc<str>,
}

impl<M: Measure> Renderer<M> {
    pub fn new(measure: M) -> Self {
        Self {
            measure,
            tab_width: TAB_WIDTH,
            images: RefCell::default(),
            actions: RefCell::default(),
            status_actions: RefCell::default(),
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
        self.actions.borrow_mut().clear();
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
        rows.push(self.status_row(&status, usize::from(size.width), screen.height));

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
        let shown: Vec<Float> = editor.floats().into_iter().cloned().collect();
        for float in shown {
            let rect = place(&float.options, screen, cursor);
            let (rows, float_cursor) = self.view_rows(editor, float.view, rect, false, decorations);
            if editor.focus() == float.view {
                cursor = float_cursor;
            }
            floats.push(FloatFrame {
                rect,
                title: float.options.title.as_deref().map(str::to_owned),
                rows,
                label: border_spans(float.options.label.as_ref()),
                footer: border_spans(float.options.footer.as_ref()),
                border: float.options.border,
            });
        }
        images.retain(|image| {
            !floats
                .iter()
                .any(|f| overlaps(image.rect, if f.border { bordered(f.rect) } else { f.rect }))
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
            gui: BTreeMap::new(),
            menus: editor.menus().to_vec(),
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
        // What falls below a screen too small for it is left out.
        let mut put = |y: usize, piece: (u16, u16, Row)| {
            if let Some(row) = pieces.get_mut(y) {
                row.push(piece);
            }
        };
        let index = |y: u16| usize::from(y.saturating_sub(area.y));
        if let Some(tabline) = tabline {
            put(0, (area.x, area.width, tabline));
        }
        for (view, rect, rows) in drawn {
            for (i, mut row) in rows.into_iter().enumerate() {
                if view != active {
                    row.tags.insert(0, Tag::PANE_INACTIVE);
                }
                put(index(rect.y) + i, (rect.x, rect.width, row));
            }
        }
        let border = |text: String| Row {
            spans: vec![Span::new(text, smallvec![Tag::PANE_BORDER])],
            ..Row::default()
        };
        for line in lines {
            if line.down {
                for y in line.y..line.y.saturating_add(line.len) {
                    put(index(y), (line.x, 1, border("│".to_owned())));
                }
            } else {
                let text = "─".repeat(usize::from(line.len));
                put(index(line.y), (line.x, line.len, border(text)));
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
                    at = x.saturating_add(width);
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
            let mut tags = smallvec![Tag::TABLINE];
            if tab.id() == shown {
                tags.push(Tag::TABLINE_ACTIVE);
            }
            row.push(&tab_label(editor, i, tab), tags);
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
        let styled = marks_in(editor, view.buffer, &visible);
        let (head, cursors) = cursors(text, view, editor.cursor_shape());
        let number = line_number(editor.line_numbers(), text, head);
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
            let line_gutter = Gutter::for_line(gutter, signs, &styled, &lines);
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
                    line_gutter.push(&mut row, (i == 0).then(|| number(line)));
                }
                let mut x = gutter;
                for cell in &cells {
                    if cell.inserted.is_some() {
                        let place = screen_position(area, x, rows.len());
                        self.push_inserted(&mut row, cell, view_id, place);
                        x += cell.width;
                        continue;
                    }
                    first_shown = first_shown.or(Some(cell.byte));
                    if !cell.end_of_line {
                        last_shown = Some(cell.byte);
                    }
                    if cursor_here(cell.byte, head, &lines, cursor.is_some()) {
                        cursor = Some(screen_position(area, x, rows.len()));
                    }
                    if let Some((text, tag)) = overlay.over(&styled, cell) {
                        row.push_scaled(&text, smallvec![tag], cell.scale);
                        x += cell.width;
                        continue;
                    }
                    let capture = cell
                        .byte
                        .checked_sub(visible.start)
                        .and_then(|i| syntax.get(i)?.clone());
                    let cell_tags = cell_tags(view, cell, &cursors, capture, &styled);
                    if !(cell.end_of_line && cell_tags.is_empty()) {
                        row.push_scaled(&cell.text, cell_tags, cell.scale);
                    }
                    x += cell.width;
                }
                if i == last {
                    let eol = styled.iter().filter(on_line).filter(|m| m.eol);
                    self.push_eol_text(&mut row, (view_id, area, rows.len()), x, eol);
                }
                push_covering(&mut rows, row, row_height(&cells), text_rows);
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

    /// Adds each mark's text after the end of a line that reaches column
    /// `x`, a space before each, cut off at the edge rather than wrapped.
    /// `at` is the view, its area and the row's index in it, for marks with
    /// actions.
    fn push_eol_text<'a>(
        &self,
        row: &mut Row,
        at: (ViewId, Rect, usize),
        x: usize,
        marks: impl Iterator<Item = &'a &'a Mark>,
    ) {
        let (view, area, row_index) = at;
        let (left, mut room) = (area.x, usize::from(area.width).saturating_sub(x));
        let screen_row = area.y + u16::try_from(row_index).unwrap_or(u16::MAX);
        for mark in marks {
            let Some(text) = &mark.text else { continue };
            let mut shown = String::new();
            let mut used = 0;
            for g in std::iter::once(" ").chain(text.graphemes(true)) {
                let w = self.measure.width(g);
                if w > room {
                    room = 0;
                    break;
                }
                room -= w;
                used += w;
                shown.push_str(g);
            }
            if !shown.is_empty() {
                if let Some(action) = &mark.action {
                    // Past the row's text so far, which can end before the
                    // cell past the end of the line, and the space in front.
                    let ends = u16::try_from(self.text_width(&row.text())).unwrap_or(u16::MAX);
                    let place = Position {
                        col: left + ends + 1,
                        row: screen_row,
                    };
                    self.record_action(view, place, used - 1, action, mark.range.start);
                }
                // The space goes in unstyled, so buttons side by side stay
                // apart.
                let (space, text) = shown.split_at(1);
                row.push(space, SmallVec::new());
                if !text.is_empty() {
                    row.push(text, smallvec![Tag::from(mark.style.clone())]);
                }
            }
        }
    }

    /// Draws a cell of a mark's text at screen position `place`.
    fn push_inserted(&self, row: &mut Row, cell: &Cell, view: ViewId, place: Position) {
        if let Some(style) = &cell.inserted {
            row.push_scaled(&cell.text, smallvec![Tag::from(style.clone())], cell.scale);
        }
        if let Some((action, at)) = &cell.action {
            // Scaled text is a button on every row it takes.
            for down in 0..u16::from(cell.scale) {
                let place = Position {
                    row: place.row.saturating_add(down),
                    ..place
                };
                self.record_action(view, place, cell.width, action, *at);
            }
        }
    }

    fn record_action(
        &self,
        view: ViewId,
        place: Position,
        width: usize,
        action: &Arc<str>,
        at: usize,
    ) {
        let end = place
            .col
            .saturating_add(u16::try_from(width).unwrap_or(u16::MAX));
        self.actions.borrow_mut().push(ActionArea {
            view,
            row: place.row,
            cols: place.col..end,
            action: action.clone(),
            at,
        });
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

        let auto = editor.reveal();
        let concealed = concealed(buffer, view, line, start..end, auto);
        // Text from marks, shown before the character at its position.
        let mut inserted: Vec<(&Mark, &str)> = buffer
            .all_marks()
            .filter(|m| !m.eol && !m.overlay && (start..=end).contains(&m.range.start))
            .filter(|m| !m.conceal || !reveals(text, view, m, line, auto))
            .filter_map(|m| Some((m, m.text.as_deref()?)))
            .collect();
        inserted.sort_by_key(|(m, _)| m.range.start);
        let mut inserted = inserted.into_iter().peekable();
        // Text scaled up by marks: each byte at the largest scale over it.
        let scaled: Vec<&Mark> = buffer
            .all_marks()
            .filter(|m| m.scale > 1 && m.range.start < end && m.range.end > start)
            .collect();
        let scale_at = |byte: usize| {
            scaled
                .iter()
                .filter(|m| m.range.contains(&byte))
                .map(|m| m.scale)
                .max()
                .unwrap_or(1)
        };

        let mut cells = Vec::new();
        let mut x = 0;
        for (offset, grapheme) in content
            .grapheme_indices(true)
            .chain(std::iter::once((content.len(), "")))
        {
            let byte = start + offset;
            while let Some((mark, extra)) = inserted.next_if(|(m, _)| m.range.start <= byte) {
                let scale = mark.scale.max(1);
                for g in extra.graphemes(true) {
                    let w = self.measure.width(g) * usize::from(scale);
                    cells.push(Cell {
                        byte,
                        text: g.to_owned(),
                        width: w,
                        end_of_line: false,
                        inserted: Some(mark.style.clone()),
                        action: mark.action.clone().map(|a| (a, mark.range.start)),
                        scale,
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
            let scale = scale_at(byte);
            let (text, w) = if grapheme == "\t" {
                let w = width_at(&self.measure, grapheme, x, self.tab_width);
                (" ".repeat(w), w)
            } else {
                let w = self.measure.width(grapheme) * usize::from(scale);
                (grapheme.to_owned(), w)
            };
            cells.push(Cell {
                byte,
                text,
                width: w,
                end_of_line: false,
                inserted: None,
                action: None,
                scale,
            });
            x += w;
        }

        wrap(cells, width, end)
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
        let head = cursor_byte(text, view.selection.primary(), editor.cursor_shape());
        let line = text.byte_to_line(head);
        let cursor = Scroll {
            line,
            row: self.row_of(editor, view, line, head, width),
        };
        let current = view.scroll;
        if (cursor.line, cursor.row) < (current.line, current.row) || height == 0 {
            return cursor;
        }

        // Is the cursor's row within `height` screen rows of the current
        // scroll? Rows count as many screen rows as their scale makes them.
        let hidden = hidden_lines(editor, view);
        let cursor_heights = self.heights(editor, view, cursor.line, width);
        // On the buffer's last row, what's drawn under it stays in sight
        // too, like the bottom of a box around a prompt.
        let tail = if cursor.line + 1 == text.len_lines() && cursor.row + 1 == cursor_heights.len()
        {
            virtual_lines(editor, view, cursor.line).count()
        } else {
            0
        };
        let mut seen = 0;
        for l in current.line..=cursor.line {
            let rows = if l == cursor.line {
                cursor_heights[..=cursor.row].iter().sum::<usize>() + tail
            } else {
                self.line_rows(editor, view, l, width, &hidden)
            };
            let skip = if l == current.line {
                // The scroll can be past the line's rows, since the line got
                // shorter or the view wider.
                self.heights(editor, view, l, width)
                    .iter()
                    .take(current.row)
                    .sum()
            } else {
                0
            };
            seen += rows.saturating_sub(skip);
            if seen > height {
                break;
            }
        }
        if seen <= height {
            return current;
        }

        // Scroll so the cursor's row is the last one on screen: take the
        // rows above it in its line while they fit, then whole lines while
        // they fit, then as many rows of the next one as are left, after
        // its virtual lines.
        let mut above = height.saturating_sub(cursor_heights[cursor.row] + tail);
        let mut top = cursor;
        top.row = fitting_from_end(&cursor_heights[..cursor.row], &mut above).unwrap_or(cursor.row);
        if top.row > 0 {
            return top;
        }
        let mut l = cursor.line;
        while above > 0 && l > 0 {
            l -= 1;
            if is_hidden(&hidden, l) {
                continue;
            }
            let heights = self.heights(editor, view, l, width);
            let virtual_rows = virtual_lines(editor, view, l).count();
            let total = heights.iter().sum::<usize>() + virtual_rows;
            if total <= above {
                above -= total;
                top = Scroll { line: l, row: 0 };
                continue;
            }
            let mut room = above.saturating_sub(virtual_rows);
            if let Some(row) = fitting_from_end(&heights, &mut room) {
                top = Scroll { line: l, row };
            }
            break;
        }
        top
    }

    /// The screen rows each row of `line` takes.
    fn heights(&self, editor: &Editor, view: &View, line: usize, width: usize) -> Vec<usize> {
        self.layout(editor, view, line, width)
            .iter()
            .map(|cells| row_height(cells))
            .collect()
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
        self.heights(editor, view, line, width)
            .iter()
            .sum::<usize>()
            + virtual_lines(editor, view, line).count()
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
        lines: impl Iterator<Item = (&'a Mark, &'a VirtualLine)>,
        gutter: Option<&Gutter>,
        room: usize,
    ) -> bool {
        for (mark, line) in lines {
            if rows.len() == limit {
                return false;
            }
            let mut row = Row::default();
            if let Some(gutter) = gutter {
                gutter.push(&mut row, None);
            }
            let kept = self.keep_start(&line.text, room);
            let base = Tag::from(mark.style.clone());
            if line.styles.is_empty() {
                row.push(&kept, smallvec![base]);
            } else {
                for (i, g) in kept.grapheme_indices(true) {
                    let mut tags = smallvec![base.clone()];
                    if let Some((_, style)) = line.styles.iter().find(|(r, _)| r.contains(&i)) {
                        tags.push(Tag::from(style.clone()));
                    }
                    row.push(g, tags);
                }
            }
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
        let head = cursor_byte(text, view.selection.primary(), editor.cursor_shape());
        let line = text.byte_to_line(head);
        let column = text.byte_to_char(head) - text.line_to_char(line) + 1;
        // Files in the project show from its root.
        let root = editor.current_project().root();
        let middle = match message {
            Some(message) => span(message, Tag::MESSAGE),
            None => span(
                &buffer.path().map_or_else(
                    || "[scratch]".to_owned(),
                    |p| p.strip_prefix(root).unwrap_or(p).display().to_string(),
                ),
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
            actions: Vec::new(),
        }
    }

    /// Lays out a status line across `width` cells, on screen row `y`. If
    /// it doesn't fit, the last segment on the left keeps only its end.
    fn status_row(&self, status: &StatusLine, width: usize, y: u16) -> Row {
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

        let gap = Span::new(" ".repeat(padding), smallvec![Tag::STATUS]);
        let action = |i: usize| status.actions.get(i).cloned().flatten();
        let spans = (left.iter().enumerate().map(|(i, s)| (s, action(i))))
            .chain([(&gap, None)])
            .chain((status.right.iter().enumerate()).map(|(i, s)| (s, action(left.len() + i))));
        let mut row = Row::default();
        let mut found = self.status_actions.borrow_mut();
        found.clear();
        let mut x = 0;
        let col = |x: usize| u16::try_from(x).unwrap_or(u16::MAX);
        for (s, action) in spans {
            let to = x + self.text_width(&s.text);
            if let Some(action) = action {
                found.push(StatusArea {
                    row: y,
                    cols: col(x)..col(to),
                    action,
                });
            }
            x = to;
            row.push(&s.text, s.tags.clone());
        }
        row
    }

    /// The action of the status line segment at (`col`, `row`), if it has
    /// one.
    fn status_action_at(&self, col: u16, row: u16) -> Option<Arc<str>> {
        self.status_actions
            .borrow()
            .iter()
            .find(|area| area.row == row && area.cols.contains(&col))
            .map(|area| area.action.clone())
    }
}

fn span(text: &str, tag: Tag) -> Span {
    Span::new(text, smallvec![tag])
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
    /// The line number's tags: the gutter's, then those of marks on the line.
    number: SmallVec<[Tag; 2]>,
}

impl<'a> Gutter<'a> {
    /// The gutter for the line spanning `lines`: the first mark with a sign
    /// on it, and the line number styles of every mark on it.
    fn for_line(width: usize, signs: bool, styled: &[&'a Mark], lines: &Range<usize>) -> Self {
        let on_line = || {
            styled
                .iter()
                .filter(|m| m.range.start < lines.end && m.range.end >= lines.start)
        };
        Gutter {
            width,
            signs,
            sign: on_line().find(|m| m.sign.is_some()).copied(),
            number: std::iter::once(Tag::GUTTER)
                .chain(on_line().filter_map(|m| m.gutter.clone().map(Tag::from)))
                .collect(),
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
        row.push(&text, self.number.clone());
    }
}

/// The number each line shows in `style`: its own, or how far it is from
/// the line of `head`, the byte the cursor is drawn on.
fn line_number(style: LineNumbers, text: &Rope, head: usize) -> impl Fn(usize) -> usize + use<> {
    let cursor = text.byte_to_line(head.min(text.len_bytes()));
    move |line| style.number(line, cursor)
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
    cursors: &[usize],
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
    tags.extend(selection_tags(view, cell, cursors));
    tags.extend(on_cell(true));
    tags
}

/// Selection and cursor tags for one cell.
fn selection_tags(view: &View, cell: &Cell, cursors: &[usize]) -> SmallVec<[Tag; 2]> {
    let mut out = SmallVec::new();
    for range in view.selection.ranges() {
        if !cell.end_of_line && range.from() <= cell.byte && cell.byte < range.to() {
            out.push(Tag::SELECTION);
        }
    }
    if cursors.contains(&cell.byte) {
        out.push(Tag::CURSOR);
    }
    out
}

/// Where a selection's cursor is drawn. A block sits on a character: for a
/// selection going forward, its last one, as in Helix. A bar sits at the head.
fn cursor_byte(text: &Rope, range: greed_text::Range, shape: CursorShape) -> usize {
    let head = range.head.min(text.len_bytes());
    if shape != CursorShape::Bar && range.anchor < head {
        text.char_to_byte(text.byte_to_char(head).saturating_sub(1))
    } else {
        head
    }
}

/// Where the primary cursor is drawn, and the others: each selection's in
/// a mode whose cursor sits on characters, otherwise only empty ones'.
fn cursors(text: &Rope, view: &View, shape: CursorShape) -> (usize, Vec<usize>) {
    let index = view.selection.primary_index();
    let others = view
        .selection
        .ranges()
        .iter()
        .enumerate()
        .filter(|&(i, range)| i != index && (shape != CursorShape::Bar || range.is_empty()))
        .map(|(_, &range)| cursor_byte(text, range, shape))
        .collect();
    (cursor_byte(text, view.selection.primary(), shape), others)
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
        for byte in &mut painted[start..end.max(start)] {
            *byte = Some(highlight.capture.clone());
        }
        previous = Some(highlight.range);
    }
    painted
}

/// The main view keeps at least this many columns; panels shrink to leave it.
const MIN_MAIN_WIDTH: u16 = 10;

/// How tab `i` (0-based) shows in the tab line: its number and name.
fn tab_label(editor: &Editor, i: usize, tab: &crate::Tab) -> String {
    let name = tab
        .name()
        .map_or_else(|| tab_title(editor, tab.active()), str::to_owned);
    format!(" {} {name} ", i + 1)
}

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
/// for the border if it has one. `cursor` is where the focused view's
/// cursor is, for floats anchored to it.
fn place(options: &FloatOptions, area: Rect, cursor: Option<Position>) -> Rect {
    let inset = u16::from(options.border);
    let outer_width = options.width.resolve(area.width).max(2 * inset + 1);
    let outer_height = options.height.resolve(area.height).max(2 * inset + 1);
    let inside = |x: u16, y: u16| Rect {
        x: x + inset,
        y: y + inset,
        width: outer_width - 2 * inset,
        height: outer_height - 2 * inset,
    };
    if matches!(options.anchor, Anchor::Cursor | Anchor::AboveCursor)
        && let Some(cursor) = cursor
    {
        // The text inside starts under the cursor, on the row below it, or
        // ends on the row above it, whichever the anchor prefers and fits.
        let below = cursor.row.saturating_add(1);
        let fits_below = u32::from(below) + u32::from(outer_height)
            <= u32::from(area.y) + u32::from(area.height);
        let above = cursor
            .row
            .checked_sub(outer_height)
            .filter(|&y| y >= area.y);
        let y = match (options.anchor, above) {
            (Anchor::AboveCursor, Some(above)) => above,
            _ if fits_below => below,
            _ => cursor.row.saturating_sub(outer_height),
        };
        let x = cursor
            .col
            .saturating_sub(inset)
            .min((area.x + area.width).saturating_sub(outer_width));
        return inside(x, y);
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
        (None, Anchor::Center | Anchor::Cursor | Anchor::AboveCursor) => {
            area.height.saturating_sub(outer_height) / 2
        }
        (None, Anchor::Bottom) => area.height.saturating_sub(outer_height),
    }
    .min(area.height.saturating_sub(outer_height));
    inside(area.x + x, area.y + y)
}

/// The marks of `buffer` that touch `visible`.
fn marks_in<'a>(editor: &'a Editor, buffer: BufferId, visible: &Range<usize>) -> Vec<&'a Mark> {
    editor
        .buffer(buffer)
        .all_marks()
        .filter(|m| m.range.start <= visible.end && m.range.end >= visible.start)
        .collect()
}

/// The bytes from the `first` drawn to just past the `last` character drawn
/// (empty when nothing was).
fn shown_bytes(text: &Rope, first: Option<usize>, last: Option<usize>) -> Range<usize> {
    let first = first.unwrap_or(0);
    last.map_or(first..first, |last| {
        first..text.char_to_byte(text.byte_to_char(last) + 1)
    })
}

/// Whether the cursor at `head` goes on the cell for `byte` of the line
/// `lines`: its own cell, or when it's on hidden text (a heading's `#`), the
/// first cell shown after it, unless it's `placed` already.
fn cursor_here(byte: usize, head: usize, lines: &Range<usize>, placed: bool) -> bool {
    byte == head || (!placed && byte > head && lines.contains(&head))
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
) -> impl Iterator<Item = (&'a Mark, &'a VirtualLine)> {
    let buffer = editor.buffer(view.buffer);
    let text = buffer.text();
    buffer
        .all_marks()
        .filter(move |m| !m.lines.is_empty() && last_line(text, &m.range) == line)
        .flat_map(|m| m.lines.iter().map(move |l| (m, l)))
}

/// Whether concealing mark `mark` on `line` shows its text now, as its
/// `reveal` says, with `auto` (the editor's) for `Reveal::Auto`.
fn reveals(text: &Rope, view: &View, mark: &Mark, line: usize, auto: Reveal) -> bool {
    let reveal = if mark.reveal == Reveal::Auto {
        auto
    } else {
        mark.reveal
    };
    match reveal {
        Reveal::Line => cursor_lines(text, view).any(|l| l == line),
        Reveal::Cursor => view
            .selection
            .ranges()
            .iter()
            .any(|r| mark.range.start < r.head && r.head < mark.range.end),
        Reveal::Never | Reveal::Auto => false,
    }
}

/// The marks hiding parts of `line` (its `bytes`) now.
fn concealed<'a>(
    buffer: &'a crate::Buffer,
    view: &View,
    line: usize,
    bytes: Range<usize>,
    auto: Reveal,
) -> Vec<&'a Mark> {
    buffer
        .all_marks()
        .filter(|m| m.conceal && m.range.start < bytes.end && m.range.end > bytes.start)
        .filter(|m| !reveals(buffer.text(), view, m, line, auto))
        .collect()
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

/// The first of the last rows of `heights` that fit in `room` screen rows,
/// taking what they use from it; `None` if not even the last one fits.
fn fitting_from_end(heights: &[usize], room: &mut usize) -> Option<usize> {
    let mut first = None;
    for (i, &h) in heights.iter().enumerate().rev() {
        if h > *room {
            break;
        }
        *room -= h;
        first = Some(i);
    }
    first
}

/// A line's `cells` in rows `width` cells wide, breaking after whitespace
/// where it can, with a cell for the end of the line (byte `end`) where a
/// cursor can sit after it, if there's room.
fn wrap(cells: Vec<Cell>, width: usize, end: usize) -> Vec<Vec<Cell>> {
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
            action: None,
            scale: 1,
        });
    }
    rows
}
