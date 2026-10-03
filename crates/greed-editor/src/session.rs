//! Running the editor as a session that outlives its terminal, like zellij
//! or tmux: `greed serve` runs it headless, `greed attach` shows it, plain
//! `greed` starts one in the background and attaches, and `greed ssh` shows a
//! session on another machine through `greed bridge` running there.

use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::{Duration, Instant};

use greed_core::SwitchTo;
use greed_core::control::{self, Attachment};
use greed_core::project;
use greed_core::server::{self, Input, Output};
use serde_json::{Value, json};

use crate::{ctl, host, read, tui};

type Error = Box<dyn std::error::Error>;

/// How long `greed` waits for the server it started to listen.
const STARTUP: Duration = Duration::from_secs(5);

/// `greed serve`: runs the editor with no terminal until something quits it.
pub fn serve(name: &str, path: Option<&Path>) -> Result<(), Error> {
    let target = absolute(path)?;
    let root = project::root_of(&target);
    // The session works from its project's root, so paths in it are short.
    std::env::set_current_dir(&root)?;
    let file = target.is_file().then_some(target);
    let text = read(file.as_deref())?;
    let session = control::listen(name, Some(&root))?;
    let requests = session.sender().clone();
    let conn = server::spawn_with_session(move || host(&text, file, Some(requests)), Some(session));
    // Nothing is drawn until a client attaches and says how big it is.
    conn.server.join().map_err(|_| "the editor crashed")??;
    // `greed` sends a background session's output here; after a clean exit
    // there is nothing in it to explain.
    let _ = std::fs::remove_file(log_path(name));
    Ok(())
}

/// `path` made absolute, or the current directory.
fn absolute(path: Option<&Path>) -> Result<PathBuf, Error> {
    let cwd = std::env::current_dir()?;
    Ok(match path {
        Some(path) => cwd.join(path),
        None => cwd,
    })
}

/// Which session `path` (or the current directory) belongs to: `name` if
/// given, else the one running for its project, else a new name for that
/// project. Returns the name, whether it's running, and the path.
fn find_session(name: Option<&str>, path: Option<&Path>) -> Result<(String, bool, PathBuf), Error> {
    let target = absolute(path)?;
    let running = control::sessions()?;
    if let Some(name) = name {
        let is_running = running.iter().any(|s| s.name == name);
        return Ok((name.to_owned(), is_running, target));
    }
    let root = project::root_of(&target);
    if let Some(session) = running.iter().find(|s| s.root.as_ref() == Some(&root)) {
        return Ok((session.name.clone(), true, target));
    }
    let names: Vec<String> = running.into_iter().map(|s| s.name).collect();
    Ok((project::session_name(&root, &names), false, target))
}

/// Where a background session's output goes.
fn log_path(name: &str) -> PathBuf {
    control::sessions_dir().join(format!("{name}.log"))
}

/// `greed attach`: shows the session called `name` (or the only one running)
/// in this terminal until it quits or lets this terminal go.
pub fn attach(name: Option<&str>) -> Result<(), Error> {
    let name = match name
        .map(str::to_owned)
        .or_else(|| std::env::var("GREED_SESSION").ok())
    {
        Some(name) => name,
        None => match ctl::live_sessions()?.as_slice() {
            [only] => only.clone(),
            [] => return Err("no editor is running".into()),
            several => {
                return Err(
                    format!("several are running ({}); name one", several.join(", ")).into(),
                );
            }
        },
    };
    if inside().as_deref() == Some(name.as_str()) {
        return Err(format!(
            "this terminal is in session {name}; attaching to it here would show it inside itself"
        )
        .into());
    }
    follow(name, None, false)
}

/// The session whose terminal this runs in (`$GREED_TERMINAL`), if it's
/// still running.
pub fn inside() -> Option<String> {
    let name = std::env::var("GREED_TERMINAL")
        .ok()
        .filter(|name| !name.is_empty())?;
    ctl::live_sessions().ok()?.contains(&name).then_some(name)
}

/// `greed [FILE]` in a terminal of session `name`: opens the file in that
/// session instead of starting another editor inside it.
pub fn open_inside(name: &str, path: Option<&Path>) -> Result<(), Error> {
    let Some(path) = path else {
        return Err(format!(
            "this terminal is in Greed already (session {name}); greed FILE opens a file there"
        )
        .into());
    };
    let path = absolute(Some(path))?;
    if path.is_dir() {
        return Err(format!(
            "this terminal is in Greed already (session {name}); :session {} goes to that folder's project",
            path.display()
        )
        .into());
    }
    let result = ctl::connect_to(Some(name))?
        .call(
            "tools/call",
            &json!({ "name": "open", "arguments": { "path": path } }),
        )?
        .map_err(std::io::Error::other)?;
    if result["isError"].as_bool() == Some(true) {
        return Err(format!("couldn't open {}: {}", path.display(), result["content"]).into());
    }
    Ok(())
}

