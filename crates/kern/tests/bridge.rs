//! `kern bridge`, the end of `kern ssh` that runs next to the session,
//! driven over pipes the way ssh drives it.

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

use serde_json::{Value, json};

const KERN: &str = env!("CARGO_BIN_EXE_kern");

struct Bridge {
    child: Child,
    input: ChildStdin,
    output: BufReader<ChildStdout>,
}

impl Bridge {
    fn start(args: &[&str]) -> Bridge {
        let mut child = Command::new(KERN)
            .arg("bridge")
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let input = child.stdin.take().unwrap();
        let output = BufReader::new(child.stdout.take().unwrap());
        Bridge {
            child,
            input,
            output,
        }
    }

    fn send(&mut self, message: &Value) {
        writeln!(self.input, "{message}").unwrap();
        self.input.flush().unwrap();
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
            "params": { "protocol": 1 },
        }));
        let hello = self.next();
        assert_eq!(hello["result"]["protocol"], 1, "{hello}");
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
        let Bridge {
            mut child, input, ..
        } = self;
        drop(input);
        let _ = child.wait();
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
    let mut server = Command::new(KERN)
        .args(["serve", "--session", &name, file.to_str().unwrap()])
        .stdin(Stdio::null())
        .spawn()
        .unwrap();
    let mut bridge = Bridge::start(&["--session", &name]);
    // The session may still be starting; the bridge waits for it.
    let rows = bridge.attach();
    assert!(rows[0].contains("already open"), "{rows:?}");
    bridge.quit();
    let _ = server.wait();
    std::fs::remove_file(file).unwrap();
}
