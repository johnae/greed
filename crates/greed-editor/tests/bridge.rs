//! `greed bridge`, the end of `greed ssh` that runs next to the session,
//! driven over pipes the way ssh drives it.

mod common;

use std::io::{BufRead, BufReader, Read, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use common::{GREED, kill_sessions, wait_until};
use serde_json::{Value, json};

/// `greed` with folders of its own for sessions, config and cache, so these
/// tests never see your editors or write to your folders.
fn greed() -> Command {
    greed_in("shared")
}

/// The folders standing in for runtime, config and cache for `world`.
/// Tests that write config get a world of their own: tests run in
/// parallel, and a session starting while a plugin is half-written fails.
fn world(name: &str) -> std::path::PathBuf {
    // Sessions keep their sockets in it, whose paths have to stay short.
    greed_core::control::socket_temp_dir()
        .join(format!("greed-bridge-{name}-{}", std::process::id()))
}

/// `greed` in `world`.
fn greed_in(name: &str) -> Command {
    let root = world(name);
    for dir in ["run", "config", "cache", "claude"] {
        std::fs::create_dir_all(root.join(dir)).unwrap();
    }
    let mut command = Command::new(GREED);
    command
        .env("XDG_RUNTIME_DIR", root.join("run"))
        .env("XDG_CONFIG_HOME", root.join("config"))
        .env("XDG_CACHE_HOME", root.join("cache"))
        .env("CLAUDE_CONFIG_DIR", root.join("claude"))
        .env_remove("GREED_SESSION")
        .env_remove("GREED_CONFIG_DIR")
        .env_remove("GREED_NO_SESSION");
    command
}

/// The sessions folder of `world`.
fn sessions(world_name: &str) -> std::path::PathBuf {
    world(world_name).join("run/greed")
}

/// A session called `name` in `world` that a test starts through a bridge.
/// The bridge starts it in the background, where stopping the bridge can't
/// reach it, so dropping this kills it, even when the test fails.
struct Session {
    world: &'static str,
    name: String,
}

impl Session {
    fn named(world: &'static str, name: &str) -> Session {
        Session {
            world,
            name: name.to_owned(),
        }
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        kill_sessions(&sessions(self.world), |name| name == self.name);
    }
}

/// A `greed bridge` driven over pipes. Dropping it stops the bridge, so a
/// failing test can't leave one behind holding the test run open.
struct Bridge {
    child: Child,
    input: Option<ChildStdin>,
    /// Its output, line by line, read as it comes so the bridge never waits
    /// on a full pipe.
    output: mpsc::Receiver<String>,
}

impl Bridge {
    fn start(args: &[&str]) -> Bridge {
        let mut command = greed();
        command.arg("bridge").args(args);
        Bridge::spawn(command)
    }

    fn spawn(mut command: Command) -> Bridge {
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let input = child.stdin.take();
        let stdout = BufReader::new(child.stdout.take().unwrap());
        let (lines, output) = mpsc::channel();
        std::thread::spawn(move || {
            for line in stdout.lines().map_while(Result::ok) {
                if lines.send(line).is_err() {
                    return;
                }
            }
        });
        Bridge {
            child,
            input,
            output,
        }
    }

    fn send(&mut self, message: &Value) {
        let input = self.input.as_mut().unwrap();
        writeln!(input, "{message}").unwrap();
        input.flush().unwrap();
    }

    fn next(&mut self) -> Value {
        let line = match self.output.recv_timeout(Duration::from_secs(60)) {
            Ok(line) => line,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                panic!("the bridge said nothing for a minute")
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                let status = self.child.wait();
                let mut said = String::new();
                if let Some(mut stderr) = self.child.stderr.take() {
                    let _ = stderr.read_to_string(&mut said);
                }
                panic!("the bridge ended ({status:?}): {said}")
            }
        };
        serde_json::from_str(&line).unwrap()
    }

    /// Waits for the bridge to end, as it does once its session is gone.
    fn wait_for_exit(&mut self) {
        wait_until("the bridge to end", || {
            self.child.try_wait().unwrap().is_some()
        });
    }

    /// Attaches, says how big the screen is, and returns the first frame's
    /// text, row by row.
    fn attach(&mut self) -> Vec<String> {
        self.send(&json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "attach",
            "params": { "protocol": greed_core::control::PROTOCOL },
        }));
        let hello = self.next();
        assert_eq!(
            hello["result"]["protocol"],
            greed_core::control::PROTOCOL,
            "{hello}"
        );
        self.send(&json!({ "Resize": { "width": 40, "height": 5 } }));
        let frame = self.next();
        let frame: greed_core::render::Frame =
            serde_json::from_value(frame["Frame"].clone()).unwrap();
        greed_core::render::grid::text_rows(&frame)
    }

    fn quit(mut self) {
        self.send(&json!("Quit"));
        // The bridge ends once its input does, the way it does when ssh
        // disconnects.
        self.input = None;
        self.wait_for_exit();
    }
}

