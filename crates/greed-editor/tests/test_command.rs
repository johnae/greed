use std::io::Write;
use std::process::Command;

#[test]
fn core_plugin_tests_pass() {
    let output = Command::new(env!("CARGO_BIN_EXE_greed"))
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
    let dir = std::env::temp_dir().join(format!("greed-test-command-{}", std::process::id()));
    std::fs::create_dir_all(dir.join("test")).unwrap();
    std::fs::write(dir.join("plugin.toml"), "name = \"sample\"\n").unwrap();
    std::fs::write(dir.join("init.luau"), "").unwrap();
    std::fs::write(
        dir.join("test/sample.luau"),
        "local test = require('@greed/test')\ntest('fails', function(t)\n  t:buffer('|a')\n  t:expect('a|')\nend)\n",
    )
    .unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_greed"))
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
fn several_plugins_are_tested_at_once_and_reported_one_by_one() {
    let root = std::env::temp_dir().join(format!("greed-test-several-{}", std::process::id()));
    let plugin = |name: &str, tests: &str| {
        let dir = root.join(name);
        std::fs::create_dir_all(dir.join("test")).unwrap();
        std::fs::write(dir.join("plugin.toml"), format!("name = \"{name}\"\n")).unwrap();
        std::fs::write(dir.join("init.luau"), "").unwrap();
        std::fs::write(
            dir.join("test/sample.luau"),
            format!("local test = require('@greed/test')\n{tests}"),
        )
        .unwrap();
        dir
    };
    let passing = plugin(
        "passing",
        "test('one', function(t) t:buffer('|a') t:expect('|a') end)\n\
         test('two', function(t) t:buffer('|b') t:expect('|b') end)\n",
    );
    let failing = plugin(
        "failing",
        "test('ok', function(t) t:buffer('|a') t:expect('|a') end)\n\
         test('wrong', function(t) t:buffer('|a') t:expect('a|') end)\n",
    );

    let output = Command::new(env!("CARGO_BIN_EXE_greed"))
        .args(["test", passing.to_str().unwrap(), failing.to_str().unwrap()])
        .output()
        .unwrap();
    let (passing, failing) = (
        passing.canonicalize().unwrap(),
        failing.canonicalize().unwrap(),
    );
    std::fs::remove_dir_all(&root).unwrap();

    let stdout = String::from_utf8(output.stdout).unwrap();
    assert!(!output.status.success(), "{stdout}");
    // Each plugin's results together, in the order given, then the total.
    let summary = |dir: &std::path::Path, counts: &str| {
        let line = format!("{}: {counts}\n", dir.display());
        stdout
            .find(&line)
            .unwrap_or_else(|| panic!("{line:?} in {stdout}"))
    };
    let passed = summary(&passing, "2 passed, 0 failed");
    let failed = summary(&failing, "1 passed, 1 failed");
    let wrong = stdout.find("  FAIL  wrong\n").expect(&stdout);
    assert!(passed < wrong && wrong < failed, "{stdout}");
    assert!(stdout.ends_with("\n3 passed, 1 failed\n"), "{stdout}");
}

#[test]
fn new_plugins_pass_their_own_tests_and_load_from_the_config_directory() {
    let config = std::env::temp_dir().join(format!("greed-new-plugin-{}", std::process::id()));
    let plugins = config.join("greed/plugins");
    std::fs::create_dir_all(&plugins).unwrap();
    let greed = |args: &[&str]| {
        Command::new(env!("CARGO_BIN_EXE_greed"))
            .args(args)
            .current_dir(&plugins)
            .env("XDG_CONFIG_HOME", &config)
            .output()
            .unwrap()
    };

    let made = greed(&["new", "greeter"]);
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
        ".greed-types/greed/init.luau",
    ] {
        assert!(plugins.join(file).is_file(), "{file}");
    }
    assert!(
        !greed(&["new", "greeter"]).status.success(),
        "won't overwrite"
    );
    assert!(
        !greed(&["new", "bad name"]).status.success(),
        "checks the name"
    );

    let tested = greed(&["test", "greeter"]);
    let out = String::from_utf8_lossy(&tested.stdout);
    assert!(tested.status.success(), "{out}");
    assert!(out.contains("1 passed, 0 failed"), "{out}");

    // Plugins in the config directory load with the defaults.
    let mut repl = Command::new(env!("CARGO_BIN_EXE_greed"))
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
    assert_eq!(out, "[helix]\nhello|\n");

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
