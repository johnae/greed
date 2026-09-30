mod common;

use common::doc_and_changeset;
use kern_text::{ChangeSet, Error, Range, Selection};
use proptest::prelude::*;

// --- Range ----------------------------------------------------------------

#[test]
fn range_basics() {
    let r = Range::new(7, 3);
    assert_eq!((r.from(), r.to(), r.len()), (3, 7, 4));
    assert!(r.is_backward());
    assert!(!r.is_empty());
    assert_eq!(r.flip(), Range::new(3, 7));
    assert!(Range::point(5).is_empty());
}

#[test]
fn cursor_moves_with_text_typed_at_it() {
    let cs = ChangeSet::from_changes(4, [(2, 2, Some("xy"))]).unwrap();
    assert_eq!(Range::point(2).map(&cs), Range::point(4));
}

#[test]
fn range_does_not_grow_from_inserts_at_its_edges() {
    // "abcdef", range over "cd", insert at both edges
    let cs = ChangeSet::from_changes(6, [(2, 2, Some("<")), (4, 4, Some(">"))]).unwrap();
    assert_eq!(Range::new(2, 4).map(&cs), Range::new(3, 5));
    assert_eq!(Range::new(4, 2).map(&cs), Range::new(5, 3));
}

#[test]
fn range_collapses_when_its_text_is_deleted() {
    let cs = ChangeSet::from_changes(6, [(1, 5, None::<&str>)]).unwrap();
    assert_eq!(Range::new(2, 4).map(&cs), Range::point(1));
}

#[test]
fn range_keeps_replaced_text_selected() {
    let cs = ChangeSet::from_changes(6, [(2, 4, Some("XYZ"))]).unwrap();
    assert_eq!(Range::new(2, 4).map(&cs), Range::new(2, 5));
}

// --- Selection ------------------------------------------------------------

#[test]
fn selection_needs_a_range() {
    assert_eq!(Selection::new([], 0), Err(Error::EmptySelection));
}

#[test]
fn selection_sorts_ranges_and_tracks_primary() {
    let sel = Selection::new([Range::new(8, 9), Range::new(0, 2), Range::new(4, 5)], 0).unwrap();
    assert_eq!(
        sel.ranges(),
        &[Range::new(0, 2), Range::new(4, 5), Range::new(8, 9)]
    );
    assert_eq!(sel.primary(), Range::new(8, 9));
}

#[test]
fn selection_merges_overlapping_ranges() {
    let sel = Selection::new(
        [
            Range::new(0, 3),
            Range::new(2, 5),
            Range::new(7, 7),
            Range::new(7, 7),
        ],
        1,
    )
    .unwrap();
    assert_eq!(sel.ranges(), &[Range::new(0, 5), Range::new(7, 7)]);
    assert_eq!(sel.primary(), Range::new(0, 5));
}

#[test]
fn touching_ranges_stay_separate() {
    let sel = Selection::new([Range::new(0, 3), Range::new(3, 5)], 0).unwrap();
    assert_eq!(sel.len(), 2);
}

#[test]
fn merged_range_keeps_direction_of_first() {
    let sel = Selection::new([Range::new(3, 0), Range::new(2, 5)], 0).unwrap();
    assert_eq!(sel.ranges(), &[Range::new(5, 0)]);
}

#[test]
fn clamped_primary_index() {
    let sel = Selection::new([Range::point(1), Range::point(4)], 9).unwrap();
    assert_eq!(sel.primary(), Range::point(4));
}

#[test]
fn push_adds_primary_range() {
    let sel = Selection::point(0).push(Range::new(4, 6));
    assert_eq!(sel.ranges(), &[Range::point(0), Range::new(4, 6)]);
    assert_eq!(sel.primary(), Range::new(4, 6));
}

#[test]
fn mapping_merges_ranges_that_collide() {
    // Two cursors inside a deleted word end up at the same spot.
    let sel = Selection::new([Range::point(2), Range::point(3)], 1).unwrap();
    let cs = ChangeSet::from_changes(6, [(1, 5, None::<&str>)]).unwrap();
    let mapped = sel.map(&cs);
    assert_eq!(mapped.ranges(), &[Range::point(1)]);
    assert_eq!(mapped.primary(), Range::point(1));
}

// --- Properties -----------------------------------------------------------

fn selection_within(len: usize) -> impl Strategy<Value = Selection> {
    let range = (0..=len, 0..=len).prop_map(|(a, h)| Range::new(a, h));
    (prop::collection::vec(range, 1..6), 0..6usize)
        .prop_map(|(ranges, primary)| Selection::new(ranges, primary).unwrap())
}

fn assert_normalized(sel: &Selection) {
    for pair in sel.ranges().windows(2) {
        let (a, b) = (pair[0], pair[1]);
        assert!(a.from() <= b.from(), "unsorted: {sel:?}");
        assert!(
            a.to() <= b.from() && !(a.is_empty() && b.is_empty() && a.from() == b.from()),
            "overlapping: {sel:?}"
        );
    }
    assert!(sel.primary_index() < sel.len());
}

proptest! {
    #[test]
    fn new_selections_are_normalized(sel in selection_within(20)) {
        assert_normalized(&sel);
    }

    #[test]
    fn mapped_selections_are_normalized_and_in_bounds(
        (sel, cs) in doc_and_changeset().prop_flat_map(|(_, cs)| (selection_within(cs.len()), Just(cs)))
    ) {
        let mapped = sel.map(&cs);
        assert_normalized(&mapped);
        for r in mapped.ranges() {
            prop_assert!(r.to() <= cs.len_after());
        }
        prop_assert!(mapped.len() <= sel.len());
    }

    #[test]
    fn mapping_through_identity_is_noop(sel in selection_within(20)) {
        prop_assert_eq!(sel.map(&ChangeSet::identity(20)), sel);
    }
}
