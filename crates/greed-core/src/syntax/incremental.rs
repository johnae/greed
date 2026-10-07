//! Parsing again after an edit without starting over: tree-sitter reuses
//! the old tree for everything outside what changed, which takes well under
//! a millisecond where a whole parse of a large file takes tens.

use std::time::Instant;

use greed_text::{ChangeSet, Operation, Rope};
use tree_sitter::{InputEdit, Parser, Point, Tree};

use crate::History;

/// The one range that differs between `old` and `new`, as tree-sitter wants
/// an edit: the bytes before it are the same in both, and so are the bytes
/// after it. `None` when they're the same text.
pub(super) fn edit_between(old: &Rope, new: &Rope) -> Option<InputEdit> {
    let (old_len, new_len) = (old.len_bytes(), new.len_bytes());
    let prefix = common_prefix(old, new);
    if prefix == old_len && prefix == new_len {
        return None;
    }
    let suffix = common_suffix(old, new).min(old_len.min(new_len) - prefix);
    let (old_end, new_end) = (old_len - suffix, new_len - suffix);
    Some(InputEdit {
        start_byte: prefix,
        old_end_byte: old_end,
        new_end_byte: new_end,
        start_position: point(old, prefix),
        old_end_position: point(old, old_end),
        new_end_position: point(new, new_end),
    })
}

/// The edits that took the text from `old`, as it was at version `from` of
/// `history`, to `new`, as it is now: one for each change of each
/// transaction since, each in the text as the ones before it left it. When
/// the history doesn't have them (it doesn't keep transactions, or `old`
/// doesn't fit them), the one range that differs instead.
pub(super) fn edits_since(
    history: &History,
    from: usize,
    old: &Rope,
    new: &Rope,
) -> Vec<InputEdit> {
    let log = history.log();
    if history.applied() == log.len() && from <= log.len() {
        let mut text = old.clone();
        let mut edits = Vec::new();
        let fits = log[from..].iter().all(|tx| {
            let fits = tx.changes.len() == text.len_bytes();
            if fits {
                edits_of(&tx.changes, &mut text, &mut edits);
            }
            fits
        });
        if fits && text.len_bytes() == new.len_bytes() {
            return edits;
        }
    }
    edit_between(old, new).into_iter().collect()
}

/// Adds the edits `changes` makes to `text` to `edits`, and makes them.
fn edits_of(changes: &ChangeSet, text: &mut Rope, edits: &mut Vec<InputEdit>) {
    let mut pos = 0;
    let mut ops = changes.ops().iter().peekable();
    while let Some(op) = ops.next() {
        let (inserted, deleted) = match op {
            Operation::Retain(n) => {
                pos += n;
                continue;
            }
            // An insert comes before a delete at the same place.
            Operation::Insert(inserted) => {
                match ops.next_if(|op| matches!(op, Operation::Delete(_))) {
                    Some(Operation::Delete(n)) => (inserted.as_str(), *n),
                    _ => (inserted.as_str(), 0),
                }
            }
            Operation::Delete(n) => ("", *n),
        };
        let start_position = point(text, pos);
        let old_end_position = point(text, pos + deleted);
        let from = text.byte_to_char(pos);
        text.remove(from..text.byte_to_char(pos + deleted));
        text.insert(from, inserted);
        let new_end = pos + inserted.len();
        edits.push(InputEdit {
            start_byte: pos,
            old_end_byte: pos + deleted,
            new_end_byte: new_end,
            start_position,
            old_end_position,
            new_end_position: point(text, new_end),
        });
        pos = new_end;
    }
}

/// Parses `new`, reusing `old`, which was parsed from `old_text`; `None` if
/// it can't finish by `deadline`.
pub(super) fn reparse(
    parser: &mut Parser,
    old: &Tree,
    old_text: &Rope,
    new: &Rope,
    deadline: Option<Instant>,
) -> Option<Tree> {
    let Some(edit) = edit_between(old_text, new) else {
        return Some(old.clone());
    };
    let mut edited = old.clone();
    edited.edit(&edit);
    super::parse_from(parser, new, Some(&edited), deadline)
}

fn point(text: &Rope, byte: usize) -> Point {
    let row = text.byte_to_line(byte);
    Point {
        row,
        column: byte - text.line_to_byte(row),
    }
}

/// How many bytes `a` and `b` start with in common, a chunk at a time.
fn common_prefix(a: &Rope, b: &Rope) -> usize {
    same_run(
        a.chunks().map(str::as_bytes),
        b.chunks().map(str::as_bytes),
        false,
    )
}

/// How many bytes `a` and `b` end with in common.
fn common_suffix(a: &Rope, b: &Rope) -> usize {
    let a: Vec<&[u8]> = a.chunks().map(str::as_bytes).collect();
    let b: Vec<&[u8]> = b.chunks().map(str::as_bytes).collect();
    same_run(a.into_iter().rev(), b.into_iter().rev(), true)
}

