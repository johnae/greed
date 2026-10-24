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

use greed_text::{Rope, Selection, line_content};

mod hit;
pub use hit::Hit;
pub mod grid;

use crate::image::ImageId;
use crate::syntax::Highlight;
use crate::theme::Theme;
use crate::{
    Anchor, BufferId, ClientState, CursorShape, Editor, Float, FloatOptions, LineNumbers, Mark,
    Panel, Reveal, ScreenSize, Scroll, Side, View, ViewId, VirtualLine,
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

/// How many cells `text` takes on a line from its start, as it's drawn:
/// wide characters take two, tabs reach the next stop.
pub fn width(text: &str, tab_width: usize) -> usize {
    text.graphemes(true)
        .fold(0, |x, g| x + width_at(&CellWidth, g, x, tab_width))
}

/// The screen column of byte `pos` in its line, counting wide characters
/// and tabs as they're drawn (but not folds, concealed or scaled text).
pub fn display_column(text: &Rope, pos: usize, tab_width: usize) -> usize {
    let start = text.line_to_byte(text.byte_to_line(pos));
    width(&text.byte_slice(start..pos).to_string(), tab_width)
}

/// The position in `line` drawn at screen column `col`: the start of the
/// character covering it, or the line's end if the line is shorter.
pub fn at_display_column(text: &Rope, line: usize, col: usize, tab_width: usize) -> usize {
    let start = text.line_to_byte(line);
    let content: Cow<str> = line_content(text, line).into();
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
    /// A view's note on why what it shows doesn't fit it, like a terminal
    /// sized for another client's screen.
    pub const SCREEN_NOTE: Tag = Tag::fixed("ui.screen.note");

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

/// One screen: the surfaces on it, the lines between panes, images, the
/// cursor and what the tags look like.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Frame {
    pub size: Size,
    /// What's on screen, bottom first: the shown tab's panes, the tab line,
    /// the status line, panels, then floats. No two have the same id.
    pub surfaces: Vec<Surface>,
    /// The lines between panes.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub lines: Vec<Separator>,
    /// Images to draw over the surfaces, after them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub images: Vec<ImagePlacement>,
    /// Scenes to draw over the surfaces, by the clients that can; the
    /// cells under them hold them drawn in characters for the others.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub scenes: Vec<ScenePlacement>,
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
    /// Which of the frames a session sent this client it is, counting from
    /// 1, so a delta can say which one it was made against (see
    /// [`crate::delta::FrameDelta::apply`]). 0 when nobody counts, as for
    /// a client in the same process.
    #[serde(default, skip_serializing_if = "uncounted")]
    pub seq: u64,
}

/// Whether a frame's `seq` is 0: from a session that doesn't count them.
#[expect(
    clippy::trivially_copy_pass_by_ref,
    reason = "serde passes a reference"
)]
pub(crate) fn uncounted(seq: &u64) -> bool {
    *seq == 0
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

impl Frame {
    /// The surface `id`, if it's on screen.
    pub fn surface(&self, id: SurfaceId) -> Option<&Surface> {
        self.surfaces.iter().find(|s| s.id == id)
    }

    /// The text areas of the floats with a border, bottom first.
    pub fn bordered_floats(&self) -> impl Iterator<Item = Rect> + '_ {
        self.surfaces.iter().filter_map(|s| match s.role {
            Role::Float { border: true, .. } => Some(s.rect),
            _ => None,
        })
    }
}

/// A rectangle of rows on screen, drawn as its role says: a pane, a panel,
/// a float, the tab line or the status line.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Surface {
    pub id: SurfaceId,
    pub role: Role,
    /// Where its rows go.
    pub rect: Rect,
    pub rows: Vec<Row>,
    /// The size of what it shows when that differs from `rect`, which the
    /// client crops or pads to fit.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content: Option<Size>,
    /// A short text for the client to show on it, like why it's cropped.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    /// The row of what it shows to keep in sight when it's cropped, like
    /// where a terminal's program has its cursor.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keep: Option<u16>,
    /// For a view, where its first row is in its text: the line, and the
    /// row of that line when it wraps. It changes when the view scrolls,
    /// and not when its text changes, so a client glides only real scrolls.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub top: Option<[u64; 2]>,
}

impl Surface {
    /// `rows` in `rect`, showing all of what it has.
    pub fn new(id: SurfaceId, role: Role, rect: Rect, rows: Vec<Row>) -> Self {
        Surface {
            id,
            role,
            rect,
            rows,
            content: None,
            note: None,
            keep: None,
            top: None,
        }
    }
}

/// A view laid out: its rows, where its cursor is on screen, and the size
/// it was laid out at with a note saying why, when that isn't the room it
/// has.
struct Laid {
    rows: Vec<Row>,
    cursor: Option<Position>,
    sized: Option<Sized>,
}

/// A view laid out at its buffer's screen size rather than its own room:
/// that size, the note saying so, and the row to keep in sight.
struct Sized {
    size: Size,
    note: String,
    keep: Option<u16>,
}

impl Laid {
    fn new(rows: Vec<Row>, cursor: Option<Position>, sized: Option<Sized>) -> Self {
        Self {
            rows,
            cursor,
            sized,
        }
    }

    /// The surface showing view `view` as `role` in `rect`, scrolled to
    /// `scroll`.
    fn surface(self, view: ViewId, role: Role, rect: Rect, scroll: Scroll) -> Surface {
        let mut surface = Surface::new(SurfaceId::View(view), role, rect, self.rows);
        if let Some(sized) = self.sized {
            surface.content = Some(sized.size);
            surface.note = Some(sized.note);
            surface.keep = sized.keep;
        }
        let wide = |n: usize| u64::try_from(n).unwrap_or(u64::MAX);
        surface.top = Some([wide(scroll.line), wide(scroll.row)]);
        surface
    }
}

/// Which surface: stays the same from frame to frame while the thing it
/// shows is on screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SurfaceId {
    /// A pane, panel or float showing this view.
    View(ViewId),
    Tabline,
    Status,
}

