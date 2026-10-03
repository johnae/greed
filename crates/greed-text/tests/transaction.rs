mod common;

use common::doc_and_changeset;
use greed_text::{
    AgentId, Author, ChangeSet, ClientId, Error, Range, Replica, Rope, Selection, Transaction,
    TxId, TxMeta,
};
use proptest::prelude::*;

fn meta(replica: &mut Replica, parents: &[TxId]) -> TxMeta {
    TxMeta::new(replica.next_id(), parents, Author::User(ClientId(1)))
}

#[test]
fn replica_ids_are_unique_and_ordered() {
    let mut a = Replica::new(1);
    let mut b = Replica::new(2);
    let (a1, a2, b1) = (a.next_id(), a.next_id(), b.next_id());
    assert_eq!(a1, TxId { replica: 1, seq: 0 });
    assert_eq!(a2, TxId { replica: 1, seq: 1 });
    assert!(a1 < a2);
    assert_ne!(a1, b1);
}

#[test]
fn meta_records_author_cause_and_group() {
    let mut r = Replica::new(1);
    let parent = r.next_id();
    let m = TxMeta::new(r.next_id(), &[parent], Author::Agent(AgentId(7)))
        .with_cause("edit.propose")
        .with_group(3);
    assert_eq!(m.parents.as_slice(), &[parent]);
    assert_eq!(m.author, Author::Agent(AgentId(7)));
    assert_eq!(m.cause.as_deref(), Some("edit.propose"));
    assert_eq!(m.group, Some(3));
}

#[test]
fn apply_uses_explicit_selection() {
    let mut r = Replica::new(1);
    let mut rope = Rope::from_str("hello");
    let tx = Transaction {
        changes: ChangeSet::from_changes(5, [(5, 5, Some(" world"))]).unwrap(),
        selection: Some(Selection::single(6, 11)),
        meta: meta(&mut r, &[]),
    };
    let sel = tx.apply(&mut rope, &Selection::point(0)).unwrap();
    assert_eq!(rope.to_string(), "hello world");
    assert_eq!(sel, Selection::single(6, 11));
}

#[test]
fn apply_maps_current_selection_without_explicit_one() {
    let mut r = Replica::new(1);
    let mut rope = Rope::from_str("hello");
    let tx = Transaction::new(
        ChangeSet::from_changes(5, [(0, 0, Some(">> "))]).unwrap(),
        meta(&mut r, &[]),
    );
    let sel = tx.apply(&mut rope, &Selection::single(0, 5)).unwrap();
    assert_eq!(rope.to_string(), ">> hello");
    assert_eq!(sel.primary(), Range::new(3, 8));
}

#[test]
fn apply_rejects_selection_past_end_without_mutating() {
    let mut r = Replica::new(1);
    let mut rope = Rope::from_str("abc");
    let tx = Transaction {
        changes: ChangeSet::from_changes(3, [(0, 1, None::<&str>)]).unwrap(),
        selection: Some(Selection::point(3)),
        meta: meta(&mut r, &[]),
    };
    assert_eq!(
        tx.apply(&mut rope, &Selection::point(0)),
        Err(Error::OutOfBounds { pos: 3, len: 2 })
    );
    assert_eq!(rope.to_string(), "abc");
}

#[test]
fn apply_rejects_selection_splitting_a_char() {
    let mut r = Replica::new(1);
    let mut rope = Rope::from_str("é");
    let tx = Transaction {
        changes: ChangeSet::identity(2),
        selection: Some(Selection::point(1)),
        meta: meta(&mut r, &[]),
    };
    assert_eq!(
        tx.apply(&mut rope, &Selection::point(0)),
        Err(Error::NotCharBoundary { pos: 1 })
    );
}

#[test]
fn invert_links_to_the_undone_transaction() {
    let mut r = Replica::new(1);
    let original = Rope::from_str("hello");
    let before = Selection::point(5);
    let tx = Transaction::new(
        ChangeSet::from_changes(5, [(0, 5, Some("bye"))]).unwrap(),
        meta(&mut r, &[]),
    );
    let undo = tx
        .invert(&original, &before, meta(&mut r, &[tx.meta.id]))
        .unwrap();
    assert_eq!(undo.meta.parents.as_slice(), &[tx.meta.id]);
    assert_eq!(undo.selection, Some(before));
}

proptest! {
    #[test]
    fn invert_restores_text_and_selection((doc, cs) in doc_and_changeset()) {
        let mut r = Replica::new(1);
        let original = Rope::from_str(&doc);
        let before = Selection::point(0);
        let tx = Transaction::new(cs, meta(&mut r, &[]));
        let undo = tx.invert(&original, &before, meta(&mut r, &[tx.meta.id])).unwrap();

        let mut rope = original.clone();
        let after = tx.apply(&mut rope, &before).unwrap();
        let restored = undo.apply(&mut rope, &after).unwrap();
        prop_assert_eq!(rope.to_string(), doc);
        prop_assert_eq!(restored, before);
    }
}
