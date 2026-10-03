//! A test world: folders standing in for a user's, so tests that run the
//! real kern binary never see your editors, config or cache, or each other.

#![allow(dead_code, reason = "each test file uses a different part")]

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

pub const KERN: &str = env!("CARGO_BIN_EXE_greed");

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
        let root = std::env::temp_dir().join(format!("kern-world-{label}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for dir in ["run", "config/kern", "cache", "claude", "remote-home"] {
            std::fs::create_dir_all(root.join(dir)).unwrap();
        }
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
            .env("CLAUDE_CONFIG_DIR", self.root.join("claude"))
            .env_remove("GREED_SESSION")
            .env_remove("GREED_TERMINAL")
            .env_remove("GREED_CONFIG_DIR")
            .env_remove("GREED_NO_SESSION");
    }

    /// `kern ARGS` without a terminal, e.g. `ls` or `ctl`.
    pub fn kern(&self, args: &[&str]) -> Output {
        let mut command = Command::new(KERN);
        command.args(args).stdin(Stdio::null());
        self.env(&mut command);
        command.output().unwrap()
    }

    pub fn sessions(&self) -> String {
        String::from_utf8(self.kern(&["ls"]).stdout).unwrap()
    }

    /// What `eval` of `code` returns in session `name`.
    pub fn eval(&self, name: &str, code: &str) -> String {
        let mut command = Command::new(KERN);
        command.args(["ctl", "eval", &format!("code={code}")]);
        self.env(&mut command);
        command.env("GREED_SESSION", name);
        let out = command.output().unwrap();
        String::from_utf8(out.stdout).unwrap().trim().to_owned()
    }

    /// Waits until `check` holds, for things that happen in the background.
    pub fn wait_for(&self, what: &str, check: impl Fn(&World) -> bool) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !check(self) {
            assert!(Instant::now() < deadline, "gave up waiting for {what}");
            std::thread::sleep(Duration::from_millis(30));
        }
    }

    /// Runs `kern ARGS` in a pseudo-terminal in `dir` with `env` added, does
    /// `steps` while it runs, and returns what it printed once it exits.
    pub fn terminal(&self, dir: &Path, args: &str, env: &[(&str, &str)], steps: &[Step]) -> String {
        let line = format!("stty cols 90 rows 20; {KERN} {args}");
        let mut command = Command::new("script");
        command
            .args(["-qfec", &line, "/dev/null"])
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
        for step in steps {
            match step {
                Step::Keys(text) => {
                    keys.write_all(text.as_bytes()).unwrap();
                    keys.flush().unwrap();
                }
                Step::Until(what, check) => self.wait_for(what, check),
                Step::Pause(ms) => std::thread::sleep(Duration::from_millis(*ms)),
            }
        }
        let deadline = Instant::now() + Duration::from_secs(10);
        while child.try_wait().unwrap().is_none() {
            if Instant::now() > deadline {
                let _ = child.kill();
                panic!("kern {args} didn't exit");
            }
            std::thread::sleep(Duration::from_millis(30));
        }
        drop(keys);
        let out = child.wait_with_output().unwrap();
        String::from_utf8_lossy(&out.stdout).into_owned()
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
            self.eval(name, "require('@kern').quit()");
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

pub enum Step {
    Keys(&'static str),
    /// Wait until the check holds.
    Until(&'static str, fn(&World) -> bool),
    Pause(u64),
}

pub fn running(world: &World) -> bool {
    !world.sessions().trim().is_empty()
}

pub fn none_running(world: &World) -> bool {
    world.sessions().trim().is_empty()
}
