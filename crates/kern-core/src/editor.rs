//! The editor's authoritative state: buffers, views, the current mode and
//! the keymap. Everything here is plain Rust; the Luau host drives it.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;

use kern_text::{Author, ChangeSet, ClientId, Replica, Selection, Transaction, TxId, TxMeta};

use crate::keymap::{Key, Keymap, Resolution};
use crate::{Buffer, BufferId, Error};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ViewId(pub u32);

/// `Buffer::undo` or `Buffer::redo`.
type HistoryStep = fn(&mut Buffer, TxId, Author, &Selection) -> Result<Option<Selection>, Error>;

/// A buffer shown on screen, with its own selection.
#[derive(Debug, Clone)]
pub struct View {
    pub buffer: BufferId,
    pub selection: Selection,
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
    focus: ViewId,
    next_id: u32,
    mode: Arc<str>,
    keymap: Keymap,
    pending: Vec<Key>,
    messages: Vec<String>,
}

impl Editor {
    pub fn new(client: ClientId) -> Self {
        Self {
            client,
            replica: Replica::new(client.0),
            buffers: BTreeMap::new(),
            views: BTreeMap::new(),
            focus: ViewId(0),
            next_id: 1,
            mode: "normal".into(),
            keymap: Keymap::default(),
            pending: Vec::new(),
            messages: Vec::new(),
        }
    }

    pub fn client(&self) -> ClientId {
        self.client
    }

    /// Opens a buffer in a new view and focuses it.
    pub fn open(&mut self, kind: &str, text: &str, path: Option<PathBuf>) -> (BufferId, ViewId) {
        let id = BufferId(self.next_id());
        let mut buffer = Buffer::new(id, kind, text);
        if let Some(path) = path {
            buffer = buffer.with_path(path);
        }
        self.buffers.insert(id, buffer);
        let view = self.add_view(id, Selection::point(0));
        (id, view)
    }

    /// Opens a second view of the same buffer, with the same selection, and
    /// focuses it.
    pub fn split(&mut self, view: ViewId) -> ViewId {
        let View { buffer, selection } = self.view(view).clone();
        self.add_view(buffer, selection)
    }

    /// Panics if the buffer doesn't exist; ids come from the editor itself.
    pub fn buffer(&self, id: BufferId) -> &Buffer {
        &self.buffers[&id]
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
        let buffer = self.buffers.get_mut(&id).expect("view's buffer exists");
        let mut meta = TxMeta::new(self.replica.next_id(), buffer.version(), author);
        if let Some(cause) = cause {
            meta = meta.with_cause(cause);
        }
        let tx = Transaction {
            changes,
            selection,
            meta,
        };
        let after = buffer.apply(tx, &self.views[&view].selection)?;
        self.view_mut(view).selection = after;
        self.map_other_views(view);
        Ok(())
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
        self.views.insert(id, View { buffer, selection });
        self.focus = id;
        id
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
        self.map_other_views(view);
        Ok(true)
    }

    /// Maps the selections of other views on `view`'s buffer through the
    /// buffer's latest transaction.
    fn map_other_views(&mut self, view: ViewId) {
        let buffer = self.view(view).buffer;
        let changes = &self.buffers[&buffer]
            .history()
            .log()
            .last()
            .expect("a transaction was just applied")
            .changes;
        for (id, other) in &mut self.views {
            if *id != view && other.buffer == buffer {
                other.selection = other.selection.map(changes);
            }
        }
    }
}
