//! The editor's authoritative state: buffers, views, the current mode and
//! the keymap. Everything here is plain Rust; the Luau host drives it.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use kern_text::{
    Author, ChangeSet, ClientId, Range, Replica, Selection, Transaction, TxId, TxMeta,
};

use crate::filetypes::FileTypes;
use crate::keymap::{Key, KeyCode, Keymap, Mods, Resolution};
use crate::theme::Theme;
use crate::{Buffer, BufferId, Error, Mark};

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
}

/// A view floating over the main one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Float {
    pub view: ViewId,
    pub options: FloatOptions,
    /// The view that had focus when this one opened, which gets it back
    /// when this one closes.
    pub(crate) return_to: ViewId,
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

/// A folder being worked on: its own main view and panels. Buffers opened
/// while it's current belong to it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Project {
    id: ProjectId,
    root: PathBuf,
    main: ViewId,
    /// Views beside the main one, outermost first on each side.
    panels: Vec<Panel>,
}

impl Project {
    pub fn id(&self) -> ProjectId {
        self.id
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// The view that fills the screen while this project is shown.
    pub fn main(&self) -> ViewId {
        self.main
    }
}

/// How the cursor looks.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum CursorShape {
    #[default]
    Block,
    Bar,
    Underline,
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
    messages: Vec<String>,
    /// Edits made while a group is open become one undo step.
    undo_group: Option<u64>,
    next_group: u64,
    quit_requested: bool,
    /// The attached client asked to leave, with the editor running on.
    detach_requested: bool,
    /// Copied text, oldest first. Each entry holds one piece per selection.
    clipboard: Vec<Vec<String>>,
    /// The cursor shape of each mode; modes not listed get a block.
    cursor_shapes: HashMap<Arc<str>, CursorShape>,
    file_types: FileTypes,
    theme: Arc<Theme>,
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
            messages: Vec::new(),
            undo_group: None,
            next_group: 0,
            quit_requested: false,
            detach_requested: false,
            clipboard: Vec::new(),
            cursor_shapes: HashMap::new(),
            file_types: FileTypes::bundled(),
            theme: Arc::default(),
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
        self.projects.push(Project {
            id,
            root,
            main,
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
        self.focus = self.projects[index].main;
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
        for view in std::iter::once(project.main).chain(project.panels.iter().map(|p| p.view)) {
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
        self.focus = self.projects[self.current].main;
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

    /// The buffer for the file at `path`: the open one, or a new buffer
    /// with the file's text (empty if the file doesn't exist yet).
    pub fn open_file(&mut self, path: &Path) -> std::io::Result<BufferId> {
        // Files are known by their absolute path, so one opened as
        // "src/a.rs" and as "/home/me/src/a.rs" is the same buffer.
        let path = &std::path::absolute(path)?;
        if let Some(buffer) = self.buffers.values().find(|b| b.path() == Some(path)) {
            return Ok(buffer.id());
        }
        let text = match std::fs::read_to_string(path) {
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => String::new(),
            other => other?,
        };
        let id = BufferId(self.next_id());
        let mut buffer = Buffer::new(id, "file", &text).with_path(path);
        buffer.set_detected(self.file_types.detect(path));
        self.insert_buffer(buffer);
        Ok(id)
    }

    /// Makes `extensions` and whole file `names` mean `language`, replacing
    /// whatever it had, and redetects every open file.
    pub fn set_file_type(&mut self, language: &str, extensions: &[String], names: &[String]) {
        self.file_types.set(language, extensions, names);
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
        self.floats.push(Float {
            view,
            options,
            return_to: previous,
        });
        view
    }

    /// Floating views, bottom first.
    pub fn floats(&self) -> &[Float] {
        &self.floats
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

    pub fn main(&self) -> ViewId {
        self.current_project().main
    }

    /// Closes a view. Focus moves to the top floating view, or the main view.
    /// A buffer without a file goes away with its last view. Returns false
    /// for the main view, which can't be closed.
    pub fn close(&mut self, view: ViewId) -> bool {
        if self.projects.iter().any(|p| p.main == view) {
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
                .or_else(|| self.floats.last().map(|f| f.view))
                .unwrap_or(self.current_project().main);
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

    /// Writes the buffer to `path`, which becomes its file.
    pub fn save_as(&mut self, id: BufferId, path: &Path) -> std::io::Result<()> {
        let detected = self.file_types.detect(path);
        let buffer = self.buffers.get_mut(&id).expect("buffer exists");
        let old = buffer.set_path(Some(path.to_path_buf()));
        let saved = buffer.save();
        if saved.is_err() {
            buffer.set_path(old);
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
        let explicit = selection.is_some();
        let tx = Transaction {
            changes,
            selection,
            meta: self.meta(id, author, cause),
        };
        let buffer = self.buffers.get_mut(&id).expect("buffer exists");
        let after = buffer.apply(tx, &Selection::point(0))?;
        if explicit {
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
        if let Some(cause) = cause {
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

    /// Starts grouping edits into one undo step, e.g. for an insert mode
    /// session. Does nothing if a group is already open.
    pub fn start_group(&mut self) {
        if self.undo_group.is_none() {
            self.undo_group = Some(self.next_group);
            self.next_group += 1;
        }
    }

    pub fn end_group(&mut self) {
        self.undo_group = None;
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

    pub fn theme(&self) -> &Arc<Theme> {
        &self.theme
    }

    pub fn theme_mut(&mut self) -> &mut Theme {
        Arc::make_mut(&mut self.theme)
    }

    pub fn set_cursor_shape(&mut self, mode: &str, shape: CursorShape) {
        self.cursor_shapes.insert(mode.into(), shape);
    }

    /// The cursor shape for the current mode.
    pub fn cursor_shape(&self) -> CursorShape {
        self.cursor_shapes
            .get(&self.mode)
            .copied()
            .unwrap_or_default()
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

    /// Feeds a key press into the keymap for the current mode and focused
    /// buffer.
    pub fn press(&mut self, key: Key) -> KeyOutcome {
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
        self.clipboard.push(pieces);
        let extra = self.clipboard.len().saturating_sub(Self::CLIPBOARD_HISTORY);
        self.clipboard.drain(..extra);
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

    /// Queues a message for the user.
    pub fn echo(&mut self, message: impl Into<String>) {
        self.messages.push(message.into());
    }

    pub fn take_messages(&mut self) -> Vec<String> {
        std::mem::take(&mut self.messages)
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
            },
        );
        self.focus = id;
        id
    }

    /// Removes a buffer that has no file and no view left.
    fn drop_if_unused(&mut self, buffer: BufferId) {
        let unused = self.buffers[&buffer].path().is_none()
            && !self.views.values().any(|v| v.buffer == buffer);
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
        let changes = &self.buffers[&buffer]
            .history()
            .log()
            .last()
            .expect("a transaction was just applied")
            .changes;
        for (id, other) in &mut self.views {
            if Some(*id) != except && other.buffer == buffer {
                other.selection = other.selection.map(changes);
            }
        }
    }
}

/// Parses text written with [`Editor::marked_text`]'s markers: `|` at each
/// head and `^` before it at the anchor of a non-empty range. The first
/// range is primary.
pub fn parse_marked(marked: &str) -> Result<(String, Selection), kern_text::Error> {
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
