use std::io::Write;
use std::process::{Command, Stdio};

fn repl(args: &[&str], script: &str) -> String {
    let mut child = Command::new(env!("CARGO_BIN_EXE_kern"))
        .arg("repl")
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
    assert_eq!(out, "[normal]\nhi|\n[normal]\n^hi|\n");
}

#[test]
fn luau_expressions_print_their_value() {
    let out = repl(&[], "1 + 2\nrequire('@kern').echo('hello')\n");
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
    let path = std::env::temp_dir().join(format!("kern-repl-test-{}.txt", std::process::id()));
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
