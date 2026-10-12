//! A test world: folders standing in for a user's, so tests that run the
//! real greed binary never see your editors, config or cache, or each other.

#![allow(dead_code, reason = "each test file uses a different part")]

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub const GREED: &str = env!("CARGO_BIN_EXE_greed");

/// Folders standing in for a user's: where sessions live, the config, the
/// cache, and Claude Code's.
pub struct World {
    pub root: PathBuf,
}

impl World {
    pub fn new(label: &str) -> Option<World> {
        if Command::new("script").arg("--version").output().is_err() {
            eprintln!("script isn't installed; skipping (it comes with the devenv shell)");
            return None;
        }
        // Sessions keep their sockets in it, whose paths have to stay short.
        let root = greed_core::control::socket_temp_dir()
            .join(format!("greed-world-{label}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for dir in ["run", "config/greed", "cache", "claude", "remote-home"] {
            std::fs::create_dir_all(root.join(dir)).unwrap();
        }
        // A config of their own, so the first-run setup page stays away.
        std::fs::write(
            root.join("config/greed/init.luau"),
            "-- A test world's config.\n",
        )
        .unwrap();
        Some(World { root })
    }

    /// A project folder (with a `.git`) holding `files`.
    pub fn project(&self, name: &str, files: &[(&str, &str)]) -> PathBuf {
        let dir = self.root.join(name);
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        for (path, text) in files {
            let path = dir.join(path);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, text).unwrap();
        }
        dir
    }

    pub fn env(&self, command: &mut Command) {
        command
            .env("XDG_RUNTIME_DIR", self.root.join("run"))
            .env("XDG_CONFIG_HOME", self.root.join("config"))
            .env("XDG_CACHE_HOME", self.root.join("cache"))
            .env("XDG_DATA_HOME", self.root.join("data"))
            .env("CLAUDE_CONFIG_DIR", self.root.join("claude"))
            .env_remove("GREED_SESSION")
            .env_remove("GREED_TERMINAL")
            .env_remove("GREED_CONFIG_DIR")
            .env_remove("GREED_NO_SESSION")
            // Your ssh agent stays out of tests.
            .env_remove("SSH_AUTH_SOCK");
    }

    /// `greed ARGS` without a terminal, e.g. `ls` or `ctl`.
    pub fn greed(&self, args: &[&str]) -> Output {
        let mut command = Command::new(GREED);
        command.args(args).stdin(Stdio::null());
        self.env(&mut command);
        command.output().unwrap()
    }

    pub fn sessions(&self) -> String {
        String::from_utf8(self.greed(&["ls"]).stdout).unwrap()
    }

    /// What `eval` of `code` returns in session `name`.
    pub fn eval(&self, name: &str, code: &str) -> String {
        let mut command = Command::new(GREED);
        command.args(["ctl", "eval", &format!("code={code}")]);
        self.env(&mut command);
        command.env("GREED_SESSION", name);
        let out = command.output().unwrap();
        String::from_utf8(out.stdout).unwrap().trim().to_owned()
    }

    /// Waits until `check` holds, for things that happen in the background.
    pub fn wait_for(&self, what: &str, check: impl Fn(&World) -> bool) {
        wait_until(what, || check(self));
    }

    /// Runs `greed ARGS` in a pseudo-terminal in `dir` with `env` added, does
    /// `steps` while it runs, and returns what it printed once it exits.
    pub fn terminal(&self, dir: &Path, args: &str, env: &[(&str, &str)], steps: &[Step]) -> String {
        let line = format!("stty cols 90 rows 20; {GREED} {args}");
        let mut command = Command::new("script");
        // util-linux's script takes the command as an option, the BSD one
        // macOS has as the words after the file.
        if cfg!(target_os = "macos") {
            command.args(["-q", "-F", "/dev/null", "sh", "-c", &line]);
        } else {
            command.args(["-qfec", &line, "/dev/null"]);
        }
        command
            .current_dir(dir)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        self.env(&mut command);
        // `script` doesn't answer the query for kitty keys, which would cost
        // its timeout at every start.
        command.env("GREED_KEYS", "legacy");
        command.envs(env.iter().copied());
        let mut child = command.spawn().unwrap();
        let mut keys = child.stdin.take().unwrap();
        // Read as it comes, so a step can wait for something to be drawn.
        let printed = Arc::new(Mutex::new(Vec::new()));
        let reader = {
            let printed = printed.clone();
            let mut stdout = child.stdout.take().unwrap();
            std::thread::spawn(move || {
                let mut buf = [0; 4096];
                while let Ok(n @ 1..) = stdout.read(&mut buf) {
                    printed.lock().unwrap().extend_from_slice(&buf[..n]);
                }
            })
        };
        let shown = || String::from_utf8_lossy(&printed.lock().unwrap()).into_owned();
        for step in steps {
            match step {
                Step::Keys(text) => {
                    // It ended early: what it printed says why, which the
                    // test's own assertions show.
                    if keys
                        .write_all(text.as_bytes())
                        .and_then(|()| keys.flush())
                        .is_err()
                    {
                        break;
                    }
                }
                Step::Until(what, check) => self.wait_for(what, check),
                Step::Shows(text) => {
                    self.wait_for(&format!("{text:?} to be drawn"), |_| shown().contains(text));
                }
                Step::Pause(ms) => std::thread::sleep(Duration::from_millis(*ms)),
            }
        }
        let deadline = Instant::now() + Duration::from_secs(60);
        while child.try_wait().unwrap().is_none() {
            if Instant::now() > deadline {
                let _ = child.kill();
                panic!("greed {args} didn't exit");
            }
            std::thread::sleep(Duration::from_millis(30));
        }
        drop(keys);
        child.wait_with_output().unwrap();
        reader.join().unwrap();
        shown()
    }
}

