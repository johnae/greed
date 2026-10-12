//! The terminal client and sessions end to end: the real `greed` binary in a
//! pseudo-terminal (through `script`), driven with keys, the way a person
//! uses it. Each test gets its own sessions, config and cache folders, so it
//! never sees your editors or another test's.

mod common;

use std::time::Duration;

use common::{GREED, Step, World, none_running, running};

#[test]
fn greed_starts_a_session_that_outlives_detaching_and_quits_from_a_new_terminal() {
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
            Step::Shows("buy milk"),
            Step::Keys("iyes \x1b"),
            Step::Pause(200),
            Step::Keys(":detach\r"),
        ],
    );
    assert!(
        out.contains("detached; greed attach notes comes back"),
        "{out}"
    );
    let listed = world.sessions();
    assert!(
        listed.starts_with("notes") && listed.contains(project.to_str().unwrap()),
        "{listed}"
    );
    assert_eq!(
        world.eval("notes", "return require('@greed').view():buffer():text()"),
        "yes buy milk"
    );

    world.terminal(
        &project,
        "attach",
        &[],
        &[Step::Shows("yes buy milk"), Step::Keys(":q!\r")],
    );
    world.wait_for("the session to quit", none_running);
}

#[test]
fn greed_anywhere_in_a_project_joins_its_session_and_opens_the_file() {
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
            Step::Shows("first"),
            Step::Keys(":detach\r"),
        ],
    );
    world.terminal(
        &project.join("src"),
        "b.txt",
        &[],
        &[Step::Shows("second"), Step::Keys(":detach\r")],
    );
    let listed = world.sessions();
    assert_eq!(
        listed.lines().count(),
        1,
        "one session for the project: {listed}"
    );
    assert_eq!(
        world.eval("app", "return require('@greed').view():buffer():text()"),
        "second"
    );
    world.eval("app", "require('@greed').quit()");
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
        "require('@greed').session.switch({{ path = {:?} }})",
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
        out.contains("detached; greed attach second comes back"),
        "{out}"
    );
    let listed = world.sessions();
    assert!(
        listed.contains("first") && listed.contains("second"),
        "{listed}"
    );
}

/// Stands in for ssh: drops -T and the host, and runs the command here
/// with a home of its own, as another machine would have. Like a login
/// shell that isn't POSIX sh (fish, nushell), it takes only plain words, so
/// anything in sh's own syntax fails.
fn fake_ssh(world: &World) -> std::path::PathBuf {
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
    fake_ssh
}

