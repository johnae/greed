//! `greed ctl`, `greed ls` and `greed mcp` against real sessions.

mod common;

use std::io::Write;
use std::process::{Child, Command, Stdio};

use common::{GREED, World, running};
use greed_core::control;

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
    // Watching the status: the whole of it at once, then again as it changes.
    let mut watch = Command::new(GREED);
    watch
        .args(["ctl", "watch", "hooks"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    world.env(&mut watch);
    let mut watch = watch.spawn().unwrap();
    let (lines, watched) = std::sync::mpsc::channel::<String>();
    let watch_out = std::io::BufReader::new(watch.stdout.take().unwrap());
    std::thread::spawn(move || {
        use std::io::BufRead;
        for line in watch_out.lines().map_while(Result::ok) {
            if lines.send(line).is_err() {
                return;
            }
        }
    });
    let first = watched
        .recv_timeout(std::time::Duration::from_secs(10))
        .unwrap();
    assert!(first.contains("\"schema\":1"), "{first}");
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
        .write_all(br#"{"hook_event_name": "PermissionRequest", "tool_name": "Bash"}"#)
        .unwrap();
    let said = hook.wait_with_output().unwrap();
    assert_eq!(text(&said).0.trim(), "waiting", "{:?}", text(&said));
    let changed = loop {
        let line = watched
            .recv_timeout(std::time::Duration::from_secs(10))
            .unwrap();
        if line.contains("\"waiting\"") {
            break line;
        }
    };
    assert!(
        changed.contains(&format!("terminal:{terminal}")),
        "{changed}"
    );
    let _ = watch.kill();
    let _ = watch.wait();
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
    // `greed ls` asks each session how its agents are doing.
    let (listed, _) = text(&world.greed(&["ls"]));
    assert!(listed.contains("◆ 1 waiting for you"), "{listed}");

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

#[test]
fn the_hub_follows_the_other_sessions_and_the_rest_follow_the_hub() {
    let Some(world) = World::new("ctl-hub") else {
        return;
    };
    let mut servers: Vec<Child> = ["alpha", "beta", "gamma"]
        .iter()
        .map(|name| serve(&world, &world.project(name, &[("a.txt", "one\n")])))
        .collect();
    world.wait_for("three sessions", |w| w.sessions().lines().count() == 3);
    // An agent waits in beta.
    let terminal = world.eval(
        "beta",
        "return require('@terminal').open({ 'sh', '-c', 'sleep 60' }).buffer:id()",
    );
    world.eval(
        "beta",
        &format!(
            "require('@terminal').agent_report(require('@greed').buffer({terminal}), \
             {{ source = 'hook', trusted = true, name = 'claude', state = 'waiting' }})"
        ),
    );
    // alpha, first by name, is the hub and sees it; gamma sees it through
    // the hub.
    let sees = |w: &World, name: &str| {
        w.eval(
            name,
            "local found = require('@hub').elsewhere() \
             for _, f in found do if f.session == 'beta' and f.agent.status == 'waiting' then return 'yes' end end \
             return 'no'",
        ) == "yes"
    };
    world.wait_for("the hub to see beta's agent", |w| sees(w, "alpha"));
    world.wait_for("gamma to see it through the hub", |w| sees(w, "gamma"));
    for name in ["alpha", "beta", "gamma"] {
        world.eval(name, "require('@greed').quit()");
    }
    for server in &mut servers {
        let _ = server.wait();
    }
}

/// A window called `client` ("gui@testbox") attached to the session `name`
/// in the sessions folder `run`.
fn attach_window(run: &std::path::Path, name: &str, client: &str) -> control::Attachment {
    use greed_core::server::Input;
    let dir = run.join("greed");
    let token = std::fs::read_to_string(dir.join(format!("{name}.token"))).unwrap();
    let mut params = control::handshake();
    params["client"] = serde_json::json!({ "kind": "gui", "name": client });
    let mut attached = control::Client::connect(&dir.join(format!("{name}.sock")), token.trim())
        .unwrap()
        .attach_with(&params)
        .unwrap();
    let resize = Input::Resize(greed_core::render::Size {
        width: 80,
        height: 20,
    });
    writeln!(
        attached.writer,
        "{}",
        serde_json::to_string(&resize).unwrap()
    )
    .unwrap();
    attached
}

/// The next notification `attached` gets, within 30 seconds.
fn next_notice(attached: &mut control::Attachment) -> greed_core::Notice {
    use greed_core::server::Output;
    use std::io::BufRead;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    loop {
        assert!(std::time::Instant::now() < deadline, "no notification came");
        let mut line = String::new();
        attached.reader.read_line(&mut line).unwrap();
        if let Ok(Output::Notify(notice)) = serde_json::from_str::<Output>(&line) {
            return notice;
        }
    }
}

/// Fails if `attached` gets a notification in the next four seconds.
fn no_notice(attached: &mut control::Attachment) {
    use greed_core::server::Output;
    use std::io::BufRead;
    let quiet = std::time::Instant::now() + std::time::Duration::from_secs(4);
    attached
        .reader
        .get_ref()
        .set_read_timeout(Some(std::time::Duration::from_millis(500)))
        .unwrap();
    // A line cut off by the timeout is read on into the same buffer.
    let mut line = String::new();
    while std::time::Instant::now() < quiet {
        if attached.reader.read_line(&mut line).is_ok() {
            assert!(
                !matches!(serde_json::from_str::<Output>(&line), Ok(Output::Notify(_))),
                "told twice: {line}"
            );
            line.clear();
        }
    }
    attached.reader.get_ref().set_read_timeout(None).unwrap();
}

/// Starts an agent waiting in a terminal of the session `name`, as its
/// hooks say it, through `eval` (the world's, or another machine's).
fn agent_waits(eval: impl Fn(&str) -> String) {
    let terminal = eval("return require('@terminal').open({ 'sh', '-c', 'sleep 60' }).buffer:id()");
    eval(&format!(
        "require('@terminal').agent_report(require('@greed').buffer({terminal}), \
         {{ source = 'hook', trusted = true, name = 'claude', state = 'waiting' }})"
    ));
}

#[test]
fn an_agent_waiting_in_one_session_is_told_to_your_client_in_another() {
    let Some(world) = World::new("ctl-told") else {
        return;
    };
    let mut servers: Vec<Child> = ["alpha", "beta", "gamma"]
        .iter()
        .map(|name| serve(&world, &world.project(name, &[("a.txt", "one\n")])))
        .collect();
    world.wait_for("three sessions", |w| w.sessions().lines().count() == 3);
    let mut attached = attach_window(&world.root.join("run"), "gamma", "gui@testbox");
    // Wait until the hub knows of the client before the agent waits.
    world.wait_for("the hub to see the client", |w| {
        w.eval(
            "alpha",
            "local s = require('@hub').machine().gamma return tostring(s and s.clients and s.clients[1])",
        ) == "gui@testbox"
    });
    agent_waits(|code| world.eval("beta", code));
    // The window in gamma hears that an agent waits in beta.
    let notice = next_notice(&mut attached);
    assert!(notice.title.contains("waits for you"), "{notice:?}");
    assert!(notice.body.contains("beta"), "{notice:?}");
    for name in ["alpha", "beta", "gamma"] {
        world.eval(name, "require('@greed').quit()");
    }
    for server in &mut servers {
        let _ = server.wait();
    }
}

#[test]
fn hubs_on_two_machines_follow_each_other_and_tell_you_once() {
    let Some(world) = World::new("ctl-hosts") else {
        return;
    };
    let machines = common::TwoMachines::new(&world);
    let eval = |name: &str, there: bool, code: &str| machines.eval(name, there, code);
    // Each machine reached the other with greed ssh lately, which noted it.
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    for (data, other) in [("data/greed", "there"), ("there/data/greed", "here")] {
        let dir = world.root.join(data);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("ssh-hosts"), format!("{{\"{other}\": {now}}}")).unwrap();
    }
    let mut servers = [machines.serve("alpha", false), machines.serve("beta", true)];
    for (name, there) in [("alpha", false), ("beta", true)] {
        common::wait_until(name, || eval(name, there, "return 'up'") == "up");
    }
    let mut attached = attach_window(&world.root.join("run"), "alpha", "gui@desk");
    // Each hub sees the other machine, and not itself through it.
    let machines = |name: &str, there: bool| {
        eval(
            name,
            there,
            "local n = 0 for _, m in require('@hub').machines() do n += 1 end \
             local me = require('@agent').host().id \
             return `{n} {require('@hub').machines()[me] == nil}`",
        )
    };
    common::wait_until("alpha to follow there", || {
        machines("alpha", false) == "1 true"
    });
    common::wait_until("beta to follow here", || machines("beta", true) == "1 true");
    agent_waits(|code| eval("beta", true, code));
    // alpha has the agent on the other machine, and tells the window here.
    common::wait_until("alpha to see the agent there", || {
        eval(
            "alpha",
            false,
            "for _, f in require('@hub').elsewhere() do \
             if f.session == 'beta' and f.machine and f.agent.status == 'waiting' then return 'yes' end end \
             return 'no'",
        ) == "yes"
    });
    let notice = next_notice(&mut attached);
    assert!(notice.title.contains("waits for you"), "{notice:?}");
    assert!(notice.body.contains("beta on "), "{notice:?}");
    // And only once, though both hubs see it.
    no_notice(&mut attached);
    // With a window from this desk on the other machine too, its own hub
    // tells it there, and this one leaves it be.
    let mut there = attach_window(&world.root.join("there/run"), "beta", "tui@desk");
    common::wait_until("alpha to see the window there", || {
        eval(
            "alpha",
            false,
            "for _, m in require('@hub').machines() do local s = m.sessions.beta \
             if s and s.clients[1] == 'tui@desk' then return 'yes' end end return 'no'",
        ) == "yes"
    });
    agent_waits(|code| eval("beta", true, code));
    let notice = next_notice(&mut there);
    assert!(notice.body.contains("beta"), "{notice:?}");
    no_notice(&mut attached);
    eval("alpha", false, "require('@greed').quit()");
    eval("beta", true, "require('@greed').quit()");
    for server in &mut servers {
        let _ = server.wait();
    }
}
