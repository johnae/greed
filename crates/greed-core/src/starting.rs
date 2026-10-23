//! Starting a session in the background: `greed serve` for it, its output
//! going to a log, waited for until it listens. `greed` does it for the
//! session it shows, and plugins for a service's session
//! (`greed.session.start`).

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use crate::control;

/// Where a session `greed ssh` started listens for its programs' ssh agent
/// requests, set for `greed serve`.
pub const AGENT_ENV: &str = "GREED_AGENT_SOCK";

/// How long starting waits for the server to listen. It listens before it
/// loads anything, so this is only long for a loaded machine.
const STARTUP: Duration = Duration::from_secs(30);

/// Where a background session's output goes.
pub fn log_path(name: &str) -> PathBuf {
    control::sessions_dir().join(format!("{name}.log"))
}

/// `--fresh` and `--restore` as this greed was given them (or, for
/// `--restore`, an upgrade asked), for a greed it starts a session with.
pub fn restore_flags() -> impl Iterator<Item = &'static str> {
    [
        control::fresh().then_some("--fresh"),
        control::restore().then_some("--restore"),
    ]
    .into_iter()
    .flatten()
}

/// Starts `greed serve` for the session called `name` in the background, its
/// output going to a log, and waits until it listens. A service's session
/// gets neither `--fresh` nor `--restore`: those were asked of the session
/// you see, not of the services it uses.
pub fn spawn_server(name: &str, file: Option<&Path>, remote: bool) -> std::io::Result<Child> {
    control::make_sessions_dir(&control::sessions_dir())?;
    let log_path = log_path(name);
    let log = std::fs::File::create(&log_path)?;
    let mut command = Command::new(std::env::current_exe()?);
    command.args(["serve", "--session", name]);
    if control::service_of(name).is_none() {
        command.args(restore_flags());
    }
    if let Some(file) = file {
        command.arg(file);
    }
    // Commands over ssh may come without it; the session and the programs
    // in its terminals should have what a login has.
    if let Some(dir) = control::runtime_dir() {
        command.env("XDG_RUNTIME_DIR", dir);
    }
    if let Some(path) = path_with_greed() {
        command.env("PATH", path);
    }
    // Started from a terminal of a session, it would think it's in that one.
    command
        .env_remove("GREED_SESSION")
        .env_remove("GREED_TERMINAL");
    if remote {
        command.env(control::REMOTE_ENV, "1");
        // Its programs reach your ssh agent through the session, at a
        // path that stays the same however often you come back.
        let agent = crate::ssh_agent::socket_of(name);
        command.env(AGENT_ENV, &agent).env("SSH_AUTH_SOCK", &agent);
    } else {
        // Started from a terminal of a session that has one: that's its.
        command.env_remove(AGENT_ENV);
    }
    std::os::unix::process::CommandExt::process_group(&mut command, 0);
    let mut child = command
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log)
        .spawn()?;
    let (socket, _) = control::session_files(name);
    let deadline = Instant::now() + STARTUP;
    while std::os::unix::net::UnixStream::connect(&socket).is_err() {
        if child.try_wait()?.is_some() || Instant::now() > deadline {
            // One that is only slow would otherwise start later with no
            // one attached, and run until someone finds it.
            let _ = child.kill();
            let _ = child.wait();
            let log = std::fs::read_to_string(&log_path).unwrap_or_default();
            return Err(std::io::Error::other(format!(
                "the editor didn't start: {}",
                log.trim()
            )));
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    Ok(child)
}

/// `PATH` with this greed's folder added at the end, when no greed is on it,
/// as on a machine `greed ssh` put greed on: so `greed FILE` and `greed ctl`
/// work in the session's terminals. A greed you installed stays first.
fn path_with_greed() -> Option<std::ffi::OsString> {
    if crate::lsp::which("greed").is_some() {
        return None;
    }
    let exe = std::env::current_exe().ok()?;
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|path| std::env::split_paths(&path).collect())
        .unwrap_or_default();
    dirs.push(exe.parent()?.to_path_buf());
    std::env::join_paths(dirs).ok()
}
