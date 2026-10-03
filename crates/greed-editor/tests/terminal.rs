//! The terminal client and sessions end to end: the real `kern` binary in a
//! pseudo-terminal (through `script`), driven with keys, the way a person
//! uses it. Each test gets its own sessions, config and cache folders, so it
//! never sees your editors or another test's.

mod common;

use std::time::Duration;

use common::{KERN, Step, World, none_running, running};

#[test]
fn kern_starts_a_session_that_outlives_detaching_and_quits_from_a_new_terminal() {
    let Some(world) = World::new("lifecycle") else {
        return;
    };
    let project = world.project("notes", &[("todo.md", "buy milk\n")]);
    let out = world.terminal(
        &project,
        "todo.md",
        &[],
        &[
            Step::Until("the session", running),
            Step::Pause(300),
            Step::Keys("iyes \x1b"),
            Step::Pause(200),
            Step::Keys(":detach\r"),
        ],
    );
    assert!(
        out.contains("detached; kern attach notes comes back"),
        "{out}"
    );
    let listed = world.sessions();
    assert!(
        listed.starts_with("notes") && listed.contains(project.to_str().unwrap()),
        "{listed}"
    );
    assert_eq!(
        world.eval("notes", "return require('@kern').view():buffer():text()"),
        "yes buy milk"
    );

    world.terminal(
        &project,
        "attach",
        &[],
        &[Step::Pause(500), Step::Keys(":q!\r")],
    );
    world.wait_for("the session to quit", none_running);
}

#[test]
fn kern_anywhere_in_a_project_joins_its_session_and_opens_the_file() {
    let Some(world) = World::new("join") else {
        return;
    };
    let project = world.project("app", &[("a.txt", "first"), ("src/b.txt", "second")]);
    world.terminal(
        &project,
        "a.txt",
        &[],
        &[
            Step::Until("the session", running),
            Step::Pause(300),
            Step::Keys(":detach\r"),
        ],
    );
    world.terminal(
        &project.join("src"),
        "b.txt",
        &[],
        &[Step::Pause(500), Step::Keys(":detach\r")],
    );
    let listed = world.sessions();
    assert_eq!(
        listed.lines().count(),
        1,
        "one session for the project: {listed}"
    );
    assert_eq!(
        world.eval("app", "return require('@kern').view():buffer():text()"),
        "second"
    );
    world.eval("app", "require('@kern').quit()");
}

#[test]
fn the_terminal_follows_when_its_session_switches_to_another_project() {
    let Some(world) = World::new("switch") else {
        return;
    };
    let first = world.project("first", &[("a.txt", "in the first")]);
    let second = world.project("second", &[("b.txt", "in the second")]);
    let target = second.join("b.txt");
    let script = format!(
        "require('@kern').session.switch({{ path = {:?} }})",
        target.to_str().unwrap()
    );
    // The switch is asked for from outside, the way an agent or plugin would.
    let world_ref = &world;
    let out = std::thread::scope(|scope| {
        let terminal = scope.spawn(|| {
            world_ref.terminal(
                &first,
                "a.txt",
                &[],
                &[
                    Step::Until("the session", running),
                    // Long enough for the switch below and the new session.
                    Step::Pause(2500),
                    Step::Keys(":detach\r"),
                ],
            )
        });
        world_ref.wait_for("the first session", running);
        std::thread::sleep(Duration::from_millis(500));
        world_ref.eval("first", &script);
        terminal.join().unwrap()
    });
    assert!(
        out.contains("in the second"),
        "the second project was drawn"
    );
    assert!(
        out.contains("detached; kern attach second comes back"),
        "{out}"
    );
    let listed = world.sessions();
    assert!(
        listed.contains("first") && listed.contains("second"),
        "{listed}"
    );
}

