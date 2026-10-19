//! Running the editor as a session that outlives its terminal, like zellij
//! or tmux: `greed serve` runs it headless, `greed attach` shows it, plain
//! `greed` starts one in the background and attaches, and `greed ssh` shows a
//! session on another machine through `greed bridge` running there.

use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
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
    // A file that isn't there yet opens empty, to be written there.
    let file = (path.is_some() && !target.is_dir()).then_some(target);
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
/// `open`, and follows the client wherever it goes from there.
fn follow(name: String, open: Option<PathBuf>, opening: Opening) -> Result<(), Error> {
    travel(Next::Here { name, open }, opening)
}

/// A session this client showed: on this machine, or on `host`. A session
/// on another machine whose greed doesn't say its name is that machine's
/// default one.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Place {
    host: Option<String>,
    session: Option<String>,
}

/// How many places the client remembers for going back.
const TRAIL: usize = 20;

/// Where the client goes next.
enum Next {
    /// The session `name` here, asked to open `open`.
    Here { name: String, open: Option<PathBuf> },
    /// The session `to` points at on `host`, or with `new` another beside
    /// the one there.
    There {
        host: String,
        to: SwitchTo,
        new: bool,
    },
}

/// What `greed ssh` needs for one machine: found once per visit.
struct Machine {
    host: String,
    config: Option<String>,
    greed: String,
    agent: Option<PathBuf>,
}

impl Machine {
    fn reach(host: &str) -> Result<Self, Error> {
        Ok(Self {
            host: host.to_owned(),
            config: bring_config(host),
            greed: remote_greed(host)?,
            agent: relays_agent(host),
        })
    }
}

