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

#[test]
fn buffers_without_files_highlight_in_the_language_they_are_given() {
    let mut ed = Editor::new(ClientId(1));
    ed.open("file", "", None);
    let preview = ed.create_buffer("preview", "fn main() {}");
    let mut syntax = Syntax::new();
    syntax.update(&ed);
    let text = ed.buffer(preview).text().clone();
    assert!(syntax.highlights(preview, &text, 0..12).is_empty());

    ed.set_language(preview, Some("rust".into()));
    syntax.update(&ed);
    wait(&mut syntax);
    let all = syntax.highlights(preview, &text, 0..12);
    assert!(captured(&all, 0..2).contains(&"keyword"), "{all:?}");

    // Switching to a language Kern doesn't know drops the highlights.
    ed.set_language(preview, Some("klingon".into()));
    syntax.update(&ed);
    assert!(syntax.highlights(preview, &text, 0..12).is_empty());
}

fn host(text: &str, language: Option<&str>) -> kern_core::luau::Host {
    let mut ed = Editor::new(ClientId(1));
    ed.open("file", text, None);
    let host = kern_core::luau::Host::new(ed).unwrap();
    if let Some(language) = language {
        host.eval(&format!(
            "require('@kern').view():buffer():set_language('{language}')"
        ))
        .unwrap();
    }
    host
}

fn eval(host: &kern_core::luau::Host, body: &str) -> String {
    host.eval(&format!(
        "(function() local kern = require('@kern') local b = kern.view():buffer() {body} end)()"
    ))
    .unwrap()
}

const RUST: &str = "fn add(a: i32, b: i32) -> i32 {\n    a + b\n}\n\nfn two() {}\n";

#[test]
fn plugins_walk_the_syntax_tree() {
    let h = host(RUST, Some("rust"));
    // The name of the first function.
    let name = eval(
        &h,
        "local n = b:node_at(3) return `{n.kind} {n.from} {n.to} {n.field} {n:text()}`",
    );
    assert_eq!(name, "identifier 3 6 name add");
    let up = eval(&h, "return b:node_at(3):parent().kind");
    assert_eq!(up, "function_item");
    let body = eval(&h, "return b:node_at(3):parent():child('body'):text()");
    assert_eq!(body, "{\n    a + b\n}");
    let params = eval(
        &h,
        "local ps = b:node_at(3):parent():child('parameters') \
         local out = {} for _, p in ps:named_children() do table.insert(out, p:text()) end \
         return `{#ps:children()} {table.concat(out, '|')}`",
    );
    assert_eq!(params, "5 a: i32|b: i32");
    let next = eval(
        &h,
        "local f = b:node_at(3):parent() return `{f:next():child('name'):text()} {f:prev()}`",
    );
    assert_eq!(next, "two nil");
    assert_eq!(eval(&h, "return b:tree().kind"), "source_file");
    assert_eq!(eval(&h, "return tostring(b:node_at(3))"), "(identifier)");
    // The same node found twice is equal.
    assert_eq!(
        eval(&h, "return tostring(b:node_at(3) == b:node_at(4))"),
        "true"
    );
}

#[test]
fn the_tree_follows_edits_right_away() {
    let h = host(RUST, Some("rust"));
    let kind = eval(
        &h,
        "b:edit(function(e) e:replace(0, 2, 'pub fn') end) \
         return `{b:node_at(0).kind} {b:node_at(7):text()}`",
    );
    assert_eq!(kind, "visibility_modifier add");
    let stale = eval(
        &h,
        "local n = b:node_at(7) b:edit(function(e) e:insert(0, ' ') end) \
         local ok, err = pcall(n.text, n) return tostring(err)",
    );
    assert!(stale.contains("changed since"), "{stale}");
}

#[test]
fn queries_return_their_captures_by_match() {
    let h = host(RUST, Some("rust"));
    let names = eval(
        &h,
        "local out = {} \
         for _, m in b:query('(function_item name: (identifier) @name) @fn') do \
           table.insert(out, `{m.name:text()}@{m.fn.from}`) end \
         return table.concat(out, ' ')",
    );
    assert_eq!(names, "add@0 two@45");
    let ranged = eval(&h, "return #b:query('(function_item) @fn', { from = 45 })");
    assert_eq!(ranged, "1");
    let predicate = eval(&h, "return #b:query('((identifier) @id (#eq? @id \"b\"))')");
    assert_eq!(predicate, "2");
    let bad = eval(
        &h,
        "local ok, err = pcall(b.query, b, '(no_such_node) @x') return tostring(err)",
    );
    assert!(bad.contains("query"), "{bad}");
}

#[test]
fn buffers_without_a_grammar_have_no_tree() {
    let h = host("plain text", None);
    assert_eq!(
        eval(
            &h,
            "return `{b:tree()} {b:node_at(0)} {#b:query('(x) @y')}`"
        ),
        "nil nil 0"
    );
    let unknown = host("plain text", Some("klingon"));
    assert_eq!(eval(&unknown, "return tostring(b:tree())"), "nil");
}

