mod common;

use common::{apply, doc_and_changeset, doc_and_two_changesets};
use greed_text::{Assoc, ChangeSet, Error, Operation, Rope};
use proptest::prelude::*;

// --- Examples -------------------------------------------------------------

#[test]
fn from_changes_builds_canonical_ops() {
    let cs = ChangeSet::from_changes(11, [(0, 5, Some("goodbye")), (6, 6, Some("big "))]).unwrap();
    assert_eq!(
        cs.ops(),
        &[
            Operation::Insert("goodbye".into()),
            Operation::Delete(5),
            Operation::Retain(1),
            Operation::Insert("big ".into()),
            Operation::Retain(5),
        ]
    );
    assert_eq!(cs.len(), 11);
    assert_eq!(cs.len_after(), 17);
    assert_eq!(apply(&cs, "hello world"), "goodbye big world");
}

#[test]
fn changed_range_spans_the_changes_in_the_new_text() {
    let cs = ChangeSet::from_changes(11, [(0, 5, Some("goodbye")), (6, 6, Some("big "))]).unwrap();
    assert_eq!(cs.changed_range(), Some(0..12));
    let deleted = ChangeSet::from_changes(11, [(2, 4, None::<&str>)]).unwrap();
    assert_eq!(deleted.changed_range(), Some(2..2));
    let appended = ChangeSet::from_changes(3, [(3, 3, Some("!"))]).unwrap();
    assert_eq!(appended.changed_range(), Some(3..4));
    assert_eq!(ChangeSet::identity(5).changed_range(), None);
}

#[test]
fn from_changes_rejects_overlapping_and_out_of_bounds() {
    assert_eq!(
        ChangeSet::from_changes(10, [(2, 5, None::<&str>), (4, 6, None)]),
        Err(Error::OverlappingChanges { at: 4 })
    );
    assert_eq!(
        ChangeSet::from_changes(10, [(3, 2, None::<&str>)]),
        Err(Error::OverlappingChanges { at: 2 })
    );
    assert_eq!(
        ChangeSet::from_changes(10, [(8, 12, None::<&str>)]),
        Err(Error::OutOfBounds { pos: 12, len: 10 })
    );
}

#[test]
fn builder_merges_and_orders_ops() {
    let mut cs = ChangeSet::default();
    cs.retain(1);
    cs.retain(2);
    cs.delete(1);
    cs.insert("a");
    cs.delete(1);
    cs.insert("b");
    cs.retain(0);
    cs.insert("");
    assert_eq!(
        cs.ops(),
        &[
            Operation::Retain(3),
            Operation::Insert("ab".into()),
            Operation::Delete(2),
        ]
    );
    assert_eq!(cs.len(), 5);
    assert_eq!(cs.len_after(), 5);
}

#[test]
fn identity_is_empty() {
    let cs = ChangeSet::identity(4);
    assert!(cs.is_empty());
    assert_eq!(apply(&cs, "abcd"), "abcd");
    assert!(
        !ChangeSet::from_changes(4, [(1, 1, Some("x"))])
            .unwrap()
            .is_empty()
    );
}

#[test]
fn apply_rejects_wrong_length() {
    let cs = ChangeSet::identity(3);
    let mut rope = Rope::from_str("abcd");
    assert_eq!(
        cs.apply(&mut rope),
        Err(Error::LengthMismatch {
            expected: 3,
            actual: 4
        })
    );
}

#[test]
fn apply_rejects_split_char_without_mutating() {
    // "é" is two bytes, so deleting 1..2 would split it. The insert at 0 is
    // valid and must not be applied either.
    let cs = ChangeSet::from_changes(4, [(0, 0, Some("x")), (1, 2, None)]).unwrap();
    let mut rope = Rope::from_str("éab");
    assert_eq!(cs.apply(&mut rope), Err(Error::NotCharBoundary { pos: 1 }));
    assert_eq!(rope.to_string(), "éab");
}

#[test]
fn compose_rejects_length_mismatch() {
    let a = ChangeSet::identity(3);
    let b = ChangeSet::identity(4);
    assert_eq!(
        a.compose(b),
        Err(Error::LengthMismatch {
            expected: 3,
            actual: 4
        })
    );
}

#[test]
fn compose_rejects_split_char_in_inserted_text() {
    let a = ChangeSet::from_changes(0, [(0, 0, Some("é"))]).unwrap();
    let b = ChangeSet::from_changes(2, [(1, 2, None::<&str>)]).unwrap();
    assert_eq!(a.compose(b), Err(Error::NotCharBoundary { pos: 1 }));
}

#[test]
fn map_pos_around_insert() {
    let cs = ChangeSet::from_changes(4, [(2, 2, Some("xyz"))]).unwrap();
    assert_eq!(cs.map_pos(1, Assoc::Before), 1);
    assert_eq!(cs.map_pos(2, Assoc::Before), 2);
    assert_eq!(cs.map_pos(2, Assoc::After), 5);
    assert_eq!(cs.map_pos(3, Assoc::Before), 6);
    assert_eq!(cs.map_pos(4, Assoc::After), 7);
}

