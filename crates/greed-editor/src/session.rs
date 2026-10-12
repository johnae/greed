//! Running the editor as a session that outlives its terminal, like zellij
//! or tmux: `greed serve` runs it headless, `greed attach` shows it, plain
//! `greed` starts one in the background and attaches, and `greed ssh` shows a
//! session on another machine through `greed bridge` running there.

use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::{Duration, Instant};

use greed_core::SwitchTo;
use greed_core::control::{self, Attachment, Opening};
use greed_core::project;
use greed_core::server::{self, Input, Output};
use serde_json::{Value, json};

use crate::versions::{self, Choice, Stale};
use crate::{client, ctl, host, read};

type Error = Box<dyn std::error::Error>;

/// Where a session `greed ssh` started listens for its programs' ssh agent
/// requests, set by `spawn_server` for `greed serve`.
const AGENT_ENV: &str = "GREED_AGENT_SOCK";

/// How long `greed` waits for the server it started to listen. It listens
/// before it loads anything, so this is only long for a loaded machine.
const STARTUP: Duration = Duration::from_secs(30);

/// `greed serve`: runs the editor with no terminal until something quits it.
pub fn serve(name: &str, path: Option<&Path>) -> Result<(), Error> {
    let target = absolute(path)?;
    let root = project::root_of(&target);
    // The session works from its project's root, so paths in it are short.
    std::env::set_current_dir(&root)?;
    let file = target.is_file().then_some(target);
    let text = read(file.as_deref())?;
    let mut session = control::listen(name, Some(&root))?;
    // A session `greed ssh` started reaches your ssh agent through you.
    if let Some(agent) = std::env::var_os(AGENT_ENV).filter(|path| !path.is_empty())
        && let Err(err) = session.serve_ssh_agent(Path::new(&agent))
    {
        eprintln!("greed: programs in this session won't reach your ssh agent: {err}");
    }
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

/// A name for another session for `path`'s project, beside any running for
/// it: the project's name, or that with `-2`, `-3`, ... after it.
pub fn new_name(path: Option<&Path>) -> Result<String, Error> {
    let root = project::root_of(&absolute(path)?);
    let names: Vec<String> = control::sessions()?.into_iter().map(|s| s.name).collect();
    Ok(project::session_name(&root, &names))
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
    follow(name, None, Opening::Nothing)
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
fn follow(mut name: String, mut open: Option<PathBuf>, mut opening: Opening) -> Result<(), Error> {
    // A terminal or shell is asked for once, not again after a switch.
    loop {
        let attached =
            ctl::connect_to(Some(&name))?.attach_opening(client::kind(), open.as_deref(), opening);
        let Attachment { reader, writer, .. } = match attached {
            Ok(attachment) => attachment,
            Err(err) => {
                let err: Error = err.into();
                let Some(refused) = versions::other_version(&err) else {
                    return Err(err);
                };
                // Another version runs it: what to do is the user's to say.
                match settle(&name, &refused)? {
                    Some(next) => {
                        name = next;
                        continue;
                    }
                    None => return Ok(()),
                }
            }
        };
        opening = Opening::Nothing;
        match show(reader, writer, false, None)? {
            Output::Switch(SwitchTo {
                host: Some(host),
                session,
                path,
                ..
            }) => {
                return ssh(
                    &host,
                    session.as_deref(),
                    path.as_deref(),
                    Opening::Nothing,
                    false,
                );
            }
            Output::Switch(to) => (name, open) = resolve(&to)?,
            Output::Detached => {
                println!("detached; greed attach {name} comes back");
                return Ok(());
            }
            Output::Exit
            | Output::Frame(_)
            | Output::Delta(_)
            | Output::Image(_)
            | Output::Scene(_)
            | Output::Clipboard(_)
            | Output::ReadClipboardImage(_)
            | Output::SshAgentRequest(..)
            | Output::Notify(_) => return Ok(()),
        }
    }
}

/// Asks what to do about the session `name` here, which another version
/// of greed runs (`refused` says which), and does it: the session to
/// attach to then, or None to stop. Opening it with that version replaces
/// this process.
fn settle(name: &str, refused: &control::Refused) -> Result<Option<String>, Error> {
    let stale = versions::here(name, refused);
    match versions::ask(&stale)? {
        Choice::End => {
            ctl::quit(Some(name), !stale.state.unsaved.is_empty())?;
            wait_gone(name)?;
            spawn_server(name, stale.root.as_deref(), false)?;
            Ok(Some(name.to_owned()))
        }
        Choice::Beside => {
            let beside = new_name(stale.root.as_deref())?;
            spawn_server(&beside, stale.root.as_deref(), false)?;
            Ok(Some(beside))
        }
        Choice::Old => {
            use std::os::unix::process::CommandExt;
            let greed = stale
                .greed
                .ok_or("that version of greed isn't here any more")?;
            let mut command = Command::new(greed);
            command.args(["attach", name]);
            if client::kind() == "gui" {
                command.arg("--gui");
            }
            Err(command.exec().into())
        }
        Choice::Cancel => Ok(None),
    }
}

/// Waits until the session `name` has gone, as after it was told to quit.
fn wait_gone(name: &str) -> Result<(), Error> {
    let deadline = Instant::now() + Duration::from_secs(10);
    while ctl::live_sessions()?.iter().any(|live| live == name) {
        if Instant::now() > deadline {
            return Err(format!("the session {name} didn't end").into());
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    Ok(())
}

/// The session `to` points at, started if it isn't running, and what to
/// ask it to open.
fn resolve(to: &SwitchTo) -> Result<(String, Option<PathBuf>), Error> {
    if let Some(name) = &to.session {
        if !ctl::live_sessions()?.contains(name) {
            spawn_server(name, to.path.as_deref().map(Path::new), false)?;
        }
        return Ok((name.clone(), None));
    }
    let (name, running, target) = find_session(None, to.path.as_deref().map(Path::new))?;
    if running {
        Ok((name, Some(target)))
    } else {
        spawn_server(&name, Some(&target), false)?;
        Ok((name, None))
    }
}

/// Opens `to` in a window of its own, for a window that stays on its
/// session: another `greed --gui`, attached to the session `to` names or
/// to the project's (started if need be), or over `greed ssh`.
pub fn open_window(to: SwitchTo) {
    std::thread::spawn(move || {
        let mut args = vec!["--gui".to_owned()];
        if let Some(host) = to.host {
            args.extend(["ssh".to_owned(), host]);
            if let Some(name) = to.session {
                args.extend(["--session".to_owned(), name]);
            }
            args.extend(to.path);
        } else {
            match resolve(&to) {
                Ok((name, _)) => args.extend(["attach".to_owned(), name]),
                Err(err) => {
                    eprintln!("greed: can't open another window: {err}");
                    return;
                }
            }
        }
        let Ok(program) = std::env::current_exe() else {
            return;
        };
        // Started from a terminal in a session, it would open in that one.
        let started = Command::new(program)
            .args(&args)
            .env_remove("GREED_SESSION")
            .env_remove("GREED_TERMINAL")
            .stdin(Stdio::null())
            .spawn();
        match started {
            // Waited for, so it doesn't linger once it ends.
            Ok(mut child) => {
                let _ = child.wait();
            }
            Err(err) => eprintln!("greed: can't open another window: {err}"),
        }
    });
}

/// Shows an attached session in this terminal: input goes to `writer` and
/// frames come from `reader`, one JSON message per line, from a session on
/// another machine with `remote`. The session's requests for your ssh agent
/// go to `agent`, the one this client relays. Returns how it ended.
fn show(
    reader: impl BufRead + Send + 'static,
    mut writer: impl Write + Send + 'static,
    remote: bool,
    agent: Option<PathBuf>,
) -> Result<Output, Error> {
    client::set_remote(remote);
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
    let replies = input.clone();
    // Whether the agent's last failure was said, so a burst of requests
    // says it once, and again only after it answered in between.
    let said = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    std::thread::spawn(move || {
        for line in reader.lines() {
            let Ok(line) = line else { break };
            // One this client can't read, as from a newer session, is left
            // out; a frame or delta left out makes the next delta not fit,
            // and the client asks for a whole frame.
            let message = match serde_json::from_str::<Output>(&line) {
                Ok(message) => message,
                Err(err) => {
                    let said = format!("couldn't read a message from the session: {err}");
                    let _ = replies.send(Input::Log(said));
                    continue;
                }
            };
            // Asked off this thread: a key touch can take a while.
            if let Output::SshAgentRequest(id, body) = message {
                let (agent, replies, said) = (agent.clone(), replies.clone(), said.clone());
                std::thread::spawn(move || {
                    use std::sync::atomic::Ordering;
                    let answer = greed_core::ssh_agent::ask_base64(agent.as_deref(), &body);
                    // Why it failed goes on the status line, rather than
                    // only "agent refused operation" in the program.
                    match &answer {
                        Ok(_) => said.store(false, Ordering::Relaxed),
                        Err(why) if !said.swap(true, Ordering::Relaxed) => {
                            let _ = replies.send(Input::Problem(why.clone()));
                        }
                        Err(_) => {}
                    }
                    let _ = replies.send(Input::SshAgentReply(id, answer.ok()));
                });
                continue;
            }
            if outputs.send(message).is_err() {
                return;
            }
        }
    });
    crate::client::run(&input, &output)
}

/// Starts `greed serve` for the session called `name` in the background, its
/// output going to a log, and waits until it listens.
fn spawn_server(name: &str, file: Option<&Path>, remote: bool) -> Result<Child, Error> {
    std::fs::create_dir_all(control::sessions_dir())?;
    let log_path = log_path(name);
    let log = std::fs::File::create(&log_path)?;
    let mut command = Command::new(std::env::current_exe()?);
    command.args(["serve", "--session", name]);
    if control::fresh() {
        command.arg("--fresh");
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
    if remote {
        command.env(control::REMOTE_ENV, "1");
        // Its programs reach your ssh agent through the session, at a
        // path that stays the same however often you come back.
        let agent = greed_core::ssh_agent::socket_of(name);
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
            return Err(format!("the editor didn't start: {}", log.trim()).into());
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    Ok(child)
}

/// `PATH` with this greed's folder added at the end, when no greed is on it,
/// as on a machine `greed ssh` put greed on: so `greed FILE` and `greed ctl`
/// work in the session's terminals. A greed you installed stays first.
fn path_with_greed() -> Option<std::ffi::OsString> {
    if greed_core::lsp::which("greed").is_some() {
        return None;
    }
    let exe = std::env::current_exe().ok()?;
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|path| std::env::split_paths(&path).collect())
        .unwrap_or_default();
    dirs.push(exe.parent()?.to_path_buf());
    std::env::join_paths(dirs).ok()
}

/// Tells a `greed --fresh` that the session `name` is already running, so
/// it keeps what it has open.
fn fresh_does_nothing(name: &str) {
    if control::fresh() {
        eprintln!(
            "greed: the session {name} is running, so --fresh does nothing; quit it first, or start another with --new"
        );
    }
}

/// Plain `greed`: attaches to the session for `path`'s project (or the one
/// called `name`), starting it in the background if it isn't running.
pub fn start(name: Option<&str>, path: Option<&Path>, opening: Opening) -> Result<(), Error> {
    let (name, running, target) = find_session(name, path)?;
    // A running session opens what was asked for; a new one starts with it.
    let open = if running {
        fresh_does_nothing(&name);
        path.map(|_| target)
    } else {
        spawn_server(&name, Some(&target), false)
            .map_err(|err| format!("{err} (GREED_NO_SESSION=1 runs it in this terminal)"))?;
        None
    };
    follow(name, open, opening)
}

/// `greed bridge`, run on the machine a session is on: connects this
/// process's input and output to the session called `name`, or to the one
/// for `path`'s project, starting it if it isn't running. What comes
/// through is passed on as it is; the client on the other end attaches.
pub fn bridge(name: Option<&str>, path: Option<&Path>) -> Result<(), Error> {
    let (name, running, target) = find_session(name, path)?;
    let mut stdin = BufReader::new(std::io::stdin());
    // The client attaches through us: say it's over ssh, and ask a running
    // session to open the path along the way, since only this end knows
    // what it means.
    let mut first = String::new();
    stdin.read_line(&mut first)?;
    let mut attach: Value = serde_json::from_str(&first)?;
    let params = attach
        .as_object_mut()
        .map(|a| a.entry("params").or_insert_with(|| json!({})))
        .and_then(Value::as_object_mut)
        .ok_or_else(|| std::io::Error::other("the first message isn't an attach request"))?;
    params.insert("remote".into(), Value::Bool(true));
    if running {
        fresh_does_nothing(&name);
        if path.is_some() {
            params.insert("open".into(), Value::from(target.to_string_lossy()));
        }
    } else {
        spawn_server(&name, Some(&target), true)?;
    }
    let first = format!("{attach}\n");
    let input: Box<dyn BufRead + Send> =
        Box::new(std::io::Cursor::new(first.into_bytes()).chain(stdin));
    ctl::connect_to(Some(&name))?.pipe(input, std::io::stdout())?;
    Ok(())
}

/// `greed ssh`: shows a session on `host`, through `greed bridge` run there
/// over ssh, starting one if none is running, or with `new` another one
/// beside it. `$GREED_SSH` replaces the ssh command and `$GREED_REMOTE` the
/// greed on the other end.
pub fn ssh(
    host: &str,
    name: Option<&str>,
    file: Option<&str>,
    mut opening: Opening,
    mut new: bool,
) -> Result<(), Error> {
    let mut host = host.to_owned();
    let mut config = bring_config(&host);
    let mut greed = remote_greed(&host)?;
    let mut agent = relays_agent(&host);
    let mut to = SwitchTo {
        session: name.map(str::to_owned),
        path: file.map(str::to_owned),
        host: None,
        window: false,
    };
    // A terminal or shell is asked for once, not again after a switch.
    loop {
        let ended = match ssh_once(
            &host,
            &greed,
            &to,
            config.as_deref(),
            opening,
            new,
            agent.as_deref(),
        ) {
            Ok(ended) => ended,
            Err(err) => {
                let Some(refused) = versions::other_version(&err) else {
                    return Err(err);
                };
                // Another version runs it there: what to do is the user's
                // to say, and it's done there.
                match settle_remote(&host, &greed, &refused)? {
                    Some(beside) => {
                        new = beside;
                        continue;
                    }
                    None => return Ok(()),
                }
            }
        };
        opening = Opening::Nothing;
        new = false;
        match ended {
            // The bridge on the other end finds (or starts) the session to
            // switch to; a new connection is the simplest way to ask it. A
            // switch to another machine brings the config there too.
            Output::Switch(next) => {
                if let Some(other) = &next.host
                    && *other != host
                {
                    host.clone_from(other);
                    config = bring_config(&host);
                    greed = remote_greed(&host)?;
                    agent = relays_agent(&host);
                }
                to = next;
            }
            Output::Detached => {
                println!("detached; greed ssh {host} comes back");
                return Ok(());
            }
            Output::Exit
            | Output::Frame(_)
            | Output::Delta(_)
            | Output::Image(_)
            | Output::Scene(_)
            | Output::Clipboard(_)
            | Output::ReadClipboardImage(_)
            | Output::SshAgentRequest(..)
            | Output::Notify(_) => return Ok(()),
        }
    }
}

/// Asks what to do about the session on `host` that another version of
/// greed runs (`refused` says which), and does it there with `greed`, this
/// version's greed on `host`: whether to attach again with a new session
/// beside it (true) or in its place (false), or None to stop. Opening it
/// with its own version isn't offered: that greed isn't here.
fn settle_remote(
    host: &str,
    greed: &str,
    refused: &control::Refused,
) -> Result<Option<bool>, Error> {
    let name = refused
        .session
        .clone()
        .ok_or("the session there didn't say its name")?;
    let open_there = remote_run(
        host,
        &format!("{} ctl state {}", quote(greed), quote(&name)),
    )
    .ok()
    .and_then(|out| serde_json::from_str::<Value>(out.trim()).ok())
    .map(|value| ctl::State::from_json(&value))
    .unwrap_or_default();
    let stale = Stale {
        session: name.clone(),
        host: Some(host.to_owned()),
        version: refused.version.clone(),
        state: open_there,
        root: None,
        greed: None,
    };
    match versions::ask(&stale)? {
        Choice::End => {
            let force = if stale.state.unsaved.is_empty() {
                ""
            } else {
                " --force"
            };
            remote_run(
                host,
                &format!("{} ctl quit{force} {}", quote(greed), quote(&name)),
            )?;
            Ok(Some(false))
        }
        Choice::Beside => Ok(Some(true)),
        Choice::Old | Choice::Cancel => Ok(None),
    }
}

/// Runs `line` on `host` with its shell, giving back what it printed; its
/// errors show here.
fn remote_run(host: &str, line: &str) -> Result<String, Error> {
    let (mut child, input, mut output) = remote(host, line)?;
    // The shell there ends after the line once its input does.
    drop(input);
    let mut out = String::new();
    output.read_to_string(&mut out)?;
    if !child.wait()?.success() {
        return Err(format!("{line} failed on {host}").into());
    }
    Ok(out)
}

/// The greed to run on `host`: `$GREED_REMOTE`, or this version, put there
/// if it isn't (see [`crate::install`]).
fn remote_greed(host: &str) -> Result<String, Error> {
    match std::env::var("GREED_REMOTE") {
        Ok(greed) => Ok(greed),
        Err(_) => crate::install::ensure(host),
    }
}

/// Your config, copied to `host` (see [`send_config`]), or `None` with a
/// word on why when it couldn't be.
fn bring_config(host: &str) -> Option<String> {
    send_config(host).unwrap_or_else(|err| {
        eprintln!("greed: couldn't bring your config to {host}, going on without it: {err}");
        None
    })
}

/// The ssh agent on this machine, from `SSH_AUTH_SOCK`.
fn local_agent() -> Option<PathBuf> {
    std::env::var_os("SSH_AUTH_SOCK")
        .filter(|path| !path.is_empty())
        .map(PathBuf::from)
}

/// The ssh agent `greed ssh` relays to the session on `host`, when your ssh
/// config forwards one there (`ForwardAgent yes`, as `ssh -G` reads it):
/// `SSH_AUTH_SOCK` if it answers, else the `IdentityAgent` your config
/// names for the host if that does. A shell can keep a socket that's gone,
/// like a terminal's whose window closed. With neither answering it's still
/// `SSH_AUTH_SOCK`, so the session can say why requests fail.
fn relays_agent(host: &str) -> Option<PathBuf> {
    let out = ssh_command()
        .args(["-G", host])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()
        .filter(|out| out.status.success())?;
    let config = String::from_utf8_lossy(&out.stdout);
    let setting = |name: &str| {
        config.lines().find_map(|line| {
            let (key, value) = line.trim().split_once(' ')?;
            key.eq_ignore_ascii_case(name)
                .then(|| value.trim().to_owned())
        })
    };
    if !setting("forwardagent").is_some_and(|v| v.eq_ignore_ascii_case("yes")) {
        return None;
    }
    let local = local_agent();
    if local.as_deref().is_some_and(greed_core::ssh_agent::answers) {
        return local;
    }
    let named = setting("identityagent")
        .filter(|v| !v.eq_ignore_ascii_case("none") && !v.eq_ignore_ascii_case("SSH_AUTH_SOCK"))
        .map(|v| match (v.strip_prefix("~/"), std::env::var_os("HOME")) {
            (Some(rest), Some(home)) => PathBuf::from(home).join(rest),
            _ => PathBuf::from(v),
        });
    named
        .filter(|path| greed_core::ssh_agent::answers(path))
        .or(local)
}

/// Shows the session `to` points at on `host` until it ends, lets go or
/// switches; returns which. With `agent`, an ssh agent's socket here, it
/// relays that agent to the session, which then has one way to it: ssh's
/// own forwarding is off.
fn ssh_once(
    host: &str,
    remote_greed: &str,
    to: &SwitchTo,
    config: Option<&str>,
    opening: Opening,
    new: bool,
    agent: Option<&Path>,
) -> Result<Output, Error> {
    let line = bridge_command(remote_greed, to, config, new);
    let attach_failed = |err: Error| -> Error {
        // Another version there is for the caller to ask about.
        if versions::other_version(&err).is_some() {
            return err;
        }
        format!("couldn't attach on {host}: {err}").into()
    };
    let options: &[&str] = if agent.is_some() {
        &["-o", "ForwardAgent=no"]
    } else {
        &[]
    };
    let (mut child, mut writer, mut reader) =
        remote_with(host, options, &line).map_err(attach_failed)?;
    handshake(
        &mut reader,
        &mut writer,
        to.session.as_deref(),
        opening,
        agent.is_some(),
    )
    .map_err(attach_failed)?;
    let ended = show(reader, writer, true, agent.map(Path::to_path_buf))?;
    // The session lives on the other end, so closing ssh loses nothing,
    // and the bridge there goes when its input does.
    let _ = child.kill();
    let _ = child.wait();
    Ok(ended)
}

/// Asks to attach over `reader` and `writer`, already connected to the
/// session `session` (or whichever the other end picks). Fails with the
/// session's reason if it refuses, e.g. because the two ends run greed
/// versions that don't speak the same protocol. With `agent`, it says it
/// relays your ssh agent.
fn handshake(
    reader: &mut impl BufRead,
    writer: &mut impl Write,
    session: Option<&str>,
    opening: Opening,
    agent: bool,
) -> Result<(), Error> {
    let mut params = control::attach_params(client::kind());
    opening.ask(&mut params);
    if agent {
        params["ssh_agent"] = Value::Bool(true);
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
        let said = error["message"].as_str().unwrap_or("refused");
        return Err(control::Refused::new(session, said).into());
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
pub(crate) fn remote(
    host: &str,
    line: &str,
) -> Result<(Child, ChildStdin, BufReader<ChildStdout>), Error> {
    remote_with(host, &[], line)
}

/// [`remote`], giving ssh `options` too.
fn remote_with(
    host: &str,
    options: &[&str],
    line: &str,
) -> Result<(Child, ChildStdin, BufReader<ChildStdout>), Error> {
    let mut child = ssh_command()
        .args(options)
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
fn bridge_command(greed: &str, to: &SwitchTo, config: Option<&str>, new: bool) -> String {
    let mut args = vec![greed.to_owned(), "bridge".to_owned()];
    if control::fresh() {
        args.push("--fresh".to_owned());
    }
    if let Some(name) = &to.session {
        args.extend(["--session".to_owned(), name.clone()]);
    } else if new {
        args.push("--new".to_owned());
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
    let name = gethostname::gethostname().to_string_lossy().into_owned();
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
            host: None,
            window: false,
        };
        assert_eq!(
            bridge_command(
                "greed",
                &to,
                Some("$HOME/.cache/greed/config-from-box"),
                false
            ),
            r#"GREED_SSH_CONFIG_DIR="$HOME/.cache/greed/config-from-box" exec 'greed' 'bridge' '--session' 'greed' 'it'\''s here.rs'"#
        );
        let plain = SwitchTo {
            session: None,
            path: None,
            host: None,
            window: false,
        };
        assert_eq!(
            bridge_command("/opt/greed", &plain, None, false),
            "exec '/opt/greed' 'bridge'"
        );
    }
}