impl Drop for World {
    fn drop(&mut self) {
        // Quit anything a failed test left running, then clean up.
        for name in self
            .sessions()
            .lines()
            .filter_map(|l| l.split_whitespace().next())
        {
            self.eval(name, "require('@greed').quit()");
        }
        // Any that didn't quit, or weren't listening yet.
        kill_sessions(&self.root.join("run/greed"), |_| true);
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

pub enum Step {
    Keys(&'static str),
    /// Wait until the check holds.
    Until(&'static str, fn(&World) -> bool),
    /// Wait until the text has been drawn.
    Shows(&'static str),
    Pause(u64),
}

/// Kills the sessions in the sessions folder `dir` whose names pass
/// `which`, by the process id each writes next to its socket. A session
/// started in the background (by plain `greed` or a bridge) is out of reach
/// of a test's child handles, so tests call this when they end, failed or
/// not.
pub fn kill_sessions(dir: &Path, which: impl Fn(&str) -> bool) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for path in entries.flatten().map(|entry| entry.path()) {
        let name = path.file_stem().unwrap_or_default().to_string_lossy();
        if path.extension().is_none_or(|ext| ext != "json") || !which(&name) {
            continue;
        }
        let pid = std::fs::read_to_string(&path)
            .ok()
            .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
            .and_then(|info| info["pid"].as_u64());
        if let Some(pid) = pid {
            let _ = Command::new("kill")
                .args(["-KILL", &pid.to_string()])
                .stderr(Stdio::null())
                .status();
        }
    }
}

/// Waits until `done` holds, failing with `what` after a minute: things
/// that take a moment can take many on a loaded machine.
pub fn wait_until(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(60);
    while !done() {
        assert!(
            Instant::now() < deadline,
            "gave up after a minute waiting for {what}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

pub fn running(world: &World) -> bool {
    !world.sessions().trim().is_empty()
}

pub fn none_running(world: &World) -> bool {
    world.sessions().trim().is_empty()
}

/// Folders standing in for another machine's, beside the world's: its
/// sessions, data (so its own machine id) and cache.
const THERE: [(&str, &str); 3] = [
    ("XDG_RUNTIME_DIR", "there/run"),
    ("XDG_DATA_HOME", "there/data"),
    ("XDG_CACHE_HOME", "there/cache"),
];

/// The world's own folders of those, as `World::env` sets them.
const HERE: [(&str, &str); 3] = [
    ("XDG_RUNTIME_DIR", "run"),
    ("XDG_DATA_HOME", "data"),
    ("XDG_CACHE_HOME", "cache"),
];

/// The world ("here") and another machine beside it ("there"), with an ssh
/// between them (`ssh`) that runs the line it's given with the folders of
/// the host it names. The other machine's sessions go when this does,
/// failed or not.
pub struct TwoMachines<'a> {
    pub world: &'a World,
    pub ssh: PathBuf,
}

impl<'a> TwoMachines<'a> {
    pub fn new(world: &'a World) -> Self {
        for (_, dir) in THERE {
            std::fs::create_dir_all(world.root.join(dir)).unwrap();
        }
        let set = |folders: [(&str, &str); 3]| -> String {
            let pairs: Vec<String> = folders
                .iter()
                .map(|(var, dir)| format!("{var}={}", world.root.join(dir).display()))
                .collect();
            pairs.join(" ") + " "
        };
        let (here, there) = (set(HERE), set(THERE));
        // `ssh -G` (your ssh config, as `greed ssh` reads it) says nothing.
        let script = format!(
            "#!/bin/sh\n\
             [ \"$1\" = -G ] && exit 0\n\
             while [ $# -gt 1 ] && [ \"$2\" != sh ]; do shift; done\n\
             case \"$1\" in there) exec env {there}sh -s;; here) exec env {here}sh -s;; esac\n\
             echo \"no host $1\" >&2; exit 255\n"
        );
        let ssh = world.root.join("two-machines-ssh");
        std::fs::write(&ssh, script).unwrap();
        std::fs::set_permissions(&ssh, std::os::unix::fs::PermissionsExt::from_mode(0o755))
            .unwrap();
        TwoMachines { world, ssh }
    }

    /// `command` as it runs on one machine, with this ssh and greed.
    pub fn env(&self, command: &mut Command, there: bool) {
        self.world.env(command);
        command
            .env("GREED_SSH", &self.ssh)
            .env("GREED_REMOTE", GREED);
        if there {
            for (var, dir) in THERE {
                command.env(var, self.world.root.join(dir));
            }
        }
    }

    /// A headless session for a new project `name` on one machine.
    pub fn serve(&self, name: &str, there: bool) -> std::process::Child {
        let mut command = Command::new(GREED);
        command
            .arg("serve")
            .arg(self.world.project(name, &[("a.txt", "one\n")]))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        self.env(&mut command, there);
        command.spawn().unwrap()
    }

    /// What `eval` of `code` returns in session `name` on one machine.
    pub fn eval(&self, name: &str, there: bool, code: &str) -> String {
        let mut command = Command::new(GREED);
        command.args(["ctl", "eval", &format!("code={code}")]);
        self.env(&mut command, there);
        command.env("GREED_SESSION", name);
        let out = command.output().unwrap();
        String::from_utf8(out.stdout).unwrap().trim().to_owned()
    }
}

impl Drop for TwoMachines<'_> {
    fn drop(&mut self) {
        kill_sessions(&self.world.root.join("there/run/greed"), |_| true);
    }
}
