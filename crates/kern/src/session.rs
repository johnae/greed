//! Running the editor as a session that outlives its terminal, like zellij
//! or tmux: `kern serve` runs it headless, `kern attach` shows it, and plain
//! `kern` starts one in the background and attaches.

use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use kern_core::control::{self, Attachment};
use kern_core::server::{self, Input, Output};

use crate::{ctl, host, read, tui};

type Error = Box<dyn std::error::Error>;

/// How long `kern` waits for the server it started to listen.
const STARTUP: Duration = Duration::from_secs(5);

/// `kern serve`: runs the editor with no terminal until something quits it.
pub fn serve(name: &str, file: Option<PathBuf>) -> Result<(), Error> {
    let text = read(file.as_deref())?;
    let session = control::listen(name)?;
    let requests = session.sender().clone();
    let conn = server::spawn_with_session(move || host(&text, file, Some(requests)), Some(session));
    // Nothing is drawn until a client attaches and says how big it is.
    conn.server.join().map_err(|_| "the editor crashed")??;
    // `kern` sends a background session's output here; after a clean exit
    // there is nothing in it to explain.
    let _ = std::fs::remove_file(log_path(name));
    Ok(())
}

/// Where a background session's output goes.
fn log_path(name: &str) -> PathBuf {
    control::sessions_dir().join(format!("{name}.log"))
}

/// `kern attach`: shows the session called `name` (or the only one running)
/// in this terminal until it quits or lets this terminal go.
pub fn attach(name: Option<&str>) -> Result<(), Error> {
    attach_to(name).map(|_| ())
}

/// Like [`attach`], returning how it ended.
fn attach_to(name: Option<&str>) -> Result<Output, Error> {
    let Attachment { reader, mut writer } = ctl::connect_to(name)?.attach()?;
    let (input, inputs) = crossbeam_channel::unbounded::<Input>();
    let (outputs, output) = crossbeam_channel::unbounded::<Output>();
    std::thread::spawn(move || {
        for message in inputs {
            let Ok(line) = serde_json::to_string(&message) else {
                continue;
            };
            if writeln!(writer, "{line}").is_err() {
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
    let ended = tui::run(&input, &output)?;
    if let Output::Detached = ended {
        let name = name.map_or_else(String::new, |name| format!(" {name}"));
        println!("detached; kern attach{name} comes back");
    }
    Ok(ended)
}

/// Plain `kern`: starts a session in the background, named after this
/// process, and attaches to it. Its output goes to a log next to its
/// socket, shown here if it doesn't start.
pub fn start(file: Option<&Path>) -> Result<(), Error> {
    let name = std::process::id().to_string();
    std::fs::create_dir_all(control::sessions_dir())?;
    let log_path = log_path(&name);
    let log = std::fs::File::create(&log_path)?;
    let mut command = Command::new(std::env::current_exe()?);
    command.args(["serve", "--session", &name]);
    if let Some(file) = file {
        command.arg(file);
    }
    std::os::unix::process::CommandExt::process_group(&mut command, 0);
    let mut child = command
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log)
        .spawn()?;
    let (socket, _) = control::session_files(&name);
    let deadline = Instant::now() + STARTUP;
    while std::os::unix::net::UnixStream::connect(&socket).is_err() {
        if child.try_wait()?.is_some() || Instant::now() > deadline {
            let log = std::fs::read_to_string(&log_path).unwrap_or_default();
            return Err(format!(
                "the editor didn't start (KERN_NO_SESSION=1 runs it in this terminal): {}",
                log.trim()
            )
            .into());
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    if let Output::Exit = attach_to(Some(&name))? {
        child.wait()?;
    }
    Ok(())
}