impl Drop for Bridge {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn temp_file(label: &str, text: &str) -> std::path::PathBuf {
    let path =
        std::env::temp_dir().join(format!("greed-bridge-{label}-{}.txt", std::process::id()));
    std::fs::write(&path, text).unwrap();
    path
}

#[test]
fn the_bridge_starts_a_session_when_none_is_running_and_attaches() {
    let file = temp_file("start", "hello from the other machine");
    let name = format!("bridge-start-{}", std::process::id());
    let _session = Session::named("shared", &name);
    let mut bridge = Bridge::start(&["--session", &name, file.to_str().unwrap()]);
    let rows = bridge.attach();
    assert!(rows[0].contains("hello from the other machine"), "{rows:?}");
    bridge.quit();
    std::fs::remove_file(file).unwrap();
}

#[test]
fn the_bridge_attaches_to_a_running_session() {
    let file = temp_file("running", "already open");
    let name = format!("bridge-running-{}", std::process::id());
    let _server = Server::start(&name, &["--session", &name, file.to_str().unwrap()]);
    let mut bridge = Bridge::start(&["--session", &name]);
    let rows = bridge.attach();
    assert!(rows[0].contains("already open"), "{rows:?}");
    bridge.quit();
    std::fs::remove_file(file).unwrap();
}

#[test]
fn sessions_are_named_after_their_project_and_found_by_it() {
    let project = std::env::temp_dir().join(format!("greed-proj-{}", std::process::id()));
    std::fs::create_dir_all(project.join(".git")).unwrap();
    std::fs::create_dir_all(project.join("src")).unwrap();
    std::fs::write(project.join("README.md"), "top").unwrap();
    std::fs::write(project.join("src/lib.rs"), "deep inside").unwrap();
    let root = project.to_str().unwrap();
    let name = format!("greed-proj-{}", std::process::id());
    let _server = Server::start(&name, &[root]);
    let out = greed().arg("ls").output().unwrap();
    let listed = String::from_utf8(out.stdout).unwrap();
    assert!(
        listed
            .lines()
            .any(|line| line.starts_with(&name) && line.contains(root)),
        "{listed}"
    );

    // A path deep inside the project finds the same session and opens there.
    let mut bridge = Bridge::start(&[project.join("src/lib.rs").to_str().unwrap()]);
    let rows = bridge.attach();
    assert!(rows[0].contains("deep inside"), "{rows:?}");
    bridge.quit();
    std::fs::remove_dir_all(&project).unwrap();
}

/// A `greed serve` started by a test, stopped when the test ends even if it
/// fails, so a session left behind can't hold the test run open.
struct Server(Child);

impl Server {
    /// Starts the session called `name` and waits until it listens: a
    /// bridge started before that would start a session of its own.
    fn start(name: &str, args: &[&str]) -> Server {
        let mut server = Server(
            greed()
                .arg("serve")
                .args(args)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
        );
        let socket = sessions("shared").join(format!("{name}.sock"));
        wait_until(&format!("session {name} to listen"), || {
            if let Some(status) = server.0.try_wait().unwrap() {
                panic!("session {name} ended before it listened: {status}");
            }
            std::os::unix::net::UnixStream::connect(&socket).is_ok()
        });
        server
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
fn a_session_loads_the_config_greed_config_dir_points_at() {
    let config =
        std::env::temp_dir().join(format!("greed-config-from-afar-{}", std::process::id()));
    std::fs::create_dir_all(config.join("plugins/hello")).unwrap();
    std::fs::write(
        config.join("init.luau"),
        "require('@greed').echo('config from afar')\n",
    )
    .unwrap();
    std::fs::write(
        config.join("plugins/hello/plugin.toml"),
        "name = \"hello\"\n",
    )
    .unwrap();
    std::fs::write(
        config.join("plugins/hello/init.luau"),
        "require('@greed').command({ name = 'hello-from-afar', run = function() end })\n",
    )
    .unwrap();
    let file = temp_file("config", "text");
    let name = format!("bridge-config-{}", std::process::id());
    let _session = Session::named("shared", &name);
    let mut command = greed();
    command
        .args(["bridge", "--session", &name, file.to_str().unwrap()])
        .env("GREED_CONFIG_DIR", &config);
    let mut bridge = Bridge::spawn(command);
    let rows = bridge.attach();
    let status = rows.last().unwrap();
    assert!(status.contains("config from afar"), "{rows:?}");
    // The plugin in the config's plugins folder loaded too.
    let listed = greed()
        .args([
            "ctl",
            "eval",
            "code=return table.concat(require('@greed').plugin.list(), ',')",
        ])
        .env("GREED_SESSION", &name)
        .output()
        .unwrap();
    let listed = String::from_utf8(listed.stdout).unwrap();
    assert!(listed.contains("hello"), "{listed}");
    bridge.quit();
    std::fs::remove_dir_all(&config).unwrap();
    std::fs::remove_file(file).unwrap();
}

/// Writes a plugin called `name` into `dir/plugins` that adds `command`.
fn plugin(dir: &std::path::Path, name: &str, command: &str) {
    let path = dir.join("plugins").join(name);
    std::fs::create_dir_all(&path).unwrap();
    std::fs::write(path.join("plugin.toml"), format!("name = \"{name}\"\n")).unwrap();
    std::fs::write(
        path.join("init.luau"),
        format!("require('@greed').command({{ name = '{command}', run = function() end }})\n"),
    )
    .unwrap();
}

#[test]
fn the_config_greed_ssh_brings_comes_first_and_the_machines_own_wins() {
    let root = world("layers");
    let own = root.join("config/greed");
    let brought = std::env::temp_dir().join(format!("greed-brought-{}", std::process::id()));
    for dir in [&own, &brought] {
        std::fs::create_dir_all(dir).unwrap();
    }
    std::fs::write(
        brought.join("init.luau"),
        "local o = require('@greed').option\no.set('indent', 'AAAA')\no.set('jump-label-alphabet', 'xy')\n",
    )
    .unwrap();
    std::fs::write(
        own.join("init.luau"),
        "require('@greed').option.set('indent', 'BB')\n",
    )
    .unwrap();
    plugin(&brought, "only-brought", "from-brought");
    plugin(&brought, "both", "both-brought");
    plugin(&own, "both", "both-own");

    let file = temp_file("layers", "text");
    let name = format!("bridge-layers-{}", std::process::id());
    let _session = Session::named("layers", &name);
    let mut command = greed_in("layers");
    command
        .args(["bridge", "--session", &name, file.to_str().unwrap()])
        .env("GREED_SSH_CONFIG_DIR", &brought);
    let mut bridge = Bridge::spawn(command);
    bridge.attach();
    let eval = |code: &str| {
        let out = greed_in("layers")
            .args(["ctl", "eval", &format!("code={code}")])
            .env("GREED_SESSION", &name)
            .output()
            .unwrap();
        String::from_utf8(out.stdout).unwrap().trim().to_owned()
    };
    assert_eq!(
        eval("return require('@greed').option.get('indent')"),
        "BB",
        "the machine's own config runs last"
    );
    assert_eq!(
        eval("return require('@greed').option.get('jump-label-alphabet')"),
        "xy",
        "the brought one still runs"
    );
    let commands = eval(
        "local n = {} for _, c in require('@greed').commands() do table.insert(n, c.name) end return table.concat(n, ',')",
    );
    assert!(
        commands.contains("from-brought"),
        "brought plugins load: {commands}"
    );
    assert!(
        commands.contains("both-own") && !commands.contains("both-brought"),
        "the own plugin of the same name wins: {commands}"
    );
    assert_eq!(
        eval("return require('@greed').fs.dirs().config"),
        own.to_str().unwrap(),
        "agents install into the machine's own config"
    );
    bridge.quit();
    std::fs::remove_dir_all(&brought).unwrap();
    std::fs::remove_dir_all(&own).unwrap();
    std::fs::remove_file(file).unwrap();
}

#[test]
fn a_trusted_projects_own_config_runs_when_its_session_starts() {
    let root = world("trusted");
    let project = std::env::temp_dir().join(format!("greed-trusted-{}", std::process::id()));
    std::fs::create_dir_all(project.join(".git")).unwrap();
    // Trusted as the session sees it: resolved, which on macOS isn't
    // /var/... but /private/var/....
    let project = project.canonicalize().unwrap();
    std::fs::create_dir_all(project.join(".greed")).unwrap();
    std::fs::write(
        project.join(".greed/init.luau"),
        "require('@greed').option.set('indent', 'FROM-PROJECT')\n",
    )
    .unwrap();
    std::fs::write(project.join("a.txt"), "text").unwrap();
    std::fs::create_dir_all(root.join("cache/greed")).unwrap();
    std::fs::write(
        root.join("cache/greed/trusted-projects"),
        format!("{}\n", project.display()),
    )
    .unwrap();
    let name = format!("bridge-trusted-{}", std::process::id());
    let _session = Session::named("trusted", &name);
    let mut command = greed_in("trusted");
    command.args([
        "bridge",
        "--session",
        &name,
        project.join("a.txt").to_str().unwrap(),
    ]);
    let mut bridge = Bridge::spawn(command);
    bridge.attach();
    let out = greed_in("trusted")
        .args([
            "ctl",
            "eval",
            "code=return require('@greed').option.get('indent')",
        ])
        .env("GREED_SESSION", &name)
        .output()
        .unwrap();
    assert_eq!(
        String::from_utf8(out.stdout).unwrap().trim(),
        "FROM-PROJECT"
    );
    bridge.quit();
    std::fs::remove_dir_all(&project).unwrap();
}

#[test]
fn the_bridge_ends_when_its_session_does_even_with_its_input_open() {
    let file = temp_file("dies", "short-lived");
    let name = format!("bridge-dies-{}", std::process::id());
    let server = Server::start(&name, &["--session", &name, file.to_str().unwrap()]);
    let mut bridge = Bridge::start(&["--session", &name]);
    bridge.attach();
    drop(server);
    // Its input stays open, as when ssh is still connected.
    bridge.wait_for_exit();
    std::fs::remove_file(file).unwrap();
}

#[test]
fn a_session_the_bridge_starts_with_fresh_knows_it() {
    let fresh = |args: &[&str], label: &str| {
        let file = temp_file(label, "text");
        let name = format!("bridge-{label}-{}", std::process::id());
        let _session = Session::named("shared", &name);
        let mut all = args.to_vec();
        all.extend(["--session", &name, file.to_str().unwrap()]);
        let mut bridge = Bridge::start(&all);
        bridge.attach();
        let out = greed()
            .args([
                "ctl",
                "eval",
                "code=return tostring(require('@greed').session.fresh())",
            ])
            .env("GREED_SESSION", &name)
            .output()
            .unwrap();
        bridge.quit();
        std::fs::remove_file(file).unwrap();
        String::from_utf8(out.stdout).unwrap().trim().to_owned()
    };
    assert_eq!(fresh(&["--fresh"], "fresh"), "true");
    assert_eq!(fresh(&[], "restored"), "false");
}

#[test]
fn a_session_started_where_greed_isnt_on_path_puts_its_own_there() {
    let which = |path: &std::path::Path, label: &str| {
        let file = temp_file(label, "text");
        let name = format!("bridge-{label}-{}", std::process::id());
        let _session = Session::named("shared", &name);
        let mut command = greed();
        command
            .env("PATH", path)
            .args(["bridge", "--session", &name, file.to_str().unwrap()]);
        let mut bridge = Bridge::spawn(command);
        bridge.attach();
        let out = greed()
            .args([
                "ctl",
                "eval",
                "code=return tostring(require('@greed').which('greed'))",
            ])
            .env("GREED_SESSION", &name)
            .output()
            .unwrap();
        bridge.quit();
        std::fs::remove_file(file).unwrap();
        String::from_utf8(out.stdout).unwrap().trim().to_owned()
    };
    let empty = world("shared").join("path-without-greed");
    std::fs::create_dir_all(&empty).unwrap();
    let ours = std::fs::canonicalize(GREED).unwrap();
    assert_eq!(which(&empty, "no-greed"), ours.to_string_lossy());
    // One you installed stays the one programs run.
    let installed = world("shared").join("path-with-greed");
    std::fs::create_dir_all(&installed).unwrap();
    let theirs = installed.join("greed");
    std::fs::write(&theirs, "#!/bin/sh\n").unwrap();
    std::fs::set_permissions(&theirs, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    assert_eq!(which(&installed, "own-greed"), theirs.to_string_lossy());
}
