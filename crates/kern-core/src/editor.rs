//! The editor's authoritative state: buffers, views, the current mode and
//! the keymap. Everything here is plain Rust; the Luau host drives it.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use kern_text::{
    Author, ChangeSet, ClientId, Range, Replica, Selection, Transaction, TxId, TxMeta,
};

use crate::keymap::{Key, Keymap, Resolution};
use crate::{Buffer, BufferId, Error};

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
}

/// A view floating over the main one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Float {
    pub view: ViewId,
    pub options: FloatOptions,
}

/// How the cursor looks.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum CursorShape {
    #[default]
    Block,
    Bar,
    Underline,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyOutcome {
    /// Run this command. `keys` is the sequence that triggered it.
    Command { name: Arc<str>, keys: Vec<Key> },
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
    /// The view that fills the screen; floating views sit on top of it.
    main: ViewId,
    /// Floating views, bottom first.
    floats: Vec<Float>,
    focus: ViewId,
    next_id: u32,
    mode: Arc<str>,
    keymap: Keymap,
    pending: Vec<Key>,
    messages: Vec<String>,
    /// Edits made while a group is open become one undo step.
    undo_group: Option<u64>,
    next_group: u64,
    quit_requested: bool,
    /// Copied text, oldest first. Each entry holds one piece per selection.
    clipboard: Vec<Vec<String>>,
    /// The cursor shape of each mode; modes not listed get a block.
    cursor_shapes: HashMap<Arc<str>, CursorShape>,
}

impl Editor {
    pub fn new(client: ClientId) -> Self {
        Self {
            client,
            replica: Replica::new(client.0),
            buffers: BTreeMap::new(),
            views: BTreeMap::new(),
            main: ViewId(0),
            floats: Vec::new(),
            focus: ViewId(0),
            next_id: 1,
            mode: "normal".into(),
            keymap: Keymap::default(),
            pending: Vec::new(),
            messages: Vec::new(),
            undo_group: None,
            next_group: 0,
            quit_requested: false,
            clipboard: Vec::new(),
            cursor_shapes: HashMap::new(),
        }
    }

    pub fn client(&self) -> ClientId {
        self.client
    }

    /// Opens a buffer in a new view and focuses it. The first view opened
    /// becomes the main view.
    pub fn open(&mut self, kind: &str, text: &str, path: Option<PathBuf>) -> (BufferId, ViewId) {
        let id = BufferId(self.next_id());
        let mut buffer = Buffer::new(id, kind, text);
        if let Some(path) = path {
            buffer = buffer.with_path(path);
        }
        self.buffers.insert(id, buffer);
        let view = self.add_view(id, Selection::point(0));
        if self.views.len() == 1 {
            self.main = view;
        }
        (id, view)
    }

    /// Creates a buffer without showing it.
    pub fn create_buffer(&mut self, kind: &str, text: &str) -> BufferId {
        let id = BufferId(self.next_id());
        self.buffers.insert(id, Buffer::new(id, kind, text));
        id
    }

    /// Makes `buffer` read-only, so only plugins can change it, or editable.
    pub fn set_readonly(&mut self, buffer: BufferId, readonly: bool) {
        if let Some(b) = self.buffers.get_mut(&buffer) {
            b.set_readonly(readonly);
        }
    }

    /// Sets the language `buffer` is in, or with `None` goes back to the one
    /// its file extension implies.
    pub fn set_language(&mut self, buffer: BufferId, language: Option<Arc<str>>) {
        if let Some(b) = self.buffers.get_mut(&buffer) {
            b.set_language(language);
        }
    }

    /// The buffer for the file at `path`: the open one, or a new buffer
    /// with the file's text (empty if the file doesn't exist yet).
    pub fn open_file(&mut self, path: &Path) -> std::io::Result<BufferId> {
        if let Some(buffer) = self.buffers.values().find(|b| b.path() == Some(path)) {
            return Ok(buffer.id());
        }
        let text = match std::fs::read_to_string(path) {
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => String::new(),
            other => other?,
        };
        let id = BufferId(self.next_id());
        self.buffers
            .insert(id, Buffer::new(id, "file", &text).with_path(path));
        Ok(id)
    }

    /// Shows `buffer` in `view`, starting at the top.
    pub fn show(&mut self, view: ViewId, buffer: BufferId) {
        let old = self.view(view).buffer;
        let view = self.view_mut(view);
        view.buffer = buffer;
        view.selection = Selection::point(0);
        view.scroll = Scroll::default();
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
        self.floats.push(Float { view, options });
        view
    }

    /// Floating views, bottom first.
    pub fn floats(&self) -> &[Float] {
        &self.floats
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
        self.main
    }

    /// Closes a view. Focus moves to the top floating view, or the main view.
    /// A buffer without a file goes away with its last view. Returns false
    /// for the main view, which can't be closed.
    pub fn close(&mut self, view: ViewId) -> bool {
        if view == self.main {
            return false;
        }
        let Some(closed) = self.views.remove(&view) else {
            return false;
        };
        self.floats.retain(|f| f.view != view);
        if self.focus == view {
            self.focus = self.floats.last().map_or(self.main, |f| f.view);
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
        let buffer = self.buffers.get_mut(&id).expect("buffer exists");
        let old = buffer.set_path(Some(path.to_path_buf()));
        let saved = buffer.save();
        if saved.is_err() {
            buffer.set_path(old);
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
        true
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
        self.pending.push(key);
        let kind = self.buffer(self.view(self.focus).buffer).kind();
        match self.keymap.resolve(&self.mode, kind, &self.pending) {
            Resolution::Pending => KeyOutcome::Pending,
            Resolution::Command(name) => KeyOutcome::Command {
                name,
                keys: std::mem::take(&mut self.pending),
            },
            Resolution::Unbound => {
                let keys = std::mem::take(&mut self.pending);
                match self.keymap.fallback(&self.mode) {
                    Some(name) if keys.len() == 1 => KeyOutcome::Command {
                        name: name.clone(),
                        keys,
                    },
                    _ => KeyOutcome::Unbound(keys),
                }
            }
        }
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