/// Shows sessions in this terminal or window, starting with `next`, and
/// follows the client to wherever it switches, here or on other machines,
/// keeping where it was so it can go back, until a session quits or lets it
/// go. A terminal or shell (`opening`) is asked for once, not again after a
/// switch.
fn travel(mut next: Next, mut opening: Opening) -> Result<(), Error> {
    let mut trail: Vec<Place> = Vec::new();
    let mut machine: Option<Machine> = None;
    // What to say once the next session shows, like why it didn't go back.
    let mut problem: Option<String> = None;
    // How many times in a row the connection to another machine went or
    // couldn't be made again, while it's tried again.
    let mut tries: u32 = 0;
    loop {
        let (place, ended) = match &mut next {
            Next::Here { name, open } => {
                let Some(Attachment { reader, writer, .. }) =
                    attach_here(name, open.as_deref(), opening)?
                else {
                    return Ok(());
                };
                // Coming back to a machine finds it again, bringing your
                // config as it is then.
                machine = None;
                let place = Place {
                    host: None,
                    session: Some(name.clone()),
                };
                let Some(ended) = show(reader, writer, false, None, problem.take(), false)? else {
                    eprintln!(
                        "greed: the session {name} ended without saying so; its log may say why: {}",
                        log_path(name).display()
                    );
                    return Ok(());
                };
                (place, ended)
            }
            Next::There { host, to, new } => {
                if machine.as_ref().is_none_or(|m| m.host != *host) {
                    machine = Some(Machine::reach(host)?);
                }
                let there = machine.as_ref().expect("just reached");
                match ssh_once(there, to, opening, *new, problem.take(), tries > 0) {
                    Ok((session, Some(ended))) => {
                        tries = 0;
                        let place = Place {
                            host: Some(host.clone()),
                            session: session.or_else(|| to.session.clone()),
                        };
                        (place, ended)
                    }
                    // The connection went: the same session again, after a
                    // while, until it's back or you stop it.
                    Ok((session, None)) => {
                        to.session = session.or_else(|| to.session.take());
                        *new = false;
                        wait_to_retry(host, &mut tries, &mut problem);
                        continue;
                    }
                    Err(err) if tries > 0 && versions::other_version(&err).is_none() => {
                        eprintln!("greed: can't reach {host} yet: {err}");
                        wait_to_retry(host, &mut tries, &mut problem);
                        continue;
                    }
                    Err(err) => {
                        let Some(refused) = versions::other_version(&err) else {
                            return Err(err);
                        };
                        // Another version runs it there: what to do is the
                        // user's to say, and it's done there.
                        match settle_remote(host, &there.greed, &refused)? {
                            Some(beside) => {
                                *new = beside;
                                continue;
                            }
                            None => return Ok(()),
                        }
                    }
                }
            }
        };
        opening = Opening::Nothing;
        // Each place once, the latest last, so going back twice comes back.
        trail.retain(|p| *p != place);
        trail.push(place.clone());
        if trail.len() > TRAIL {
            trail.remove(0);
        }
        next = match ended {
            Output::Switch(to) => {
                let (to, said) = where_to(to, &place, &mut trail)?;
                problem = said;
                to
            }
            Output::Detached => {
                say_detached(&place);
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
            | Output::HomeStatus(_)
            | Output::Notify(_)
            | Output::Ping => return Ok(()),
        };
    }
}

/// Attaches to the session `name` here, asking it to open `open` and
/// `opening`. When another version of greed runs it, you say what to do:
/// `name` becomes the session beside it to attach to instead, or None when
/// you'd rather stop.
fn attach_here(
    name: &mut String,
    open: Option<&Path>,
    opening: Opening,
) -> Result<Option<Attachment>, Error> {
    loop {
        let attached = ctl::connect_to(Some(name))?.attach_opening(client::kind(), open, opening);
        let err: Error = match attached {
            Ok(attachment) => return Ok(Some(attachment)),
            Err(err) => err.into(),
        };
        let Some(refused) = versions::other_version(&err) else {
            return Err(err);
        };
        match settle(name, &refused, open)? {
            Some(beside) => *name = beside,
            None => return Ok(None),
        }
    }
}

/// Waits before trying a connection to `host` again, the `tries`th time,
/// saying so the first time; what to say once it's back goes in `problem`.
fn wait_to_retry(host: &str, tries: &mut u32, problem: &mut Option<String>) {
    if *tries == 0 {
        eprintln!("greed: lost the connection to {host}; trying again (ctrl-c stops)");
    }
    *tries += 1;
    *problem = Some(format!("back on {host} after losing the connection"));
    std::thread::sleep(retry_after(*tries));
}

/// Says how to come back to `place` after letting it go.
fn say_detached(place: &Place) {
    match (&place.host, &place.session) {
        (Some(host), _) => println!("detached; greed ssh {host} comes back"),
        (None, Some(name)) => println!("detached; greed attach {name} comes back"),
        (None, None) => println!("detached"),
    }
}

/// How long to wait before trying a lost connection again for the
/// `tries`th time: longer each time, up to half a minute.
fn retry_after(tries: u32) -> Duration {
    Duration::from_secs(1 << tries.min(5)).min(Duration::from_secs(30))
}

/// Where a switch `to` from `here` goes, with the places the client has been
/// (`trail`, each once, ending with `here`): back to the latest before it,
/// home to the session on this machine it was on last (or the one for this
/// folder), to another machine, or to a session on the same machine as
/// `here`. Also what to tell the user there, as when there's nowhere to go
/// back to.
fn where_to(
    to: SwitchTo,
    here: &Place,
    trail: &mut Vec<Place>,
) -> Result<(Next, Option<String>), Error> {
    // A session here that has ended since is passed over; one on another
    // machine is found (or started) there.
    let live = ctl::live_sessions()?;
    let go = |place: &Place| -> Option<Next> {
        match (&place.host, &place.session) {
            (Some(host), session) => Some(Next::There {
                host: host.clone(),
                to: SwitchTo {
                    session: session.clone(),
                    ..SwitchTo::default()
                },
                new: false,
            }),
            (None, Some(name)) if live.contains(name) => Some(Next::Here {
                name: name.clone(),
                open: None,
            }),
            (None, _) => None,
        }
    };
    if to.back {
        // The latest place before this one; sessions here that ended since
        // are forgotten.
        while trail.len() > 1 {
            let before = trail[trail.len() - 2].clone();
            if let Some(next) = go(&before) {
                return Ok((next, None));
            }
            trail.remove(trail.len() - 2);
        }
        let stay = go(here).ok_or("the session ended")?;
        return Ok((stay, Some("nowhere to go back to".to_owned())));
    }
    if to.home {
        // A session named on this machine, if it runs.
        if let Some(name) = to.session.filter(|name| live.contains(name)) {
            return Ok((Next::Here { name, open: None }, None));
        }
        let last_here = trail.iter().rev().filter(|p| p.host.is_none()).find_map(go);
        if let Some(next) = last_here {
            return Ok((next, None));
        }
        let (name, open) = resolve(&SwitchTo::default())?;
        return Ok((Next::Here { name, open }, None));
    }
    // Anywhere else is on the machine named, or on the one shown.
    if let Some(host) = to.host.clone().or_else(|| here.host.clone()) {
        let to = SwitchTo { host: None, ..to };
        return Ok((
            Next::There {
                host,
                to,
                new: false,
            },
            None,
        ));
    }
    let (name, open) = resolve(&to)?;
    Ok((Next::Here { name, open }, None))
}

/// Asks what to do about the session `name` here, which another version
/// of greed runs (`refused` says which), and does it: the session to
/// attach to then, or None to stop. Opening it with that version replaces
/// this process, which asks it to open `open` too.
fn settle(
    name: &str,
    refused: &control::Refused,
    open: Option<&Path>,
) -> Result<Option<String>, Error> {
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
            Err(other_greed(&greed, name, open, client::kind() == "gui")
                .exec()
                .into())
        }
        Choice::Cancel => Ok(None),
    }
}

