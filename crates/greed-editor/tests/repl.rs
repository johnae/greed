use std::io::Write;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};

/// `greed repl` with a profile of its own, so your config, plugins and
/// approvals stay out of it.
fn greed_repl() -> Command {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let profile = std::env::temp_dir().join(format!(
        "greed-repl-test-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let mut command = Command::new(env!("CARGO_BIN_EXE_greed"));
    command.arg("repl").env("GREED_PROFILE", profile);
    command
}

fn repl(args: &[&str], script: &str) -> String {
    let mut child = greed_repl()
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(script.as_bytes())
        .unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    String::from_utf8(output.stdout).unwrap()
}

#[test]
fn keys_edit_and_show_the_buffer() {
    let out = repl(&[], ":keys i h i esc\n:keys g h w\n");
    assert_eq!(out, "[helix]\nhi|\n[helix]\n^hi|\n");
}

#[test]
fn luau_expressions_print_their_value() {
    let out = repl(&[], "1 + 2\nrequire('@greed').echo('hello')\n");
    assert_eq!(out, "3\nhello\n");
}

#[test]
fn errors_are_reported_and_the_repl_continues() {
    let out = repl(&[], ":run nope\n:bogus\n1\n");
    assert_eq!(
        out,
        "error: there is no command called \"nope\"\nerror: unknown REPL command :bogus (try :help)\n1\n"
    );
}

#[test]
fn files_open_and_write_back() {
    let path = std::env::temp_dir().join(format!("greed-repl-test-{}.txt", std::process::id()));
    std::fs::write(&path, "world").unwrap();
    let out = repl(
        &[path.to_str().unwrap()],
        ":keys i h e l l o space esc\n:write\n:quit\n1\n",
    );
    assert!(
        out.ends_with(&format!("wrote {}\n", path.display())),
        "{out}"
    );
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "hello world");
    std::fs::remove_file(&path).unwrap();
}

#[test]
fn the_user_config_loads_last_and_errors_are_shown() {
    let dir = std::env::temp_dir().join(format!("greed-config-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let config = dir.join("init.luau");
    std::fs::write(&config, "require('@greed').mode.set('insert')\n").unwrap();
    let run = |script: &str| {
        let mut child = greed_repl()
            .env("GREED_CONFIG", &config)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(script.as_bytes())
            .unwrap();
        String::from_utf8(child.wait_with_output().unwrap().stdout).unwrap()
    };
    assert_eq!(run(":show\n"), "[insert]\n|\n");

    std::fs::write(&config, "error('broken config')\n").unwrap();
    let out = run("1\n");
    assert!(
        out.contains("config: ") && out.contains("broken config"),
        "{out}"
    );
    std::fs::remove_dir_all(&dir).unwrap();
}
