//! Highlighting of each bundled language, with the runtime's own queries,
//! checked against a snapshot beside its sample. When a query changes on
//! purpose, run with `KERN_UPDATE_SNAPSHOTS=1` and look the diff over.

use std::collections::BTreeSet;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::time::Duration;

use kern_core::Editor;
use kern_core::syntax::{Highlight, Syntax};
use kern_text::ClientId;

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn queries() -> PathBuf {
    root().join("runtime/plugins/languages/queries")
}

fn samples() -> PathBuf {
    root().join("crates/kern-core/tests/samples")
}

/// Sets every query file the languages plugin has, as it does when it loads.
fn load_queries(syntax: &mut Syntax) {
    for language in std::fs::read_dir(queries()).unwrap() {
        let language = language.unwrap().path();
        let name = language.file_name().unwrap().to_string_lossy().into_owned();
        for file in std::fs::read_dir(&language).unwrap() {
            let file = file.unwrap().path();
            let kind = file.file_stem().unwrap().to_string_lossy().into_owned();
            let source = std::fs::read_to_string(&file).unwrap();
            syntax
                .set_query(&name, &kind, Some(source))
                .unwrap_or_else(|err| panic!("{}: {err}", file.display()));
        }
    }
}

/// Each line of `text`, then a line marking each highlight that starts on
/// it, `+` where it goes on past the line's end.
fn render(text: &str, highlights: &[Highlight]) -> String {
    let mut sorted = highlights.to_vec();
    sorted.sort_by_key(|h| (h.range.start, std::cmp::Reverse(h.range.end)));
    sorted.dedup();
    let mut out = String::new();
    let mut start = 0;
    for line in text.split_inclusive('\n') {
        let end = start + line.trim_end_matches('\n').len();
        let _ = writeln!(out, "{}", &text[start..end]);
        for h in sorted
            .iter()
            .filter(|h| (start..=end).contains(&h.range.start) && !h.range.is_empty())
        {
            let width = h.range.end.min(end).saturating_sub(h.range.start).max(1);
            let more = if h.range.end > end { "+" } else { "" };
            let _ = writeln!(
                out,
                "{}{}{more} {}",
                " ".repeat(h.range.start - start),
                "^".repeat(width),
                h.capture
            );
        }
        start += line.len();
    }
    out
}

fn highlight(sample: &str) -> String {
    let path = samples().join(sample);
    let text = std::fs::read_to_string(&path).unwrap();
    let mut ed = Editor::new(ClientId(1));
    ed.open("file", &text, Some(path));
    let mut syntax = Syntax::new();
    load_queries(&mut syntax);
    syntax.update(&ed);
    let parsed = syntax
        .results()
        .recv_timeout(Duration::from_secs(5))
        .expect("parse finished");
    syntax.receive(parsed);
    let buffer = ed.buffers().next().unwrap();
    render(
        &text,
        &syntax.highlights(buffer.id(), buffer.text(), 0..text.len()),
    )
}

fn check(sample: &str) {
    let actual = highlight(sample);
    let snapshot = samples().join(format!("{sample}.highlights"));
    if std::env::var_os("KERN_UPDATE_SNAPSHOTS").is_some() {
        std::fs::write(&snapshot, &actual).unwrap();
        return;
    }
    let expected = std::fs::read_to_string(&snapshot).unwrap_or_default();
    assert!(
        actual == expected,
        "{sample} highlights differently from {}; if that's on purpose, run with \
         KERN_UPDATE_SNAPSHOTS=1. Now:\n{actual}",
        snapshot.display()
    );
}

#[test]
fn rust() {
    check("sample.rs");
}

#[test]
fn luau() {
    check("sample.luau");
}

#[test]
fn json() {
    check("sample.json");
}

#[test]
fn toml() {
    check("sample.toml");
}

#[test]
fn markdown_with_its_inline_text_and_code_blocks() {
    check("sample.md");
}

#[test]
fn nix_with_shell_in_its_build_phases() {
    check("sample.nix");
}

#[test]
fn bash() {
    check("sample.sh");
}

#[test]
fn python() {
    check("sample.py");
}

#[test]
fn go() {
    check("sample.go");
}

#[test]
fn javascript_with_jsx() {
    check("sample.js");
}

#[test]
fn typescript() {
    check("sample.ts");
}

#[test]
fn tsx() {
    check("sample.tsx");
}

#[test]
fn c() {
    check("sample.c");
}

#[test]
fn yaml() {
    check("sample.yaml");
}

/// The names docs/highlighting.md lists, from its tables.
fn documented() -> BTreeSet<String> {
    let docs = std::fs::read_to_string(root().join("docs/highlighting.md")).unwrap();
    docs.lines()
        .filter_map(|line| line.strip_prefix("| `")?.split_once('`'))
        .map(|(name, _)| name.to_owned())
        .collect()
}

/// Whether an `@` after `before` starts a capture. Strings and comments can
/// hold an `@` too; captures follow a pattern's closing bracket or quote,
/// or another capture.
fn is_capture(before: &str) -> bool {
    before.ends_with([')', ']', '"'])
        || before
            .split_whitespace()
            .last()
            .is_some_and(|w| w.starts_with('@'))
}

#[test]
fn bundled_queries_only_use_documented_names() {
    let documented = documented();
    assert!(
        documented.contains("keyword.control.return"),
        "{documented:?}"
    );
    for language in std::fs::read_dir(queries()).unwrap() {
        let path = language.unwrap().path().join("highlights.scm");
        let Ok(source) = std::fs::read_to_string(&path) else {
            continue;
        };
        for line in source.lines().filter(|l| !l.trim_start().starts_with(';')) {
            for (i, _) in line.match_indices('@') {
                if !is_capture(line[..i].trim_end()) {
                    continue;
                }
                let name: String = line[i + 1..]
                    .chars()
                    .take_while(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '_')
                    .collect();
                assert!(
                    name.is_empty() || name.starts_with('_') || documented.contains(&name),
                    "{} uses @{name}, which docs/highlighting.md doesn't list",
                    path.display()
                );
            }
        }
    }
}
