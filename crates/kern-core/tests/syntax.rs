use std::path::Path;
use std::time::Duration;

use kern_core::Editor;
use kern_core::syntax::{Highlight, Syntax};
use kern_text::ClientId;

fn editor(text: &str, path: &str) -> Editor {
    let mut ed = Editor::new(ClientId(1));
    ed.open("file", text, Some(path.into()));
    ed
}

/// Waits for the worker to finish one parse and keeps it.
fn wait(syntax: &mut Syntax) {
    let parsed = syntax
        .results()
        .recv_timeout(Duration::from_secs(5))
        .expect("parse finished");
    syntax.receive(parsed);
}

fn captured(highlights: &[Highlight], range: std::ops::Range<usize>) -> Vec<&str> {
    highlights
        .iter()
        .filter(|h| h.range == range)
        .map(|h| &*h.capture)
        .collect()
}

#[test]
fn every_bundled_language_loads() {
    let syntax = Syntax::new();
    for (file, name) in [
        ("a.rs", "rust"),
        ("Cargo.toml", "toml"),
        ("a.json", "json"),
        ("init.luau", "luau"),
        ("x.lua", "luau"),
        ("README.md", "markdown"),
    ] {
        let language = syntax.language_for(Path::new(file)).unwrap();
        assert_eq!(language.name, name, "{file}");
    }
    assert!(syntax.language_for(Path::new("notes.txt")).is_none());
    assert!(syntax.language_for(Path::new("Makefile")).is_none());
}

#[test]
fn parsed_buffers_highlight_their_visible_range() {
    let text = "fn main() {\n    let s = \"hi\";\n}\n";
    let ed = editor(text, "main.rs");
    let mut syntax = Syntax::new();
    syntax.update(&ed);
    wait(&mut syntax);

    let buffer = ed.buffers().next().unwrap();
    let all = syntax.highlights(buffer.id(), buffer.text(), 0..text.len());
    assert!(captured(&all, 0..2).contains(&"keyword"), "{all:?}");
    assert!(
        captured(&all, 3..7)
            .iter()
            .any(|c| c.starts_with("function")),
        "{all:?}"
    );
    let string = text.find('"').unwrap();
    assert!(
        captured(&all, string..string + 4).contains(&"string"),
        "{all:?}"
    );

    // Only the requested range is queried.
    let first_line = syntax.highlights(buffer.id(), buffer.text(), 0..11);
    assert!(first_line.iter().all(|h| h.range.start < 11));
}

#[test]
fn unchanged_buffers_are_not_parsed_again() {
    let ed = editor("fn a() {}", "a.rs");
    let mut syntax = Syntax::new();
    syntax.update(&ed);
    wait(&mut syntax);
    syntax.update(&ed);
    assert!(
        syntax
            .results()
            .recv_timeout(Duration::from_millis(200))
            .is_err()
    );
}

#[test]
fn buffers_without_a_language_or_too_big_are_skipped() {
    let mut ed = editor("plain text", "notes.txt");
    ed.open("file", "fn big() {}", Some("big.rs".into()));
    let mut syntax = Syntax::new();
    syntax.max_bytes = 5;
    syntax.update(&ed);
    assert!(
        syntax
            .results()
            .recv_timeout(Duration::from_millis(200))
            .is_err()
    );
    for buffer in ed.buffers() {
        assert!(
            syntax
                .highlights(buffer.id(), buffer.text(), 0..100)
                .is_empty()
        );
    }
}