#[test]
fn greed_ssh_puts_greed_on_a_machine_without_it_once() {
    let Some(world) = World::new("ssh-install") else {
        return;
    };
    let project = world.project("remote", &[("main.rs", "fn main() {}")]);
    let fake_ssh = fake_ssh(&world);
    // A greed of another version on the other machine's PATH, which doesn't
    // do, in place of any this machine has.
    let other = world.root.join("other-greed");
    std::fs::create_dir_all(&other).unwrap();
    std::fs::write(other.join("greed"), "#!/bin/sh\necho greed 0.0.1\n").unwrap();
    std::fs::set_permissions(
        other.join("greed"),
        std::os::unix::fs::PermissionsExt::from_mode(0o755),
    )
    .unwrap();
    let path = format!(
        "{}:{}",
        other.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let env = [("GREED_SSH", fake_ssh.to_str().unwrap()), ("PATH", &path)];
    let steps = [
        Step::Until("the remote session", running),
        Step::Shows("main"),
        Step::Keys(":detach\r"),
    ];
    let command = format!("ssh somehost {}", project.join("main.rs").display());
    let first = world.terminal(&project, &command, &env, &steps);
    assert!(first.contains("putting this greed (build "), "{first}");
    let server = world.root.join("remote-home/.local/share/greed/server");
    let installed: Vec<_> = std::fs::read_dir(&server).unwrap().flatten().collect();
    assert_eq!(installed.len(), 1, "one build");
    assert!(installed[0].path().join("greed").is_file());
    // In a folder of its build, which `greed --version` says.
    let folder = installed[0].file_name().to_string_lossy().into_owned();
    let version = std::process::Command::new(GREED)
        .arg("--version")
        .output()
        .unwrap();
    let version = String::from_utf8_lossy(&version.stdout).into_owned();
    let build = folder.rsplit('-').next().unwrap();
    assert!(
        version.contains(&format!("(build {build})")),
        "{folder}: {version}"
    );
    let again = world.terminal(&project, &command, &env, &steps);
    assert!(!again.contains("putting"), "there already: {again}");
    assert!(
        again.contains("detached; greed ssh somehost comes back"),
        "{again}"
    );
    world.eval("remote", "require('@greed').quit()");
}

#[test]
fn the_terminal_follows_when_its_session_switches_to_another_machine() {
    let Some(world) = World::new("switch-host") else {
        return;
    };
    let here = world.project("here", &[("a.txt", "on this machine")]);
    let there = world.project("remote", &[("b.txt", "on the other machine")]);
    let fake_ssh = fake_ssh(&world);
    let script = format!(
        "require('@greed').session.switch({{ host = 'somehost', path = {:?} }})",
        there.join("b.txt").to_str().unwrap()
    );
    let world_ref = &world;
    let out = std::thread::scope(|scope| {
        let terminal = scope.spawn(|| {
            world_ref.terminal(
                &here,
                "a.txt",
                &[
                    ("GREED_SSH", fake_ssh.to_str().unwrap()),
                    ("GREED_REMOTE", GREED),
                ],
                &[
                    Step::Until("the session", running),
                    Step::Pause(3000),
                    Step::Keys(":detach\r"),
                ],
            )
        });
        world_ref.wait_for("the first session", running);
        std::thread::sleep(Duration::from_millis(500));
        world_ref.eval("here", &script);
        terminal.join().unwrap()
    });
    assert!(out.contains("on the other machine"), "{out}");
    assert!(
        out.contains("detached; greed ssh somehost comes back"),
        "{out}"
    );
    world.eval("remote", "require('@greed').quit()");
}

#[test]
fn greed_ssh_comes_back_to_the_same_session_when_the_connection_drops() {
    let Some(world) = World::new("ssh-drop") else {
        return;
    };
    let project = world.project("remote", &[("main.rs", "fn main() {}")]);
    // Like `fake_ssh`, but the first connection dies a few seconds in, as
    // when the network goes; the ones after stay. It takes the options ssh
    // gets when trying again.
    let dying = world.root.join("dying-ssh");
    std::fs::write(
        &dying,
        format!(
            "#!/bin/sh\nwhile [ \"$1\" = -o ]; do shift 2; done\nshift 2\n[ \"$*\" = 'sh -s' ] || exit 9\nmarker={}\nif [ ! -e \"$marker\" ]; then touch \"$marker\"; (sleep 3; kill -9 $$) & fi\nHOME={} exec sh -s\n",
            world.root.join("died-once").display(),
            world.root.join("remote-home").display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&dying, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    let command = format!("ssh somehost {}", project.join("main.rs").display());
    let out = world.terminal(
        &project,
        &command,
        &[
            ("GREED_SSH", dying.to_str().unwrap()),
            // So the first connection is the session's, not the config's copy.
            ("GREED_SSH_CONFIG", "0"),
            ("GREED_REMOTE", GREED),
        ],
        &[
            Step::Until("the remote session", running),
            Step::Shows("main"),
            Step::Shows("lost the connection to somehost"),
            Step::Shows("back on somehost after losing the connection"),
            Step::Keys(":detach\r"),
        ],
    );
    assert!(
        out.contains("detached; greed ssh somehost comes back"),
        "{out}"
    );
    assert_eq!(world.sessions().lines().count(), 1, "the same session");
    world.eval("remote", "require('@greed').quit()");
}

/// Whether a client shows the session `name`.
fn shows(world: &World, name: &str) -> bool {
    world.eval(
        name,
        "return tostring(require('@greed').session.attached())",
    ) == "true"
}

/// Asks the session `here` to send its client to the project `remote` on
/// another machine, the way a plugin would; true once asked.
fn go_to_the_other_machine(world: &World) -> bool {
    let file = world.root.join("remote/b.txt");
    let script = format!(
        "require('@greed').session.switch({{ host = 'somehost', path = {:?} }})",
        file.to_str().unwrap()
    );
    world.eval("here", &script);
    true
}

#[test]
fn the_terminal_goes_back_and_home_across_machines() {
    let Some(world) = World::new("switch-back") else {
        return;
    };
    let here = world.project("here", &[("a.txt", "on this machine")]);
    world.project("remote", &[("b.txt", "on the other machine")]);
    let fake_ssh = fake_ssh(&world);
    let out = world.terminal(
        &here,
        "a.txt",
        &[
            ("GREED_SSH", fake_ssh.to_str().unwrap()),
            ("GREED_REMOTE", GREED),
        ],
        &[
            Step::Until("the session", running),
            Step::Shows("on this machine"),
            Step::Keys(" B"),
            Step::Shows("nowhere to go back to"),
            Step::Until("the switch", go_to_the_other_machine),
            Step::Shows("on the other machine"),
            Step::Until("the other machine", |w| {
                shows(w, "remote") && !shows(w, "here")
            }),
            Step::Keys(" B"),
            Step::Until("back here", |w| shows(w, "here") && !shows(w, "remote")),
            Step::Keys(" B"),
            Step::Until("back there", |w| shows(w, "remote") && !shows(w, "here")),
            Step::Keys(":session-home\r"),
            Step::Until("home", |w| shows(w, "here") && !shows(w, "remote")),
            Step::Keys(":detach\r"),
        ],
    );
    assert!(
        out.contains("detached; greed attach here comes back"),
        "{out}"
    );
    world.eval("remote", "require('@greed').quit()");
    world.eval("here", "require('@greed').quit()");
}

/// A fake ssh agent at `path`, answering every request with no keys and
/// leaving `agent-asked` in the world's folder once asked.
fn fake_agent(world: &World, path: &std::path::Path) {
    use std::io::{Read, Write};
    let listener = std::os::unix::net::UnixListener::bind(path).unwrap();
    let asked = world.root.join("agent-asked");
    std::thread::spawn(move || {
        for mut stream in listener.incoming().flatten() {
            let mut length = [0; 4];
            let mut body = [0; 1];
            if stream.read_exact(&mut length).is_ok() && stream.read_exact(&mut body).is_ok() {
                std::fs::write(&asked, "").unwrap();
                let _ = stream.write_all(&[0, 0, 0, 5, 12, 0, 0, 0, 0]);
            }
        }
    });
}

#[test]
fn greed_ssh_brings_your_ssh_agent_to_the_session_on_the_other_machine() {
    let Some(world) = World::new("ssh-agent") else {
        return;
    };
    let project = world.project("remote", &[("main.rs", "fn main() {}")]);
    // An ssh whose config forwards the agent to every host, which notes
    // how it's run.
    let fake_ssh = world.root.join("fake-ssh");
    std::fs::write(
        &fake_ssh,
        format!(
            "#!/bin/sh\necho \"$*\" >> {root}/ssh-args\n\
             [ \"$1\" = -G ] && {{ echo 'forwardagent yes'; exit 0; }}\n\
             [ \"$1\" = -o ] && shift 2\nshift 2\n\
             [ \"$*\" = 'sh -s' ] || {{ echo \"not plain words: $*\" >&2; exit 9; }}\n\
             HOME={root}/remote-home exec sh -s\n",
            root = world.root.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(
        &fake_ssh,
        std::os::unix::fs::PermissionsExt::from_mode(0o755),
    )
    .unwrap();
    let agent = world.root.join("agent.sock");
    fake_agent(&world, &agent);
    let world_ref = &world;
    let socket = std::thread::scope(|scope| {
        let terminal = scope.spawn(|| {
            world_ref.terminal(
                &project,
                &format!("ssh somehost {}", project.join("main.rs").display()),
                &[
                    ("GREED_SSH", fake_ssh.to_str().unwrap()),
                    ("GREED_REMOTE", GREED),
                    ("SSH_AUTH_SOCK", agent.to_str().unwrap()),
                ],
                &[
                    Step::Until("the remote session", running),
                    Step::Shows("main"),
                    // Only once a program there had its answer: the client
                    // has to stay attached until then. (The agent is asked
                    // already as greed ssh checks that it answers.)
                    Step::Until("the agent's answer", |w| w.root.join("answered").exists()),
                    Step::Keys(":detach\r"),
                ],
            )
        });
        world_ref.wait_for("the remote session", running);
        // A shell on that machine outside the session finds its socket.
        let mut socket = String::new();
        common::wait_until("the agent socket", || {
            let out = world_ref.greed(&["ctl", "agent-socket", "remote"]);
            socket = String::from_utf8(out.stdout).unwrap().trim().to_owned();
            out.status.success()
        });
        // A program there reaches the agent here through the client.
        common::wait_until("the agent's answer", || {
            greed_core::ssh_agent::ask(std::path::Path::new(&socket), &[11])
                .is_ok_and(|answer| answer == [12, 0, 0, 0, 0])
        });
        std::fs::write(world_ref.root.join("answered"), "").unwrap();
        let out = terminal.join().unwrap();
        assert!(
            out.contains("detached; greed ssh somehost comes back"),
            "{out}"
        );
        socket
    });
    assert_eq!(
        std::path::PathBuf::from(socket),
        world.root.join("run/greed/remote/agent.sock")
    );
    let args = std::fs::read_to_string(world.root.join("ssh-args")).unwrap();
    assert!(
        args.contains("-o ForwardAgent=no -T somehost sh -s"),
        "ssh's own forwarding is off: {args}"
    );
    world.eval("remote", "require('@greed').quit()");
}

#[test]
fn greed_ssh_brings_the_config_and_shows_the_remote_session() {
    let Some(world) = World::new("ssh") else {
        return;
    };
    let project = world.project("remote", &[("main.rs", "fn main() {}")]);
    std::fs::write(
        world.root.join("config/greed/init.luau"),
        "require('@greed').option.set('flash-duration', 123)\nrequire('@greed').option.set('terminal-shell', 'cat')\n",
    )
    .unwrap();
    let fake_ssh = fake_ssh(&world);
    let file = project.join("main.rs");
    let out = world.terminal(
        &project,
        &format!("ssh somehost --terminal {}", file.display()),
        &[
            ("GREED_SSH", fake_ssh.to_str().unwrap()),
            ("GREED_REMOTE", GREED),
        ],
        &[
            Step::Until("the remote session", running),
            Step::Shows("main"),
            // Typing goes to the terminal it opened; ctrl-\ leaves it.
            Step::Keys("\x1c:detach\r"),
        ],
    );
    assert!(
        out.contains("detached; greed ssh somehost comes back"),
        "{out}"
    );
    // Highlighting puts colour codes between "fn" and "main".
    assert!(out.contains("main"), "the remote file was drawn");
    assert_eq!(
        world.eval(
            "remote",
            "return require('@greed').option.get('flash-duration')"
        ),
        "123",
        "the session runs with the config that came along"
    );
    assert!(world.root.join("remote-home/.cache/greed").is_dir());
    assert_eq!(
        world.eval("remote", HAS_TERMINAL),
        "true",
        "--terminal opened one"
    );
    world.eval("remote", "require('@greed').quit()");
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
        &[Step::Shows("local text"), Step::Keys(":q\r")],
    );
    assert!(out.contains("local text"), "drawn in this terminal");
    assert!(none_running(&world), "no session was started");
}

#[test]
fn greed_in_one_of_its_own_terminals_opens_the_file_there_instead_of_nesting() {
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
            Step::Shows("first"),
            Step::Keys(":detach\r"),
        ],
    );
    // As a program in one of the session's terminals runs it.
    let inside = |args: &[&str]| {
        let mut command = std::process::Command::new(GREED);
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
        world.eval("app", "return require('@greed').view():buffer():text()"),
        "second"
    );
    let bare = inside(&[]);
    assert!(!bare.status.success());
    assert!(
        String::from_utf8_lossy(&bare.stderr).contains("in Greed already"),
        "{bare:?}"
    );
    let attach = inside(&["attach", "app"]);
    assert!(!attach.status.success(), "no session inside itself");
    world.eval("app", "require('@greed').quit()");
}

/// Luau that says whether the session has a terminal open.
const HAS_TERMINAL: &str = "for _, b in require('@greed').buffers() do if b:kind() == 'terminal' then return true end end return false";

#[test]
fn greed_with_terminal_opens_one_in_the_session_it_shows() {
    let Some(world) = World::new("withterm") else {
        return;
    };
    std::fs::write(
        world.root.join("config/greed/init.luau"),
        "require('@greed').option.set('terminal-shell', 'cat')\n",
    )
    .unwrap();
    let project = world.project("app", &[("a.txt", "first")]);
    world.terminal(
        &project,
        "--terminal a.txt",
        &[],
        &[
            Step::Until("the session", running),
            Step::Shows("a.txt"),
            Step::Keys("\x1c:detach\r"),
        ],
    );
    assert_eq!(world.eval("app", HAS_TERMINAL), "true");
    world.eval("app", "require('@greed').quit()");
}
