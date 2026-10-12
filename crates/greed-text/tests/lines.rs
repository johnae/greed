use greed_text::{Rope, line_end};

#[test]
fn lines_break_where_compilers_and_language_servers_break_them() {
    let text = Rope::from_str("a\nb\r\nc\rd\u{2028}e\u{85}f\u{0C}g\u{0B}h");
    assert_eq!(text.len_lines(), 4);
    assert_eq!(text.line(3).to_string(), "d\u{2028}e\u{85}f\u{0C}g\u{0B}h");
}

#[test]
fn a_line_ends_before_its_break() {
    let text = Rope::from_str("ab\ncd\r\nef\rgh");
    let ends: Vec<usize> = (0..text.len_lines()).map(|l| line_end(&text, l)).collect();
    assert_eq!(ends, [2, 5, 9, 12]);
    let empty = Rope::from_str("\n\r\n\r");
    let ends: Vec<usize> = (0..empty.len_lines())
        .map(|l| line_end(&empty, l))
        .collect();
    assert_eq!(ends, [0, 1, 3, 4]);
}
