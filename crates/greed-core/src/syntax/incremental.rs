//! Parsing again after an edit without starting over: tree-sitter reuses
//! the old tree for everything outside what changed, which takes well under
//! a millisecond where a whole parse of a large file takes tens.

use greed_text::Rope;
use tree_sitter::{InputEdit, Parser, Point, Tree};

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

/// Parses `new`, reusing `old`, which was parsed from `old_text`.
pub(super) fn reparse(
    parser: &mut Parser,
    old: &Tree,
    old_text: &Rope,
    new: &Rope,
) -> Option<Tree> {
    let Some(edit) = edit_between(old_text, new) else {
        return Some(old.clone());
    };
    let mut edited = old.clone();
    edited.edit(&edit);
    super::parse_from(parser, new, Some(&edited))
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
    fn long_texts_compare_across_chunks() {
        let old: String = "fn x() {}\n".repeat(5000);
        let mut new = old.clone();
        new.insert_str(25_000, "// here\n");
        assert_eq!(edit(&old, &new), Some((25_000, 25_000, 25_008)));
    }

    #[test]
    fn reparsing_gives_the_tree_a_whole_parse_does() {
        let language = tree_sitter::Language::new(tree_sitter_rust::LANGUAGE);
        let mut parser = Parser::new();
        parser.set_language(&language).unwrap();
        let old_text = Rope::from_str(&"fn a() { let x = 1; }\n".repeat(500));
        let old = super::super::parse_from(&mut parser, &old_text, None).unwrap();
        let mut new = old_text.clone();
        new.insert(5_000, "fn b(y: u8) {}\n");
        let incremental = reparse(&mut parser, &old, &old_text, &new).unwrap();
        let whole = super::super::parse_from(&mut parser, &new, None).unwrap();
        assert_eq!(
            incremental.root_node().to_sexp(),
            whole.root_node().to_sexp()
        );
    }
}
