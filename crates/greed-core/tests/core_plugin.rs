//! Runs the default `core` plugin's Luau tests, and checks that the test
//! harness reports failures usefully.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use greed_core::luau::run_tests;

fn core() -> PathBuf {
    plugin("core")
}

fn plugin(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../runtime/plugins")
        .join(name)
}

/// Runs the tests in `dir`, failing on any failure, and returns how many ran.
fn assert_all_pass(plugins: &[PathBuf], dir: &Path) -> usize {
    let results = run_tests(plugins, dir).unwrap();
    assert!(!results.is_empty(), "no tests found in {}", dir.display());
    let failures: Vec<String> = results
        .iter()
        .filter_map(|r| r.failure.as_ref().map(|f| format!("{}: {f}", r.name)))
        .collect();
    assert!(failures.is_empty(), "{}", failures.join("\n"));
    results.len()
}

#[test]
fn picker_plugin_tests_pass() {
    assert_all_pass(&[core(), plugin("picker")], &plugin("picker"));
}

#[test]
fn core_plugin_tests_pass() {
    let count = assert_all_pass(&[core()], &core());
    assert!(count >= 10, "found only {count} tests");
}

#[test]
fn failures_name_the_line_and_what_differed() {
    let dir = std::env::temp_dir().join(format!("greed-test-harness-{}", std::process::id()));
    std::fs::create_dir_all(dir.join("test")).unwrap();
    std::fs::write(
        dir.join("test/sample.luau"),
        "local test = require('@greed/test')\ntest('passes', function(t)\n  t:buffer('|ab')\n  t:keys('l')\n  t:expect('a|b')\nend)\n\
         test('fails', function(t)\n  t:buffer('|ab')\n  t:keys('l')\n  t:expect('ab|')\nend)\n\
         test('errors', function(t)\n  t:run('no-such-command')\nend)\n",
    )
    .unwrap();

    let results = run_tests(&[core()], &dir).unwrap();
    std::fs::remove_dir_all(&dir).unwrap();

    let summary: Vec<(&str, Option<&str>)> = results
        .iter()
        .map(|r| (r.name.as_str(), r.failure.as_deref()))
        .collect();
    assert_eq!(summary[0], ("passes", None));
    assert_eq!(summary[1].0, "fails");
    let failure = summary[1].1.unwrap();
    assert!(
        failure.contains("line 10: expected buffer \"ab|\", got \"a|b\""),
        "{failure}"
    );
    assert!(summary[2].1.unwrap().contains("no-such-command"));
}

#[test]
fn statusline_plugin_tests_pass() {
    assert_all_pass(&[core(), plugin("statusline")], &plugin("statusline"));
}

#[test]
fn hints_plugin_tests_pass() {
    assert_all_pass(&[core(), plugin("hints")], &plugin("hints"));
}

#[test]
fn describe_plugin_tests_pass() {
    assert_all_pass(
        &[core(), plugin("picker"), plugin("describe")],
        &plugin("describe"),
    );
}

#[test]
fn edit_mode_plugin_tests_pass() {
    assert_all_pass(
        &[core(), plugin("picker"), plugin("edit-mode")],
        &plugin("edit-mode"),
    );
}

#[test]
fn prose_plugin_tests_pass() {
    assert_all_pass(&[core(), plugin("prose")], &plugin("prose"));
}

#[test]
fn cmdline_plugin_tests_pass() {
    // :norm is tried in the Vim style.
    assert_all_pass(
        &[core(), plugin("cmdline"), plugin("vim")],
        &plugin("cmdline"),
    );
}

#[test]
fn vim_plugin_tests_pass() {
    // Vim uses the completion menu for ctrl-n in insert mode and the
    // command line for :.
    let plugins = [
        core(),
        plugin("picker"),
        plugin("multibuffer"),
        plugin("statusline"),
        plugin("lsp"),
        plugin("cmdline"),
        plugin("vim"),
    ];
    assert_all_pass(&plugins, &plugin("vim"));
}

