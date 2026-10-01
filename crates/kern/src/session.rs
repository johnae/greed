//! Running the editor as a session that outlives its terminal, like zellij
//! or tmux: `kern serve` runs it headless, `kern attach` shows it, plain
//! `kern` starts one in the background and attaches, and `kern ssh` shows a
//! session on another machine through `kern bridge` running there.

use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use kern_core::SwitchTo;
use kern_core::control::{self, Attachment};
use kern_core::project;
use kern_core::server::{self, Input, Output};
use serde_json::{Value, json};

use crate::{ctl, host, read, tui};

type Error = Box<dyn std::error::Error>;

/// How long `kern` waits for the server it started to listen.
const STARTUP: Duration = Duration::from_secs(5);

/// `kern serve`: runs the editor with no terminal until something quits it.
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
    // `kern` sends a background session's output here; after a clean exit
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

/// `kern attach`: shows the session called `name` (or the only one running)
/// in this terminal until it quits or lets this terminal go.
pub fn attach(name: Option<&str>) -> Result<(), Error> {
    let name = match name
        .map(str::to_owned)
        .or_else(|| std::env::var("KERN_SESSION").ok())
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
    follow(name, None)
}

/// Shows the session called `name` in this terminal, asking it to open
/// `open`, and follows the client to any session it switches to, until a
/// session quits or lets the terminal go.
fn follow(mut name: String, mut open: Option<PathBuf>) -> Result<(), Error> {
    loop {
        let Attachment { reader, writer, .. } =
            ctl::connect_to(Some(&name))?.attach_opening(open.as_deref())?;
        match show(reader, writer)? {
            Output::Switch(to) => (name, open) = resolve(&to)?,
            Output::Detached => {
                println!("detached; kern attach {name} comes back");
                return Ok(());
            }
            Output::Exit | Output::Frame(_) | Output::Delta(_) | Output::Image(_) => return Ok(()),
        }
    }
}

