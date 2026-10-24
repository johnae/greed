use std::collections::{BTreeMap, HashMap};
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use greed_text::{Assoc, Author, ChangeSet, Rope, Selection, Transaction, TxId, TxMeta};
use smallvec::SmallVec;

use crate::history::{History, SavedHistory, Step};
use crate::keymap::Key;
use crate::{Error, ViewId};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct BufferId(pub u32);

/// Open text, backed by a file or not.
#[derive(Debug)]
#[expect(clippy::struct_excessive_bools, reason = "independent flags")]
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
    /// Where in the undo tree that text was, so undo or redo back to it
    /// counts as unmodified.
    saved_place: Option<u64>,
    readonly: bool,
    /// Where the part of the text only plugins can change ends, when that's
    /// only its start, like a transcript above the box you write in. It
    /// moves with edits: what plugins insert there joins the read-only part,
    /// what you type there stays writable.
    readonly_before: Option<usize>,
    /// Whether the file wasn't UTF-8 and what couldn't be read was replaced,
    /// so saving over it would lose that.
    lossy: bool,
    /// Whether the main view shows line numbers beside it.
    line_numbers: bool,
    /// How many columns apart its tab stops are.
    tab_width: usize,
    /// Kept open while nothing shows it, though it has no file.
    kept: bool,
    /// Single keys bound for this buffer alone, ahead of every keymap layer.
    keys: HashMap<Key, Arc<str>>,
    /// The language set for the buffer, overriding the detected one.
    language: Option<Arc<str>>,
    /// The language its file name says, from the editor's file types.
    detected: Option<Arc<str>>,
    /// Decorations by namespace. They move with edits.
    marks: BTreeMap<Arc<str>, Vec<Mark>>,
    /// Places plugins follow through edits, by id.
    tracked: HashMap<TrackId, Tracked>,
    next_track: u64,
    /// The text edits changed since plugins were last told, as it is now.
    changed: Option<Range<usize>>,
    /// The size its text is laid out at in every view, whatever room a view
    /// has, like a terminal's screen, which can be one size only.
    screen_size: Option<ScreenSize>,
    /// What a buffer without a file is called where it shows, like a
    /// terminal's "nu ~/src", set by the plugin that made it.
    name: Option<Arc<str>>,
}

/// The size a buffer's text is laid out at, in rows and columns, and what a
/// client shows on a view of another size: why it doesn't fit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScreenSize {
    pub rows: u16,
    pub cols: u16,
    pub note: Option<Arc<str>>,
    /// The row of the screen, its buffer's last `rows` lines, to keep in
    /// sight where it's cropped, like where a terminal's program has its
    /// cursor.
    pub cursor_row: Option<u16>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TrackId(pub u64);

/// A range of the text that moves with edits without being drawn, so a
/// plugin can find a place again after the text around it changed. A
/// position is an empty range.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tracked {
    pub range: Range<usize>,
    /// The side of text inserted exactly at the start, and at the end, that
    /// each stays on.
    pub gravity: (Assoc, Assoc),
    /// Whether all of the range's text was deleted. It stays deleted, even
    /// if undo brings the text back. A range that started empty never is.
    pub deleted: bool,
}