/// The command for `greed`, another version, to show session `name`,
/// opening `open` there, in a window with `gui`.
fn other_greed(greed: &Path, name: &str, open: Option<&Path>, gui: bool) -> Command {
    let mut command = Command::new(greed);
    // Every version takes `--session NAME FILE`; `attach` takes no file.
    match open {
        Some(open) => command.args(["--session", name]).arg(open),
        None => command.args(["attach", name]),
    };
    if gui {
        command.arg("--gui");
    }
    command
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

/// Milliseconds since `started`.
fn millis_since(started: Instant) -> u64 {
    u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX)
}

/// Shows an attached session in this terminal: input goes to `writer` and
/// frames come from `reader`, one JSON message per line, from a session on
/// another machine with `remote`. The session's requests for your ssh agent
/// go to `agent`, the one this client relays. `problem` goes on its status
/// line. With `heartbeat`, as the session agreed to as this client
/// attached, both say they're there every few seconds. Returns how it
/// ended, or None when the connection went without the session saying so:
/// it closed, or with a heartbeat, nothing came for a while.
fn show(
    reader: impl BufRead + Send + 'static,
    mut writer: impl Write + Send + 'static,
    remote: bool,
    agent: Option<PathBuf>,
    problem: Option<String>,
    heartbeat: bool,
) -> Result<Option<Output>, Error> {
    client::set_remote(remote);
    let (input, inputs) = crossbeam_channel::unbounded::<Input>();
    if let Some(problem) = problem {
        let _ = input.send(Input::Problem(problem));
    }
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
    // When the session was last heard from, and whether the connection
    // went without it saying how things ended.
    let started = Instant::now();
    let heard = Arc::new(AtomicU64::new(0));
    let lost = Arc::new(AtomicBool::new(false));
    // Whether this run is over, for the heartbeat to stop.
    let over = Arc::new(AtomicBool::new(false));
    if heartbeat {
        let (input, outputs, heard, lost, over) = (
            input.clone(),
            outputs.clone(),
            heard.clone(),
            lost.clone(),
            over.clone(),
        );
        std::thread::spawn(move || {
            while !over.load(Ordering::Relaxed) {
                std::thread::sleep(control::HEARTBEAT);
                let since = millis_since(started) - heard.load(Ordering::Relaxed);
                if Duration::from_millis(since) > control::HEARTBEAT_LOST {
                    lost.store(true, Ordering::Relaxed);
                    let _ = outputs.send(Output::Exit);
                    return;
                }
                if input.send(Input::Ping).is_err() {
                    return;
                }
            }
        });
    }
    let replies = input.clone();
    // Whether the agent's last failure was said, so a burst of requests
    // says it once, and again only after it answered in between.
    let failure_said = Arc::new(AtomicBool::new(false));
    let reading_lost = lost.clone();
    std::thread::spawn(move || {
        // Whether the session said how this ends, before the connection did.
        let mut said_end = false;
        for line in reader.lines() {
            let Ok(line) = line else { break };
            heard.store(millis_since(started), Ordering::Relaxed);
            // One this client can't read, as from a newer session, is left
            // out; a frame or delta left out makes the next delta not fit,
            // and the client asks for a whole frame.
            let message = match serde_json::from_str::<Output>(&line) {
                Ok(Output::Ping) => continue,
                Ok(message) => message,
                Err(err) => {
                    let said = format!("couldn't read a message from the session: {err}");
                    let _ = replies.send(Input::Log(said));
                    continue;
                }
            };
            let Some(message) = answer_here(message, agent.as_ref(), &replies, &failure_said)
            else {
                continue;
            };
            said_end |= message.ends();
            if outputs.send(message).is_err() {
                return;
            }
        }
        if !said_end {
            reading_lost.store(true, Ordering::Relaxed);
            let _ = outputs.send(Output::Exit);
        }
    });
    let ended = crate::client::run(&input, &output);
    over.store(true, Ordering::Relaxed);
    let ended = ended?;
    Ok(if lost.load(Ordering::Relaxed) {
        None
    } else {
        Some(ended)
    })
}

