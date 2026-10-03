use greed_core::diff::line_changes;

/// `old` with the changes applied, last first so offsets stay valid.
fn apply(old: &str, changes: &[(std::ops::Range<usize>, String)]) -> String {
    let mut text = old.to_owned();
    for (range, new) in changes.iter().rev() {
        text.replace_range(range.clone(), new);
    }
    text
}

#[test]
fn changes_are_whole_lines_and_turn_old_into_new() {
    let old = "a\nb\nc\nd\n";
    let new = "a\nB\nc\nd\ne\n";
    let changes = line_changes(old, new);
    assert_eq!(
        changes,
        [(2..4, "B\n".to_owned()), (8..8, "e\n".to_owned())]
    );
    assert_eq!(apply(old, &changes), new);
}

#[test]
fn edge_cases_round_trip() {
    for (old, new) in [
        ("", "new file\n"),
        ("gone\n", ""),
        ("same\n", "same\n"),
        ("no newline", "no newline\nnow two"),
        ("x\ny\nz\n", "z\ny\nx\n"),
    ] {
        assert_eq!(
            apply(old, &line_changes(old, new)),
            new,
            "{old:?} -> {new:?}"
        );
    }
    assert!(line_changes("same\n", "same\n").is_empty());
}
