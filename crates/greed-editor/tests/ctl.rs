//! `greed ctl`, `greed ls` and `greed mcp` against real sessions.

mod common;

use std::io::Write;
use std::process::{Child, Command, Stdio};

use common::{GREED, World, running};

/// A headless session for `project`, started like `greed serve` does it.
fn serve(world: &World, project: &std::path::Path) -> Child {
    let mut command = Command::new(GREED);
    command
        .arg("serve")
        .arg(project)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    world.env(&mut command);
    command.spawn().unwrap()
}

fn text(out: &std::process::Output) -> (String, String) {
    (
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

#[test]
fn ctl_says_when_no_editor_is_running() {
    let Some(world) = World::new("ctl-none") else {
        return;
    };
    let out = world.greed(&["ctl", "tools"]);
    assert!(!out.status.success());
    assert!(
        text(&out).1.contains("no editor is running"),
        "{:?}",
        text(&out)
    );
    // Help needs no editor.
    for help in ["--help", "help", "-h"] {
        let out = world.greed(&["ctl", help]);
        assert!(out.status.success(), "{help}: {:?}", text(&out));
        assert!(
            text(&out).0.contains("usage: greed ctl"),
            "{help}: {:?}",
            text(&out)
        );
    }
}

#[test]
fn ctl_runs_tools_with_arguments_as_pairs_or_json() {
    let Some(world) = World::new("ctl-tools") else {
        return;
    };
    let project = world.project("tools", &[("a.txt", "one\ntwo\nthree\n")]);
    let mut server = serve(&world, &project.join("a.txt"));
    world.wait_for("the session", running);

    let (tools, _) = text(&world.greed(&["ctl", "tools"]));
    for name in ["focus", "read", "propose", "eval"] {
        assert!(
            tools.lines().any(|l| l.starts_with(name)),
            "{name} in {tools}"
        );
    }
    let (lines, _) = text(&world.greed(&["ctl", "read", "path=a.txt", "from_line=2", "to_line=2"]));
    assert_eq!(lines.trim(), "two", "pairs, with numbers parsed as JSON");
    let (lines, _) = text(&world.greed(&["ctl", "read", r#"{"path": "a.txt", "from_line": 3}"#]));
    assert_eq!(lines.trim(), "three", "one JSON object");
    let (focus, _) = text(&world.greed(&["ctl", "focus"]));
    assert!(
        focus.contains("\"path\""),
        "JSON results are pretty-printed: {focus}"
    );

    let failed = world.greed(&["ctl", "nope"]);
    assert!(!failed.status.success());
    assert!(
        text(&failed).1.contains("no tool called nope"),
        "{:?}",
        text(&failed)
    );
    let bad = world.greed(&["ctl", "read", "no-equals-sign"]);
    assert!(
        text(&bad).1.contains("expected KEY=VALUE"),
        "{:?}",
        text(&bad)
    );
    // A tool's help, and arguments it doesn't take.
    let (help, _) = text(&world.greed(&["ctl", "shell_run", "--help"]));
    assert!(
        help.contains("Run a command line")
            && help.contains("command")
            && help.contains("required"),
        "{help}"
    );
    let wrong = world.greed(&["ctl", "shell_run", "cmd=ls"]);
    assert!(!wrong.status.success());
    assert!(
        text(&wrong)
            .1
            .contains("shell_run has no argument cmd; it takes command (required)"),
        "{:?}",
        text(&wrong)
    );
    let missing = world.greed(&["ctl", "shell_run"]);
    assert!(
        text(&missing).1.contains("shell_run needs command"),
        "{:?}",
        text(&missing)
    );

    world.eval("tools", "require('@greed').quit()");
    let _ = server.wait();
}

#[test]
fn several_sessions_need_a_name_and_ls_lists_them_with_their_projects() {
    let Some(world) = World::new("ctl-several") else {
        return;
    };
    let first = world.project("first", &[]);
    let second = world.project("second", &[]);
    let mut servers = [serve(&world, &first), serve(&world, &second)];
    world.wait_for("both sessions", |w| w.sessions().lines().count() == 2);

    let listed = world.sessions();
    assert!(listed.contains(first.to_str().unwrap()) && listed.contains(second.to_str().unwrap()));
    let out = world.greed(&["ctl", "focus"]);
    assert!(
        text(&out).1.contains("several editors are running"),
        "{:?}",
        text(&out)
    );
    assert_eq!(
        world.eval("second", "return require('@greed').session.current()"),
        "second"
    );

    for name in ["first", "second"] {
        world.eval(name, "require('@greed').quit()");
    }
    for server in &mut servers {
        let _ = server.wait();
    }
}

#[test]
fn greed_mcp_speaks_mcp_on_stdio() {
    let Some(world) = World::new("mcp") else {
        return;
    };
    let project = world.project("mcp", &[("a.txt", "hello mcp")]);
    let mut server = serve(&world, &project.join("a.txt"));
    world.wait_for("the session", running);

    let mut command = Command::new(GREED);
    command
        .arg("mcp")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    world.env(&mut command);
    let mut mcp = command.spawn().unwrap();
    let mut input = mcp.stdin.take().unwrap();
    writeln!(
        input,
        r#"{{"jsonrpc":"2.0","id":1,"method":"initialize","params":{{"protocolVersion":"2025-06-18"}}}}"#
    )
    .unwrap();
    writeln!(
        input,
        r#"{{"jsonrpc":"2.0","method":"notifications/initialized"}}"#
    )
    .unwrap();
    writeln!(
        input,
        r#"{{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{{"name":"read","arguments":{{}}}}}}"#
    )
    .unwrap();
    drop(input);
    let out = mcp.wait_with_output().unwrap();
    let answers: Vec<serde_json::Value> = String::from_utf8(out.stdout)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(
        answers.len(),
        2,
        "the notification gets no answer: {answers:?}"
    );
    assert_eq!(answers[0]["result"]["serverInfo"]["name"], "greed");
    assert_eq!(answers[1]["result"]["content"][0]["text"], "hello mcp");

    world.eval("mcp", "require('@greed').quit()");
    let _ = server.wait();
}
