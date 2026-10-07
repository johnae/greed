//! The editor's authoritative state: buffers, views, the current mode and
//! the keymap. Everything here is plain Rust; the Luau host drives it.

use std::collections::{BTreeMap, HashMap};
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

use greed_text::{
    Assoc, Author, ChangeSet, ClientId, Range, Replica, Selection, Transaction, TxId, TxMeta,
};

use crate::filetypes::FileTypes;
use crate::keymap::{Key, KeyCode, Keymap, Mods, Resolution};
use crate::theme::Theme;
use crate::{Buffer, BufferId, Error, GroupState, Mark, TrackId};

mod panes;
pub use panes::{Tab, TabId};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ViewId(pub u32);

/// `Buffer::undo` or `Buffer::redo`.
type HistoryStep = fn(&mut Buffer, TxId, Author, &Selection) -> Result<Option<Selection>, Error>;

/// A buffer shown on screen, with its own selection and scroll position.
#[derive(Debug, Clone)]
pub struct View {
    pub buffer: BufferId,
    pub selection: Selection,
    pub scroll: Scroll,
    /// The bytes on screen when the view was last drawn; None before that.
    pub visible: Option<std::ops::Range<usize>>,
    /// The rows and columns of text it had room for when last drawn.
    pub size: Option<(u16, u16)>,
    /// Where it was last drawn, gutter included.
    pub area: Option<crate::render::Rect>,
}

impl View {
    /// Notes what drawing it showed: the bytes on screen, where it went, and
    /// how wide its text was.
    pub(crate) fn drawn(
        &mut self,
        shown: std::ops::Range<usize>,
        area: crate::render::Rect,
        text_width: usize,
    ) {
        self.visible = Some(shown);
        self.size = Some((area.height, u16::try_from(text_width).unwrap_or(u16::MAX)));
        self.area = Some(area);
    }
}

/// The first thing a view shows: a buffer line, and how many of its wrapped
/// rows are scrolled past.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Scroll {
    pub line: usize,
    pub row: usize,
}

/// A size given in cells, or as a percentage of the screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Extent {
    Cells(u16),
    Percent(u16),
}

impl Extent {
    /// The size in cells, out of `total`.
    pub fn resolve(self, total: u16) -> u16 {
        match self {
            Extent::Cells(n) => n.min(total),
            Extent::Percent(p) => {
                u16::try_from(u32::from(total) * u32::from(p.min(100)) / 100).unwrap_or(total)
            }
        }
    }
}

/// Where on the screen a floating view goes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Anchor {
    Center,
    Top,
    Bottom,
    /// Just below the focused view's cursor, or above it when there's no
    /// room below, like a completion menu.
    Cursor,
    /// Just above the focused view's cursor, or below it when there's no
    /// room above, like signature help, so a completion menu fits below.
    AboveCursor,
}

/// How a floating view is shown.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FloatOptions {
    pub title: Option<Arc<str>>,
    pub width: Extent,
    pub height: Extent,
    pub anchor: Anchor,
    /// Whether the view takes focus when it's shown.
    pub focus: bool,
    /// Where the outside of the border goes, from the left and top of the
    /// screen. Either one left out follows `anchor` (or centers, across).
    pub x: Option<Extent>,
    /// See `x`.
    pub y: Option<Extent>,
    /// Whether it belongs to the tab it opened in, shown only with that tab
    /// and closed with it, like a floating terminal. Otherwise it floats
    /// over every tab, like a picker.
    pub tab: bool,
}

/// A view floating over the main one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Float {
    pub view: ViewId,
    pub options: FloatOptions,
    /// The view that had focus when this one opened, which gets it back
    /// when this one closes.
    pub(crate) return_to: ViewId,
    /// The tab it belongs to, if it belongs to one.
    pub(crate) tab: Option<TabId>,
}

/// Which edge of the screen a panel is on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Side {
    Left,
    Right,
}

/// How a panel is shown.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PanelOptions {
    pub side: Side,
    pub width: Extent,
    /// Shown on the panel's first row.
    pub title: Option<Arc<str>>,
    /// Whether the view takes focus when it's shown.
    pub focus: bool,
}

/// A view beside the main one, which gives up the room.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Panel {
    pub view: ViewId,
    pub options: PanelOptions,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ProjectId(pub u32);

/// A folder being worked on: its tabs of panes, and panels. Buffers opened
/// while it's current belong to it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Project {
    id: ProjectId,
    root: PathBuf,
    /// Never empty.
    tabs: Vec<Tab>,
    /// Which of `tabs` is shown.
    tab: usize,
    /// Views beside the panes, outermost first on each side.
    panels: Vec<Panel>,
}

impl Project {
    pub fn id(&self) -> ProjectId {
        self.id
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// The active pane of the shown tab: where files open, and what the
    /// status line describes.
    pub fn main(&self) -> ViewId {
        self.tabs[self.tab].active()
    }

    pub fn tabs(&self) -> &[Tab] {
        &self.tabs
    }

    /// Every pane of every tab, then the panels.
    pub fn views(&self) -> impl Iterator<Item = ViewId> + '_ {
        self.tabs
            .iter()
            .flat_map(Tab::panes)
            .chain(self.panels.iter().map(|p| p.view))
    }
}

/// Another session for a client to go to: a session by name, or the session
/// of the project a path is in (opening the path), started if it isn't
/// running.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct SwitchTo {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
}

/// A notification for the user's desktop, which the attached client shows
/// its own way: a terminal's notification escape, or nothing.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Notice {
    pub title: String,
    pub body: String,
}