#[test]
fn theme_plugin_tests_pass() {
    let plugins = [core(), plugin("picker"), plugin("cmdline"), plugin("theme")];
    assert_all_pass(&plugins, &plugin("theme"));
}

#[test]
fn flash_plugin_tests_pass() {
    assert_all_pass(&[core(), plugin("flash")], &plugin("flash"));
}

#[test]
fn lsp_plugin_tests_pass() {
    let plugins = [
        core(),
        plugin("picker"),
        plugin("multibuffer"),
        plugin("statusline"),
        plugin("lsp"),
    ];
    assert_all_pass(&plugins, &plugin("lsp"));
}

#[test]
fn languages_plugin_tests_pass() {
    assert_all_pass(&[core(), plugin("languages")], &plugin("languages"));
}

#[test]
fn tree_plugin_tests_pass() {
    assert_all_pass(&[core(), plugin("tree")], &plugin("tree"));
}

/// Every default plugin's tests, with all the default plugins loaded the
/// way `greed test` runs them, so a plugin added later can't be missed here.
#[test]
fn every_default_plugin_passes_its_tests_with_the_others_loaded() {
    let root = core().parent().unwrap().to_owned();
    let mut all: Vec<PathBuf> = std::fs::read_dir(&root)
        .unwrap()
        .filter_map(|entry| Some(entry.ok()?.path()))
        .filter(|dir| dir.join("plugin.toml").is_file())
        .collect();
    all.sort();
    let mut ran = Vec::new();
    for dir in &all {
        if dir.join("test").is_dir() {
            assert_all_pass(&all, dir);
            ran.push(dir.file_name().unwrap().to_string_lossy().into_owned());
        }
    }
    for expected in ["agent", "core", "grep", "picker"] {
        assert!(
            ran.iter().any(|name| name == expected),
            "{expected} ran: {ran:?}"
        );
    }
}

/// The `"ui.…"` names in the default plugins' code, outside their tests.
fn ui_names(dir: &Path, names: &mut BTreeSet<String>) {
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            if path.file_name() != Some("test".as_ref()) {
                ui_names(&path, names);
            }
        } else if path.extension() == Some("luau".as_ref()) {
            let text = std::fs::read_to_string(&path).unwrap();
            for piece in text.split("\"ui.").skip(1) {
                let name: String = piece
                    .chars()
                    .take_while(|c| c.is_ascii_lowercase() || *c == '.')
                    .collect();
                if piece[name.len()..].starts_with('"') {
                    names.insert(format!("ui.{name}"));
                }
            }
        }
    }
}

#[test]
fn every_style_name_the_plugins_use_is_in_the_theme() {
    let mut names = BTreeSet::new();
    ui_names(&plugin(""), &mut names);
    // Set while flashing, and looked up with a fallback.
    names.remove("ui.flash.now");
    names.remove("ui.text");
    names.extend(["diff.plus", "diff.minus"].map(String::from));
    for severity in ["error", "warning", "info", "hint"] {
        names.insert(format!("diagnostic.sign.{severity}"));
        names.insert(format!("diagnostic.message.{severity}"));
    }
    assert!(names.len() > 20, "found the names: {names:?}");

    let host =
        greed_core::luau::Host::new(greed_core::Editor::new(greed_text::ClientId(1))).unwrap();
    host.load_dirs(&[core(), plugin("picker"), plugin("cmdline"), plugin("theme")])
        .unwrap();
    let missing: Vec<&String> = names
        .iter()
        .filter(|name| {
            // An entry for the name or one of its parents.
            let mut parts: Vec<&str> = name.split('.').collect();
            while !parts.is_empty() {
                let found = host
                    .eval(&format!(
                        "require('@greed').theme.get({:?}) ~= nil",
                        parts.join(".")
                    ))
                    .unwrap();
                if found == "true" {
                    return false;
                }
                parts.pop();
            }
            true
        })
        .collect();
    assert!(missing.is_empty(), "no theme entry for {missing:?}");
}