/// Shows the session called `name` in this terminal, asking it to open
/// `open`, and follows the client to any session it switches to, until a
/// session quits or lets the terminal go.
fn follow(mut name: String, mut open: Option<PathBuf>, mut terminal: bool) -> Result<(), Error> {
    // A terminal is asked for once, not again after a switch.
    loop {
        let Attachment { reader, writer, .. } =
            ctl::connect_to(Some(&name))?.attach_opening(open.as_deref(), terminal)?;
        terminal = false;
        match show(reader, writer)? {
            Output::Switch(to) => (name, open) = resolve(&to)?,
            Output::Detached => {
                println!("detached; greed attach {name} comes back");
                return Ok(());
            }
            Output::Exit
            | Output::Frame(_)
            | Output::Delta(_)
            | Output::Image(_)
            | Output::Clipboard(_) => return Ok(()),
        }
    }
}

/// The session `to` points at, started if it isn't running, and what to
/// ask it to open.
fn resolve(to: &SwitchTo) -> Result<(String, Option<PathBuf>), Error> {
    if let Some(name) = &to.session {
        if !ctl::live_sessions()?.contains(name) {
            spawn_server(name, to.path.as_deref().map(Path::new))?;
        }
        return Ok((name.clone(), None));
    }
    let (name, running, target) = find_session(None, to.path.as_deref().map(Path::new))?;
    if running {
        Ok((name, Some(target)))
    } else {
        spawn_server(&name, Some(&target))?;
        Ok((name, None))
    }
}

/// Shows an attached session in this terminal: input goes to `writer` and
/// frames come from `reader`, one JSON message per line. Returns how it
/// ended.
fn show(
    reader: impl BufRead + Send + 'static,
    mut writer: impl Write + Send + 'static,
) -> Result<Output, Error> {
    let (input, inputs) = crossbeam_channel::unbounded::<Input>();
    let (outputs, output) = crossbeam_channel::unbounded::<Output>();
    std::thread::spawn(move || {
        for message in inputs {
            let Ok(line) = serde_json::to_string(&message) else {
                continue;
            };
            if writeln!(writer, "{line}")
                .and_then(|()| writer.flush())
                .is_err()
            {
                return;
            }
        }
    });
    std::thread::spawn(move || {
        for line in reader.lines() {
            let Ok(line) = line else { break };
            let Ok(message) = serde_json::from_str::<Output>(&line) else {
                continue;
            };
            if outputs.send(message).is_err() {
                return;
            }
        }
    });
    tui::run(&input, &output)
}