/// How the cursor looks.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum CursorShape {
    #[default]
    Block,
    Bar,
    Underline,
}

/// How line numbers count.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum LineNumbers {
    /// Each line's own number.
    #[default]
    Absolute,
    /// How far each line is from the cursor's, 0 on the cursor's own.
    Relative,
    /// As `Relative`, with the cursor's line showing its own number.
    Hybrid,
}

impl LineNumbers {
    /// The number shown by line `line` (0-based) with the cursor on line
    /// `cursor`.
    pub fn number(self, line: usize, cursor: usize) -> usize {
        match self {
            LineNumbers::Absolute => line + 1,
            LineNumbers::Hybrid if line == cursor => line + 1,
            LineNumbers::Relative | LineNumbers::Hybrid => line.abs_diff(cursor),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyOutcome {
    /// Run this command. `keys` is the sequence that triggered it, and
    /// `count` the number typed before it, in modes with counts.
    Command {
        name: Arc<str>,
        keys: Vec<Key>,
        count: Option<u32>,
    },
    /// Waiting for more keys.
    Pending,
    /// Nothing is bound to this sequence.
    Unbound(Vec<Key>),
}

#[derive(Debug)]
pub struct Editor {
    client: ClientId,
    replica: Replica,
    buffers: BTreeMap<BufferId, Buffer>,
    views: BTreeMap<ViewId, View>,
    /// Open projects, each with its own main view and panels. Empty until the
    /// first view opens.
    projects: Vec<Project>,
    /// Which of `projects` is shown.
    current: usize,
    /// The project each buffer was opened in.
    buffer_projects: HashMap<BufferId, ProjectId>,
    /// Floating views, bottom first.
    floats: Vec<Float>,
    focus: ViewId,
    next_id: u32,
    mode: Arc<str>,
    keymap: Keymap,
    pending: Vec<Key>,
    /// A count typed before the pending keys.
    count: Option<u32>,
    /// Single keys bound for the next key press only, over every layer;
    /// any other key drops them and goes through the keymap as usual.
    overlay: Option<HashMap<Key, Arc<str>>>,
    messages: Vec<String>,
    /// Edits made while a group is open become one undo step.
    undo_group: Option<u64>,
    next_group: u64,
    /// Why edits are being made, e.g. the command running, when the edit
    /// itself doesn't say.
    cause: Option<Arc<str>>,
    quit_requested: bool,
    /// The attached client asked to leave, with the editor running on.
    detach_requested: bool,
    /// Where the attached client was asked to go instead of this session.
    switch_requested: Option<SwitchTo>,
    /// Copied text, oldest first. Each entry holds one piece per selection.
    clipboard: Vec<Vec<String>>,
    /// The latest copy, until the client has been told.
    copied: Option<String>,
    /// Notifications for the attached client, until it has been told.
    notices: Vec<Notice>,
    /// The cursor shape of each mode; modes not listed get a block.
    cursor_shapes: HashMap<Arc<str>, CursorShape>,
    /// How line numbers count, where buffers show them.
    line_numbers: LineNumbers,
    file_types: FileTypes,
    theme: Arc<Theme>,
    /// The menus for a window's menu bar, as plugins set them.
    menus: Vec<crate::render::Menu>,
    /// Images marks can show.
    images: crate::image::Images,
    /// How many pixels wide and high a cell is on the client's screen, for
    /// sizing images.
    cell_size: (u16, u16),
}

impl Editor {
    pub fn new(client: ClientId) -> Self {
        Self {
            client,
            replica: Replica::new(client.0),
            buffers: BTreeMap::new(),
            views: BTreeMap::new(),
            projects: Vec::new(),
            current: 0,
            buffer_projects: HashMap::new(),
            floats: Vec::new(),
            focus: ViewId(0),
            next_id: 1,
            mode: "normal".into(),
            keymap: Keymap::default(),
            pending: Vec::new(),
            count: None,
            overlay: None,
            messages: Vec::new(),
            undo_group: None,
            next_group: 0,
            cause: None,
            quit_requested: false,
            detach_requested: false,
            switch_requested: None,
            clipboard: Vec::new(),
            copied: None,
            notices: Vec::new(),
            cursor_shapes: HashMap::new(),
            line_numbers: LineNumbers::default(),
            file_types: FileTypes::bundled(),
            theme: Arc::default(),
            menus: Vec::new(),
            images: crate::image::Images::default(),
            cell_size: (8, 16),
        }
    }

    pub fn client(&self) -> ClientId {
        self.client
    }

    /// Opens a buffer in a new view and focuses it. The first view opened
    /// becomes the main view of the first project, rooted in the current
    /// directory.
    pub fn open(&mut self, kind: &str, text: &str, path: Option<PathBuf>) -> (BufferId, ViewId) {
        let id = BufferId(self.next_id());
        let mut buffer = Buffer::new(id, kind, text);
        if let Some(path) = path {
            let path = file_path(&path).unwrap_or(path);
            buffer.set_detected(self.file_types.detect(&path));
            buffer = buffer.with_path(path);
        }
        let view = self.add_view(id, Selection::point(0));
        if self.projects.is_empty() {
            let root = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
            self.add_project(root, view);
        }
        self.insert_buffer(buffer);
        (id, view)
    }

    /// Creates a buffer without showing it.
    pub fn create_buffer(&mut self, kind: &str, text: &str) -> BufferId {
        let id = BufferId(self.next_id());
        self.insert_buffer(Buffer::new(id, kind, text));
        id
    }

    /// Adds `buffer`, belonging to the current project.
    fn insert_buffer(&mut self, buffer: Buffer) {
        if let Some(project) = self.projects.get(self.current) {
            self.buffer_projects.insert(buffer.id(), project.id);
        }
        self.buffers.insert(buffer.id(), buffer);
    }

    fn add_project(&mut self, root: PathBuf, main: ViewId) -> ProjectId {
        let id = ProjectId(self.next_id());
        let tab = Tab::new(TabId(self.next_id()), main);
        self.projects.push(Project {
            id,
            root,
            tabs: vec![tab],
            tab: 0,
            panels: Vec::new(),
        });
        self.current = self.projects.len() - 1;
        id
    }

    /// Opens a project at `root` with an empty main view, and shows it.
    pub fn open_project(&mut self, root: PathBuf) -> ProjectId {
        let id = BufferId(self.next_id());
        let view = self.add_view(id, Selection::point(0));
        let project = self.add_project(root, view);
        self.insert_buffer(Buffer::new(id, "file", ""));
        project
    }

    /// Shows the project `id`. Returns false if there is no such project.
    pub fn switch_project(&mut self, id: ProjectId) -> bool {
        let Some(index) = self.projects.iter().position(|p| p.id == id) else {
            return false;
        };
        self.current = index;
        self.focus = self.projects[index].main();
        true
    }

    /// Closes project `id`: its views, and the buffers opened in it. The
    /// last project can't be closed; returns false for it.
    pub fn close_project(&mut self, id: ProjectId) -> bool {
        let Some(index) = self.projects.iter().position(|p| p.id == id) else {
            return false;
        };
        if self.projects.len() == 1 {
            return false;
        }
        let project = self.projects.remove(index);
        for view in project.views() {
            self.views.remove(&view);
        }
        let owned: Vec<BufferId> = self
            .buffer_projects
            .iter()
            .filter(|(_, owner)| **owner == id)
            .map(|(buffer, _)| *buffer)
            .collect();
        for buffer in owned {
            if !self.views.values().any(|v| v.buffer == buffer) {
                self.buffers.remove(&buffer);
                self.buffer_projects.remove(&buffer);
            }
        }
        // The same project stays current unless it was the one closed; then
        // the one after it takes over, or the one before at the end.
        if index < self.current {
            self.current -= 1;
        }
        self.current = self.current.min(self.projects.len() - 1);
        self.focus = self.projects[self.current].main();
        true
    }

    /// Open projects, in the order they were opened.
    pub fn projects(&self) -> &[Project] {
        &self.projects
    }

    /// The project shown. Panics before the first view opens.
    pub fn current_project(&self) -> &Project {
        &self.projects[self.current]
    }

    fn current_project_mut(&mut self) -> &mut Project {
        &mut self.projects[self.current]
    }

    /// The project `buffer` was opened in.
    pub fn buffer_project(&self, buffer: BufferId) -> Option<ProjectId> {
        self.buffer_projects.get(&buffer).copied()
    }

    /// Makes `buffer` read-only, so only plugins can change it, or editable.
    pub fn set_readonly(&mut self, buffer: BufferId, readonly: bool) {
        if let Some(b) = self.buffers.get_mut(&buffer) {
            b.set_readonly(readonly);
        }
    }

    /// Shows or hides line numbers beside `buffer` in the main view.
    pub fn set_line_numbers(&mut self, buffer: BufferId, on: bool) {
        if let Some(b) = self.buffers.get_mut(&buffer) {
            b.set_line_numbers(on);
        }
    }

    /// Stops keeping `buffer`'s undo history (see [`Buffer::forget_history`]).
    pub fn forget_history(&mut self, buffer: BufferId) {
        if let Some(b) = self.buffers.get_mut(&buffer) {
            b.forget_history();
        }
    }

    /// Keeps `buffer` open while nothing shows it, like a terminal you'll
    /// come back to, or lets it go then again (right away if nothing shows
    /// it now).
    pub fn set_kept(&mut self, buffer: BufferId, kept: bool) {
        if let Some(b) = self.buffers.get_mut(&buffer) {
            b.set_kept(kept);
            self.drop_if_unused(buffer);
        }
    }

    /// Sets the language `buffer` is in, or with `None` goes back to the one
    /// its file name says.
    pub fn set_language(&mut self, buffer: BufferId, language: Option<Arc<str>>) {
        if let Some(b) = self.buffers.get_mut(&buffer) {
            b.set_language(language);
        }
    }

    /// Replaces `buffer`'s marks in namespace `ns`, clamping them to its text.
    pub fn decorate(&mut self, buffer: BufferId, ns: &str, mut marks: Vec<Mark>) {
        let Some(b) = self.buffers.get_mut(&buffer) else {
            return;
        };
        let len = b.text().len_bytes();
        for mark in &mut marks {
            let end = mark.range.end.min(len);
            mark.range = mark.range.start.min(end)..end;
        }
        b.set_marks(ns, marks);
    }

    /// Starts following `range` of `buffer` through edits; see [`crate::Tracked`].
    pub fn track(
        &mut self,
        buffer: BufferId,
        range: std::ops::Range<usize>,
        gravity: (Assoc, Assoc),
    ) -> Option<TrackId> {
        Some(self.buffers.get_mut(&buffer)?.track(range, gravity))
    }

    pub fn forget_tracked(&mut self, buffer: BufferId, id: TrackId) {
        if let Some(b) = self.buffers.get_mut(&buffer) {
            b.forget(id);
        }
    }

    /// The buffer for the file at `path`: the open one, or a new buffer
    /// with the file's text (empty if the file doesn't exist yet). A file
    /// that isn't UTF-8 opens read-only, with what can't be read replaced,
    /// and can't be saved over.
    pub fn open_file(&mut self, path: &Path) -> std::io::Result<BufferId> {
        let path = &file_path(path)?;
        if let Some(buffer) = self.buffer_for(path) {
            return Ok(buffer);
        }
        let (text, binary) = match std::fs::read(path) {
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => (String::new(), false),
            Err(err) => return Err(err),
            Ok(bytes) => match String::from_utf8(bytes) {
                Ok(text) => (text, false),
                Err(err) => (String::from_utf8_lossy(err.as_bytes()).into_owned(), true),
            },
        };
        let id = BufferId(self.next_id());
        let mut buffer = Buffer::new(id, "file", &text).with_path(path);
        buffer.set_detected(self.file_types.detect(path));
        buffer.set_readonly(binary);
        buffer.set_lossy(binary);
        self.insert_buffer(buffer);
        Ok(id)
    }

    /// The open buffer for the file at `path`, however it's spelled (see
    /// [`file_path`]), without opening it.
    pub fn buffer_for(&self, path: &Path) -> Option<BufferId> {
        let path = file_path(path).ok()?;
        self.buffers
            .values()
            .find(|b| b.path() == Some(&path))
            .map(Buffer::id)
    }

    /// Makes `extensions` and whole file `names` mean `language`, replacing
    /// whatever it had, and redetects every open file.
    pub fn set_file_type(&mut self, language: &str, extensions: &[String], names: &[String]) {
        self.file_types.set(language, extensions, names);
        self.redetect();
    }

    /// Goes back to the bundled file types, then sets each of `types` as
    /// `(language, extensions, names)`, in order, and redetects every open
    /// file.
    pub fn reset_file_types<'a>(
        &mut self,
        types: impl IntoIterator<Item = (&'a str, &'a [String], &'a [String])>,
    ) {
        self.file_types = FileTypes::bundled();
        for (language, extensions, names) in types {
            self.file_types.set(language, extensions, names);
        }
        self.redetect();
    }

    fn redetect(&mut self) {
        for buffer in self.buffers.values_mut() {
            let detected = buffer.path().and_then(|p| self.file_types.detect(p));
            buffer.set_detected(detected);
        }
    }

    /// The language of the file at `path`, by its name or extension.
    pub fn file_type(&self, path: &Path) -> Option<Arc<str>> {
        self.file_types.detect(path)
    }

    /// Shows `buffer` in `view`, starting at the top.
    pub fn show(&mut self, view: ViewId, buffer: BufferId) {
        let old = self.view(view).buffer;
        let view = self.view_mut(view);
        view.buffer = buffer;
        view.selection = Selection::point(0);
        view.scroll = Scroll::default();
        view.visible = None;
        self.drop_if_unused(old);
    }

    /// Shows `buffer` in a new view floating over the main one, focusing it
    /// if `options.focus` says so.
    pub fn float(&mut self, buffer: BufferId, options: FloatOptions) -> ViewId {
        let previous = self.focus;
        let view = self.add_view(buffer, Selection::point(0));
        if !options.focus {
            self.focus = previous;
        }
        let tab = options.tab.then(|| self.current_tab().id());
        self.floats.push(Float {
            view,
            options,
            return_to: previous,
            tab,
        });
        view
    }

    /// The floating views shown: those over every tab and the shown tab's
    /// own, bottom first.
    pub fn floats(&self) -> Vec<&Float> {
        let tab = self.current_tab().id();
        self.floats
            .iter()
            .filter(|f| f.tab.is_none_or(|t| t == tab))
            .collect()
    }

    /// Shows `buffer` in a new panel beside the main view, focusing it if
    /// `options.focus` says so. Later panels go inside earlier ones.
    pub fn panel(&mut self, buffer: BufferId, options: PanelOptions) -> ViewId {
        let previous = self.focus;
        let view = self.add_view(buffer, Selection::point(0));
        if !options.focus {
            self.focus = previous;
        }
        self.current_project_mut()
            .panels
            .push(Panel { view, options });
        view
    }

    /// Panels, outermost first on each side.
    pub fn panels(&self) -> &[Panel] {
        &self.current_project().panels
    }

    /// How `view` is shown, if it's a floating view.
    pub fn float_options(&self, view: ViewId) -> Option<&FloatOptions> {
        self.floats
            .iter()
            .find(|f| f.view == view)
            .map(|f| &f.options)
    }

    /// Changes how a floating view is shown. Returns false if `view` isn't
    /// floating.
    pub fn configure_float(&mut self, view: ViewId, options: FloatOptions) -> bool {
        match self.floats.iter_mut().find(|f| f.view == view) {
            Some(float) => {
                float.options = options;
                true
            }
            None => false,
        }
    }

    /// Brings a floating view in front of the others. Returns false if
    /// `view` isn't floating.
    pub fn raise_float(&mut self, view: ViewId) -> bool {
        let Some(at) = self.floats.iter().position(|f| f.view == view) else {
            return false;
        };
        let float = self.floats.remove(at);
        self.floats.push(float);
        true
    }

    pub fn main(&self) -> ViewId {
        self.current_project().main()
    }

    /// Closes a view. Focus moves to the top floating view, or the main view.
    /// A buffer without a file goes away with its last view. Closing a tab's
    /// last pane closes the tab. Returns false for the project's last pane,
    /// which can't be closed.
    pub fn close(&mut self, view: ViewId) -> bool {
        if !self.views.contains_key(&view) || !self.remove_pane(view) {
            return false;
        }
        let Some(closed) = self.views.remove(&view) else {
            return false;
        };
        let return_to = self
            .floats
            .iter()
            .find(|f| f.view == view)
            .map(|f| f.return_to)
            .filter(|v| self.views.contains_key(v));
        self.floats.retain(|f| f.view != view);
        for project in &mut self.projects {
            project.panels.retain(|p| p.view != view);
        }
        if self.focus == view {
            self.focus = return_to
                .or_else(|| self.floats().last().map(|f| f.view))
                .unwrap_or(self.current_project().main());
        }
        self.drop_if_unused(closed.buffer);
        true
    }

    /// Opens a second view of the same buffer, with the same selection, and
    /// focuses it.
    pub fn split(&mut self, view: ViewId) -> ViewId {
        let copy = self.view(view).clone();
        let id = self.add_view(copy.buffer, copy.selection);
        self.view_mut(id).scroll = copy.scroll;
        id
    }

    /// Panics if the buffer doesn't exist; ids come from the editor itself.
    pub fn buffer(&self, id: BufferId) -> &Buffer {
        &self.buffers[&id]
    }

    /// Writes a buffer to its file.
    pub fn save(&mut self, id: BufferId) -> std::io::Result<()> {
        self.buffers.get_mut(&id).expect("buffer exists").save()
    }

    /// Reads a buffer's file again, as an edit by [`Author::External`] that
    /// undo can take back, and counts the buffer as saved. Returns whether
    /// the text changed.
    pub fn reload(&mut self, id: BufferId) -> std::io::Result<bool> {
        let buffer = &self.buffers[&id];
        let path = buffer
            .path()
            .ok_or_else(|| std::io::Error::other("this buffer has no file"))?;
        let disk = std::fs::read_to_string(path)?;
        let text = buffer.text().to_string();
        let changes = crate::diff::line_changes(&text, &disk);
        if !changes.is_empty() {
            let changes = ChangeSet::from_changes(
                text.len(),
                changes
                    .iter()
                    .map(|(range, new)| (range.start, range.end, Some(new.as_str()))),
            )
            .map_err(std::io::Error::other)?;
            // Not part of whatever the user has going, like an insert.
            let group = self.undo_group.take();
            let applied = self.apply_to_buffer(id, changes, Author::External, Some("reload"), None);
            self.undo_group = group;
            applied.map_err(std::io::Error::other)?;
        }
        self.buffers
            .get_mut(&id)
            .expect("buffer exists")
            .mark_saved();
        Ok(!changes.is_empty())
    }

    /// Writes the buffer to `path`, which becomes its file. A buffer whose
    /// file wasn't UTF-8 can be saved to another path, which then holds
    /// what it shows, but not over its own file.
    pub fn save_as(&mut self, id: BufferId, path: &Path) -> std::io::Result<()> {
        let detected = self.file_types.detect(path);
        let buffer = self.buffers.get_mut(&id).expect("buffer exists");
        let lossy = buffer.is_lossy();
        let path = file_path(path)?;
        if lossy && buffer.path() == Some(&path) {
            // Refused, as saving over it would be.
            return buffer.save();
        }
        let old = buffer.set_path(Some(path));
        buffer.set_lossy(false);
        let saved = buffer.save();
        if saved.is_err() {
            buffer.set_path(old);
            buffer.set_lossy(lossy);
        } else {
            buffer.set_detected(detected);
        }
        saved
    }

    /// The buffer with `id`, if it still exists.
    pub fn find_buffer(&self, id: BufferId) -> Option<&Buffer> {
        self.buffers.get(&id)
    }

    /// The view with `id`, if it's still open.
    pub fn find_view(&self, id: ViewId) -> Option<&View> {
        self.views.get(&id)
    }

    pub fn buffers(&self) -> impl Iterator<Item = &Buffer> {
        self.buffers.values()
    }

    /// The views showing `buffer`.
    pub fn views_of(&self, buffer: BufferId) -> Vec<ViewId> {
        self.views
            .iter()
            .filter(|(_, view)| view.buffer == buffer)
            .map(|(id, _)| *id)
            .collect()
    }

    /// Each open view that has been drawn, with its rows and columns.
    pub fn view_sizes(&self) -> impl Iterator<Item = (ViewId, (u16, u16))> + '_ {
        self.views
            .iter()
            .filter_map(|(id, view)| Some((*id, view.size?)))
    }

    /// Each view's top line.
    pub fn view_scrolls(&self) -> impl Iterator<Item = (ViewId, usize)> + '_ {
        self.views.iter().map(|(id, view)| (*id, view.scroll.line))
    }

    pub fn view(&self, id: ViewId) -> &View {
        &self.views[&id]
    }

    pub fn view_mut(&mut self, id: ViewId) -> &mut View {
        self.views.get_mut(&id).expect("view exists")
    }

    pub fn focus(&self) -> ViewId {
        self.focus
    }

    pub fn set_focus(&mut self, view: ViewId) {
        assert!(self.views.contains_key(&view), "no view {view:?}");
        self.focus = view;
        self.activate(view);
    }

    /// Applies a change to the buffer shown in `view`. The view's selection
    /// becomes `selection`, or is mapped through the change if `None`; other
    /// views of the same buffer are always mapped.
    pub fn apply(
        &mut self,
        view: ViewId,
        changes: ChangeSet,
        author: Author,
        cause: Option<&str>,
        selection: Option<Selection>,
    ) -> Result<(), Error> {
        let id = self.view(view).buffer;
        let tx = Transaction {
            changes,
            selection,
            meta: self.meta(id, author, cause),
        };
        let buffer = self.buffers.get_mut(&id).expect("view's buffer exists");
        let after = buffer.apply(tx, &self.views[&view].selection)?;
        self.view_mut(view).selection = after;
        self.map_views(id, Some(view));
        Ok(())
    }

    /// Applies a change to a buffer, whether or not it's on screen. Every
    /// view of it gets `selection`, or is mapped through the change if
    /// `None`.
    pub fn apply_to_buffer(
        &mut self,
        id: BufferId,
        changes: ChangeSet,
        author: Author,
        cause: Option<&str>,
        selection: Option<Selection>,
    ) -> Result<(), Error> {
        let tx = Transaction {
            changes,
            selection,
            meta: self.meta(id, author, cause),
        };
        let buffer = self.buffers.get_mut(&id).expect("buffer exists");
        if let Some(after) = buffer.apply_detached(tx)? {
            for view in self.views.values_mut().filter(|v| v.buffer == id) {
                view.selection = after.clone();
            }
        } else {
            self.map_views(id, None);
        }
        Ok(())
    }

    /// Metadata for the next transaction on `buffer`.
    fn meta(&mut self, buffer: BufferId, author: Author, cause: Option<&str>) -> TxMeta {
        let version = self.buffers[&buffer].version();
        let mut meta = TxMeta::new(self.replica.next_id(), version, author);
        meta.group = self.undo_group;
        if let Some(cause) = cause.or(self.cause.as_deref()) {
            meta = meta.with_cause(cause);
        }
        meta
    }

    /// Undoes the last change in `view`'s buffer. Returns false if there was
    /// nothing to undo.
    pub fn undo(&mut self, view: ViewId) -> Result<bool, Error> {
        self.history_step(view, Buffer::undo)
    }

    /// Redoes the last undone change in `view`'s buffer. Returns false if
    /// there was nothing to redo.
    pub fn redo(&mut self, view: ViewId) -> Result<bool, Error> {
        self.history_step(view, Buffer::redo)
    }

    /// Takes `view`'s buffer to node `target` of its undo tree, undoing up
    /// to where the two paths meet and redoing down the other branch, which
    /// redo follows from then on. Returns false if there's no such node or
    /// the text is there already.
    pub fn undo_to(&mut self, view: ViewId, target: usize) -> Result<bool, Error> {
        let id = self.view(view).buffer;
        let Some((up, down)) = self.buffers[&id].history().path_to(target) else {
            return Ok(false);
        };
        if up == 0 && down.is_empty() {
            return Ok(false);
        }
        for _ in 0..up {
            self.undo(view)?;
        }
        for node in down {
            self.buffers
                .get_mut(&id)
                .expect("view's buffer exists")
                .prefer_branch(node);
            self.redo(view)?;
        }
        Ok(true)
    }

    /// Starts grouping edits into one undo step, e.g. for an insert mode
    /// session. Does nothing if a group is already open.
    pub fn start_group(&mut self) {
        if self.undo_group.is_none() {
            self.undo_group = Some(self.new_group());
        }
    }

    pub fn end_group(&mut self) {
        self.undo_group = None;
    }

    /// A group id nothing has used yet.
    pub fn new_group(&mut self) -> u64 {
        let group = self.next_group;
        self.next_group += 1;
        group
    }

    /// The group edits go into now, if one is open.
    pub fn group(&self) -> Option<u64> {
        self.undo_group
    }

    /// Puts the edits that follow into `group`, which can be one used
    /// before, or into none.
    pub fn set_group(&mut self, group: Option<u64>) {
        self.undo_group = group;
    }

    /// Sets why the edits that follow are made, for those that don't say.
    pub fn set_cause(&mut self, cause: Option<Arc<str>>) {
        self.cause = cause;
    }

    pub fn cause(&self) -> Option<&Arc<str>> {
        self.cause.as_ref()
    }

    /// Undoes `group` in every buffer it touched, as `author`. Returns the
    /// buffers that changed: none if the group was already undone or never
    /// used. Changes nothing if a buffer had something done on top of it.
    pub fn undo_group(&mut self, group: u64, author: &Author) -> Result<Vec<BufferId>, Error> {
        let mut current = Vec::new();
        for (id, buffer) in &self.buffers {
            match buffer.history().group_state(group) {
                GroupState::Buried => return Err(Error::GroupChanged),
                GroupState::Current
                    if buffer.is_readonly() && !matches!(author, Author::Plugin(_)) =>
                {
                    return Err(Error::ReadOnly);
                }
                GroupState::Current => current.push(*id),
                GroupState::Absent | GroupState::Undone => {}
            }
        }
        for &id in &current {
            let tx_id = self.replica.next_id();
            let buffer = self.buffers.get_mut(&id).expect("buffer exists");
            // Views keep their places, moved along with the text, rather than
            // jumping to wherever the group's edits were made from.
            buffer.undo(tx_id, author.clone(), &Selection::point(0))?;
            self.map_views(id, None);
        }
        Ok(current)
    }

    pub fn mode(&self) -> &str {
        &self.mode
    }

    /// Switches mode. Returns false if already in that mode.
    pub fn set_mode(&mut self, mode: &str) -> bool {
        if &*self.mode == mode {
            return false;
        }
        self.mode = mode.into();
        self.pending.clear();
        self.count = None;
        true
    }

    /// The menus for a window's menu bar.
    pub fn menus(&self) -> &[crate::render::Menu] {
        &self.menus
    }

    pub fn set_menus(&mut self, menus: Vec<crate::render::Menu>) {
        self.menus = menus;
    }

    pub fn theme(&self) -> &Arc<Theme> {
        &self.theme
    }

    pub fn images(&self) -> &crate::image::Images {
        &self.images
    }

    pub fn images_mut(&mut self) -> &mut crate::image::Images {
        &mut self.images
    }

    /// A cell's width and height in pixels on the client's screen; 8 by 16
    /// until a client says.
    pub fn cell_size(&self) -> (u16, u16) {
        self.cell_size
    }

    pub fn set_cell_size(&mut self, size: (u16, u16)) {
        if size.0 > 0 && size.1 > 0 {
            self.cell_size = size;
        }
    }

    pub fn theme_mut(&mut self) -> &mut Theme {
        Arc::make_mut(&mut self.theme)
    }

    pub fn set_cursor_shape(&mut self, mode: &str, shape: CursorShape) {
        self.cursor_shapes.insert(mode.into(), shape);
    }

    /// How line numbers count, where buffers show them.
    pub fn line_numbers(&self) -> LineNumbers {
        self.line_numbers
    }

    pub fn set_line_numbers_style(&mut self, style: LineNumbers) {
        self.line_numbers = style;
    }

    /// The cursor shape for the current mode.
    pub fn cursor_shape(&self) -> CursorShape {
        self.cursor_shape_of(&self.mode)
    }

    /// The cursor shape for `mode`: a block unless set otherwise.
    pub fn cursor_shape_of(&self, mode: &str) -> CursorShape {
        self.cursor_shapes.get(mode).copied().unwrap_or_default()
    }

    pub fn keymap(&self) -> &Keymap {
        &self.keymap
    }

    pub fn keymap_mut(&mut self) -> &mut Keymap {
        &mut self.keymap
    }

    /// Keys pressed so far in an unfinished sequence.
    pub fn pending(&self) -> &[Key] {
        &self.pending
    }

    /// Binds `keys` for the next key press only (see `overlay`), or drops
    /// such bindings with `None`.
    pub fn set_overlay(&mut self, keys: Option<HashMap<Key, Arc<str>>>) {
        self.overlay = keys;
    }

    /// Feeds a key press into the keymap for the current mode and focused
    /// buffer.
    pub fn press(&mut self, key: Key) -> KeyOutcome {
        if self.pending.is_empty()
            && self.count.is_none()
            && let Some(overlay) = self.overlay.take()
            && let Some(name) = overlay.get(&key)
        {
            return KeyOutcome::Command {
                name: name.clone(),
                keys: vec![key],
                count: None,
            };
        }
        if let Some(digit) = self.count_digit(key) {
            self.count = Some(
                self.count
                    .unwrap_or(0)
                    .saturating_mul(10)
                    .saturating_add(digit),
            );
            return KeyOutcome::Pending;
        }
        self.pending.push(key);
        let kind = self.buffer(self.view(self.focus).buffer).kind();
        match self.keymap.resolve(&self.mode, kind, &self.pending) {
            Resolution::Pending => KeyOutcome::Pending,
            Resolution::Command(name) => KeyOutcome::Command {
                name,
                keys: std::mem::take(&mut self.pending),
                count: self.count.take(),
            },
            Resolution::Unbound => {
                let keys = std::mem::take(&mut self.pending);
                let count = self.count.take();
                match self.keymap.fallback(&self.mode) {
                    Some(name) if keys.len() == 1 => KeyOutcome::Command {
                        name: name.clone(),
                        keys,
                        count,
                    },
                    _ => KeyOutcome::Unbound(keys),
                }
            }
        }
    }

    /// The digit `key` adds to a count: counts are on in this mode, no
    /// sequence has started, and it's a plain digit (0 only after another).
    fn count_digit(&self, key: Key) -> Option<u32> {
        let KeyCode::Char(c) = key.code else {
            return None;
        };
        let digit = c.to_digit(10)?;
        let counting = key.mods == Mods::NONE
            && self.pending.is_empty()
            && (digit != 0 || self.count.is_some())
            && self.keymap.counts(&self.mode);
        counting.then_some(digit)
    }

    /// The text of `view`'s buffer with its selection marked: `|` at each
    /// head and `^` at the anchor of each non-empty range. For tests and the
    /// REPL.
    pub fn marked_text(&self, view: ViewId) -> String {
        let view = self.view(view);
        let mut text = self.buffer(view.buffer).text().to_string();
        let mut marks: Vec<(usize, char)> = view
            .selection
            .ranges()
            .iter()
            .flat_map(|r| {
                let anchor = (!r.is_empty()).then_some((r.anchor, '^'));
                std::iter::once((r.head, '|')).chain(anchor)
            })
            .collect();
        marks.sort_unstable_by(|a, b| b.cmp(a));
        for (pos, mark) in marks {
            text.insert(pos, mark);
        }
        text
    }

    /// How many copies the clipboard remembers.
    const CLIPBOARD_HISTORY: usize = 20;

    /// Puts text on the clipboard: one piece per selection it came from.
    pub fn copy(&mut self, pieces: Vec<String>) {
        self.copied = Some(pieces.join("\n"));
        self.remember_copy(pieces);
    }

    fn remember_copy(&mut self, pieces: Vec<String>) {
        self.clipboard.push(pieces);
        let extra = self.clipboard.len().saturating_sub(Self::CLIPBOARD_HISTORY);
        self.clipboard.drain(..extra);
    }

    /// Makes `text`, from the system clipboard, the latest copy, unless it
    /// already is. It isn't sent back to the client.
    pub fn take_system_clipboard(&mut self, text: &str) {
        if self.clipboard().is_some_and(|last| last.join("\n") == text) {
            return;
        }
        self.remember_copy(vec![text.to_owned()]);
    }

    /// The latest copy, once, as one text, for the client to put on the
    /// system clipboard.
    pub fn take_copied(&mut self) -> Option<String> {
        self.copied.take()
    }

    /// Asks the attached client to notify the user's desktop.
    pub fn notify(&mut self, notice: Notice) {
        self.notices.push(notice);
    }

    /// The notifications not yet sent to the client, oldest first.
    pub fn take_notices(&mut self) -> Vec<Notice> {
        std::mem::take(&mut self.notices)
    }

    /// The latest copy, if any.
    pub fn clipboard(&self) -> Option<&[String]> {
        self.clipboard.last().map(Vec::as_slice)
    }

    /// Every remembered copy, newest first.
    pub fn clipboard_history(&self) -> impl Iterator<Item = &[String]> {
        self.clipboard.iter().rev().map(Vec::as_slice)
    }

    /// Asks whoever runs the editor to stop it.
    pub fn request_quit(&mut self) {
        self.quit_requested = true;
    }

    pub fn quit_requested(&self) -> bool {
        self.quit_requested
    }

    /// Asks whoever runs the editor to let the attached client go and keep
    /// running without it.
    pub fn request_detach(&mut self) {
        self.detach_requested = true;
    }

    /// Whether a detach was asked for since the last call.
    pub fn take_detach_request(&mut self) -> bool {
        std::mem::take(&mut self.detach_requested)
    }

    /// Asks whoever runs the editor to send the attached client to another
    /// session, which lets it go from this one.
    pub fn request_switch(&mut self, to: SwitchTo) {
        self.switch_requested = Some(to);
    }

    /// Where a switch was asked to go since the last call, if one was.
    pub fn take_switch_request(&mut self) -> Option<SwitchTo> {
        self.switch_requested.take()
    }

    /// Queues a message for the user.
    pub fn echo(&mut self, message: impl Into<String>) {
        self.messages.push(message.into());
    }

    pub fn take_messages(&mut self) -> Vec<String> {
        std::mem::take(&mut self.messages)
    }

    /// The messages queued since they were last taken.
    pub fn messages(&self) -> &[String] {
        &self.messages
    }

    fn next_id(&mut self) -> u32 {
        let id = self.next_id;
        self.next_id += 1;
        id
    }

    fn add_view(&mut self, buffer: BufferId, selection: Selection) -> ViewId {
        let id = ViewId(self.next_id());
        self.views.insert(
            id,
            View {
                buffer,
                selection,
                scroll: Scroll::default(),
                visible: None,
                size: None,
                area: None,
            },
        );
        self.focus = id;
        id
    }

    /// Closes `buffer`, unsaved changes and all. Fails while a view shows it,
    /// so whoever closes it decides what those views show instead.
    pub fn close_buffer(&mut self, buffer: BufferId) -> Result<(), Error> {
        if self.views.values().any(|v| v.buffer == buffer) {
            return Err(Error::Shown);
        }
        self.buffers.remove(&buffer);
        self.buffer_projects.remove(&buffer);
        Ok(())
    }

    /// Removes a buffer that has no file and no view left.
    fn drop_if_unused(&mut self, buffer: BufferId) {
        let b = &self.buffers[&buffer];
        let unused =
            b.path().is_none() && !b.is_kept() && !self.views.values().any(|v| v.buffer == buffer);
        if unused {
            self.buffers.remove(&buffer);
        }
    }

    fn history_step(&mut self, view: ViewId, step: HistoryStep) -> Result<bool, Error> {
        let id = self.view(view).buffer;
        let tx_id = self.replica.next_id();
        let author = Author::User(self.client);
        let buffer = self.buffers.get_mut(&id).expect("view's buffer exists");
        let Some(selection) = step(buffer, tx_id, author, &self.views[&view].selection)? else {
            return Ok(false);
        };
        self.view_mut(view).selection = selection;
        self.map_views(self.view(view).buffer, Some(view));
        Ok(true)
    }

    /// Maps the selections of views on `buffer`, other than `except`, through
    /// the buffer's latest transaction.
    fn map_views(&mut self, buffer: BufferId, except: Option<ViewId>) {
        let changes = self.buffers[&buffer].history().latest();
        for (id, other) in &mut self.views {
            if Some(*id) != except && other.buffer == buffer {
                other.selection = other.selection.map(changes);
            }
        }
    }
}

/// `path` as buffers know their files: absolute (from the current
/// directory when relative), with `.` and `..` worked out without following
/// symbolic links, so "src/a.rs", "./src/../src/a.rs" and "/home/me/src/a.rs"
/// are one buffer.
pub fn file_path(path: &Path) -> std::io::Result<PathBuf> {
    let mut clean = PathBuf::new();
    for part in std::path::absolute(path)?.components() {
        match part {
            Component::ParentDir => {
                clean.pop();
            }
            Component::CurDir => {}
            other => clean.push(other),
        }
    }
    Ok(clean)
}

/// Parses text written with [`Editor::marked_text`]'s markers: `|` at each
/// head and `^` before it at the anchor of a non-empty range. The first
/// range is primary.
pub fn parse_marked(marked: &str) -> Result<(String, Selection), greed_text::Error> {
    let mut text = String::with_capacity(marked.len());
    let mut ranges = Vec::new();
    let mut anchor = None;
    for c in marked.chars() {
        match c {
            '^' => anchor = Some(text.len()),
            '|' => ranges.push(Range::new(anchor.take().unwrap_or(text.len()), text.len())),
            c => text.push(c),
        }
    }
    Ok((text, Selection::new(ranges, 0)?))
}
