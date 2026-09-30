//! Shared helpers and proptest strategies for kern-text tests.

#![allow(dead_code)]

use kern_text::{ChangeSet, Rope};
use proptest::prelude::*;

pub fn apply(cs: &ChangeSet, doc: &str) -> String {
    let mut rope = Rope::from_str(doc);
    cs.apply(&mut rope).expect("apply");
    rope.to_string()
}

/// Text with multi-byte characters and newlines so byte/char mistakes show up.
pub fn text() -> impl Strategy<Value = String> {
    "[ab é😀\n]{0,24}"
}

#[derive(Debug, Clone)]
enum Step {
    Retain(usize),
    Delete(usize),
    Insert(String),
}

fn step() -> impl Strategy<Value = Step> {
    prop_oneof![
        (0..6usize).prop_map(Step::Retain),
        (0..6usize).prop_map(Step::Delete),
        "[xé😀\n]{0,4}".prop_map(Step::Insert),
    ]
}

/// Builds a change set over `doc` by walking it char by char, so every
/// retain and delete lands on a char boundary.
fn build(doc: &str, steps: &[Step]) -> ChangeSet {
    let chars: Vec<usize> = doc
        .char_indices()
        .map(|(i, _)| i)
        .chain([doc.len()])
        .collect();
    let n_chars = chars.len() - 1;
    let mut ci = 0;
    let mut cs = ChangeSet::default();
    let advance = |n: usize, ci: &mut usize| {
        let end = (*ci + n).min(n_chars);
        let bytes = chars[end] - chars[*ci];
        *ci = end;
        bytes
    };
    for s in steps {
        match s {
            Step::Retain(n) => cs.retain(advance(*n, &mut ci)),
            Step::Delete(n) => cs.delete(advance(*n, &mut ci)),
            Step::Insert(t) => cs.insert(t),
        }
    }
    cs.retain(doc.len() - chars[ci]);
    cs
}

fn changeset_for(doc: String) -> impl Strategy<Value = (String, ChangeSet)> {
    prop::collection::vec(step(), 0..8).prop_map(move |steps| {
        let cs = build(&doc, &steps);
        (doc.clone(), cs)
    })
}

pub fn doc_and_changeset() -> impl Strategy<Value = (String, ChangeSet)> {
    text().prop_flat_map(changeset_for)
}

pub fn doc_and_two_changesets() -> impl Strategy<Value = (String, ChangeSet, ChangeSet)> {
    doc_and_changeset().prop_flat_map(|(doc, a)| {
        let after = apply(&a, &doc);
        changeset_for(after).prop_map(move |(_, b)| (doc.clone(), a.clone(), b))
    })
}