/// The session `to` points at, started if it isn't running, and what to
/// ask it to open.
fn resolve(to: &SwitchTo) -> Result<(String, Option<PathBuf>), Error> {
    if let Some(name) = &to.session {
        if !ctl::live_sessions()?.contains(name) {
            spawn_server(name, None)?;
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

/// Starts `kern serve` for the session called `name` in the background, its
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

/// Plain `kern`: attaches to the session for `path`'s project (or the one
/// called `name`), starting it in the background if it isn't running.
pub fn start(name: Option<&str>, path: Option<&Path>) -> Result<(), Error> {
    let (name, running, target) = find_session(name, path)?;
    // A running session opens what was asked for; a new one starts with it.
    let open = if running {
        path.map(|_| target)
    } else {
        spawn_server(&name, Some(&target))
            .map_err(|err| format!("{err} (KERN_NO_SESSION=1 runs it in this terminal)"))?;
        None
    };
    follow(name, open)
}

/// `kern bridge`, run on the machine a session is on: connects this
/// process's input and output to the session called `name`, or to the one
/// for `path`'s project, starting it if it isn't running. What comes
/// through is passed on as it is; the client on the other end attaches.
pub fn bridge(name: Option<&str>, path: Option<&Path>) -> Result<(), Error> {
    let (name, running, target) = find_session(name, path)?;
    let mut input: Box<dyn BufRead> = Box::new(std::io::stdin().lock());
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

/// `kern ssh`: shows a session on `host`, through `kern bridge` run there
/// over ssh, starting one if none is running. `$KERN_SSH` replaces the ssh
/// command and `$KERN_REMOTE` the kern on the other end.
pub fn ssh(host: &str, name: Option<&str>, file: Option<&str>) -> Result<(), Error> {
    let config = match send_config(host) {
        Ok(config) => config,
        Err(err) => {
            eprintln!("kern: couldn't bring your config to {host}, going on without it: {err}");
            None
        }
    };
    let mut to = SwitchTo {
        session: name.map(str::to_owned),
        path: file.map(str::to_owned),
    };
    loop {
        match ssh_once(host, &to, config.as_deref())? {
            // The bridge on the other end finds (or starts) the session to
            // switch to; a new connection is the simplest way to ask it.
            Output::Switch(next) => to = next,
            Output::Detached => {
                println!("detached; kern ssh {host} comes back");
                return Ok(());
            }
            Output::Exit | Output::Frame(_) | Output::Delta(_) | Output::Image(_) => return Ok(()),
        }
    }
}

/// Shows the session `to` points at on `host` until it ends, lets go or
/// switches; returns which.
fn ssh_once(host: &str, to: &SwitchTo, config: Option<&str>) -> Result<Output, Error> {
    let remote_kern = std::env::var("KERN_REMOTE").unwrap_or_else(|_| "kern".to_owned());
    let line = bridge_command(&remote_kern, to, config);
    let mut child = ssh_command()
        .args(["-T", host, &line])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()?;
    let mut writer = child.stdin.take().ok_or("ssh has no input")?;
    let mut reader = BufReader::new(child.stdout.take().ok_or("ssh has no output")?);
    handshake(&mut reader, &mut writer)
        .map_err(|err| format!("couldn't attach on {host}: {err}"))?;
    let ended = show(reader, writer)?;
    // The session lives on the other end, so closing ssh loses nothing,
    // and the bridge there goes when its input does.
    let _ = child.kill();
    let _ = child.wait();
    Ok(ended)
}

/// Asks to attach over `reader` and `writer`, already connected to a
/// session. Fails with the session's reason if it refuses, e.g. because the
/// two ends run kern versions that don't speak the same protocol.
fn handshake(reader: &mut impl BufRead, writer: &mut impl Write) -> Result<(), Error> {
    let request = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "attach",
        "params": control::handshake(),
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

/// The ssh command, which `$KERN_SSH` replaces.
fn ssh_command() -> Command {
    Command::new(std::env::var("KERN_SSH").unwrap_or_else(|_| "ssh".to_owned()))
}

/// `arg` quoted for a POSIX shell.
fn quote(arg: &str) -> String {
    format!("'{}'", arg.replace('\'', r"'\''"))
}

/// `kern serve` without a name: the session for `path`'s project, named
/// after it.
pub fn serve_project(path: Option<&Path>) -> Result<(), Error> {
    let (name, running, _) = find_session(None, path)?;
    if running {
        return Err(format!("the session {name} is already running for that project").into());
    }
    serve(&name, path)
}

/// The command line that runs `kern bridge` on the other machine for `to`,
/// with the config `kern ssh` brought along in `config` (a folder, which
/// may use `$HOME`).
fn bridge_command(kern: &str, to: &SwitchTo, config: Option<&str>) -> String {
    let mut args = vec![kern.to_owned(), "bridge".to_owned()];
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
        Some(dir) => format!("KERN_SSH_CONFIG_DIR=\"{dir}\" {command}"),
        None => command,
    }
}

/// Copies your config (init.luau and plugins) to `host` with tar over ssh,
/// into a folder named after this machine, and returns that folder as the
/// remote shell should write it. Nothing to copy, or `$KERN_SSH_CONFIG` set
/// to 0, gives `None`.
fn send_config(host: &str) -> Result<Option<String>, Error> {
    let Some(local) = crate::config_dir().filter(|dir| dir.is_dir()) else {
        return Ok(None);
    };
    if std::env::var("KERN_SSH_CONFIG").is_ok_and(|v| v == "0") {
        return Ok(None);
    }
    let dir = format!("$HOME/.cache/kern/config-from-{}", this_machine());
    let mut tar = Command::new("tar")
        .arg("-C")
        .arg(&local)
        .args(["-cf", "-", "."])
        .stdout(Stdio::piped())
        .spawn()?;
    let packed = tar.stdout.take().ok_or("tar has no output")?;
    // A fresh copy each time, so plugins you removed go from there too.
    let unpack = format!("rm -rf \"{dir}\" && mkdir -p \"{dir}\" && tar -C \"{dir}\" -xf -");
    let status = ssh_command()
        .args(["-T", host, &unpack])
        .stdin(packed)
        .status()?;
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
            session: Some("kern".to_owned()),
            path: Some("it's here.rs".to_owned()),
        };
        assert_eq!(
            bridge_command("kern", &to, Some("$HOME/.cache/kern/config-from-box")),
            r#"KERN_SSH_CONFIG_DIR="$HOME/.cache/kern/config-from-box" 'kern' 'bridge' '--session' 'kern' 'it'\''s here.rs'"#
        );
        let plain = SwitchTo {
            session: None,
            path: None,
        };
        assert_eq!(
            bridge_command("/opt/kern", &plain, None),
            "'/opt/kern' 'bridge'"
        );
    }
}
