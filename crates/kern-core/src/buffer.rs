use std::collections::BTreeMap;
use std::io::Write;
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use kern_text::{Assoc, Author, ChangeSet, Rope, Selection, Transaction, TxId, TxMeta};
use smallvec::SmallVec;

use crate::Error;
use crate::history::{History, Step};
use crate::syntax::language_name;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct BufferId(pub u32);

/// Open text, backed by a file or not.
#[derive(Debug)]
pub struct Buffer {
    id: BufferId,
    text: Rope,
    kind: Arc<str>,
    path: Option<PathBuf>,
    history: History,
    /// The latest transaction(s): the buffer's version. Empty until the first
    /// edit.
    version: SmallVec<[TxId; 1]>,
    /// The version last loaded from or written to the file.
    saved: SmallVec<[TxId; 1]>,
    readonly: bool,
    /// The language set for the buffer, overriding the one its path implies.
    language: Option<Arc<str>>,
    /// Decorations by namespace. They move with edits.
    marks: BTreeMap<Arc<str>, Vec<Mark>>,
}

/// Text drawn with a style, e.g. a search match. It moves with edits; text
/// typed at either edge stays outside it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Mark {
    pub range: Range<usize>,
    /// A style name for the theme.
    pub style: Arc<str>,
    /// Style the whole of every line the mark touches, not just its text.
    pub line: bool,
    /// Text shown that isn't in the buffer, like an inlay hint: at the start
    /// of the range, or after the end of its line with `eol`.
    pub text: Option<Arc<str>>,
    pub eol: bool,
    /// A symbol for the sign column, next to the line numbers.
    pub sign: Option<Arc<str>>,
    /// Draw over selections and cursors rather than under them, e.g. for a
    /// flash that must show even on selected text.
    pub above: bool,
}

impl Buffer {
    /// Creates a buffer. `kind` says what it is (`"file"`, `"terminal"`, …)
    /// and picks its keymaps and event handlers.
    pub fn new(id: BufferId, kind: impl Into<Arc<str>>, text: &str) -> Self {
        Self {
            id,
            text: Rope::from_str(text),
            kind: kind.into(),
            path: None,
            history: History::default(),
            version: SmallVec::new(),
            saved: SmallVec::new(),
            readonly: false,
            language: None,
            marks: BTreeMap::new(),
        }
    }

    /// The marks in namespace `ns`.
    pub fn marks(&self, ns: &str) -> &[Mark] {
        self.marks.get(ns).map_or(&[], Vec::as_slice)
    }

    /// Every mark, by namespace.
    pub fn all_marks(&self) -> impl Iterator<Item = &Mark> {
        self.marks.values().flatten()
    }

    /// Replaces the marks in namespace `ns`.
    pub(crate) fn set_marks(&mut self, ns: &str, marks: Vec<Mark>) {
        if marks.is_empty() {
            self.marks.remove(ns);
        } else {
            self.marks.insert(ns.into(), marks);
        }
    }

    /// Moves every mark through `changes`, dropping marks whose text went.
    fn map_marks(&mut self, changes: &ChangeSet) {
        for marks in self.marks.values_mut() {
            marks.retain_mut(|mark| {
                let was_empty = mark.range.is_empty();
                let start = changes.map_pos(mark.range.start, Assoc::After);
                let end = changes.map_pos(mark.range.end, Assoc::Before);
                mark.range = start..end.max(start);
                was_empty || start < end
            });
        }
        self.marks.retain(|_, marks| !marks.is_empty());
    }

    #[must_use]
    pub fn with_path(mut self, path: impl Into<PathBuf>) -> Self {
        self.path = Some(path.into());
        self
    }

    pub fn id(&self) -> BufferId {
        self.id
    }

    pub fn text(&self) -> &Rope {
        &self.text
    }

    pub fn kind(&self) -> &str {
        &self.kind
    }

    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    /// Sets the buffer's file, returning the previous one.
    pub(crate) fn set_path(&mut self, path: Option<PathBuf>) -> Option<PathBuf> {
        std::mem::replace(&mut self.path, path)
    }

