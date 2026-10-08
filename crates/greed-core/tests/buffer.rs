use greed_core::{Buffer, BufferId, Error};
use greed_text::{
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

    /// Replaces `from..to` with `text` without keeping it to undo, as a
    /// plugin streaming output in does; the cursor moves with the text.
    fn unrecorded(&mut self, from: usize, to: usize, text: &str) {
        let len = self.buffer.text().len_bytes();
        let changes = ChangeSet::from_changes(len, [(from, to, Some(text))]).unwrap();
        let tx = self.tx(changes, Author::Plugin("shell".into()), None);
        let after = self.buffer.apply_unrecorded(tx, Some(&self.selection));
        self.selection = after.unwrap().unwrap();
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
    let path = std::env::temp_dir().join(format!("greed-modified-{}.txt", std::process::id()));
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

#[test]
fn text_before_a_transaction_comes_back_from_the_log() {
    let mut f = Fixture::new("one");
    let a = f.edit(3, 3, " two");
    let b = f.edit(0, 3, "ONE");
    f.undo();
    let history = f.buffer.history();
    let before = |id| {
        history
            .text_before(f.buffer.text(), id)
            .map(|t| t.to_string())
    };
    assert_eq!(before(a).as_deref(), Some("one"));
    assert_eq!(before(b).as_deref(), Some("one two"));
    let missing = TxId { replica: 9, seq: 9 };
    assert_eq!(before(missing), None);
}

#[test]
fn a_group_is_current_buried_or_undone() {
    use greed_core::GroupState;
    let mut f = Fixture::new("");
    assert_eq!(f.buffer.history().group_state(1), GroupState::Absent);
    f.edit_by(0, 0, "a", USER, Some(1));
    assert_eq!(f.buffer.history().group_state(1), GroupState::Current);
    f.edit(1, 1, "b");
    assert_eq!(f.buffer.history().group_state(1), GroupState::Buried);
    f.undo();
    f.undo();
    assert_eq!(f.buffer.history().group_state(1), GroupState::Undone);
}

#[test]
fn undo_skips_an_edit_kept_out_of_it_and_takes_back_only_the_typing() {
    let mut f = Fixture::new("$ ");
    f.selection = Selection::point(2);
    f.edit(2, 2, "ls");
    // Output arrives above the prompt while the cursor is after the typing.
    f.unrecorded(0, 0, "out\n");
    assert_eq!(f.text(), "out\n$ ls");
    assert_eq!(f.selection.primary(), Range::point(8));
    assert!(f.undo());
    assert_eq!(f.text(), "out\n$ ");
    // Where the typing started, moved along by the output.
    assert_eq!(f.selection.primary(), Range::point(6));
    assert!(!f.undo(), "the output isn't a step to undo");
    assert!(f.redo());
    assert_eq!(f.text(), "out\n$ ls");
    assert_eq!(f.selection.primary(), Range::point(8));
}

#[test]
fn an_edit_kept_out_of_undo_inside_typed_text_stays_when_the_typing_goes() {
    let mut f = Fixture::new("");
    f.edit_by(0, 0, "ab", USER, Some(1));
    f.unrecorded(1, 1, "X");
    f.edit_by(3, 3, "c", USER, Some(1));
    assert_eq!(f.text(), "aXbc");
    // The typing is one group still, and undo takes all of it back.
    assert!(f.undo());
    assert_eq!(f.text(), "X");
    assert!(!f.undo());
}

#[test]
fn steps_an_edit_kept_out_of_undo_took_away_go() {
    let mut f = Fixture::new("");
    f.edit(0, 0, "typed");
    f.edit(5, 5, " more");
    // A plugin replaces everything, as a shell does when a command runs.
    f.unrecorded(0, 10, "block\n");
    assert_eq!(f.text(), "block\n");
    assert!(!f.undo(), "nothing typed is left to take back");
    assert_eq!(f.text(), "block\n");
}

#[test]
fn redo_branches_go_and_the_log_starts_again_after_an_edit_kept_out_of_undo() {
    let mut f = Fixture::new("");
    f.edit(0, 0, "a");
    f.edit(1, 1, "b");
    f.undo();
    assert!(f.buffer.history().can_redo());
    f.unrecorded(0, 0, ">");
    assert!(!f.buffer.history().can_redo(), "the redo branch went");
    assert!(f.buffer.history().log().is_empty());
    assert_eq!(f.buffer.history().applied(), 4);
    let id = f.edit(2, 2, "c");
    assert_eq!(f.buffer.history().log().len(), 1);
    let before = f.buffer.history().text_before(f.buffer.text(), id);
    assert_eq!(before.map(|t| t.to_string()).as_deref(), Some(">a"));
    assert!(f.undo());
    assert!(f.undo());
    assert_eq!(f.text(), ">");
}

/// Something done to a buffer: an edit that's kept to undo (`from`, how
/// many characters it replaces, the text) or output kept out of it.
#[derive(Debug, Clone)]
enum Done {
    Typed(usize, usize, String),
    Output(usize, String),
}

fn done() -> impl Strategy<Value = Done> {
    prop_oneof![
        ("[a-cé]{0,3}", 0..12usize, 0..4usize).prop_map(|(t, at, n)| Done::Typed(at, n, t)),
        ("X{1,3}", 0..12usize).prop_map(|(t, at)| Done::Output(at, t)),
    ]
}

/// The byte offset of the `n`th character of `text`, or its end.
fn char_at(text: &str, n: usize) -> usize {
    text.char_indices()
        .map(|(i, _)| i)
        .chain([text.len()])
        .nth(n)
        .unwrap_or(text.len())
}

proptest! {
    #[test]
    fn undoing_every_kept_step_leaves_the_start_with_the_output_in(
        start in "[a-cé]{0,6}",
        steps in prop::collection::vec(done(), 1..16),
    ) {
        let mut f = Fixture::new(&start);
        let mut output = 0;
        for step in &steps {
            let text = f.text();
            match step {
                Done::Typed(at, n, typed) => {
                    let from = char_at(&text, *at);
                    let to = char_at(&text, at + n);
                    f.edit(from, to, typed);
                }
                Done::Output(at, out) => {
                    let pos = char_at(&text, *at);
                    f.unrecorded(pos, pos, out);
                    output += out.len();
                }
            }
        }
        let end = f.text();
        let mut undone = 0;
        while f.undo() {
            undone += 1;
            prop_assert!(undone <= steps.len(), "more undo steps than edits");
        }
        let left = f.text();
        // Every bit of output is there, and without it, the text it started as.
        prop_assert_eq!(left.matches('X').count(), output);
        prop_assert_eq!(left.replace('X', ""), start);
        for _ in 0..undone {
            prop_assert!(f.redo());
        }
        prop_assert_eq!(f.text(), end);
    }
}