/// Text drawn with a style, e.g. a search match. It moves with edits; text
/// typed at either edge stays outside it.
#[derive(Debug, Clone, PartialEq, Eq)]
#[expect(clippy::struct_excessive_bools, reason = "flags set from Luau")]
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
    /// Separate EOL text from the line or preceding EOL text with a space.
    pub eol_space: bool,
    /// A symbol for the sign column, next to the line numbers.
    pub sign: Option<Arc<str>>,
    /// A style for the line number of each line the mark touches.
    pub gutter: Option<Arc<str>>,
    /// Draw over selections and cursors rather than under them, e.g. for a
    /// flash that must show even on selected text.
    pub above: bool,
    /// Draw `text` over the characters from the start of the range, like a
    /// jump label, instead of inserting it.
    pub overlay: bool,
    /// Hide the range's text, showing `text` (if any) in its place, e.g. the
    /// brackets of a `[[link]]`, except where `reveal` says.
    pub conceal: bool,
    /// When a concealing mark shows its text after all.
    pub reveal: Reveal,
    /// Hide the lines after the range's first line, up to its last, unless a
    /// cursor is in them, e.g. a section folded under its heading.
    pub fold: bool,
    /// With `fold`, show the lines while a cursor is on the first line too,
    /// as a part hidden under the line that says when it shows.
    pub peek: bool,
    /// Don't wrap the lines the range touches: what's past the right edge is
    /// out of sight, and the view scrolls sideways to show the cursor, as
    /// for a wide table.
    pub nowrap: bool,
    /// Draw the range's text without syntax highlighting, e.g. a tool's
    /// output in an agent's Markdown transcript.
    pub plain: bool,
    /// Lines shown under the range's last line that aren't in the buffer,
    /// like a list of backlinks. The cursor never goes on them.
    pub lines: Vec<VirtualLine>,
    /// An image drawn over the text from the start of the range.
    pub image: Option<MarkImage>,
    /// A scene drawn over the text from the start of the range, by the
    /// clients that can; the text there is what the others show.
    pub scene: Option<MarkScene>,
    /// A command that clicking the mark's `text` runs, with the cursor put
    /// at the start of the range first, like a button.
    pub action: Option<Arc<str>>,
    /// How many times bigger the range's text (and the mark's `text`) is:
    /// each character takes that many cells across, and its row that many
    /// rows down. 0 and 1 are the normal size.
    pub scale: u8,
    /// Anything its owner wants kept with it, like a problem's message.
    /// Never drawn.
    pub data: Option<serde_json::Value>,
    /// The one view that draws it, as `view:decorate` sets; every view of
    /// the buffer when none.
    pub view: Option<ViewId>,
}

impl Default for Mark {
    fn default() -> Self {
        Self {
            range: Range::default(),
            style: Arc::default(),
            line: false,
            text: None,
            eol: false,
            eol_space: true,
            sign: None,
            gutter: None,
            above: false,
            overlay: false,
            conceal: false,
            reveal: Reveal::default(),
            fold: false,
            peek: false,
            nowrap: false,
            plain: false,
            lines: Vec::new(),
            image: None,
            scene: None,
            action: None,
            scale: 0,
            data: None,
            view: None,
        }
    }
}

/// When a concealing mark shows the text it hides, so it can be edited.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Reveal {
    /// When a cursor is on its line.
    #[default]
    Line,
    /// When a cursor is inside it, past its start: a click, which puts the
    /// cursor at the start, leaves it hidden.
    Cursor,
    /// Never.
    Never,
    /// As the editor says for all such marks at once, e.g. on its line
    /// only while typing (see [`crate::Editor::set_reveal`]).
    Auto,
    /// As the editor says for markup that shows only while typing, like a
    /// table's borders (see [`crate::Editor::set_typing_reveal`]).
    Typing,
}

/// A line a mark shows under the text: drawn in the mark's style, with
/// `styles` on top of parts of it (byte ranges of `text`), like the words
/// that changed in a proposed line. On a float's border, `actions` are the
/// commands parts of it run when clicked (byte ranges too), like a label's
/// arrows going to the float before or after.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct VirtualLine {
    pub text: Arc<str>,
    pub styles: Vec<(Range<usize>, Arc<str>)>,
    pub actions: Vec<(Range<usize>, Arc<str>)>,
}

impl From<&str> for VirtualLine {
    fn from(text: &str) -> Self {
        VirtualLine {
            text: text.into(),
            ..VirtualLine::default()
        }
    }
}

/// An image over a block of cells: `cols` by `rows`, right of and below
/// the mark's start. `col` and `row` say which of the image's cells is at
/// the start, so an image whose top or left was cut off still lines up.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct MarkImage {
    pub id: crate::image::ImageId,
    pub cols: u16,
    pub rows: u16,
    pub col: u16,
    pub row: u16,
}

