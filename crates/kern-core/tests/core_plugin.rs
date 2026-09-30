//! Runs the default `core` plugin's Luau tests, and checks that the test
//! harness reports failures usefully.

use std::path::{Path, PathBuf};

use kern_core::luau::run_tests;

fn core() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../runtime/plugins/core")
}

#[test]
fn core_plugin_tests_pass() {
    let results = run_tests(&[core()], &core()).unwrap();
    assert!(results.len() >= 10, "found only {} tests", results.len());
    let failures: Vec<String> = results
        .iter()
        .filter_map(|r| r.failure.as_ref().map(|f| format!("{}: {f}", r.name)))
        .collect();
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn failures_name_the_line_and_what_differed() {
    let dir = std::env::temp_dir().join(format!("kern-test-harness-{}", std::process::id()));
    std::fs::create_dir_all(dir.join("test")).unwrap();
    std::fs::write(
        dir.join("test/sample.luau"),
        "test('passes', function(t)\n  t:buffer('|ab')\n  t:keys('l')\n  t:expect('a|b')\nend)\n\
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
        failure.contains("line 9: expected buffer \"ab|\", got \"a|b\""),
        "{failure}"
    );
    assert!(summary[2].1.unwrap().contains("no-such-command"));
}