/// How many bytes two runs of chunks have in common from their start, or
/// with `backwards` from their end (the chunks come last first).
fn same_run<'a>(
    mut a: impl Iterator<Item = &'a [u8]>,
    mut b: impl Iterator<Item = &'a [u8]>,
    backwards: bool,
) -> usize {
    let (mut x, mut y): (&[u8], &[u8]) = (&[], &[]);
    let mut same = 0;
    loop {
        if x.is_empty() {
            match a.next() {
                Some(chunk) => x = chunk,
                None => return same,
            }
            continue;
        }
        if y.is_empty() {
            match b.next() {
                Some(chunk) => y = chunk,
                None => return same,
            }
            continue;
        }
        let n = x.len().min(y.len());
        let equal = if backwards {
            let (x_rest, xs) = x.split_at(x.len() - n);
            let (y_rest, ys) = y.split_at(y.len() - n);
            (x, y) = (x_rest, y_rest);
            xs.iter()
                .rev()
                .zip(ys.iter().rev())
                .take_while(|(p, q)| p == q)
                .count()
        } else {
            let (xs, x_rest) = x.split_at(n);
            let (ys, y_rest) = y.split_at(n);
            (x, y) = (x_rest, y_rest);
            xs.iter().zip(ys).take_while(|(p, q)| p == q).count()
        };
        same += equal;
        if equal < n {
            return same;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn edit(old: &str, new: &str) -> Option<(usize, usize, usize)> {
        edit_between(&Rope::from_str(old), &Rope::from_str(new))
            .map(|e| (e.start_byte, e.old_end_byte, e.new_end_byte))
    }

    #[test]
    fn the_edit_is_the_part_between_what_stays() {
        assert_eq!(edit("hello world", "hello world"), None);
        assert_eq!(edit("hello world", "hello brave world"), Some((6, 6, 12)));
        assert_eq!(edit("hello brave world", "hello world"), Some((6, 12, 6)));
        assert_eq!(edit("abc", "abX"), Some((2, 3, 3)));
        assert_eq!(edit("", "x"), Some((0, 0, 1)));
        // Repeated text: the suffix can't eat into the prefix.
        assert_eq!(edit("aaa", "aaaa"), Some((3, 3, 4)));
    }

    #[test]
    fn positions_are_rows_and_byte_columns() {
        let e = edit_between(&Rope::from_str("ab\ncd\n"), &Rope::from_str("ab\ncXd\n")).unwrap();
        assert_eq!((e.start_position.row, e.start_position.column), (1, 1));
        assert_eq!((e.new_end_position.row, e.new_end_position.column), (1, 2));
    }

    #[test]
    fn each_change_is_an_edit_in_the_text_the_ones_before_left() {
        let mut text = Rope::from_str("ab\ncd\nef\n");
        let changes =
            ChangeSet::from_changes(9, [(1, 1, Some("X\n")), (3, 4, None), (6, 8, Some("g"))])
                .unwrap();
        let mut edits = Vec::new();
        edits_of(&changes, &mut text, &mut edits);
        assert_eq!(text.to_string(), "aX\nb\nd\ng\n");
        let found: Vec<_> = edits
            .iter()
            .map(|e| {
                (
                    (e.start_byte, e.old_end_byte, e.new_end_byte),
                    (e.start_position.row, e.start_position.column),
                    (e.new_end_position.row, e.new_end_position.column),
                )
            })
            .collect();
        assert_eq!(
            found,
            [
                ((1, 1, 3), (0, 1), (1, 0)),
                ((5, 6, 5), (2, 0), (2, 0)),
                ((7, 9, 8), (3, 0), (3, 1)),
            ]
        );
    }

    #[test]
    fn long_texts_compare_across_chunks() {
        let old: String = "fn x() {}\n".repeat(5000);
        let mut new = old.clone();
        new.insert_str(25_000, "// here\n");
        assert_eq!(edit(&old, &new), Some((25_000, 25_000, 25_008)));
    }

    #[test]
    fn a_parse_past_its_deadline_gives_up_and_the_next_starts_fresh() {
        let language = tree_sitter::Language::new(tree_sitter_rust::LANGUAGE);
        let mut parser = Parser::new();
        parser.set_language(&language).unwrap();
        let text = Rope::from_str(&"fn a() { let x = 1; }\n".repeat(20_000));
        let past = Some(Instant::now());
        assert!(super::super::parse_from(&mut parser, &text, None, past).is_none());
        let small = Rope::from_str("fn b() {}\n");
        let tree = super::super::parse_from(&mut parser, &small, None, None).unwrap();
        assert_eq!(
            tree.root_node().end_byte(),
            small.len_bytes(),
            "not the text before"
        );
    }

    #[test]
    fn reparsing_gives_the_tree_a_whole_parse_does() {
        let language = tree_sitter::Language::new(tree_sitter_rust::LANGUAGE);
        let mut parser = Parser::new();
        parser.set_language(&language).unwrap();
        let old_text = Rope::from_str(&"fn a() { let x = 1; }\n".repeat(500));
        let old = super::super::parse_from(&mut parser, &old_text, None, None).unwrap();
        let mut new = old_text.clone();
        new.insert(5_000, "fn b(y: u8) {}\n");
        let incremental = reparse(&mut parser, &old, &old_text, &new, None).unwrap();
        let whole = super::super::parse_from(&mut parser, &new, None, None).unwrap();
        assert_eq!(
            incremental.root_node().to_sexp(),
            whole.root_node().to_sexp()
        );
    }
}