/// Starts `greed serve` for the session called `name` in the background, its
/// output going to a log, and waits until it listens.
fn spawn_server(name: &str, file: Option<&Path>) -> Result<Child, Error> {
    std::fs::create_dir_all(control::sessions_dir())?;
    let log_path = log_path(name);
    let log = std::fs::File::create(&log_path)?;
    let mut command = Command::new(std::env::current_exe()?);
    command.args(["serve", "--session", name]);
    if let Some(file) = file {
        command.arg(file);
    }
    // Commands over ssh may come without it; the session and the programs
    // in its terminals should have what a login has.
    if let Some(dir) = control::runtime_dir() {
        command.env("XDG_RUNTIME_DIR", dir);
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
            let log = std::fs::read_to_string(&log_path).unwrap_or_default();
            return Err(format!("the editor didn't start: {}", log.trim()).into());
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    Ok(child)
}

/// Plain `greed`: attaches to the session for `path`'s project (or the one
/// called `name`), starting it in the background if it isn't running.
pub fn start(name: Option<&str>, path: Option<&Path>, terminal: bool) -> Result<(), Error> {
    let (name, running, target) = find_session(name, path)?;
    // A running session opens what was asked for; a new one starts with it.
    let open = if running {
        path.map(|_| target)
    } else {
        spawn_server(&name, Some(&target))
            .map_err(|err| format!("{err} (GREED_NO_SESSION=1 runs it in this terminal)"))?;
        None
    };
    follow(name, open, terminal)
}

/// `greed bridge`, run on the machine a session is on: connects this
/// process's input and output to the session called `name`, or to the one
/// for `path`'s project, starting it if it isn't running. What comes
/// through is passed on as it is; the client on the other end attaches.
pub fn bridge(name: Option<&str>, path: Option<&Path>) -> Result<(), Error> {
    let (name, running, target) = find_session(name, path)?;
    let mut input: Box<dyn BufRead + Send> = Box::new(BufReader::new(std::io::stdin()));
    if running {
        if path.is_some() {
            // The client attaches through us; ask the session to open the
            // path along the way, since only this end knows what it means.
            let mut first = String::new();
            input.read_line(&mut first)?;
            let mut attach: Value = serde_json::from_str(&first)?;
            attach["params"]["open"] = Value::from(target.to_string_lossy());
            let first = format!("{attach}\n");
            input = Box::new(std::io::Cursor::new(first.into_bytes()).chain(input));
        }
    } else {
        spawn_server(&name, Some(&target))?;
    }
    ctl::connect_to(Some(&name))?.pipe(input, std::io::stdout())?;
    Ok(())
}

/// `greed ssh`: shows a session on `host`, through `greed bridge` run there
/// over ssh, starting one if none is running. `$GREED_SSH` replaces the ssh
/// command and `$GREED_REMOTE` the greed on the other end.
pub fn ssh(
    host: &str,
    name: Option<&str>,
    file: Option<&str>,
    mut terminal: bool,
) -> Result<(), Error> {
    let config = match send_config(host) {
        Ok(config) => config,
        Err(err) => {
            eprintln!("greed: couldn't bring your config to {host}, going on without it: {err}");
            None
        }
    };
    let mut to = SwitchTo {
        session: name.map(str::to_owned),
        path: file.map(str::to_owned),
    };
    // A terminal is asked for once, not again after a switch.
    loop {
        let ended = ssh_once(host, &to, config.as_deref(), terminal)?;
        terminal = false;
        match ended {
            // The bridge on the other end finds (or starts) the session to
            // switch to; a new connection is the simplest way to ask it.
            Output::Switch(next) => to = next,
            Output::Detached => {
                println!("detached; greed ssh {host} comes back");
                return Ok(());
            }
            Output::Exit
            | Output::Frame(_)
            | Output::Delta(_)
            | Output::Image(_)
            | Output::Clipboard(_) => return Ok(()),
        }
    }
}

/// Shows the session `to` points at on `host` until it ends, lets go or
/// switches; returns which.
fn ssh_once(
    host: &str,
    to: &SwitchTo,
    config: Option<&str>,
    terminal: bool,
) -> Result<Output, Error> {
    let remote_greed = std::env::var("GREED_REMOTE").unwrap_or_else(|_| "greed".to_owned());
    let line = bridge_command(&remote_greed, to, config);
    let attach_failed = |err: Error| format!("couldn't attach on {host}: {err}");
    let (mut child, mut writer, mut reader) = remote(host, &line).map_err(attach_failed)?;
    handshake(&mut reader, &mut writer, terminal).map_err(attach_failed)?;
    let ended = show(reader, writer)?;
    // The session lives on the other end, so closing ssh loses nothing,
    // and the bridge there goes when its input does.
    let _ = child.kill();
    let _ = child.wait();
    Ok(ended)
}

/// Asks to attach over `reader` and `writer`, already connected to a
/// session. Fails with the session's reason if it refuses, e.g. because the
/// two ends run greed versions that don't speak the same protocol.
fn handshake(
    reader: &mut impl BufRead,
    writer: &mut impl Write,
    terminal: bool,
) -> Result<(), Error> {
    let mut params = control::handshake();
    if terminal {
        params["terminal"] = Value::Bool(true);
    }
    let request = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "attach",
        "params": params,
    });
    writeln!(writer, "{request}")?;
    writer.flush()?;
    let mut line = String::new();
    if reader.read_line(&mut line)? == 0 {
        return Err("the other end closed the connection (see above for why)".into());
    }
    let response: Value = serde_json::from_str(&line)?;
    if let Some(error) = response.get("error") {
        return Err(error["message"].as_str().unwrap_or("refused").into());
    }
    Ok(())
}

/// The ssh command, which `$GREED_SSH` replaces.
fn ssh_command() -> Command {
    Command::new(std::env::var("GREED_SSH").unwrap_or_else(|_| "ssh".to_owned()))
}

/// What the remote sh prints once it has read the line it runs.
const READY: &str = "greed-ready";

