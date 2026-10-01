use std::ops::Range;

use kern_core::search::{Direction, find, find_all};
use kern_text::Rope;

fn pairs(ranges: &[Range<usize>]) -> Vec<(usize, usize)> {
    ranges.iter().map(|r| (r.start, r.end)).collect()
}

fn all(text: &Rope, pattern: &str, from: usize) -> Vec<(usize, usize)> {
    pairs(&find_all(text, pattern, from..text.len_bytes()).unwrap())
}

fn next(text: &Rope, from: usize, direction: Direction, wrap: bool) -> Option<(usize, usize)> {
    find(text, r"\d", from, direction, wrap)
        .unwrap()
        .map(|r| (r.start, r.end))
}

#[test]
fn every_match_in_a_range_with_byte_offsets() {
    let text = Rope::from_str("fn é() { let x = é; }");
    assert_eq!(all(&text, "é", 0), [(3, 5), (18, 20)]);
    assert_eq!(all(&text, "é", 4), [(18, 20)]);
    assert_eq!(all(&text, r"\bx\b", 0), [(14, 15)]);
    assert!(find_all(&text, "(", 0..1).is_err());
}

#[test]
fn the_next_or_previous_match_wrapping_around() {
    use Direction::{Backward, Forward};
    let text = Rope::from_str("a1 b2 c3");
    assert_eq!(next(&text, 3, Forward, false), Some((4, 5)));
    assert_eq!(next(&text, 3, Backward, false), Some((1, 2)));
    assert_eq!(next(&text, 8, Forward, false), None);
    assert_eq!(next(&text, 8, Forward, true), Some((1, 2)));
    assert_eq!(next(&text, 0, Backward, true), Some((7, 8)));
    // A match starting right at `from` counts going forward, not going back.
    assert_eq!(next(&text, 1, Forward, false), Some((1, 2)));
    assert_eq!(next(&text, 1, Backward, false), None);
}

#[test]
fn big_texts_are_searched_without_copying_them() {
    let big = "x".repeat(200_000) + "needle" + &"y".repeat(200_000);
    let text = Rope::from_str(&big);
    assert_eq!(all(&text, "needle", 0), [(200_000, 200_006)]);
}