/// What a surface is, which decides how a client draws around it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "kind")]
pub enum Role {
    /// A pane of the shown tab. All but the active one are drawn dimmed
    /// (`ui.pane.inactive`).
    Pane { active: bool },
    /// A panel beside the panes, with a line down column `separator`
    /// between them and its title (if any) on the row above its rect.
    Panel {
        separator: u16,
        title: Option<String>,
    },
    /// A floating view over the rest, with a border one cell around its
    /// rect unless `border` is false.
    Float {
        #[serde(default = "yes", skip_serializing_if = "is_true")]
        border: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        title: Option<String>,
        /// Drawn at the right end of the top border.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        label: Vec<Span>,
        /// Drawn in the middle of the bottom border.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        footer: Vec<Span>,
    },
    /// The row of tabs above the panes, when there's more than one tab.
    Tabline,
    /// The status line at the bottom.
    Status,
}

/// A line drawn between two panes: down from (`x`, `y`) when `down`,
/// across otherwise, `len` cells long.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Separator {
    pub x: u16,
    pub y: u16,
    pub len: u16,
    pub down: bool,
}

impl From<crate::layout::Line> for Separator {
    fn from(line: crate::layout::Line) -> Self {
        Separator {
            x: line.x,
            y: line.y,
            len: line.len,
            down: line.down,
        }
    }
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

/// Part of a scene on screen, as an image's part is: the scene is `cols`
/// by `rows` cells, and the part from its cell (`col`, `row`) goes in
/// `rect`. `version` says which of the scene's versions it shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScenePlacement {
    pub id: crate::scene::SceneId,
    pub version: u64,
    pub rect: Rect,
    pub col: u16,
    pub row: u16,
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
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
    /// A copy of the line's leading whitespace that starts a wrapped row, so
    /// the row lines up under the text above it: styles and overlays (a
    /// transcript's bar) show on it as on the first row, and the cursor and
    /// selections never do.
    repeated: bool,
}

impl Cell {
    /// Whitespace from the buffer, where a row may break.
    fn is_space(&self) -> bool {
        self.inserted.is_none() && self.text.chars().all(char::is_whitespace)
    }
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
    /// Images placed while laying out the frame being drawn.
    images: RefCell<Vec<ImagePlacement>>,
    /// Scenes placed while laying out the frame being drawn.
    scenes: RefCell<Vec<ScenePlacement>>,
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
            images: RefCell::default(),
            scenes: RefCell::default(),
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
        self.scenes.borrow_mut().clear();
        self.actions.borrow_mut().clear();
        let screen = Rect {
            x: 0,
            y: 0,
            width: size.width,
            height: size.height.saturating_sub(1),
        };
        let (area, placed) = layout_panels(editor.panels(), screen);
        let mut surfaces = Vec::new();
        // Each view's cursor on screen, as views are laid out.
        let (lines, mut cursors) = self.panes(editor, area, decorations, &mut surfaces);
        let status = match status {
            Status::Default { message } => {
                Self::default_status(editor, editor.view(editor.status_view()), *message)
            }
            Status::Line(line) => line.clone(),
        };
        let status_rect = Rect {
            x: 0,
            y: screen.height,
            width: size.width,
            height: 1,
        };
        let status = self.status_row(&status, usize::from(size.width), screen.height);
        surfaces.push(Surface::new(
            SurfaceId::Status,
            Role::Status,
            status_rect,
            vec![status],
        ));

        for (view, rect, role) in placed {
            let laid = self.view_rows(editor, view, rect, false, decorations);
            if let Some(cursor) = laid.cursor {
                cursors.push((view, cursor));
            }
            surfaces.push(laid.surface(view, role, rect, editor.view(view).scroll));
        }
        let cursor_of = |cursors: &[(ViewId, Position)], view: ViewId| {
            cursors.iter().find(|(v, _)| *v == view).map(|(_, c)| *c)
        };
        // Images under a floating view are left out rather than drawn over
        // it.
        let mut images = self.images.take();
        let mut scenes = self.scenes.take();
        let mut covered = Vec::new();
        let shown: Vec<Float> = editor.floats().into_iter().cloned().collect();
        for float in shown {
            // A float by the cursor goes by the view it opened from: one that
            // takes focus has none of its own to go by yet.
            let anchor = cursor_of(&cursors, float.return_to)
                .or_else(|| cursor_of(&cursors, editor.focus()));
            let rect = place(&float.options, screen, anchor);
            let laid = self.view_rows(editor, float.view, rect, false, decorations);
            if let Some(cursor) = laid.cursor {
                cursors.push((float.view, cursor));
            }
            let options = &float.options;
            covered.push(if options.border {
                rect.bordered()
            } else {
                rect
            });
            let role = Role::Float {
                border: options.border,
                // Without a title, a float of a named buffer, like a
                // terminal's, is called by its name.
                title: options
                    .title
                    .as_deref()
                    .or_else(|| editor.buffer(editor.view(float.view).buffer).name())
                    .map(str::to_owned),
                label: border_spans(options.label.as_ref()),
                footer: border_spans(options.footer.as_ref()),
            };
            surfaces.push(laid.surface(float.view, role, rect, editor.view(float.view).scroll));
        }
        images.retain(|image| !covered.iter().any(|&c| image.rect.overlaps(c)));
        images.extend(self.images.take());
        scenes.retain(|scene| !covered.iter().any(|&c| scene.rect.overlaps(c)));
        scenes.extend(self.scenes.take());
        // Deltas tell surfaces apart by id. A view is on screen once, but
        // should one show up twice, only the first is drawn.
        let mut seen = std::collections::HashSet::new();
        surfaces.retain(|s| seen.insert(s.id));