#[test]
fn a_highlights_query_set_replaces_the_grammars_own() {
    let text = "fn main() {}";
    let ed = editor(text, "main.rs");
    let mut syntax = Syntax::new();
    syntax.update(&ed);
    wait(&mut syntax);
    let buffer = ed.buffers().next().unwrap();
    let all = |syntax: &Syntax| syntax.highlights(buffer.id(), buffer.text(), 0..text.len());

    syntax
        .set_query("rust", "highlights", Some("\"fn\" @custom.fn".into()))
        .unwrap();
    assert_eq!(captured(&all(&syntax), 0..2), ["custom.fn"]);
    assert_eq!(
        syntax.query_source("rust", "highlights").as_deref(),
        Some("\"fn\" @custom.fn")
    );

    // A query the grammar can't compile is refused, and the last one stays.
    let err = syntax
        .set_query("rust", "highlights", Some("(no_such_node) @x".into()))
        .unwrap_err();
    assert!(err.contains("no_such_node"), "{err}");
    assert_eq!(captured(&all(&syntax), 0..2), ["custom.fn"]);

    syntax.set_query("rust", "highlights", None).unwrap();
    assert!(captured(&all(&syntax), 0..2).contains(&"keyword"));

    // Languages without a grammar keep their queries for plugins to read.
    syntax
        .set_query("klingon", "textobjects", Some("anything".into()))
        .unwrap();
    assert_eq!(
        syntax.query_source("klingon", "textobjects").as_deref(),
        Some("anything")
    );
}

#[test]
fn code_blocks_and_inline_text_in_markdown_are_highlighted_in_their_own_language() {
    let text = "# Title\n\nSome *emphasis* here.\n\n```rust\nfn main() {}\n```\n\n```klingon\nqapla\n```\n";
    let ed = editor(text, "README.md");
    let mut syntax = Syntax::new();
    syntax.update(&ed);
    wait(&mut syntax);
    let buffer = ed.buffers().next().unwrap();
    let all = syntax.highlights(buffer.id(), buffer.text(), 0..text.len());

    let fn_at = text.find("fn main").unwrap();
    assert!(
        captured(&all, fn_at..fn_at + 2).contains(&"keyword"),
        "Rust inside the code block: {all:?}"
    );
    let emphasis = text.find("*emphasis*").unwrap();
    assert!(
        captured(&all, emphasis..emphasis + "*emphasis*".len()).contains(&"text.emphasis"),
        "Markdown's inline text: {all:?}"
    );
    // A language Kern has no grammar for is left as it is.
    let klingon = text.find("qapla").unwrap();
    assert!(
        all.iter()
            .all(|h| !h.range.contains(&klingon) || !h.capture.starts_with("keyword"))
    );

    // An injections query set in place of the grammar's own is used, here
    // one that injects nothing.
    syntax
        .set_query("markdown", "injections", Some(String::new()))
        .unwrap();
    syntax.update(&ed);
    wait(&mut syntax);
    let all = syntax.highlights(buffer.id(), buffer.text(), 0..text.len());
    assert!(
        !captured(&all, fn_at..fn_at + 2).contains(&"keyword"),
        "{all:?}"
    );
}

#[test]
fn rust_macro_bodies_are_highlighted_as_rust() {
    let text = "fn f() { println!(\"{}\", 1 + 2); }";
    let ed = editor(text, "a.rs");
    let mut syntax = Syntax::new();
    syntax.update(&ed);
    wait(&mut syntax);
    let buffer = ed.buffers().next().unwrap();
    let all = syntax.highlights(buffer.id(), buffer.text(), 0..text.len());
    let one = text.find('1').unwrap();
    assert!(
        captured(&all, one..one + 1)
            .iter()
            .any(|c| c.starts_with("constant") || c.starts_with("number")),
        "{all:?}"
    );
}

#[test]
fn queries_for_languages_no_buffer_is_in_compile_when_one_opens() {
    let mut syntax = Syntax::new();
    // Nothing is in Python yet, so a broken query isn't noticed now.
    syntax
        .set_query("python", "highlights", Some("(no_such_node) @x".into()))
        .unwrap();
    let text = "def f(): pass";
    let ed = editor(text, "a.py");
    syntax.update(&ed);
    wait(&mut syntax);
    let problems = syntax.take_problems();
    assert_eq!(problems.len(), 1, "{problems:?}");
    assert!(problems[0].contains("python highlights"), "{problems:?}");
    // The grammar's own query is used instead.
    let buffer = ed.buffers().next().unwrap();
    let all = syntax.highlights(buffer.id(), buffer.text(), 0..text.len());
    assert!(captured(&all, 0..3).contains(&"keyword"), "{all:?}");

    // One that compiles is used once a buffer needs it.
    let mut syntax = Syntax::new();
    syntax
        .set_query("python", "highlights", Some("\"def\" @custom".into()))
        .unwrap();
    syntax.update(&ed);
    wait(&mut syntax);
    assert!(syntax.take_problems().is_empty());
    let all = syntax.highlights(buffer.id(), buffer.text(), 0..text.len());
    assert_eq!(captured(&all, 0..3), ["custom"]);
}

#[test]
fn grammars_load_from_webassembly_and_parse_like_built_in_ones() {
    let wasm = std::fs::read(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/samples/tree-sitter-json.wasm"),
    )
    .unwrap();
    let mut syntax = Syntax::new();
    // A query set before the grammar arrives is used once it does.
    syntax
        .set_query(
            "jsonish",
            "highlights",
            Some("(number) @constant.numeric".into()),
        )
        .unwrap();
    assert!(syntax.load_grammar("jsonish", "json", b"not wasm").is_err());
    syntax.load_grammar("jsonish", "json", &wasm).unwrap();
    assert!(syntax.names().contains(&"jsonish"));

    let text = "{\"a\": 42}";
    let mut ed = Editor::new(ClientId(1));
    let buffer = ed.create_buffer("file", text);
    ed.set_language(buffer, Some("jsonish".into()));
    syntax.update(&ed);
    wait(&mut syntax);
    let all = syntax.highlights(buffer, ed.buffer(buffer).text(), 0..text.len());
    let at = text.find("42").unwrap();
    assert_eq!(captured(&all, at..at + 2), ["constant.numeric"], "{all:?}");
}