#[test]
fn map_pos_around_delete_and_replace() {
    // "abcdef" -> delete "cd"
    let cs = ChangeSet::from_changes(6, [(2, 4, None::<&str>)]).unwrap();
    assert_eq!(cs.map_pos(2, Assoc::After), 2);
    assert_eq!(cs.map_pos(3, Assoc::Before), 2);
    assert_eq!(cs.map_pos(3, Assoc::After), 2);
    assert_eq!(cs.map_pos(4, Assoc::Before), 2);
    assert_eq!(cs.map_pos(5, Assoc::Before), 3);

    // "abcdef" -> replace "cd" with "XYZ"
    let cs = ChangeSet::from_changes(6, [(2, 4, Some("XYZ"))]).unwrap();
    assert_eq!(cs.map_pos(2, Assoc::Before), 2);
    assert_eq!(cs.map_pos(2, Assoc::After), 5);
    assert_eq!(cs.map_pos(3, Assoc::Before), 2);
    assert_eq!(cs.map_pos(3, Assoc::After), 5);
    assert_eq!(cs.map_pos(4, Assoc::Before), 5);
    assert_eq!(cs.map_pos(4, Assoc::After), 5);
}

#[test]
fn invert_restores_original() {
    let doc = "héllo wörld";
    let cs = ChangeSet::from_changes(doc.len(), [(0, 1, Some("J")), (7, 13, Some("🌍"))]).unwrap();
    let rope = Rope::from_str(doc);
    let inv = cs.invert(&rope).unwrap();
    assert_eq!(apply(&cs, doc), "Jéllo 🌍");
    assert_eq!(apply(&inv, &apply(&cs, doc)), doc);
}

// --- Properties -----------------------------------------------------------

fn assert_canonical(cs: &ChangeSet) {
    for op in cs.ops() {
        match op {
            Operation::Retain(0) | Operation::Delete(0) => panic!("zero-length op in {cs:?}"),
            Operation::Insert(s) if s.is_empty() => panic!("empty insert in {cs:?}"),
            _ => {}
        }
    }
    for pair in cs.ops().windows(2) {
        match pair {
            [Operation::Retain(_), Operation::Retain(_)]
            | [Operation::Delete(_), Operation::Delete(_)]
            | [Operation::Insert(_), Operation::Insert(_)] => panic!("unmerged ops in {cs:?}"),
            [Operation::Delete(_), Operation::Insert(_)] => {
                panic!("delete before insert in {cs:?}")
            }
            _ => {}
        }
    }
}

proptest! {
    #[test]
    fn built_changesets_are_canonical((doc, cs) in doc_and_changeset()) {
        assert_canonical(&cs);
        prop_assert_eq!(cs.len(), doc.len());
        prop_assert_eq!(apply(&cs, &doc).len(), cs.len_after());
    }

    #[test]
    fn compose_matches_sequential_apply((doc, a, b) in doc_and_two_changesets()) {
        let sequential = apply(&b, &apply(&a, &doc));
        let composed = a.clone().compose(b.clone()).unwrap();
        assert_canonical(&composed);
        prop_assert_eq!(composed.len(), a.len());
        prop_assert_eq!(composed.len_after(), b.len_after());
        prop_assert_eq!(apply(&composed, &doc), sequential);
    }

    #[test]
    fn compose_with_identity_is_noop((doc, cs) in doc_and_changeset()) {
        let left = ChangeSet::identity(cs.len()).compose(cs.clone()).unwrap();
        let right = cs.clone().compose(ChangeSet::identity(cs.len_after())).unwrap();
        prop_assert_eq!(&left, &cs);
        prop_assert_eq!(&right, &cs);
        prop_assert_eq!(apply(&left, &doc), apply(&cs, &doc));
    }

    #[test]
    fn invert_undoes_apply((doc, cs) in doc_and_changeset()) {
        let inv = cs.invert(&Rope::from_str(&doc)).unwrap();
        assert_canonical(&inv);
        prop_assert_eq!(apply(&inv, &apply(&cs, &doc)), doc.clone());
        let round_trip = cs.clone().compose(inv).unwrap();
        prop_assert_eq!(apply(&round_trip, &doc), doc);
    }

    #[test]
    fn map_pos_is_monotonic_and_in_bounds((_doc, cs) in doc_and_changeset()) {
        for assoc in [Assoc::Before, Assoc::After] {
            let mut prev = 0;
            for pos in 0..=cs.len() {
                let mapped = cs.map_pos(pos, assoc);
                prop_assert!(mapped >= prev, "{pos} -> {mapped} < {prev}");
                prop_assert!(mapped <= cs.len_after());
                prev = mapped;
            }
        }
    }

    #[test]
    fn map_pos_preserves_retained_text((doc, cs) in doc_and_changeset()) {
        let after = apply(&cs, &doc);
        let mut old = 0;
        for op in cs.ops() {
            match op {
                Operation::Retain(n) => {
                    for pos in old..old + n {
                        let mapped = cs.map_pos(pos, Assoc::After);
                        prop_assert_eq!(doc.as_bytes()[pos], after.as_bytes()[mapped]);
                    }
                    old += n;
                }
                Operation::Delete(n) => old += n,
                Operation::Insert(_) => {}
            }
        }
    }

    #[test]
    fn map_pos_through_compose_matches_sequential((_doc, a, b) in doc_and_two_changesets()) {
        let composed = a.clone().compose(b.clone()).unwrap();
        // Positions touching deleted text are ambiguous after composing; see
        // `ChangeSet::map_pos`.
        let mut ambiguous = Vec::new();
        let mut old = 0;
        for op in composed.ops() {
            match op {
                Operation::Retain(n) => old += n,
                Operation::Delete(n) => {
                    ambiguous.extend(old..=old + n);
                    old += n;
                }
                Operation::Insert(_) => {}
            }
        }
        for assoc in [Assoc::Before, Assoc::After] {
            for pos in (0..=a.len()).filter(|p| !ambiguous.contains(p)) {
                prop_assert_eq!(
                    composed.map_pos(pos, assoc),
                    b.map_pos(a.map_pos(pos, assoc), assoc),
                    "pos {} {:?}", pos, assoc
                );
            }
        }
    }
}
