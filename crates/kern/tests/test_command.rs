use std::process::Command;

#[test]
fn core_plugin_tests_pass() {
    let output = Command::new(env!("CARGO_BIN_EXE_kern"))
        .arg("test")
        .output()
        .unwrap();
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(output.status.success(), "{stdout}");
    assert!(
        stdout.contains("  ok    word motions select what they move over\n"),
        "{stdout}"
    );
    assert!(stdout.ends_with(" passed, 0 failed\n"), "{stdout}");
}

#[test]
fn failing_tests_fail_the_command() {
    let dir = std::env::temp_dir().join(format!("kern-test-command-{}", std::process::id()));
    std::fs::create_dir_all(dir.join("test")).unwrap();
    std::fs::write(dir.join("plugin.toml"), "name = \"sample\"\n").unwrap();
    std::fs::write(dir.join("init.luau"), "").unwrap();
    std::fs::write(
        dir.join("test/sample.luau"),
        "local test = require('@kern/test')\ntest('fails', function(t)\n  t:buffer('|a')\n  t:expect('a|')\nend)\n",
    )
    .unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_kern"))
        .args(["test", dir.to_str().unwrap()])
        .output()
        .unwrap();
    std::fs::remove_dir_all(&dir).unwrap();

    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(!output.status.success());
    assert!(
        stdout.contains("  FAIL  fails\n        line 4: expected buffer \"a|\", got \"|a\"\n"),
        "{stdout}"
    );
    assert!(stdout.ends_with("0 passed, 1 failed\n"), "{stdout}");
}
