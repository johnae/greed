//! `kern bridge`, the end of `kern ssh` that runs next to the session,
//! driven over pipes the way ssh drives it.

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

use serde_json::{Value, json};

const KERN: &str = env!("CARGO_BIN_EXE_greed");

/// `kern` with folders of its own for sessions, config and cache, so these
/// tests never see your editors or write to your folders.
fn kern() -> Command {
    kern_in("shared")
}

/// The folders standing in for runtime, config and cache for `world`.
/// Tests that write config get a world of their own: tests run in
/// parallel, and a session starting while a plugin is half-written fails.
fn world(name: &str) -> std::path::PathBuf {
    std::env::temp_dir().join(format!("kern-bridge-{name}-{}", std::process::id()))
}

/// `kern` in `world`.
fn kern_in(name: &str) -> Command {
    let root = world(name);
    for dir in ["run", "config", "cache", "claude"] {
        std::fs::create_dir_all(root.join(dir)).unwrap();
    }
    let mut command = Command::new(KERN);
    command
        .env("XDG_RUNTIME_DIR", root.join("run"))
        .env("XDG_CONFIG_HOME", root.join("config"))
        .env("XDG_CACHE_HOME", root.join("cache"))
        .env("CLAUDE_CONFIG_DIR", root.join("claude"))
        .env_remove("KERN_SESSION")
        .env_remove("KERN_CONFIG_DIR")
        .env_remove("KERN_NO_SESSION");
    command
}

/// A `kern bridge` driven over pipes. Dropping it stops the bridge, so a
/// failing test can't leave one behind holding the test run open.
struct Bridge {
    child: Child,
    input: Option<ChildStdin>,
    output: BufReader<ChildStdout>,
}

impl Bridge {
    fn start(args: &[&str]) -> Bridge {
        let mut command = kern();
        command.arg("bridge").args(args);
        Bridge::spawn(command)
    }

    fn spawn(mut command: Command) -> Bridge {
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let input = child.stdin.take();
        let output = BufReader::new(child.stdout.take().unwrap());
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
        let mut line = String::new();
        self.output.read_line(&mut line).unwrap();
        serde_json::from_str(&line).unwrap()
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
        frame["Frame"]["rows"]
            .as_array()
            .unwrap()
            .iter()
            .map(|row| {
                row["spans"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|span| span["text"].as_str().unwrap())
                    .collect()
            })
            .collect()
    }

    fn quit(mut self) {
        self.send(&json!("Quit"));
        // The bridge ends once its input does, the way it does when ssh
        // disconnects.
        self.input = None;
        let _ = self.child.wait();
    }
}

impl Drop for Bridge {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn temp_file(label: &str, text: &str) -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!("kern-bridge-{label}-{}.txt", std::process::id()));
    std::fs::write(&path, text).unwrap();
    path
}

#[test]
fn the_bridge_starts_a_session_when_none_is_running_and_attaches() {
    let file = temp_file("start", "hello from the other machine");
    let name = format!("bridge-start-{}", std::process::id());
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
    let _server = Server::start(&["--session", &name, file.to_str().unwrap()]);
    let mut bridge = Bridge::start(&["--session", &name]);
    // The session may still be starting; the bridge waits for it.
    let rows = bridge.attach();
    assert!(rows[0].contains("already open"), "{rows:?}");
    bridge.quit();
    std::fs::remove_file(file).unwrap();
}

