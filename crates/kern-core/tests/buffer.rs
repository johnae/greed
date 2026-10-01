use kern_core::{Buffer, BufferId, Error};
use kern_text::{
    AgentId, Author, ChangeSet, ClientId, Range, Replica, Selection, Transaction, TxId, TxMeta,
};
use proptest::prelude::*;

const USER: Author = Author::User(ClientId(1));

struct Fixture {
    replica: Replica,
    buffer: Buffer,
    selection: Selection,
}

impl Fixture {
    fn new(text: &str) -> Self {
        Self {
            replica: Replica::new(1),
            buffer: Buffer::new(BufferId(1), "file", text),
            selection: Selection::point(0),
        }
    }

    fn tx(&mut self, changes: ChangeSet, author: Author, group: Option<u64>) -> Transaction {
        let mut meta = TxMeta::new(self.replica.next_id(), self.buffer.version(), author);
        meta.group = group;
        Transaction::new(changes, meta)
    }

    /// Replaces `from..to` with `text`, leaving a cursor after it.
    fn edit(&mut self, from: usize, to: usize, text: &str) -> TxId {
        self.edit_by(from, to, text, USER, None)
    }

    fn edit_by(
        &mut self,
        from: usize,
        to: usize,
        text: &str,
        author: Author,
        group: Option<u64>,
    ) -> TxId {
        let len = self.buffer.text().len_bytes();
        let changes = ChangeSet::from_changes(len, [(from, to, Some(text))]).unwrap();
        let mut tx = self.tx(changes, author, group);
        tx.selection = Some(Selection::point(from + text.len()));
        let id = tx.meta.id;
        self.selection = self.buffer.apply(tx, &self.selection).unwrap();
        id
    }

    fn undo(&mut self) -> bool {
        let id = self.replica.next_id();
        match self.buffer.undo(id, USER, &self.selection).unwrap() {
            Some(sel) => {
                self.selection = sel;
                true
            }
            None => false,
        }
    }

    fn redo(&mut self) -> bool {
        let id = self.replica.next_id();
        match self.buffer.redo(id, USER, &self.selection).unwrap() {
            Some(sel) => {
                self.selection = sel;
                true
            }
            None => false,
        }
    }

    fn text(&self) -> String {
        self.buffer.text().to_string()
    }
}

#[test]
fn new_buffer_is_pristine() {
    let f = Fixture::new("hello");
    assert_eq!(f.text(), "hello");
    assert!(f.buffer.version().is_empty());
    assert_eq!(f.buffer.kind(), "file");
    assert!(!f.buffer.history().can_undo());
    assert!(!f.buffer.history().can_redo());
}

#[test]
fn apply_advances_version() {
    let mut f = Fixture::new("hello");
    let id = f.edit(5, 5, "!");
    assert_eq!(f.text(), "hello!");
    assert_eq!(f.buffer.version(), &[id]);
    assert_eq!(f.selection.primary(), Range::point(6));
}

#[test]
fn apply_rejects_stale_version() {
    let mut f = Fixture::new("hello");
    let stale = f.tx(ChangeSet::identity(5), USER, None);
    f.edit(0, 0, ">");
    let err = f.buffer.apply(stale, &f.selection).unwrap_err();
    assert!(matches!(err, Error::StaleVersion { .. }), "{err:?}");
    assert_eq!(f.text(), ">hello");
}

#[test]
fn apply_passes_through_text_errors() {
    let mut f = Fixture::new("hello");
    let bad = f.tx(ChangeSet::identity(3), USER, None);
    let err = f.buffer.apply(bad, &f.selection).unwrap_err();
    assert!(matches!(err, Error::Text(_)), "{err:?}");
    assert!(f.buffer.version().is_empty());
}

#[test]
fn undo_and_redo_restore_text_and_selection() {
    let mut f = Fixture::new("hello");
    f.edit(5, 5, " world");
    f.edit(0, 5, "goodbye");
    assert_eq!(f.text(), "goodbye world");

    assert!(f.undo());
    assert_eq!(f.text(), "hello world");
    assert_eq!(f.selection.primary(), Range::point(11));
    assert!(f.undo());
    assert_eq!(f.text(), "hello");
    assert_eq!(f.selection.primary(), Range::point(0));
    assert!(!f.undo());

    assert!(f.redo());
    assert_eq!(f.text(), "hello world");
    assert_eq!(f.selection.primary(), Range::point(11));
    assert!(f.redo());
    assert_eq!(f.text(), "goodbye world");
    assert!(!f.redo());
}