/// A scene over a block of cells, as `MarkImage` places an image. A
/// negative `row` starts it that many rows below the mark's start, like a
/// chart under the comment line that asks for it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct MarkScene {
    pub id: crate::scene::SceneId,
    pub cols: u16,
    pub rows: u16,
    pub col: u16,
    pub row: i32,
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
            saved_place: Some(0),
            readonly: false,
            readonly_before: None,
            lossy: false,
            line_numbers: true,
            tab_width: crate::render::TAB_WIDTH,
            kept: false,
            keys: HashMap::new(),
            language: None,
            detected: None,
            marks: BTreeMap::new(),
            tracked: HashMap::new(),
            next_track: 0,
            changed: None,
            screen_size: None,
            name: None,
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

    /// The marks over `pos`, with their namespaces: those whose range holds
    /// it, and empty ones that start there.
    pub fn marks_at(&self, pos: usize) -> impl Iterator<Item = (&str, &Mark)> {
        self.marks.iter().flat_map(move |(ns, marks)| {
            marks
                .iter()
                .filter(move |m| {
                    m.range.contains(&pos) || (m.range.is_empty() && m.range.start == pos)
                })
                .map(move |m| (&**ns, m))
        })
    }

    /// The marks `view` draws: its own and every view's.
    pub fn marks_for(&self, view: ViewId) -> impl Iterator<Item = &Mark> {
        self.all_marks()
            .filter(move |m| m.view.is_none_or(|v| v == view))
    }

    /// Replaces the marks in namespace `ns` that only `view` draws (with
    /// none, those every view draws) and that start within `range`, if
    /// given, with `marks`, keeping the rest.
    pub(crate) fn set_marks_in(
        &mut self,
        ns: &str,
        view: Option<ViewId>,
        range: Option<Range<usize>>,
        marks: Vec<Mark>,
    ) {
        let range = range.unwrap_or(0..usize::MAX);
        let mut kept = self.marks.remove(ns).unwrap_or_default();
        kept.retain(|m| m.view != view || !range.contains(&m.range.start));
        kept.extend(marks);
        self.set_marks(ns, kept);
    }

    /// Takes away the marks only `view` draws, once it's gone.
    pub(crate) fn forget_view(&mut self, view: ViewId) {
        for marks in self.marks.values_mut() {
            marks.retain(|m| m.view != Some(view));
        }
        self.marks.retain(|_, marks| !marks.is_empty());
    }

    /// Replaces the marks in namespace `ns`.
    pub(crate) fn set_marks(&mut self, ns: &str, marks: Vec<Mark>) {
        if marks.is_empty() {
            self.marks.remove(ns);
        } else {
            self.marks.insert(ns.into(), marks);
        }
    }

    /// Starts following `range` (clamped to the text) through edits.
    pub(crate) fn track(&mut self, range: Range<usize>, gravity: (Assoc, Assoc)) -> TrackId {
        let end = range.end.min(self.text.len_bytes());
        let id = TrackId(self.next_track);
        self.next_track += 1;
        let tracked = Tracked {
            range: range.start.min(end)..end,
            gravity,
            deleted: false,
        };
        self.tracked.insert(id, tracked);
        id
    }

    /// Where the range tracked as `id` is now, unless it was forgotten.
    pub fn tracked(&self, id: TrackId) -> Option<&Tracked> {
        self.tracked.get(&id)
    }

    pub(crate) fn forget(&mut self, id: TrackId) {
        self.tracked.remove(&id);
    }

    /// Moves every mark and tracked range through `changes`, dropping marks
    /// whose text went.
    fn map_marks(&mut self, changes: &ChangeSet) {
        for t in self.tracked.values_mut() {
            let was_empty = t.range.is_empty();
            let start = changes.map_pos(t.range.start, t.gravity.0);
            let end = changes.map_pos(t.range.end, t.gravity.1).max(start);
            t.range = start..end;
            t.deleted |= !was_empty && start == end;
        }
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

    /// Adds what `changes` changed to the text plugins haven't been told
    /// about, moving what was there through them.
    fn note_changed(&mut self, changes: &ChangeSet) {
        let Some(new) = changes.changed_range() else {
            return;
        };
        self.changed = Some(match self.changed.take() {
            Some(old) => {
                let start = changes.map_pos(old.start, Assoc::Before);
                let end = changes.map_pos(old.end, Assoc::After);
                start.min(new.start)..end.max(new.end)
            }
            None => new,
        });
    }

    /// The text edits changed since this was last called, as it is now, or
    /// `None` if they changed nothing.
    pub fn take_changed(&mut self) -> Option<Range<usize>> {
        self.changed.take()
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

    /// Where the read-only start of the text ends, if only its start is.
    pub fn readonly_before(&self) -> Option<usize> {
        self.readonly_before
    }

    /// Makes the text before `pos` (clamped to the text) read-only and the
    /// rest writable, or with `None`, all of it writable again.
    pub(crate) fn set_readonly_before(&mut self, pos: Option<usize>) {
        self.readonly_before = pos.map(|pos| pos.min(self.text.len_bytes()));
    }

    /// Whether `changes` reach into the read-only start of the text.
    pub(crate) fn touches_readonly_start(&self, changes: &ChangeSet) -> bool {
        let first = changes.changed_range().map(|range| range.start);
        matches!((self.readonly_before, first), (Some(before), Some(first)) if first < before)
    }

    /// Whether the file wasn't UTF-8 when opened, so the text has
    /// replacements in it and saving over the file is refused.
    pub fn is_lossy(&self) -> bool {
        self.lossy
    }

    pub(crate) fn set_lossy(&mut self, lossy: bool) {
        self.lossy = lossy;
    }

    pub fn line_numbers(&self) -> bool {
        self.line_numbers
    }

    pub(crate) fn set_line_numbers(&mut self, on: bool) {
        self.line_numbers = on;
    }

    /// How many columns apart its tab stops are.
    pub fn tab_width(&self) -> usize {
        self.tab_width
    }

    /// Sets how many columns apart its tab stops are, at least 1.
    pub(crate) fn set_tab_width(&mut self, width: usize) {
        self.tab_width = width.max(1);
    }

    /// Whether it stays open while nothing shows it, though it has no file.
    pub fn is_kept(&self) -> bool {
        self.kept
    }

    pub(crate) fn set_kept(&mut self, kept: bool) {
        self.kept = kept;
    }

    /// The size its text is laid out at in every view, if it has one.
    pub fn screen_size(&self) -> Option<&ScreenSize> {
        self.screen_size.as_ref()
    }

    /// Lays its text out at `size` in every view, or with `None` at each
    /// view's own size again.
    pub fn set_screen_size(&mut self, size: Option<ScreenSize>) {
        self.screen_size = size;
    }

    /// What it's called where it shows, if it was given a name.
    pub fn name(&self) -> Option<&str> {
        self.name.as_deref()
    }

    /// Names it, or with `None` (or "") leaves it unnamed again.
    pub fn set_name(&mut self, name: Option<&str>) {
        self.name = name.filter(|n| !n.is_empty()).map(Arc::from);
    }

    /// What it's called where it shows: its file's name, the name it was
    /// given, "untitled" for a file not saved yet, or its kind, like
    /// "terminal".
    pub fn title(&self) -> String {
        match (self.path().and_then(|p| p.file_name()), self.name()) {
            (Some(file), _) => file.to_string_lossy().into_owned(),
            (None, Some(name)) => name.to_owned(),
            (None, None) if self.kind() == "file" => "untitled".to_owned(),
            (None, None) => self.kind().to_owned(),
        }
    }

    /// The command `key` runs in this buffer whatever the mode, if it's
    /// bound for the buffer.
    pub fn key(&self, key: Key) -> Option<&Arc<str>> {
        self.keys.get(&key)
    }

    pub(crate) fn set_keys(&mut self, keys: HashMap<Key, Arc<str>>) {
        self.keys = keys;
    }

    /// The language the text is in: the one set for the buffer, or the one
    /// its file name says.
    pub fn language(&self) -> Option<&str> {
        self.language.as_deref().or(self.detected.as_deref())
    }

    pub(crate) fn set_language(&mut self, language: Option<Arc<str>>) {
        self.language = language;
    }

    pub(crate) fn set_detected(&mut self, language: Option<Arc<str>>) {
        self.detected = language;
    }

    /// Writes the text to the buffer's file, whole (see [`crate::files::write`]).
    /// Refused if the file didn't open as UTF-8.
    pub fn save(&mut self) -> std::io::Result<()> {
        let path = self
            .path
            .as_deref()
            .ok_or_else(|| std::io::Error::other("this buffer has no file"))?;
        if self.lossy {
            return Err(std::io::Error::other(format!(
                "{} isn't UTF-8, so saving would replace what couldn't be read; save to another path instead",
                path.display()
            )));
        }
        crate::files::write(path, |out| self.text.write_to(out)).map_err(|err| {
            std::io::Error::new(err.kind(), format!("can't save {}: {err}", path.display()))
        })?;
        self.mark_saved();
        Ok(())
    }

    /// Counts the text as what its file holds, as after a save.
    pub(crate) fn mark_saved(&mut self) {
        self.saved = self.version.clone();
        self.saved_place = self.history.place();
    }

    pub fn history(&self) -> &History {
        &self.history
    }

    /// Takes back an undo tree kept from before (`History::saved`), whose
    /// current step is the text as it is now; only while nothing was done
    /// since the buffer was loaded. The text stays as saved.
    pub fn restore_history(&mut self, saved: &SavedHistory) -> Result<(), String> {
        let unmodified = !self.is_modified();
        self.history.restore(saved, self.text.len_bytes())?;
        if unmodified {
            self.saved_place = self.history.place();
        }
        Ok(())
    }

    /// Stops keeping undo history, for buffers whose edits nobody undoes,
    /// like a terminal's: what's kept goes, and later edits aren't kept.
    pub fn forget_history(&mut self) {
        self.history.forget();
    }

    /// Lets go of the undo history so far, keeping later edits: undo can't
    /// go back past now, as at a shell's prompt after a command runs.
    pub fn clear_history(&mut self) {
        self.history.clear();
    }

    /// Makes redo follow undo-tree node `child` (see `History::prefer`).
    pub(crate) fn prefer_branch(&mut self, child: usize) {
        self.history.prefer(child);
    }

    /// True if the text changed since it was loaded or last saved, and undo
    /// or redo hasn't brought it back to that.
    pub fn is_modified(&self) -> bool {
        self.version != self.saved
            && (self.saved_place.is_none() || self.saved_place != self.history.place())
    }

    pub fn version(&self) -> &[TxId] {
        &self.version
    }

    /// Applies a transaction made against the current version and records it
    /// as an undo step. Returns the selection that follows it.
    pub fn apply(&mut self, tx: Transaction, current: &Selection) -> Result<Selection, Error> {
        let after = self.commit(tx, Some(current), true)?;
        Ok(after.expect("a selection to map gives one back"))
    }

    /// Applies a transaction made without a view. Undoing or redoing it
    /// leaves views where the change moves them, unless it sets a selection,
    /// which is returned and which redo restores.
    pub fn apply_detached(&mut self, tx: Transaction) -> Result<Option<Selection>, Error> {
        self.commit(tx, None, true)
    }

    /// Applies a transaction without keeping it to undo, like output
    /// streaming in above a prompt: undo and redo skip it, and the steps
    /// kept still take back only what they did (see `History::skip`).
    /// `current` is the selection of the view it's made in, if any; returns
    /// the selection that follows it, as `apply` and `apply_detached` do.
    pub fn apply_unrecorded(
        &mut self,
        tx: Transaction,
        current: Option<&Selection>,
    ) -> Result<Option<Selection>, Error> {
        self.commit(tx, current, false)
    }

    fn commit(
        &mut self,
        tx: Transaction,
        current: Option<&Selection>,
        record: bool,
    ) -> Result<Option<Selection>, Error> {
        self.check_author(&tx.meta.author, &tx.changes)?;
        self.check_version(&tx.meta)?;
        let before = self.text.clone();
        let mapped = tx.apply(&mut self.text, current.unwrap_or(&Selection::point(0)))?;
        let after = (current.is_some() || tx.selection.is_some()).then_some(mapped);
        let inverse = tx.changes.invert(&before)?;
        self.map_readonly(&tx.changes, &tx.meta.author);
        self.map_marks(&tx.changes);
        self.note_changed(&tx.changes);
        self.version = SmallVec::from_buf([tx.meta.id]);
        if !record {
            self.history.skip(tx.changes, &self.text);
            return Ok(after);
        }
        self.history
            .commit(tx, inverse, current.cloned(), after.clone());
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
        self.check_author(&author, &step.changes)?;
        let tx = Transaction {
            changes: step.changes,
            selection: step.selection,
            meta: TxMeta::new(id, &self.version, author).with_cause(cause),
        };
        let inverse = tx.changes.invert(&self.text)?;
        let selection = tx.apply(&mut self.text, current)?;
        self.map_readonly(&tx.changes, &tx.meta.author);
        self.map_marks(&tx.changes);
        self.note_changed(&tx.changes);
        self.version = SmallVec::from_buf([id]);
        self.history.record(tx, inverse);
        Ok(selection)
    }

    /// Refuses `changes` by anyone but a plugin where the text is read-only.
    fn check_author(&self, author: &Author, changes: &ChangeSet) -> Result<(), Error> {
        if matches!(author, Author::Plugin(_)) {
            return Ok(());
        }
        if self.readonly {
            return Err(Error::ReadOnly);
        }
        if self.touches_readonly_start(changes) {
            return Err(Error::ReadOnlyPart);
        }
        Ok(())
    }

    fn map_readonly(&mut self, changes: &ChangeSet, author: &Author) {
        let assoc = if matches!(author, Author::Plugin(_)) {
            Assoc::After
        } else {
            Assoc::Before
        };
        self.readonly_before = self.readonly_before.map(|pos| changes.map_pos(pos, assoc));
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
