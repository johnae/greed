use std::ops::Range;

use greed_core::search::{Direction, find, find_all};
use greed_text::Rope;

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

#[test]
fn every_file_of_a_big_tree_is_listed_once_sorted_leaving_out_hidden_and_ignored() {
    let dir = std::env::temp_dir().join(format!("greed-files-{}", std::process::id()));
    // More than a thread hands over at once, across folders.
    for n in 0..10_000 {
        let path = dir.join(format!("src/m{}/f{n:05}.rs", n % 37));
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, "").unwrap();
    }
    std::fs::create_dir_all(dir.join("target")).unwrap();
    std::fs::write(dir.join("target/out.o"), "").unwrap();
    std::fs::write(dir.join(".gitignore"), "target/\n").unwrap();
    std::fs::write(dir.join(".hidden"), "").unwrap();
    let files = greed_core::search::files(&dir, &[]);
    assert_eq!(files.len(), 10_000, "every file, nothing ignored or hidden");
    assert!(files.windows(2).all(|w| w[0] < w[1]), "sorted, each once");
    assert!(
        !files
            .iter()
            .any(|f| f.starts_with("target") || f.starts_with('.'))
    );
    let skipped = greed_core::search::files(&dir, &["src"]);
    assert!(skipped.is_empty(), "{skipped:?}");
    std::fs::remove_dir_all(&dir).unwrap();
}