#[test]
fn kern_ssh_brings_the_config_and_shows_the_remote_session() {
    let Some(world) = World::new("ssh") else {
        return;
    };
    let project = world.project("remote", &[("main.rs", "fn main() {}")]);
    std::fs::write(
        world.root.join("config/kern/init.luau"),
        "require('@kern').option.set('flash-duration', 123)\nrequire('@kern').option.set('terminal-shell', 'cat')\n",
    )
    .unwrap();
    // Stands in for ssh: drops -T and the host, and runs the command here
    // with a home of its own, as another machine would have. Like a login
    // shell that isn't POSIX sh (fish, nushell), it takes only plain words,
    // so anything in sh's own syntax fails.
    let fake_ssh = world.root.join("fake-ssh");
    std::fs::write(
        &fake_ssh,
        format!(
            "#!/bin/sh\nshift 2\n[ \"$*\" = 'sh -s' ] || {{ echo \"not plain words: $*\" >&2; exit 9; }}\nHOME={} exec sh -s\n",
            world.root.join("remote-home").display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(
        &fake_ssh,
        std::os::unix::fs::PermissionsExt::from_mode(0o755),
    )
    .unwrap();
    let file = project.join("main.rs");
    let out = world.terminal(
        &project,
        &format!("ssh somehost --terminal {}", file.display()),
        &[
            ("GREED_SSH", fake_ssh.to_str().unwrap()),
            ("GREED_REMOTE", KERN),
        ],
        &[
            Step::Until("the remote session", running),
            Step::Pause(400),
            // Typing goes to the terminal it opened; ctrl-\ leaves it.
            Step::Keys("\x1c:detach\r"),
        ],
    );
    assert!(
        out.contains("detached; kern ssh somehost comes back"),
        "{out}"
    );
    // Highlighting puts colour codes between "fn" and "main".
    assert!(out.contains("main"), "the remote file was drawn");
    assert_eq!(
        world.eval(
            "remote",
            "return require('@kern').option.get('flash-duration')"
        ),
        "123",
        "the session runs with the config that came along"
    );
    assert!(world.root.join("remote-home/.cache/kern").is_dir());
    assert_eq!(
        world.eval("remote", HAS_TERMINAL),
        "true",
        "--terminal opened one"
    );
    world.eval("remote", "require('@kern').quit()");
}

#[test]
fn without_sessions_the_editor_runs_in_the_terminal_and_quits_with_it() {
    let Some(world) = World::new("local") else {
        return;
    };
    let project = world.project("here", &[("a.txt", "local text")]);
    let out = world.terminal(
        &project,
        "a.txt",
        &[("GREED_NO_SESSION", "1")],
        &[Step::Pause(800), Step::Keys(":q\r")],
    );
    assert!(out.contains("local text"), "drawn in this terminal");
    assert!(none_running(&world), "no session was started");
}

#[test]
fn kern_in_one_of_its_own_terminals_opens_the_file_there_instead_of_nesting() {
    let Some(world) = World::new("inside") else {
        return;
    };
    let project = world.project("app", &[("a.txt", "first"), ("b.txt", "second")]);
    world.terminal(
        &project,
        "a.txt",
        &[],
        &[
            Step::Until("the session", running),
            Step::Pause(300),
            Step::Keys(":detach\r"),
        ],
    );
    // As a program in one of the session's terminals runs it.
    let inside = |args: &[&str]| {
        let mut command = std::process::Command::new(KERN);
        command
            .args(args)
            .current_dir(&project)
            .stdin(std::process::Stdio::null());
        world.env(&mut command);
        command.env("GREED_TERMINAL", "app").output().unwrap()
    };
    let opened = inside(&["b.txt"]);
    assert!(opened.status.success(), "{opened:?}");
    assert_eq!(
        world.eval("app", "return require('@kern').view():buffer():text()"),
        "second"
    );
    let bare = inside(&[]);
    assert!(!bare.status.success());
    assert!(
        String::from_utf8_lossy(&bare.stderr).contains("in Kern already"),
        "{bare:?}"
    );
    let attach = inside(&["attach", "app"]);
    assert!(!attach.status.success(), "no session inside itself");
    world.eval("app", "require('@kern').quit()");
}

/// Luau that says whether the session has a terminal open.
const HAS_TERMINAL: &str = "for _, b in require('@kern').buffers() do if b:kind() == 'terminal' then return true end end return false";

#[test]
fn kern_with_terminal_opens_one_in_the_session_it_shows() {
    let Some(world) = World::new("withterm") else {
        return;
    };
    std::fs::write(
        world.root.join("config/kern/init.luau"),
        "require('@kern').option.set('terminal-shell', 'cat')\n",
    )
    .unwrap();
    let project = world.project("app", &[("a.txt", "first")]);
    world.terminal(
        &project,
        "--terminal a.txt",
        &[],
        &[
            Step::Until("the session", running),
            Step::Pause(400),
            Step::Keys("\x1c:detach\r"),
        ],
    );
    assert_eq!(world.eval("app", HAS_TERMINAL), "true");
    world.eval("app", "require('@kern').quit()");
}
