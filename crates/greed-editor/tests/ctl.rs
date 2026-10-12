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
    let (status, _) = text(&world.greed(&["ctl", "status"]));
    let status: serde_json::Value = serde_json::from_str(&status).unwrap();
    assert_eq!(status["schema"], 1, "{status}");
    assert_eq!(status["session"], "tools", "{status}");
    assert!(
        status["attention"].is_array() && status["agents"].is_array(),
        "{status}"
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
fn an_agents_hooks_in_a_terminal_reach_the_status() {
    let Some(world) = World::new("ctl-hooks") else {
        return;
    };
    let project = world.project("hooks", &[("a.txt", "one\n")]);
    let mut server = serve(&world, &project.join("a.txt"));
    world.wait_for("the session", running);
    // An agent's hook in a terminal says it waits for you, as Claude Code's
    // would: the hook's input goes along as JSON, to the greed and the
    // terminal the terminal's programs are told of.
    let told = project.join("told");
    let terminal = world.eval(
        "hooks",
        &format!(
            "return require('@terminal').open({{ 'sh', '-c', 'echo \"$GREED_TERMINAL_ID $GREED_BIN\" > {}; sleep 30' }}).buffer:id()",
            told.display()
        ),
    );
    world.wait_for("the terminal to say", |_| told.exists());
    let greed = std::fs::canonicalize(GREED).unwrap();
    assert_eq!(
        std::fs::read_to_string(&told).unwrap().trim(),
        format!("{terminal} {}", greed.display())
    );
    let mut hook = Command::new(GREED);
    hook.args([
        "ctl",
        "agent_hook",
        &format!("terminal={terminal}"),
        "hook=@-",
    ])
    .stdin(Stdio::piped())
    .stdout(Stdio::piped())
    .stderr(Stdio::piped());
    world.env(&mut hook);
    let mut hook = hook.spawn().unwrap();
    hook.stdin
        .take()
        .unwrap()
        .write_all(br#"{"hook_event_name": "Notification", "notification_type": "permission_prompt", "message": "Claude needs your permission"}"#)
        .unwrap();
    let said = hook.wait_with_output().unwrap();
    assert_eq!(text(&said).0.trim(), "waiting", "{:?}", text(&said));
    let (status, _) = text(&world.greed(&["ctl", "status"]));
    let status: serde_json::Value = serde_json::from_str(&status).unwrap();
    let id = format!("terminal:{terminal}");
    assert!(
        status["agents"]
            .as_array()
            .unwrap()
            .iter()
            .any(|a| a["id"] == id.as_str() && a["status"] == "waiting"),
        "{status}"
    );
    assert!(
        status["attention"]
            .as_array()
            .unwrap()
            .iter()
            .any(|n| n["id"] == id.as_str() && n["reason"] == "claude waits for your answer"),
        "{status}"
    );

    world.eval("hooks", "require('@greed').quit()");
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

#[test]
fn edit_opens_files_and_waits_until_they_are_done_with() {
    let Some(world) = World::new("ctl-edit") else {
        return;
    };
    let project = world.project("edit", &[("a.txt", "a\n"), ("msg", "msg\n")]);
    let mut server = serve(&world, &project.join("a.txt"));
    world.wait_for("the session", running);
    let shown = "require('@greed').view():buffer():path() or ''";

    let opened = world.greed(&["edit", project.join("a.txt").to_str().unwrap()]);
    assert!(opened.status.success(), "{:?}", text(&opened));

    let msg = project.join("msg");
    let wait = |world: &World| {
        let mut command = Command::new(GREED);
        command
            .args(["edit", "--wait", msg.to_str().unwrap()])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped());
        world.env(&mut command);
        command.spawn().unwrap()
    };
    let msg_shown = |w: &World| w.eval("edit", shown).ends_with("/msg");
    // :q in it lets `greed edit` go, succeeding.
    let mut editing = wait(&world);
    world.wait_for("msg to show", msg_shown);
    assert!(editing.try_wait().unwrap().is_none(), "it waits");
    world.eval("edit", "require('@greed').run('quit')");
    assert!(editing.wait().unwrap().success());
    // :cq fails it.
    let editing = wait(&world);
    world.wait_for("msg to show again", msg_shown);
    world.eval("edit", "require('@greed').run('quit-abort')");
    let out = editing.wait_with_output().unwrap();
    assert!(!out.status.success());
    assert!(
        String::from_utf8_lossy(&out.stderr).contains(":cq"),
        "{out:?}"
    );

    world.eval("edit", "require('@greed').quit()");
    let _ = server.wait();
}
