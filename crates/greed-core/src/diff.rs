//! Line diffs, for showing a whole new version of a file as reviewable
//! changes.

use std::ops::Range;

use similar::{Algorithm, DiffTag};

/// The changes that turn `old` into `new`, whole lines at a time: each
/// replaces a byte range of `old` with text from `new`. Changes are sorted
/// and never touch.
pub fn line_changes(old: &str, new: &str) -> Vec<(Range<usize>, String)> {
    let old_lines: Vec<&str> = old.split_inclusive('\n').collect();
    let new_lines: Vec<&str> = new.split_inclusive('\n').collect();
    let old_at = starts(&old_lines);
    let new_at = starts(&new_lines);
    let mut changes: Vec<(Range<usize>, String)> = Vec::new();
    for op in similar::capture_diff_slices(Algorithm::Myers, &old_lines, &new_lines) {
        if op.tag() == DiffTag::Equal {
            continue;
        }
        let (from, to) = (op.old_range(), op.new_range());
        let range = old_at[from.start]..old_at[from.end];
        let text = &new[new_at[to.start]..new_at[to.end]];
        // A deletion next to an insertion is one change.
        match changes.last_mut() {
            Some((last, last_text)) if last.end == range.start => {
                last.end = range.end;
                last_text.push_str(text);
            }
            _ => changes.push((range, text.to_owned())),
        }
    }
    changes
}

/// The byte offset each line starts at, and the end of the text last.
fn starts(lines: &[&str]) -> Vec<usize> {
    let mut at = Vec::with_capacity(lines.len() + 1);
    let mut offset = 0;
    at.push(0);
    for line in lines {
        offset += line.len();
        at.push(offset);
    }
    at
}