#[test]
fn sessions_are_named_after_their_project_and_found_by_it() {
    let project = std::env::temp_dir().join(format!("kern-proj-{}", std::process::id()));
    std::fs::create_dir_all(project.join(".git")).unwrap();
    std::fs::create_dir_all(project.join("src")).unwrap();
    std::fs::write(project.join("README.md"), "top").unwrap();
    std::fs::write(project.join("src/lib.rs"), "deep inside").unwrap();
    let root = project.to_str().unwrap();
    let _server = Server::start(&[root]);
    let name = format!("kern-proj-{}", std::process::id());
    // The session takes a moment to start listening.
    let mut listed = String::new();
    for _ in 0..500 {
        let out = kern().arg("ls").output().unwrap();
        listed = String::from_utf8(out.stdout).unwrap();
        if listed
            .lines()
            .any(|line| line.starts_with(&name) && line.contains(root))
        {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert!(listed.contains(root), "{listed}");

    // A path deep inside the project finds the same session and opens there.
    let mut bridge = Bridge::start(&[project.join("src/lib.rs").to_str().unwrap()]);
    let rows = bridge.attach();
    assert!(rows[0].contains("deep inside"), "{rows:?}");
    bridge.quit();
    std::fs::remove_dir_all(&project).unwrap();
}

/// A `kern serve` started by a test, stopped when the test ends even if it
/// fails, so a session left behind can't hold the test run open.
struct Server(Child);

impl Server {
    fn start(args: &[&str]) -> Server {
        Server(
            kern()
                .arg("serve")
                .args(args)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
        )
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
fn a_session_loads_the_config_kern_config_dir_points_at() {
    let config = std::env::temp_dir().join(format!("kern-config-from-afar-{}", std::process::id()));
    std::fs::create_dir_all(config.join("plugins/hello")).unwrap();
    std::fs::write(
        config.join("init.luau"),
        "require('@kern').echo('config from afar')\n",
    )
    .unwrap();
    std::fs::write(
        config.join("plugins/hello/plugin.toml"),
        "name = \"hello\"\n",
    )
    .unwrap();
    std::fs::write(
        config.join("plugins/hello/init.luau"),
        "require('@kern').command({ name = 'hello-from-afar', run = function() end })\n",
    )
    .unwrap();
    let file = temp_file("config", "text");
    let name = format!("bridge-config-{}", std::process::id());
    let mut command = kern();
    command
        .args(["bridge", "--session", &name, file.to_str().unwrap()])
        .env("KERN_CONFIG_DIR", &config);
    let mut bridge = Bridge::spawn(command);
    let rows = bridge.attach();
    let status = rows.last().unwrap();
    assert!(status.contains("config from afar"), "{rows:?}");
    // The plugin in the config's plugins folder loaded too.
    let listed = kern()
        .args([
            "ctl",
            "eval",
            "code=return table.concat(require('@kern').plugin.list(), ',')",
        ])
        .env("KERN_SESSION", &name)
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
        format!("require('@kern').command({{ name = '{command}', run = function() end }})\n"),
    )
    .unwrap();
}

#[test]
fn the_config_kern_ssh_brings_comes_first_and_the_machines_own_wins() {
    let root = world("layers");
    let own = root.join("config/kern");
    let brought = std::env::temp_dir().join(format!("kern-brought-{}", std::process::id()));
    for dir in [&own, &brought] {
        std::fs::create_dir_all(dir).unwrap();
    }
    std::fs::write(
        brought.join("init.luau"),
        "local o = require('@kern').option\no.set('indent', 'AAAA')\no.set('jump-label-alphabet', 'xy')\n",
    )
    .unwrap();
    std::fs::write(
        own.join("init.luau"),
        "require('@kern').option.set('indent', 'BB')\n",
    )
    .unwrap();
    plugin(&brought, "only-brought", "from-brought");
    plugin(&brought, "both", "both-brought");
    plugin(&own, "both", "both-own");

    let file = temp_file("layers", "text");
    let name = format!("bridge-layers-{}", std::process::id());
    let mut command = kern_in("layers");
    command
        .args(["bridge", "--session", &name, file.to_str().unwrap()])
        .env("KERN_SSH_CONFIG_DIR", &brought);
    let mut bridge = Bridge::spawn(command);
    bridge.attach();
    let eval = |code: &str| {
        let out = kern_in("layers")
            .args(["ctl", "eval", &format!("code={code}")])
            .env("KERN_SESSION", &name)
            .output()
            .unwrap();
        String::from_utf8(out.stdout).unwrap().trim().to_owned()
    };
    assert_eq!(
        eval("return require('@kern').option.get('indent')"),
        "BB",
        "the machine's own config runs last"
    );
    assert_eq!(
        eval("return require('@kern').option.get('jump-label-alphabet')"),
        "xy",
        "the brought one still runs"
    );
    let commands = eval(
        "local n = {} for _, c in require('@kern').commands() do table.insert(n, c.name) end return table.concat(n, ',')",
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
        eval("return require('@kern').fs.dirs().config"),
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
    let project = std::env::temp_dir().join(format!("kern-trusted-{}", std::process::id()));
    std::fs::create_dir_all(project.join(".git")).unwrap();
    std::fs::create_dir_all(project.join(".kern")).unwrap();
    std::fs::write(
        project.join(".kern/init.luau"),
        "require('@kern').option.set('indent', 'FROM-PROJECT')\n",
    )
    .unwrap();
    std::fs::write(project.join("a.txt"), "text").unwrap();
    std::fs::create_dir_all(root.join("cache/kern")).unwrap();
    std::fs::write(
        root.join("cache/kern/trusted-projects"),
        format!("{}\n", project.display()),
    )
    .unwrap();
    let name = format!("bridge-trusted-{}", std::process::id());
    let mut command = kern_in("trusted");
    command.args([
        "bridge",
        "--session",
        &name,
        project.join("a.txt").to_str().unwrap(),
    ]);
    let mut bridge = Bridge::spawn(command);
    bridge.attach();
    let out = kern_in("trusted")
        .args([
            "ctl",
            "eval",
            "code=return require('@kern').option.get('indent')",
        ])
        .env("KERN_SESSION", &name)
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
    let server = Server::start(&["--session", &name, file.to_str().unwrap()]);
    let mut bridge = Bridge::start(&["--session", &name]);
    bridge.attach();
    drop(server);
    // Its input stays open, as when ssh is still connected.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while bridge.child.try_wait().unwrap().is_none() {
        assert!(
            std::time::Instant::now() < deadline,
            "the bridge still runs after its session ended"
        );
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    std::fs::remove_file(file).unwrap();
}
