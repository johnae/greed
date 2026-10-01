use std::io::Write;
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

#[test]
fn new_plugins_pass_their_own_tests_and_load_from_the_config_directory() {
    let config = std::env::temp_dir().join(format!("kern-new-plugin-{}", std::process::id()));
    let plugins = config.join("kern/plugins");
    std::fs::create_dir_all(&plugins).unwrap();
    let kern = |args: &[&str]| {
        Command::new(env!("CARGO_BIN_EXE_kern"))
            .args(args)
            .current_dir(&plugins)
            .env("XDG_CONFIG_HOME", &config)
            .output()
            .unwrap()
    };

    let made = kern(&["new", "greeter"]);
    assert!(
        made.status.success(),
        "{}",
        String::from_utf8_lossy(&made.stderr)
    );
    for file in [
        "greeter/plugin.toml",
        "greeter/init.luau",
        "greeter/test/greet.luau",
        ".luaurc",
        ".kern-types/kern/init.luau",
    ] {
        assert!(plugins.join(file).is_file(), "{file}");
    }
    assert!(
        !kern(&["new", "greeter"]).status.success(),
        "won't overwrite"
    );
    assert!(
        !kern(&["new", "bad name"]).status.success(),
        "checks the name"
    );

    let tested = kern(&["test", "greeter"]);
    let out = String::from_utf8_lossy(&tested.stdout);
    assert!(tested.status.success(), "{out}");
    assert!(out.contains("1 passed, 0 failed"), "{out}");

    // Plugins in the config directory load with the defaults.
    let mut repl = Command::new(env!("CARGO_BIN_EXE_kern"))
        .arg("repl")
        .env("XDG_CONFIG_HOME", &config)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();

    repl.stdin
        .take()
        .unwrap()
        .write_all(b":run greeter-greet\n")
        .unwrap();
    let out = String::from_utf8(repl.wait_with_output().unwrap().stdout).unwrap();
    assert_eq!(out, "[normal]\nhello|\n");

    // The scaffold type-checks in strict mode, if luau-analyze is around.
    if let Ok(output) = Command::new("luau-analyze")
        .args(["init.luau", "test/greet.luau"])
        .current_dir(plugins.join("greeter"))
        .output()
    {
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stdout)
        );
    }
    std::fs::remove_dir_all(&config).unwrap();
}