    /// Whether only plugins can change the text.
    pub fn is_readonly(&self) -> bool {
        self.readonly
    }

    pub(crate) fn set_readonly(&mut self, readonly: bool) {
        self.readonly = readonly;
    }

    /// The language the text is in: the one set for the buffer, or the one
    /// its file extension implies.
    pub fn language(&self) -> Option<&str> {
        self.language
            .as_deref()
            .or_else(|| language_name(self.path.as_deref()?))
    }

    pub(crate) fn set_language(&mut self, language: Option<Arc<str>>) {
        self.language = language;
    }

    /// Writes the text to the buffer's file.
    pub fn save(&mut self) -> std::io::Result<()> {
        let path = self
            .path
            .as_deref()
            .ok_or_else(|| std::io::Error::other("this buffer has no file"))?;
        let mut file = std::io::BufWriter::new(std::fs::File::create(path)?);
        self.text.write_to(&mut file)?;
        file.flush()?;
        self.saved = self.version.clone();
        Ok(())
    }

    pub fn history(&self) -> &History {
        &self.history
    }

    /// True if the text changed since it was loaded or last saved.
    pub fn is_modified(&self) -> bool {
        self.version != self.saved
    }

    pub fn version(&self) -> &[TxId] {
        &self.version
    }

    /// Applies a transaction made against the current version and records it
    /// as an undo step. Returns the selection that follows it.
    pub fn apply(&mut self, tx: Transaction, current: &Selection) -> Result<Selection, Error> {
        self.check_author(&tx.meta.author)?;
        self.check_version(&tx.meta)?;
        let before = self.text.clone();
        let after = tx.apply(&mut self.text, current)?;
        let inverse = tx.changes.invert(&before)?;
        self.map_marks(&tx.changes);
        self.version = SmallVec::from_buf([tx.meta.id]);
        self.history
            .commit(tx, inverse, current.clone(), after.clone());
        Ok(after)
    }

    /// Undoes the current undo step as a new transaction with id `id`.
    /// Returns the restored selection, or `None` if there is nothing to undo.
    pub fn undo(
        &mut self,
        id: TxId,
        author: Author,
        current: &Selection,
    ) -> Result<Option<Selection>, Error> {
        let Some(step) = self.history.undo_step() else {
            return Ok(None);
        };
        let selection = self.step(step, id, author, "undo", current)?;
        self.history.move_up();
        Ok(Some(selection))
    }

    /// Redoes the most recently undone step as a new transaction with id
    /// `id`. Returns the restored selection, or `None` if there is nothing to
    /// redo.
    pub fn redo(
        &mut self,
        id: TxId,
        author: Author,
        current: &Selection,
    ) -> Result<Option<Selection>, Error> {
        let Some(step) = self.history.redo_step() else {
            return Ok(None);
        };
        let selection = self.step(step, id, author, "redo", current)?;
        self.history.move_down();
        Ok(Some(selection))
    }

    fn step(
        &mut self,
        step: Step,
        id: TxId,
        author: Author,
        cause: &str,
        current: &Selection,
    ) -> Result<Selection, Error> {
        self.check_author(&author)?;
        let tx = Transaction {
            changes: step.changes,
            selection: Some(step.selection),
            meta: TxMeta::new(id, &self.version, author).with_cause(cause),
        };
        let selection = tx.apply(&mut self.text, current)?;
        self.map_marks(&tx.changes);
        self.version = SmallVec::from_buf([id]);
        self.history.record(tx);
        Ok(selection)
    }

    fn check_author(&self, author: &Author) -> Result<(), Error> {
        if self.readonly && !matches!(author, Author::Plugin(_)) {
            return Err(Error::ReadOnly);
        }
        Ok(())
    }

    fn check_version(&self, meta: &TxMeta) -> Result<(), Error> {
        if meta.parents.as_slice() == self.version.as_slice() {
            Ok(())
        } else {
            Err(Error::StaleVersion {
                expected: self.version.to_vec(),
                actual: meta.parents.to_vec(),
            })
        }
    }
}
