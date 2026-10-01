//! `kern bridge`, the end of `kern ssh` that runs next to the session,
//! driven over pipes the way ssh drives it.

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

use serde_json::{Value, json};

const KERN: &str = env!("CARGO_BIN_EXE_kern");

/// A `kern bridge` driven over pipes. Dropping it stops the bridge, so a
/// failing test can't leave one behind holding the test run open.
struct Bridge {
    child: Child,
    input: Option<ChildStdin>,
    output: BufReader<ChildStdout>,
}

impl Bridge {
    fn start(args: &[&str]) -> Bridge {
        let mut command = Command::new(KERN);
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
            "params": { "protocol": kern_core::control::PROTOCOL },
        }));
        let hello = self.next();
        assert_eq!(
            hello["result"]["protocol"],
            kern_core::control::PROTOCOL,
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
    let _server = Server::start(&[project.to_str().unwrap()]);
    let name = format!("kern-proj-{}", std::process::id());
    // The session takes a moment to start listening.
    let mut listed = String::new();
    for _ in 0..250 {
        let out = Command::new(KERN).arg("ls").output().unwrap();
        listed = String::from_utf8(out.stdout).unwrap();
        if listed.lines().any(|line| line.starts_with(&name)) {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert!(listed.contains(project.to_str().unwrap()), "{listed}");

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
            Command::new(KERN)
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
    let mut command = Command::new(KERN);
    command
        .args(["bridge", "--session", &name, file.to_str().unwrap()])
        .env("KERN_CONFIG_DIR", &config);
    let mut bridge = Bridge::spawn(command);
    let rows = bridge.attach();
    let status = rows.last().unwrap();
    assert!(status.contains("config from afar"), "{rows:?}");
    // The plugin in the config's plugins folder loaded too.
    let listed = Command::new(KERN)
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