/// Runs the sh `line` on `host` and returns ssh with its input and output,
/// for the program the line `exec`s.
///
/// ssh hands the remote command to the user's login shell, which may not
/// speak POSIX sh (fish, nushell), so the command is only `sh -s`, two
/// plain words every shell reads the same, and the line goes to that sh as
/// input. Some shells (busybox's) read ahead of the line they run, so
/// nothing more is sent until the line says it's running.
fn remote(host: &str, line: &str) -> Result<(Child, ChildStdin, BufReader<ChildStdout>), Error> {
    let mut child = ssh_command()
        .args(["-T", host, "sh", "-s"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()?;
    let mut input = child.stdin.take().ok_or("ssh has no input")?;
    let mut output = BufReader::new(child.stdout.take().ok_or("ssh has no output")?);
    writeln!(input, "echo {READY}; {line}")?;
    input.flush()?;
    let mut said = String::new();
    loop {
        said.clear();
        if output.read_line(&mut said)? == 0 {
            return Err("the other end closed the connection (see above for why)".into());
        }
        if said.trim_end() == READY {
            return Ok((child, input, output));
        }
    }
}

/// `arg` quoted for a POSIX shell.
fn quote(arg: &str) -> String {
    format!("'{}'", arg.replace('\'', r"'\''"))
}

/// `greed serve` without a name: the session for `path`'s project, named
/// after it.
pub fn serve_project(path: Option<&Path>) -> Result<(), Error> {
    let (name, running, _) = find_session(None, path)?;
    if running {
        return Err(format!("the session {name} is already running for that project").into());
    }
    serve(&name, path)
}

/// The sh line that runs `greed bridge` (in its place) on the other machine for `to`,
/// with the config `greed ssh` brought along in `config` (a folder, which
/// may use `$HOME`).
fn bridge_command(greed: &str, to: &SwitchTo, config: Option<&str>) -> String {
    let mut args = vec![greed.to_owned(), "bridge".to_owned()];
    if let Some(name) = &to.session {
        args.extend(["--session".to_owned(), name.clone()]);
    }
    args.extend(to.path.clone());
    // ssh joins its arguments into one command line for the remote shell.
    let command = args
        .iter()
        .map(|arg| quote(arg))
        .collect::<Vec<_>>()
        .join(" ");
    match config {
        // Double quotes, so the remote shell fills in $HOME.
        Some(dir) => format!("GREED_SSH_CONFIG_DIR=\"{dir}\" exec {command}"),
        None => format!("exec {command}"),
    }
}

/// Copies your config (init.luau and plugins) to `host` with tar over ssh,
/// into a folder named after this machine, and returns that folder as the
/// remote shell should write it. Nothing to copy, or `$GREED_SSH_CONFIG` set
/// to 0, gives `None`.
fn send_config(host: &str) -> Result<Option<String>, Error> {
    let Some(local) = crate::config_dir().filter(|dir| dir.is_dir()) else {
        return Ok(None);
    };
    if std::env::var("GREED_SSH_CONFIG").is_ok_and(|v| v == "0") {
        return Ok(None);
    }
    let dir = format!("$HOME/.cache/greed/config-from-{}", this_machine());
    let mut tar = Command::new("tar")
        .arg("-C")
        .arg(&local)
        .args(["-cf", "-", "."])
        .stdout(Stdio::piped())
        .spawn()?;
    let mut packed = tar.stdout.take().ok_or("tar has no output")?;
    // A fresh copy each time, so plugins you removed go from there too.
    let unpack = format!("rm -rf \"{dir}\" && mkdir -p \"{dir}\" && exec tar -C \"{dir}\" -xf -");
    let (mut ssh, mut input, _) = remote(host, &unpack)?;
    std::io::copy(&mut packed, &mut input)?;
    drop(input);
    let status = ssh.wait()?;
    tar.wait()?;
    if !status.success() {
        return Err(format!("unpacking it there failed ({status})").into());
    }
    Ok(Some(dir))
}

/// This machine's name, in characters that are safe in a folder name.
fn this_machine() -> String {
    let name = std::fs::read_to_string("/proc/sys/kernel/hostname")
        .or_else(|_| std::fs::read_to_string("/etc/hostname"))
        .unwrap_or_default();
    let name: String = name
        .trim()
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect();
    if name.is_empty() {
        "local".to_owned()
    } else {
        name
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_bridge_command_quotes_paths_and_brings_the_config() {
        let to = SwitchTo {
            session: Some("greed".to_owned()),
            path: Some("it's here.rs".to_owned()),
        };
        assert_eq!(
            bridge_command("greed", &to, Some("$HOME/.cache/greed/config-from-box")),
            r#"GREED_SSH_CONFIG_DIR="$HOME/.cache/greed/config-from-box" exec 'greed' 'bridge' '--session' 'greed' 'it'\''s here.rs'"#
        );
        let plain = SwitchTo {
            session: None,
            path: None,
        };
        assert_eq!(
            bridge_command("/opt/greed", &plain, None),
            "exec '/opt/greed' 'bridge'"
        );
    }
}