        Frame {
            size,
            surfaces,
            lines,
            images,
            scenes,
            cursor: cursor_of(&cursors, editor.focus()),
            cursor_shape: editor.cursor_shape(),
            theme: editor.theme().clone(),
            gui: BTreeMap::new(),
            menus: editor.menus().to_vec(),
            seq: 0,
        }
    }

    /// Places the images and scenes `marks` show in `view`, cut to
    /// `text_area`, the part of the screen its text takes. Each goes over
    /// whole cells from its mark's start, whatever text is under it.
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
        // Where something `cols` by `rows` cells, whose cell (`col`, `row`)
        // is at `mark`'s start, is on screen: the part in the text area, and
        // its first cell there. Nil when none of it is.
        let place = |mark: &Mark, cols: u16, rows: u16, col: u16, row: i64| {
            let start = mark.range.start.min(text.len_bytes());
            let line = text.byte_to_line(start);
            // The screen row of the mark's line, counting from the top of
            // the view, so negative above it.
            let screen_row = if line >= view.scroll.line {
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
            let left = i64::try_from(x).unwrap_or(0) - i64::from(col);
            let top = screen_row - row;
            let (x0, y0) = (left.max(0), top.max(0));
            let x1 = (left + i64::from(cols)).min(i64::from(text_area.width));
            let y1 = (top + i64::from(rows)).min(i64::from(text_area.height));
            if x1 <= x0 || y1 <= y0 {
                return None;
            }
            let cell = |n: i64| u16::try_from(n).unwrap_or(u16::MAX);
            let rect = Rect {
                x: text_area.x + cell(x0),
                y: text_area.y + cell(y0),
                width: cell(x1 - x0),
                height: cell(y1 - y0),
            };
            Some((rect, cell(x0 - left), cell(y0 - top)))
        };
        for (mark, scene) in marks.iter().filter_map(|m| Some((m, m.scene?))) {
            let Some(version) = editor.scenes().get(scene.id).map(|s| s.version) else {
                continue;
            };
            // A scene goes over the text drawn under it in characters, which
            // its mark covers: only while every line of that shows, a row
            // each. Folded, wrapped or changed, the characters show alone.
            if !mark.range.is_empty() {
                let first = text.byte_to_line(mark.range.start.min(text.len_bytes()));
                let last = text.byte_to_line(mark.range.end.min(text.len_bytes()));
                let lines = i64::try_from(last - first + 1).unwrap_or(i64::MAX);
                // Lines added under its last line, like the space under a
                // shell's block, are below it.
                let below = i64::try_from(virtual_lines(editor, view, last).count()).unwrap_or(0);
                let shown = rows_of(first..last + 1) - below;
                if shown != lines || lines != i64::from(scene.rows) {
                    continue;
                }
            }
            if let Some((rect, col, row)) =
                place(mark, scene.cols, scene.rows, scene.col, scene.row.into())
            {
                self.scenes.borrow_mut().push(ScenePlacement {
                    id: scene.id,
                    version,
                    rect,
                    col,
                    row,
                    cols: scene.cols,
                    rows: scene.rows,
                });
            }
        }
        for (mark, image) in marks.iter().filter_map(|m| Some((m, m.image?))) {
            if !editor.images().contains(image.id) {
                continue;
            }
            if let Some((rect, col, row)) =
                place(mark, image.cols, image.rows, image.col, image.row.into())
            {
                self.images.borrow_mut().push(ImagePlacement {
                    id: image.id,
                    rect,
                    col,
                    row,
                    cols: image.cols,
                    rows: image.rows,
                });
            }
        }
    }

    /// Lays out the shown tab's panes in `area`, and the tabs above them
    /// when there's more than one, adding them to `surfaces`. Returns the
    /// lines between the panes and where the focused pane's cursor is, if
    /// a pane has focus.
    fn panes(
        &self,
        editor: &mut Editor,
        area: Rect,
        decorations: &dyn Decorations,
        surfaces: &mut Vec<Surface>,
    ) -> (Vec<Separator>, Vec<(ViewId, Position)>) {
        let tabline = editor.tabs().len() > 1;
        let panes_area = if tabline {
            Rect {
                y: area.y + 1,
                height: area.height.saturating_sub(1),
                ..area
            }
        } else {
            area
        };
        editor.set_tab_area(panes_area);
        let (panes, lines) = editor.current_tab().place(panes_area);
        let active = editor.current_tab().active();
        let mut cursors = Vec::new();
        for (view, rect) in panes {
            let numbers = editor.buffer(editor.view(view).buffer).line_numbers();
            let laid = self.view_rows(editor, view, rect, numbers, decorations);
            if let Some(cursor) = laid.cursor {
                cursors.push((view, cursor));
            }
            let role = Role::Pane {
                active: view == active,
            };
            surfaces.push(laid.surface(view, role, rect, editor.view(view).scroll));
        }
        if tabline {
            let rect = Rect {
                height: area.height.min(1),
                ..area
            };
            let rows = vec![Self::tabline(editor)];
            surfaces.push(Surface::new(SurfaceId::Tabline, Role::Tabline, rect, rows));
        }
        (lines.into_iter().map(Separator::from).collect(), cursors)
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

    /// Lays out one view to fill `room`, scrolling it to keep its primary
    /// cursor visible: its rows, and where that cursor is on screen. A
    /// buffer with a screen size of its own, like a terminal's, is laid out
    /// at that size from `room`'s top left, whatever room the view has, for
    /// the client to crop or scale to fit.
    fn view_rows(
        &self,
        editor: &mut Editor,
        view_id: ViewId,
        room: Rect,
        line_numbers: bool,
        decorations: &dyn Decorations,
    ) -> Laid {
        let (gutter, signs) = gutter_width(editor, editor.view(view_id), line_numbers);
        let screen = editor.buffer(editor.view(view_id).buffer).screen_size();
        let (area, sized) = laid_out_at(screen, room, gutter);
        let text_rows = usize::from(area.height);
        let text_width = usize::from(area.width).saturating_sub(gutter).max(1);

        let scroll = self.place(editor, view_id, sized.is_some(), text_width, text_rows);

        let view = editor.view(view_id);
        let text = editor.buffer(view.buffer).text();
        let hidden = hidden_lines(editor, view);
        let visible = visible_bytes(text, scroll, text_rows, &hidden);
        let syntax = paint(
            decorations.highlights(view.buffer, text, visible.clone()),
            &visible,
        );
        let styled = marks_in(editor, view, &visible);
        let (head, cursors) = cursors(text, view, editor.cursor_shape());
        let peers = Peer::all(editor, text, view_id);
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
            // Include EOF in the last line: marks can sit after its final character.
            let start = text.line_to_byte(line);
            let end = text.line_to_byte(line + 1) + usize::from(line + 1 == text.len_lines());
            let lines = start..end;
            let head_shown = !lines.contains(&head) || shows(&layout, head);
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
                // Whether the line's end cell is drawn: the cursor is on it.
                let (mut x, mut drawn) = (gutter, false);
                let tight = i == last
                    && styled.iter().filter(on_line).any(|m| {
                        m.eol && !m.eol_space && m.text.as_ref().is_some_and(|s| !s.is_empty())
                    });
                let mut end_tags = SmallVec::new();
                for cell in &cells {
                    let place = screen_position(area, x, rows.len());
                    if cursor_here(cell, (head, head_shown), &lines, cursor.is_some()) {
                        cursor = Some(place);
                    }
                    if cell.repeated || cell.inserted.is_some() {
                        self.push_not_text(&mut row, cell, &styled, view_id, place);
                        x += cell.width;
                        continue;
                    }
                    first_shown = first_shown.or(Some(cell.byte));
                    if !cell.end_of_line {
                        last_shown = Some(cell.byte);
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
                    let cell_tags = cell_tags(view, cell, &cursors, &peers, capture, &styled);
                    if cell.end_of_line && tight {
                        end_tags = cell_tags;
                    } else if !(cell.end_of_line && cell_tags.is_empty()) {
                        drawn = cell.end_of_line;
                        row.push_scaled(&cell.text, cell_tags, cell.scale);
                    }
                    x += cell.width;
                }
                if i == last {
                    let gap = x - usize::from(cells.last().is_some_and(|c| c.end_of_line));
                    let at = (view_id, area, rows.len());
                    self.push_eol_text(
                        &mut row,
                        at,
                        (gap, drawn, tight),
                        end_tags,
                        styled.iter().filter(on_line),
                    );
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
        // The view's own room is what it says it has, so the client the
        // screen size is for can tell its own changing.
        editor.view_mut(view_id).drawn(shown, room, gutter);
        rows.resize_with(text_rows, Row::default);
        Laid::new(rows, cursor, sized)
    }

    /// Adds EOL text without wrapping. Tight marks come first, at the line
    /// end, carrying its cursor/selection tags on their first grapheme.
    /// Ordinary marks follow with a separating space. `at` locates actions
    /// in the view.
    fn push_eol_text<'a>(
        &self,
        row: &mut Row,
        at: (ViewId, Rect, usize),
        (gap, mut drawn, tight): (usize, bool, bool),
        mut end_tags: SmallVec<[Tag; 2]>,
        marks: impl Iterator<Item = &'a &'a Mark> + Clone,
    ) {
        let (view, area, row_index) = at;
        let (left, mut room) = (area.x, usize::from(area.width).saturating_sub(gap));
        let screen_row = area.y + u16::try_from(row_index).unwrap_or(u16::MAX);
        let leading = marks
            .clone()
            .filter(|m| m.eol && !m.eol_space)
            .take(if tight { usize::MAX } else { 0 });
        let trailing = marks.filter(|m| m.eol && (!tight || m.eol_space));
        for mark in leading.chain(trailing) {
            let Some(text) = &mark.text else { continue };
            let mut shown = String::new();
            let mut used = 0;
            for g in mark
                .eol_space
                .then_some(" ")
                .into_iter()
                .chain(text.graphemes(true))
            {
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
                // Ordinary labels keep their unstyled separator.
                let (space, text) = shown.split_at(usize::from(mark.eol_space));
                if !std::mem::take(&mut drawn) && !space.is_empty() {
                    row.push(space, SmallVec::new());
                }
                if let Some(action) = &mark.action {
                    let ends = u16::try_from(self.text_width(&row.text())).unwrap_or(u16::MAX);
                    let place = Position {
                        col: left + ends,
                        row: screen_row,
                    };
                    self.record_action(
                        view,
                        place,
                        used - usize::from(mark.eol_space),
                        action,
                        mark.range.start,
                    );
                }
                if !text.is_empty() {
                    let tag = Tag::from(mark.style.clone());
                    if end_tags.is_empty() {
                        row.push(text, smallvec![tag]);
                    } else {
                        let first = text.graphemes(true).next().unwrap();
                        end_tags.insert(0, tag.clone());
                        row.push(first, std::mem::take(&mut end_tags));
                        if first.len() < text.len() {
                            row.push(&text[first.len()..], smallvec![tag]);
                        }
                    }
                }
            }
        }
    }

    /// Draws a cell that isn't the buffer's text where it stands: a wrapped
    /// row's indent, or a mark's text, at screen position `place`.
    fn push_not_text(
        &self,
        row: &mut Row,
        cell: &Cell,
        marks: &[&Mark],
        view: ViewId,
        place: Position,
    ) {
        if cell.repeated {
            push_repeated(row, cell, marks);
        } else {
            self.push_inserted(row, cell, view, place);
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
    /// after whitespace where it can; a line that doesn't wrap is one row,
    /// of the cells from the view's `columns` on.
    fn layout(&self, editor: &Editor, view: &View, line: usize, width: usize) -> Vec<Vec<Cell>> {
        let (cells, end) = self.line_cells(editor, view, line);
        if nowrap(editor, view, line) {
            vec![clip(cells, view.columns, width, end)]
        } else {
            wrap(cells, width, end)
        }
    }

    /// The column byte `pos` is drawn at in its line in `view`, the line as
    /// one long row: hidden text takes no room and text marks show takes
    /// theirs, as the line looks now. Where hidden text is, it's the column
    /// of what's drawn next, text a mark shows from `pos` included (a
    /// link in the reading view), where the cursor is drawn.
    pub fn drawn_column(&self, editor: &Editor, view: &View, pos: usize) -> usize {
        let text = editor.buffer(view.buffer).text();
        let pos = pos.min(text.len_bytes());
        let (cells, _) = self.line_cells(editor, view, text.byte_to_line(pos));
        let shown = cells.iter().any(|c| c.byte == pos && c.inserted.is_none());
        cells
            .iter()
            .take_while(|c| c.byte < pos || (shown && c.byte == pos && c.inserted.is_some()))
            .map(|c| c.width)
            .sum()
    }

    /// The position drawn at column `col` of `line` in `view`, the line as
    /// one long row: the text there, where a button's mark starts when `col`
    /// is on one, or where the text drawn next starts when `col` is on other
    /// text a mark shows (a table's border, say) or past the line's end.
    pub fn at_drawn_column(&self, editor: &Editor, view: &View, line: usize, col: usize) -> usize {
        let (cells, end) = self.line_cells(editor, view, line);
        let mut x = 0;
        let mut past = false;
        for cell in &cells {
            past = past || col < x + cell.width;
            if past {
                match (&cell.inserted, &cell.action) {
                    (None, _) => return cell.byte,
                    (Some(_), Some((_, start))) => return *start,
                    (Some(_), None) => {}
                }
            }
            x += cell.width;
        }
        end
    }

    /// The cells of `line` as one long row, and the byte its text ends at.
    fn line_cells(&self, editor: &Editor, view: &View, line: usize) -> (Vec<Cell>, usize) {
        let buffer = editor.buffer(view.buffer);
        let text = buffer.text();
        let start = text.line_to_byte(line);
        let content: Cow<str> = line_content(text, line).into();
        let end = start + content.len();

        let concealed = concealed(buffer, view, line, start..end, editor);
        // Text from marks, shown before the character at its position.
        let mut inserted: Vec<(&Mark, &str)> = buffer
            .marks_for(view.id)
            .filter(|m| !m.eol && !m.overlay && (start..=end).contains(&m.range.start))
            .filter(|m| !m.conceal || !reveals(text, view, m, line, editor))
            .filter_map(|m| Some((m, m.text.as_deref()?)))
            .collect();
        inserted.sort_by_key(|(m, _)| m.range.start);
        let mut inserted = inserted.into_iter().peekable();
        // Text scaled up by marks: each byte at the largest scale over it.
        let scaled: Vec<&Mark> = buffer
            .marks_for(view.id)
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
                        repeated: false,
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
                let w = width_at(&self.measure, grapheme, x, buffer.tab_width());
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
                repeated: false,
            });
            x += w;
        }
        (cells, end)
    }

    /// How many columns `view` is scrolled sideways, `width` wide: as it
    /// was, or as little moved from that as shows the primary cursor, when
    /// its line doesn't wrap.
    fn columns_for(&self, editor: &Editor, view: &View, width: usize) -> usize {
        let text = editor.buffer(view.buffer).text();
        let head = cursor_byte(text, view.selection.primary(), editor.cursor_shape());
        let line = text.byte_to_line(head);
        if !nowrap(editor, view, line) {
            return view.columns;
        }
        let (cells, _) = self.line_cells(editor, view, line);
        let x: usize = cells
            .iter()
            .take_while(|c| c.byte < head)
            .map(|c| c.width)
            .sum();
        // A cell of room on either side, where `clip` marks what's out of
        // sight, so the cursor never sits under the mark.
        if x < view.columns || (x == view.columns && x > 0) {
            x.saturating_sub(1)
        } else if x + 1 >= view.columns + width {
            (x + 2).saturating_sub(width)
        } else {
            view.columns
        }
    }

    /// Which row of its line `pos` is on.
    fn row_of(&self, editor: &Editor, view: &View, line: usize, pos: usize, width: usize) -> usize {
        let rows = self.layout(editor, view, line, width);
        rows.iter()
            .position(|cells| cells.last().is_some_and(|c| c.byte >= pos))
            .unwrap_or(rows.len() - 1)
    }

    /// Scrolls `view_id` as `scroll_for` says, down and sideways, and gives
    /// back where it starts.
    fn place(
        &self,
        editor: &mut Editor,
        view_id: ViewId,
        screen: bool,
        width: usize,
        height: usize,
    ) -> Scroll {
        let (scroll, columns) =
            self.scroll_for(editor, editor.view(view_id), screen, width, height);
        let laid = editor.view_mut(view_id);
        (laid.scroll, laid.columns) = (scroll, columns);
        scroll
    }

    /// Where `view` starts, laid out `width` by `height`: at the screen, its
    /// buffer's last lines, when it's laid out at its buffer's screen size
    /// (`screen`), else keeping its primary cursor on screen; within the
    /// lines it's narrowed to, if it is. And how many columns it's scrolled
    /// sideways (see `columns_for`).
    fn scroll_for(
        &self,
        editor: &Editor,
        view: &View,
        screen: bool,
        width: usize,
        height: usize,
    ) -> (Scroll, usize) {
        let lines = editor.buffer(view.buffer).text().len_lines();
        let scroll = if screen {
            Scroll {
                line: lines.saturating_sub(height),
                row: 0,
            }
        } else {
            self.scroll_to_cursor(editor, view, width, height)
        };
        let columns = self.columns_for(editor, view, width);
        (within_lines(view, scroll, height, lines), columns)
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

    /// `text` if it fits in `room` cells, or as much of its start as fits
    /// before an ellipsis, so it's plain that it goes on.
    fn keep_start(&self, text: &str, room: usize) -> String {
        if self.text_width(text) <= room {
            return text.to_owned();
        }
        let mut kept = String::new();
        let mut used = 0;
        for g in text.graphemes(true) {
            let w = self.measure.width(g);
            if used + w + 1 > room {
                break;
            }
            used += w;
            kept.push_str(g);
        }
        if room > 0 {
            kept.push('…');
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
            Some(message) => span(&status_message(message), Tag::MESSAGE),
            None => span(
                &buffer.path().map_or_else(
                    || buffer.title(),
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
    /// Status line segments this wide or narrower, like the mode, are left whole
    /// while longer ones give way.
    const SHORT: usize = 12;

    /// Makes `spans` `excess` cells narrower, as far as their long ones
    /// (wider than [`Self::SHORT`], and not a message, which is read from
    /// its start) go: the widest keeps only its end, down to the next
    /// widest, so they give way in turn.
    fn give_way(&self, spans: &mut [Span], mut excess: usize) {
        while excess > 0 {
            let mut sizes: Vec<(usize, usize)> = (spans.iter().enumerate())
                .map(|(i, s)| (i, self.text_width(&s.text)))
                .filter(|&(i, w)| w > Self::SHORT && !spans[i].tags.contains(&Tag::MESSAGE))
                .collect();
            sizes.sort_by_key(|&(_, w)| std::cmp::Reverse(w));
            let Some(&(i, w)) = sizes.first() else {
                return;
            };
            let next = sizes.get(1).map_or(Self::SHORT, |&(_, w)| w);
            let room = w
                .saturating_sub(excess)
                .max(next)
                .min(w - 1)
                .max(Self::SHORT);
            spans[i].text = self.keep_end(&spans[i].text, room);
            excess = excess.saturating_sub(w - self.text_width(&spans[i].text));
        }
    }

    /// Lays out a status line across `width` cells, on screen row `y`. If
    /// it doesn't fit, the widest segments keep only their ends.
    fn status_row(&self, status: &StatusLine, width: usize, y: u16) -> Row {
        let widths = |spans: &[Span]| {
            spans
                .iter()
                .map(|s| self.text_width(&s.text))
                .sum::<usize>()
        };
        let mut left = status.left.clone();
        let mut right = status.right.clone();
        // Leave at least one space between the two sides. While it doesn't
        // fit, long segments keep only their ends: the right side's first
        // (what language, style and machine), then the left's, so the file
        // name and a message stay longest; short ones, like the mode, stay
        // whole.
        let over = |left: &[Span], right: &[Span]| {
            (widths(left) + widths(right) + 1).saturating_sub(width)
        };
        let excess = over(&left, &right);
        self.give_way(&mut right, excess);
        let excess = over(&left, &right);
        self.give_way(&mut left, excess);
        // Still too wide, the last segment on the left gives way further.
        let excess = over(&left, &right);
        if let Some(last) =
            (left.last_mut()).filter(|last| excess > 0 && !last.tags.contains(&Tag::MESSAGE))
        {
            let room = self.text_width(&last.text).saturating_sub(excess);
            last.text = self.keep_end(&last.text, room);
        }
        let padding = width.saturating_sub(widths(&left) + widths(&right));

        let gap = Span::new(" ".repeat(padding), smallvec![Tag::STATUS]);
        let action = |i: usize| status.actions.get(i).cloned().flatten();
        let spans = (left.iter().enumerate().map(|(i, s)| (s, action(i))))
            .chain([(&gap, None)])
            .chain((right.iter().enumerate()).map(|(i, s)| (s, action(left.len() + i))));
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
/// Without `line_numbers`, there's no gutter.
fn gutter_width(editor: &Editor, view: &View, line_numbers: bool) -> (usize, bool) {
    if !line_numbers {
        return (0, false);
    }
    let buffer = editor.buffer(view.buffer);
    let numbers = buffer.text().len_lines().to_string().len() + 1;
    let signs = buffer.marks_for(view.id).any(|m| m.sign.is_some());
    (numbers + if signs { SIGN_WIDTH } else { 0 }, signs)
}

/// Another client's selections and cursors in a view, and the tags they're
/// drawn with: `ui.selection.peer.N` and `ui.cursor.peer.N` for its color
/// N, which fall back to `ui.selection` and `ui.cursor`.
struct Peer {
    selection: Selection,
    cursors: Vec<usize>,
    selection_tag: Tag,
    cursor_tag: Tag,
}

impl Peer {
    /// Every other attached client's view `view`, of `text`.
    fn all(editor: &Editor, text: &Rope, view: ViewId) -> Vec<Self> {
        editor
            .peers(view)
            .map(|(client, seen)| {
                Self::new(text, client, seen, editor.cursor_shape_of(client.mode()))
            })
            .collect()
    }

    /// How another client, `client`, sees `view`.
    fn new(text: &Rope, client: &ClientState, view: &View, shape: CursorShape) -> Self {
        let color = client.color();
        Self {
            selection: view.selection.clone(),
            cursors: view
                .selection
                .ranges()
                .iter()
                .map(|&range| cursor_byte(text, range, shape))
                .collect(),
            selection_tag: Tag::from(format!("ui.selection.peer.{color}").as_str()),
            cursor_tag: Tag::from(format!("ui.cursor.peer.{color}").as_str()),
        }
    }
}

/// The tags for one cell, bottom first: its syntax capture, the marks on it,
/// then other clients' selections and cursors, then the client's own, then
/// marks drawn above them.
fn cell_tags(
    view: &View,
    cell: &Cell,
    cursors: &[usize],
    peers: &[Peer],
    capture: Option<Arc<str>>,
    marks: &[&Mark],
) -> SmallVec<[Tag; 2]> {
    // A mark that shows text in place of what it hides styles that text,
    // so text it shows as written (the cursor inside) looks as it is.
    let on_cell = |above: bool| {
        marks
            .iter()
            .filter(move |m| {
                !cell.end_of_line
                    && !m.line
                    && m.above == above
                    && (!m.conceal || m.text.is_none())
                    && m.range.contains(&cell.byte)
            })
            .map(|m| Tag::from(m.style.clone()))
    };
    let plain = marks
        .iter()
        .any(|m| m.plain && m.range.contains(&cell.byte));
    let mut tags: SmallVec<[Tag; 2]> = capture
        .filter(|_| !plain)
        .map(Tag::from)
        .into_iter()
        .collect();
    tags.extend(on_cell(false));
    for peer in peers {
        tags.extend(selection_tags(
            &peer.selection,
            cell,
            &peer.cursors,
            (&peer.selection_tag, &peer.cursor_tag),
        ));
    }
    tags.extend(selection_tags(
        &view.selection,
        cell,
        cursors,
        (&Tag::SELECTION, &Tag::CURSOR),
    ));
    tags.extend(on_cell(true));
    tags
}

/// Selection and cursor tags for one cell, as `tags` (for the selection, for
/// the cursors).
fn selection_tags(
    selection: &Selection,
    cell: &Cell,
    cursors: &[usize],
    tags: (&Tag, &Tag),
) -> SmallVec<[Tag; 2]> {
    let mut out = SmallVec::new();
    for range in selection.ranges() {
        if !cell.end_of_line && range.from() <= cell.byte && cell.byte < range.to() {
            out.push(tags.0.clone());
        }
    }
    if cursors.contains(&cell.byte) {
        out.push(tags.1.clone());
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

/// A message as the status line shows it: its first line, with "…" when
/// there's more, like an error's stack trace. Its lines would otherwise
/// all be drawn on the one row.
pub(crate) fn status_message(message: &str) -> Cow<'_, str> {
    match message.split_once('\n') {
        Some((first, _)) => Cow::Owned(format!("{} …", first.trim_end())),
        None => Cow::Borrowed(message),
    }
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
fn tab_label(editor: &Editor, i: usize, tab: &crate::TabView) -> String {
    let name = tab
        .name()
        .map_or_else(|| tab_title(editor, tab.active()), str::to_owned);
    format!(" {} {name} ", i + 1)
}

/// What a tab is called when it has no name: what its active pane shows
/// (see [`crate::Buffer::title`]).
fn tab_title(editor: &Editor, pane: ViewId) -> String {
    editor.buffer(editor.view(pane).buffer).title()
}

/// Where a view in `room` with a `gutter` that wide lays its text out: in
/// `room`, or from its top left at `screen`'s size when its buffer has one
/// other than the room's, with that size and a note saying why it doesn't
/// fit.
fn laid_out_at(screen: Option<&ScreenSize>, room: Rect, gutter: usize) -> (Rect, Option<Sized>) {
    let room_width = usize::from(room.width).saturating_sub(gutter).max(1);
    let Some(s) = screen.filter(|s| {
        (usize::from(s.rows), usize::from(s.cols)) != (usize::from(room.height), room_width)
    }) else {
        return (room, None);
    };
    let area = Rect {
        width: u16::try_from(gutter).unwrap_or(0).saturating_add(s.cols),
        height: s.rows,
        ..room
    };
    let note = s
        .note
        .as_deref()
        .map_or_else(|| format!("{}×{}", s.cols, s.rows), str::to_owned);
    let size = Size {
        width: area.width,
        height: area.height,
    };
    let sized = Sized {
        size,
        note,
        keep: s.cursor_row,
    };
    (area, Some(sized))
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

impl Rect {
    /// Whether it and `other` share a cell.
    pub fn overlaps(self, other: Rect) -> bool {
        self.x < other.x + other.width
            && other.x < self.x + self.width
            && self.y < other.y + other.height
            && other.y < self.y + self.height
    }

    /// It with the one-cell border a client draws around a floating view.
    #[must_use]
    pub fn bordered(self) -> Rect {
        Rect {
            x: self.x.saturating_sub(1),
            y: self.y.saturating_sub(1),
            width: self.width + 2,
            height: self.height + 2,
        }
    }
}

/// Where panels go: each one takes its width from its side of `screen`,
/// plus a column for the line between it and the main view, and a row for
/// its title if it has one. Returns the main view's area and, for each
/// panel shown, its view, where its rows go and its role.
fn layout_panels(panels: &[Panel], screen: Rect) -> (Rect, Vec<(ViewId, Rect, Role)>) {
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
        let role = Role::Panel {
            separator,
            title: panel.options.title.as_deref().map(str::to_owned),
        };
        placed.push((panel.view, rect, role));
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
    // Whatever the position, the box stays on screen. With no cursor on
    // screen, a cursor float centers.
    let (room_x, room_y) = (
        area.width.saturating_sub(outer_width),
        area.height.saturating_sub(outer_height),
    );
    let x = match (options.x, options.anchor) {
        (Some(x), _) => x.resolve(area.width),
        (None, Anchor::Left | Anchor::TopLeft | Anchor::BottomLeft) => 0,
        (None, Anchor::Right | Anchor::TopRight | Anchor::BottomRight) => room_x,
        (None, _) => room_x / 2,
    }
    .min(room_x);
    let y = match (options.y, options.anchor) {
        (Some(y), _) => y.resolve(area.height),
        (None, Anchor::Top | Anchor::TopLeft | Anchor::TopRight) => 0,
        (None, Anchor::Bottom | Anchor::BottomLeft | Anchor::BottomRight) => room_y,
        (None, _) => room_y / 2,
    }
    .min(room_y);
    inside(area.x + x, area.y + y)
}

/// The marks `view` draws that touch `visible`.
fn marks_in<'a>(editor: &'a Editor, view: &View, visible: &Range<usize>) -> Vec<&'a Mark> {
    editor
        .buffer(view.buffer)
        .marks_for(view.id)
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

/// Whether the line laid out as `layout` draws the text at `byte`.
fn shows(layout: &[Vec<Cell>], byte: usize) -> bool {
    layout
        .iter()
        .flatten()
        .any(|c| c.byte == byte && c.inserted.is_none() && !c.repeated)
}

/// Whether the cursor at `head` goes on `cell` of the line `lines`: its own
/// cell, or when it's on hidden text (a heading's `#`, `shown` false), the
/// first cell drawn from there on, text a mark shows (an empty table cell's
/// padding) too, unless it's `placed` already.
fn cursor_here(
    cell: &Cell,
    (head, shown): (usize, bool),
    lines: &Range<usize>,
    placed: bool,
) -> bool {
    let first_after = |from: usize| !placed && cell.byte >= from && lines.contains(&head);
    match (&cell.inserted, cell.repeated) {
        (_, true) => false,
        (Some(_), false) => !shown && first_after(head),
        (None, false) => cell.byte == head || first_after(head + 1),
    }
}

/// The lines hidden in `view`: each fold's lines after its first, unless a
/// cursor is in them, and those outside the lines it's narrowed to.
pub(crate) fn hidden_lines(editor: &Editor, view: &View) -> Vec<Range<usize>> {
    let buffer = editor.buffer(view.buffer);
    let text = buffer.text();
    let cursors: Vec<usize> = cursor_lines(text, view).collect();
    let mut hidden: Vec<Range<usize>> = buffer
        .marks_for(view.id)
        .filter(|m| m.fold)
        .filter_map(|m| {
            let first = text.byte_to_line(m.range.start.min(text.len_bytes()));
            let hidden = first + 1..last_line(text, &m.range) + 1;
            let open = cursors
                .iter()
                .any(|c| hidden.contains(c) || (m.peek && *c == first));
            (!hidden.is_empty() && !open).then_some(hidden)
        })
        .collect();
    if let Some(lines) = &view.lines {
        let all = text.len_lines();
        hidden.extend(
            [0..lines.start.min(all), lines.end.min(all)..all]
                .into_iter()
                .filter(|r| !r.is_empty()),
        );
    }
    if let Some(filter) = &view.filter {
        let shown = view.lines.clone().unwrap_or(0..text.len_lines());
        hidden.extend(filter.hidden(text, shown, &cursors));
    }
    hidden
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
        .marks_for(view.id)
        .filter(move |m| !m.lines.is_empty() && last_line(text, &m.range) == line)
        .flat_map(|m| m.lines.iter().map(move |l| (m, l)))
}

/// Whether concealing mark `mark` on `line` shows its text now, as its
/// `reveal` says, `Auto` and `Typing` as `editor` has them.
fn reveals(text: &Rope, view: &View, mark: &Mark, line: usize, editor: &Editor) -> bool {
    match editor.resolve_reveal(mark.reveal) {
        Reveal::Line => cursor_lines(text, view).any(|l| l == line),
        Reveal::Cursor => view
            .selection
            .ranges()
            .iter()
            .any(|r| mark.range.start < r.head && r.head < mark.range.end),
        Reveal::Never | Reveal::Auto | Reveal::Typing => false,
    }
}

/// The marks hiding parts of `line` (its `bytes`) now.
fn concealed<'a>(
    buffer: &'a crate::Buffer,
    view: &View,
    line: usize,
    bytes: Range<usize>,
    editor: &Editor,
) -> Vec<&'a Mark> {
    buffer
        .marks_for(view.id)
        .filter(|m| m.conceal && m.range.start < bytes.end && m.range.end > bytes.start)
        .filter(|m| !reveals(buffer.text(), view, m, line, editor))
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

/// `scroll` within the lines `view` is narrowed to, if it is: the first of
/// them, or scrolled past the last, as many lines above it as `rows` fit;
/// never past the last of the buffer's `all` lines.
fn within_lines(view: &View, scroll: Scroll, rows: usize, all: usize) -> Scroll {
    let lines = view
        .lines
        .as_ref()
        .map(|l| l.start.min(all.saturating_sub(1))..l.end.min(all));
    match &lines {
        Some(lines) if scroll.line < lines.start => Scroll {
            line: lines.start,
            row: 0,
        },
        Some(lines) if scroll.line >= lines.end => Scroll {
            line: lines.end.saturating_sub(rows).max(lines.start),
            row: 0,
        },
        _ => scroll,
    }
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

/// Whether a mark says `line` of `view`'s buffer doesn't wrap.
fn nowrap(editor: &Editor, view: &View, line: usize) -> bool {
    let buffer = editor.buffer(view.buffer);
    let text = buffer.text();
    buffer.marks_for(view.id).any(|m| {
        m.nowrap
            && text.byte_to_line(m.range.start.min(text.len_bytes())) <= line
            && line <= last_line(text, &m.range)
    })
}

/// The cells of a line that doesn't wrap that show `width` columns from
/// column `from`, with its end after them when that shows too.
fn clip(cells: Vec<Cell>, from: usize, width: usize, end: usize) -> Vec<Cell> {
    let mut row = Vec::new();
    let mut x = 0;
    for cell in cells {
        let w = cell.width;
        if x >= from && x + w <= from + width {
            row.push(cell);
        }
        x += w;
    }
    if (from..from + width).contains(&x) {
        row.push(end_cell(end));
    }
    // What's out of sight at either edge is marked there, as a wide table's
    // columns past the right edge are.
    if x > from + width && row.len() > 1 {
        let last = row.len() - 1;
        row[last] = clipped("›", row[last].byte);
    }
    if from > 0 && row.len() > 1 {
        row[0] = clipped("‹", row[0].byte);
    }
    row
}

/// A cell at a no-wrap line's edge, at byte `byte`, saying more of it is
/// out of sight that way.
fn clipped(mark: &str, byte: usize) -> Cell {
    Cell {
        byte,
        text: mark.to_owned(),
        width: 1,
        end_of_line: false,
        inserted: Some(Arc::from("fold")),
        action: None,
        scale: 1,
        repeated: false,
    }
}

/// The cell for the end of a line, at byte `end`, where a cursor can sit
/// after its text.
fn end_cell(end: usize) -> Cell {
    Cell {
        byte: end,
        text: " ".to_owned(),
        width: 1,
        end_of_line: true,
        inserted: None,
        action: None,
        scale: 1,
        repeated: false,
    }
}

/// Draws `cell`, a wrapped row's indent (see [`Cell::repeated`]): what
/// `marks` draw there, a transcript's bar say, without the cursor or a
/// selection.
fn push_repeated(row: &mut Row, cell: &Cell, marks: &[&Mark]) {
    if let Some((text, tag)) = Overlay::default().over(marks, cell) {
        row.push_scaled(&text, smallvec![tag], cell.scale);
        return;
    }
    let tags = marks
        .iter()
        .filter(|m| !m.line && m.range.contains(&cell.byte))
        .map(|m| Tag::from(m.style.clone()))
        .collect();
    row.push_scaled(&cell.text, tags, cell.scale);
}

/// A line's leading whitespace, as copies to start its wrapped rows with
/// (see [`Cell::repeated`]); none when the line is only whitespace or the
/// indent would take more than half of `width`.
fn wrap_indent(cells: &[Cell], width: usize) -> Vec<Cell> {
    let leading: Vec<Cell> = cells
        .iter()
        .take_while(|c| c.is_space())
        .map(|c| Cell {
            repeated: true,
            ..c.clone()
        })
        .collect();
    let indent: usize = leading.iter().map(|c| c.width).sum();
    if leading.len() == cells.len() || indent * 2 > width {
        return Vec::new();
    }
    leading
}

/// A line's `cells` in rows `width` cells wide, breaking after whitespace
/// where it can, with a cell for the end of the line (byte `end`) where a
/// cursor can sit after it, if there's room. Rows after the first start
/// with the line's indent, so wrapped text lines up under the text above.
fn wrap(cells: Vec<Cell>, width: usize, end: usize) -> Vec<Vec<Cell>> {
    let indent = wrap_indent(&cells, width);
    let indent_width: usize = indent.iter().map(|c| c.width).sum();
    let mut rows = vec![Vec::new()];
    let mut x = 0;
    // Where the current row may break: just after its last whitespace.
    let mut last_break = 0;
    for cell in cells {
        let row = rows.last_mut().expect("at least one row");
        if x + cell.width > width && row.iter().any(|c: &Cell| !c.repeated) {
            let carried = if last_break > 0 && last_break < row.len() {
                row.split_off(last_break)
            } else {
                Vec::new()
            };
            x = indent_width + carried.iter().map(|c: &Cell| c.width).sum::<usize>();
            let mut next = indent.clone();
            next.extend(carried);
            rows.push(next);
            last_break = 0;
        }
        let row = rows.last_mut().expect("at least one row");
        let breaks = cell.is_space();
        x += cell.width;
        row.push(cell);
        if breaks {
            last_break = row.len();
        }
    }
    if x < width {
        rows.last_mut()
            .expect("at least one row")
            .push(end_cell(end));
    }
    rows
}