#[test]
fn edit_after_undo_starts_a_branch_that_redo_follows() {
    let mut f = Fixture::new("");
    f.edit(0, 0, "a");
    f.edit(1, 1, "b");
    f.undo();
    f.edit(1, 1, "c");
    assert_eq!(f.text(), "ac");
    f.undo();
    assert_eq!(f.text(), "a");
    f.redo();
    assert_eq!(f.text(), "ac");
}

#[test]
fn grouped_transactions_undo_together() {
    let mut f = Fixture::new("");
    f.edit_by(0, 0, "a", USER, Some(1));
    f.edit_by(1, 1, "b", USER, Some(1));
    f.edit_by(2, 2, "c", USER, Some(2));
    f.undo();
    assert_eq!(f.text(), "ab");
    f.undo();
    assert_eq!(f.text(), "");
    f.redo();
    assert_eq!(f.text(), "ab");
}

#[test]
fn group_does_not_merge_across_an_undo() {
    let mut f = Fixture::new("");
    f.edit_by(0, 0, "a", USER, Some(1));
    f.edit_by(1, 1, "b", USER, Some(1));
    f.undo();
    f.edit_by(0, 0, "x", USER, Some(1));
    f.undo();
    assert_eq!(f.text(), "");
}

#[test]
fn log_records_every_transaction_including_undo() {
    let mut f = Fixture::new("");
    let a = f.edit(0, 0, "a");
    f.undo();
    let log = f.buffer.history().log();
    assert_eq!(log.len(), 2);
    assert_eq!(log[1].meta.parents.as_slice(), &[a]);
    assert_eq!(log[1].meta.cause.as_deref(), Some("undo"));
    assert_eq!(f.buffer.version(), &[log[1].meta.id]);
}

#[test]
fn history_filters_by_author() {
    let mut f = Fixture::new("");
    let agent = Author::Agent(AgentId(3));
    f.edit(0, 0, "a");
    let by_agent = f.edit_by(1, 1, "b", agent.clone(), None);
    f.edit(2, 2, "c");
    let ids: Vec<TxId> = f
        .buffer
        .history()
        .by_author(&agent)
        .map(|tx| tx.meta.id)
        .collect();
    assert_eq!(ids, [by_agent]);
}

proptest! {
    #[test]
    fn undo_all_then_redo_all_round_trips(
        edits in prop::collection::vec(("[a-cé]{0,3}", 0..4usize, 0..3usize), 1..12)
    ) {
        let mut f = Fixture::new("start");
        let mut texts = vec![f.text()];
        for (text, at, del) in &edits {
            let chars: Vec<usize> = f.text().char_indices().map(|(i, _)| i).chain([f.text().len()]).collect();
            let from = chars[(*at).min(chars.len() - 1)];
            let to = chars[(*at + *del).min(chars.len() - 1)];
            f.edit(from, to, text);
            texts.push(f.text());
        }
        for expected in texts.iter().rev().skip(1) {
            prop_assert!(f.undo());
            prop_assert_eq!(&f.text(), expected);
        }
        prop_assert!(!f.undo());
        for expected in texts.iter().skip(1) {
            prop_assert!(f.redo());
            prop_assert_eq!(&f.text(), expected);
        }
    }
}

#[test]
fn buffers_know_whether_they_changed_since_saving() {
    let path = std::env::temp_dir().join(format!("kern-modified-{}.txt", std::process::id()));
    let mut f = Fixture::new("");
    f.buffer = Buffer::new(BufferId(1), "file", "").with_path(&path);
    assert!(!f.buffer.is_modified());
    f.edit(0, 0, "x");
    assert!(f.buffer.is_modified());
    f.buffer.save().unwrap();
    assert!(!f.buffer.is_modified());
    f.edit(1, 1, "y");
    assert!(f.buffer.is_modified());
    std::fs::remove_file(&path).unwrap();
}