/// Answers what the session asks this client to find out on its own
/// machine, off the reading thread, sending the answer on `replies`: a
/// request for your ssh agent (to `agent`; `failure_said` keeps a burst of
/// failures to one word on the status line), or what the hub here says.
/// Gives back any other message, for the client.
fn answer_here(
    message: Output,
    agent: Option<&PathBuf>,
    replies: &crossbeam_channel::Sender<Input>,
    failure_said: &Arc<AtomicBool>,
) -> Option<Output> {
    match message {
        Output::HomeStatus(id) => {
            let replies = replies.clone();
            std::thread::spawn(move || {
                let status = ctl::hub()
                    .ok()
                    .and_then(|hub| control::status_of(&hub, control::STATUS_WAIT).ok());
                let _ = replies.send(Input::HomeStatus(id, status));
            });
            None
        }
        // A key touch can take a while.
        Output::SshAgentRequest(id, body) => {
            let (agent, replies, failure_said) =
                (agent.cloned(), replies.clone(), failure_said.clone());
            std::thread::spawn(move || {
                let answer = greed_core::ssh_agent::ask_base64(agent.as_deref(), &body);
                // Why it failed goes on the status line, rather than only
                // "agent refused operation" in the program.
                match &answer {
                    Ok(_) => failure_said.store(false, Ordering::Relaxed),
                    Err(why) if !failure_said.swap(true, Ordering::Relaxed) => {
                        let _ = replies.send(Input::Problem(why.clone()));
                    }
                    Err(_) => {}
                }
                let _ = replies.send(Input::SshAgentReply(id, answer.ok()));
            });
            None
        }
        other => Some(other),
    }
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
/// beside it, and follows the client wherever it goes from there.
/// `$GREED_SSH` replaces the ssh command and `$GREED_REMOTE` the greed on
/// the other end.
pub fn ssh(
    host: &str,
    name: Option<&str>,
    file: Option<&str>,
    opening: Opening,
    new: bool,
) -> Result<(), Error> {
    let to = SwitchTo {
        session: name.map(str::to_owned),
        path: file.map(str::to_owned),
        ..SwitchTo::default()
    };
    travel(
        Next::There {
            host: host.to_owned(),
            to,
            new,
        },
        opening,
    )
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
    let mut out = Vec::new();
    remote_run_into(host, line, &mut out)?;
    Ok(String::from_utf8_lossy(&out).into_owned())
}

/// [`remote_run`], passing what it prints on to `out` as it comes.
fn remote_run_into(host: &str, line: &str, out: &mut impl Write) -> Result<(), Error> {
    let (mut child, input, mut output) = remote(host, line)?;
    // The shell there ends after the line once its input does.
    drop(input);
    std::io::copy(&mut output, out)?;
    if !child.wait()?.success() {
        return Err(format!("{line} failed on {host}").into());
    }
    Ok(())
}

/// Whether ssh may ask anything (a password, a new host key): not for
/// `greed ssh HOST ctl`, which programs run.
static NO_QUESTIONS: AtomicBool = AtomicBool::new(false);

/// `greed ssh HOST ctl ARGS`: `greed ctl ARGS` on `host`, with the greed
/// `greed ssh` uses there (put there if it isn't), printing what it prints
/// as it does. ssh asks nothing, so it fails rather than waits when it
/// would have to, as a program like a hub following another machine needs.
pub fn ssh_ctl(host: &str, args: &[String]) -> Result<(), Error> {
    NO_QUESTIONS.store(true, Ordering::Relaxed);
    let greed = remote_greed(host)?;
    let mut line = format!("exec {} ctl", quote(&greed));
    for arg in args {
        line.push(' ');
        line.push_str(&quote(arg));
    }
    remote_run_into(host, &line, &mut std::io::stdout().lock())
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

/// Shows the session `to` points at on `machine` until it ends, lets go or
/// switches; returns the session's name, when its greed says it, and which
/// of those it was, or None when the connection went without the session
/// saying so. With an agent to relay, an ssh agent's socket here, it
/// relays that agent to the session, which then has one way to it: ssh's
/// own forwarding is off. `problem` goes on its status line once it shows.
/// Coming back after a lost connection (`again`), ssh gives up connecting
/// sooner, to try again.
fn ssh_once(
    machine: &Machine,
    to: &SwitchTo,
    opening: Opening,
    new: bool,
    problem: Option<String>,
    again: bool,
) -> Result<(Option<String>, Option<Output>), Error> {
    let Machine {
        host,
        config,
        greed,
        agent,
    } = machine;
    let line = bridge_command(greed, to, config.as_deref(), new);
    let attach_failed = |err: Error| -> Error {
        // Another version there is for the caller to ask about.
        if versions::other_version(&err).is_some() {
            return err;
        }
        format!("couldn't attach on {host}: {err}").into()
    };
    let mut options: Vec<&str> = Vec::new();
    if agent.is_some() {
        options.extend(["-o", "ForwardAgent=no"]);
    }
    if again {
        options.extend(["-o", "ConnectTimeout=15"]);
    }
    let (mut child, mut writer, mut reader) =
        remote_with(host, &options, &line).map_err(attach_failed)?;
    let (session, heartbeat) = handshake(
        &mut reader,
        &mut writer,
        to.session.as_deref(),
        opening,
        agent.is_some(),
    )
    .map_err(attach_failed)?;
    remember_host(host);
    let ended = show(reader, writer, true, agent.clone(), problem, heartbeat)?;
    // The session lives on the other end, so closing ssh loses nothing,
    // and the bridge there goes when its input does.
    let _ = child.kill();
    let _ = child.wait();
    Ok((session, ended))
}

/// Notes in Greed's data folder that you reached `host` now (`ssh-hosts`:
/// JSON, each host with when, in seconds since 1970), so this machine's hub
/// follows the hub there; the hub plugin reads it. Not noted if it can't be.
fn remember_host(host: &str) {
    let Some(data) = greed_core::dirs::dir(greed_core::dirs::Kind::Data) else {
        return;
    };
    let file = data.join("ssh-hosts");
    let mut hosts: serde_json::Map<String, Value> = std::fs::read_to_string(&file)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_secs());
    hosts.insert(host.to_owned(), now.into());
    let _ = std::fs::create_dir_all(&data);
    let _ = std::fs::write(&file, Value::Object(hosts).to_string());
}

/// Asks to attach over `reader` and `writer`, already connected to the
/// session `session` (or whichever the other end picks), with a heartbeat,
/// since ssh can go quiet without closing. Fails with the session's reason
/// if it refuses, e.g. because the two ends run greed versions that don't
/// speak the same protocol. It answers for the hub on this machine
/// (`Output::HomeStatus`), and with `agent` says it relays your ssh agent.
/// Returns the session's name, when its greed says, and whether it agreed
/// to the heartbeat (an older one doesn't know it).
fn handshake(
    reader: &mut impl BufRead,
    writer: &mut impl Write,
    session: Option<&str>,
    opening: Opening,
    agent: bool,
) -> Result<(Option<String>, bool), Error> {
    let mut params = control::attach_params(client::kind());
    opening.ask(&mut params);
    params["heartbeat"] = Value::Bool(true);
    params["home"] = Value::Bool(true);
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
    let result = &response["result"];
    Ok((
        result["session"].as_str().map(str::to_owned),
        result["heartbeat"].as_bool() == Some(true),
    ))
}

/// The ssh command, which `$GREED_SSH` replaces.
fn ssh_command() -> Command {
    let mut command = Command::new(std::env::var("GREED_SSH").unwrap_or_else(|_| "ssh".to_owned()));
    if NO_QUESTIONS.load(Ordering::Relaxed) {
        command.args(["-o", "BatchMode=yes"]);
    }
    command
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
            ..SwitchTo::default()
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
        let plain = SwitchTo::default();
        assert_eq!(
            bridge_command("/opt/greed", &plain, None, false),
            "exec '/opt/greed' 'bridge'"
        );
    }

    #[test]
    fn another_version_is_asked_to_open_the_file_too() {
        let args = |open: Option<&str>, gui| -> Vec<String> {
            other_greed(Path::new("/old/greed"), "app", open.map(Path::new), gui)
                .get_args()
                .map(|arg| arg.to_string_lossy().into_owned())
                .collect()
        };
        assert_eq!(
            args(Some("/app/new.md"), false),
            ["--session", "app", "/app/new.md"]
        );
        assert_eq!(args(None, false), ["attach", "app"]);
        assert_eq!(args(None, true), ["attach", "app", "--gui"]);
    }
}
