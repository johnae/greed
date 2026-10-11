//! `greed.process`: running other programs. `run` runs one to the end,
//! like a formatter or `jj`, waiting for it on another thread so the editor
//! keeps going. `spawn` starts one to talk to over its input and output,
//! like an agent speaking JSON-RPC.

use std::collections::{HashMap, VecDeque};
use std::io::{Read, Write};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, RecvTimeoutError, Sender};
use mlua::{Function, IntoLuaMulti, Lua, Table};
use nix::sys::signal::Signal;
use nix::unistd::Pid;

use super::jobs::{self, Output};
use super::{state, state_mut, tasks};
use crate::registry::PluginId;

type LuaResult<T> = mlua::Result<T>;

/// What a program did: how it exited and what it printed.
pub struct Finished {
    pub code: Option<i32>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

/// How to run a program: its command line, its input, its folder and the
/// variables it gets besides the editor's.
struct Run {
    command: Vec<String>,
    stdin: Option<Vec<u8>>,
    cwd: Option<String>,
    env: Vec<(String, Option<String>)>,
}

/// Why `program` didn't start, naming it.
fn cant_run(program: &str, err: &std::io::Error) -> std::io::Error {
    std::io::Error::new(err.kind(), format!("can't run {program}: {err}"))
}

fn run(how: Run) -> std::io::Result<Finished> {
    let (program, args) = how
        .command
        .split_first()
        .ok_or_else(|| std::io::Error::other("an empty command line"))?;
    let mut command = Command::new(program);
    command
        .args(args)
        .stdin(if how.stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(cwd) = &how.cwd {
        command.current_dir(cwd);
    }
    for (name, value) in &how.env {
        match value {
            Some(value) => command.env(name, value),
            None => command.env_remove(name),
        };
    }
    let mut child = command.spawn().map_err(|err| cant_run(program, &err))?;
    if let (Some(input), Some(mut stdin)) = (how.stdin, child.stdin.take()) {
        // Written on its own thread, so a program that prints while it reads
        // can't fill a pipe and stall both ends.
        std::thread::spawn(move || {
            let _ = stdin.write_all(&input);
        });
    }
    let out = child.wait_with_output()?;
    Ok(Finished {
        code: out.status.code(),
        stdout: out.stdout,
        stderr: out.stderr,
    })
}

/// A program's `env` option: each name to a string to set it, or `false` to
/// leave the variable out of what it inherits.
pub(super) fn env_from_lua(
    lua: &Lua,
    env: Option<Table>,
) -> LuaResult<Vec<(String, Option<String>)>> {
    let mut out = super::testing::child_env(lua);
    let Some(env) = env else {
        return Ok(out);
    };
    let given = env
        .pairs::<String, mlua::Value>()
        .map(|pair| {
            let (name, value) = pair?;
            match value {
                mlua::Value::String(s) => Ok((name, Some(s.to_str()?.to_owned()))),
                mlua::Value::Boolean(false) => Ok((name, None)),
                other => Err(mlua::Error::runtime(format!(
                    "env.{name} is a {}; give a string, or false to unset it",
                    other.type_name()
                ))),
            }
        })
        .collect::<LuaResult<Vec<_>>>()?;
    // The program's own say comes after, so it wins.
    out.extend(given);
    Ok(out)
}

fn run_from_lua(lua: &Lua, command: Vec<String>, opts: Option<&Table>) -> LuaResult<Run> {
    let (stdin, cwd) = match opts {
        Some(opts) => (
            opts.get::<Option<mlua::LuaString>>("stdin")?
                .map(|s| s.as_bytes().to_vec()),
            opts.get("cwd")?,
        ),
        None => (None, None),
    };
    Ok(Run {
        command,
        stdin,
        cwd,
        env: super::testing::child_env(lua),
    })
}

/// `{ code, stdout, stderr }` for a program that ran, or `nil, error` for
/// one that couldn't start.
pub(super) fn to_lua(lua: &Lua, result: std::io::Result<Finished>) -> LuaResult<mlua::MultiValue> {
    match result {
        Ok(done) => {
            let table = lua.create_table()?;
            table.set("code", done.code)?;
            table.set("stdout", lua.create_string(&done.stdout)?)?;
            table.set("stderr", lua.create_string(&done.stderr)?)?;
            table.into_lua_multi(lua)
        }
        Err(err) => (mlua::Value::Nil, err.to_string()).into_lua_multi(lua),
    }
}

pub(super) fn module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let process = lua.create_table()?;
    let start = lua.create_function(|lua, (command, opts): (Vec<String>, Option<Table>)| {
        let how = run_from_lua(lua, command, opts.as_ref())?;
        Ok(jobs::start(
            lua,
            format!("greed.process.run {}", how.command.join(" ")),
            move || Output::Process(run(how)),
        ))
    })?;
    process.set("run", jobs::waiting(lua, "greed.process.run", start)?)?;
    let owner = owner.clone();
    process.set(
        "spawn",
        lua.create_function(move |lua, (command, opts): (Vec<String>, Option<Table>)| {
            spawn(lua, &owner, &command, opts.as_ref())
        })?,
    )?;
    Ok(process)
}

/// Which of a program's outputs a piece came from.
#[derive(Clone, Copy)]
pub(crate) enum Stream {
    Stdout,
    Stderr,
}

impl Stream {
    fn name(self) -> &'static str {
        match self {
            Stream::Stdout => "stdout",
            Stream::Stderr => "stderr",
        }
    }
}

/// What a running program's threads send: a piece of what it printed, or
/// how it exited: its code, or the signal that ended it.
pub(crate) enum Piece {
    Out(Stream, Vec<u8>),
    Exited {
        code: Option<i32>,
        signal: Option<i32>,
    },
}

/// The most of a program's error output kept, from the end.
const STDERR_KEPT: usize = 64 * 1024;

/// A program started with `spawn`, talking over its input and output.
struct Child {
    owner: PluginId,
    /// Where its input goes, until closed.
    stdin: Option<Sender<Vec<u8>>>,
    /// What it printed and nobody read yet.
    queue: VecDeque<(Stream, Vec<u8>)>,
    /// The command waiting for the next piece, and those waiting for it to
    /// exit.
    reader: Option<u64>,
    waiting: Vec<u64>,
    /// Whether it exited, and its code or the signal that ended it.
    exited: bool,
    code: Option<i32>,
    signal: Option<&'static str>,
    process: Arc<Mutex<std::process::Child>>,
    /// Whether it leads a process group of its own, which signals go to.
    group: bool,
    stderr: Arc<Mutex<Vec<u8>>>,
}

impl Child {
    /// Sends `signal` to the program, or with `group` to its process group,
    /// as a shell signals a job: what's left of the group, even once the
    /// program itself has gone. Returns whether it went.
    fn signal(&self, signal: Signal) -> bool {
        let Ok(mut process) = self.process.lock() else {
            return false;
        };
        let Ok(pid) = i32::try_from(process.id()) else {
            return false;
        };
        let pid = Pid::from_raw(pid);
        if self.group {
            return nix::sys::signal::killpg(pid, signal).is_ok();
        }
        // Holding the lock, the program can't be reaped meanwhile, so its
        // id can't go to another.
        matches!(process.try_wait(), Ok(None)) && nix::sys::signal::kill(pid, signal).is_ok()
    }
}

impl Drop for Child {
    fn drop(&mut self) {
        if !self.exited || self.group {
            self.signal(Signal::SIGKILL);
        }
    }
}

/// The signal named `name`, like "INT" or "SIGINT".
fn signal_named(name: &str) -> LuaResult<Signal> {
    let upper = name.to_ascii_uppercase();
    let full = if upper.starts_with("SIG") {
        upper
    } else {
        format!("SIG{upper}")
    };
    full.parse().map_err(|_| {
        mlua::Error::runtime(format!(
            "{name:?} isn't a signal; give one like \"INT\", \"TERM\" or \"KILL\""
        ))
    })
}

/// The name of signal number `number`, like "INT".
fn signal_name(number: i32) -> Option<&'static str> {
    let signal = Signal::try_from(number).ok()?;
    Some(signal.as_str().trim_start_matches("SIG"))
}

/// Programs started with `spawn`, by id.
#[derive(Default)]
pub(crate) struct Children {
    next: u64,
    open: HashMap<u64, Child>,
}

impl Children {
    /// Ends the programs plugin `name` started.
    pub fn remove_owned_by(&mut self, name: &str) {
        self.open.retain(|_, child| &*child.owner != name);
    }
}

/// A program `start_child` started.
struct Started {
    pid: u32,
    stdin: Sender<Vec<u8>>,
    process: Arc<Mutex<std::process::Child>>,
    stderr: Arc<Mutex<Vec<u8>>>,
}

/// How `spawn` starts a program, besides its command line.
#[derive(Default)]
struct SpawnOptions {
    cwd: Option<String>,
    env: Vec<(String, Option<String>)>,
    /// Whether its error output arrives as pieces too, not only kept.
    stream_stderr: bool,
    /// Whether it starts a process group of its own.
    group: bool,
}

/// How long the end of a program's output may take to arrive once it has
/// exited. Something it started can hold its output open for longer.
const OUTPUT_AFTER_EXIT: Duration = Duration::from_secs(1);

/// Starts `command` with piped input and output, and threads that write
/// its input, read its output (sending each piece with `send`), keep the
/// end of its error output and wait for it to exit.
fn start_child(
    command: &[String],
    options: &SpawnOptions,
    send: impl Fn(Piece) + Send + Sync + 'static,
) -> std::io::Result<Started> {
    let (program, args) = command
        .split_first()
        .ok_or_else(|| std::io::Error::other("an empty command line"))?;
    let mut builder = Command::new(program);
    builder
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (name, value) in &options.env {
        match value {
            Some(value) => builder.env(name, value),
            None => builder.env_remove(name),
        };
    }
    if let Some(cwd) = &options.cwd {
        builder.current_dir(cwd);
    }
    if options.group {
        builder.process_group(0);
    }
    let mut child = builder.spawn().map_err(|err| cant_run(program, &err))?;
    let pid = child.id();
    let (mut stdin, mut stdout, mut stderr) = (
        child.stdin.take().expect("piped"),
        child.stdout.take().expect("piped"),
        child.stderr.take().expect("piped"),
    );
    let process = Arc::new(Mutex::new(child));
    let (input, inputs) = crossbeam_channel::unbounded::<Vec<u8>>();
    std::thread::spawn(move || {
        // Ends when the sender goes, which closes the program's input.
        for bytes in inputs {
            if stdin
                .write_all(&bytes)
                .and_then(|()| stdin.flush())
                .is_err()
            {
                break;
            }
        }
    });
    let send = Arc::new(send);
    let kept = Arc::new(Mutex::new(Vec::new()));
    let errors = kept.clone();
    // Each dropped when all of that output is read.
    let (stderr_reading, stderr_read) = crossbeam_channel::bounded::<()>(0);
    let (stdout_reading, stdout_read) = crossbeam_channel::bounded::<()>(0);
    let stream_stderr = options.stream_stderr;
    let sender = send.clone();
    std::thread::spawn(move || {
        let _reading = stderr_reading;
        let mut buffer = [0; 4096];
        while let Ok(n @ 1..) = stderr.read(&mut buffer) {
            if let Ok(mut kept) = errors.lock() {
                kept.extend_from_slice(&buffer[..n]);
                let over = kept.len().saturating_sub(STDERR_KEPT);
                kept.drain(..over);
            }
            if stream_stderr {
                sender(Piece::Out(Stream::Stderr, buffer[..n].to_vec()));
            }
        }
    });
    let sender = send.clone();
    std::thread::spawn(move || {
        let _reading = stdout_reading;
        let mut buffer = vec![0; 16 * 1024];
        while let Ok(n @ 1..) = stdout.read(&mut buffer) {
            sender(Piece::Out(Stream::Stdout, buffer[..n].to_vec()));
        }
    });
    let watched = process.clone();
    std::thread::spawn(move || {
        let status = wait_for_exit(&watched, &stdout_read);
        // What it said last is there when its exit is, unless something it
        // started keeps its output open.
        let until = Instant::now() + OUTPUT_AFTER_EXIT;
        let _ = stdout_read.recv_deadline(until);
        let _ = stderr_read.recv_deadline(until);
        send(Piece::Exited {
            code: status.and_then(|s| s.code()),
            signal: status.and_then(|s| s.signal()),
        });
    });
    Ok(Started {
        pid,
        stdin: input,
        process,
        stderr: kept,
    })
}

/// Waits for the program to exit, taking its lock only to look, so it can
/// be signalled meanwhile. Most programs close their output as they exit,
/// so once that's closed it looks often; before, less and less often.
fn wait_for_exit(
    process: &Mutex<std::process::Child>,
    output_closed: &Receiver<()>,
) -> Option<std::process::ExitStatus> {
    const OFTEN: Duration = Duration::from_millis(20);
    const SELDOM: Duration = Duration::from_millis(500);
    let mut pause = OFTEN;
    loop {
        match process.lock().map(|mut p| p.try_wait()) {
            Ok(Ok(Some(status))) => return Some(status),
            Ok(Ok(None)) => {}
            _ => return None,
        }
        match output_closed.recv_timeout(pause) {
            Err(RecvTimeoutError::Disconnected) => std::thread::sleep(OFTEN),
            _ => pause = (pause * 2).min(SELDOM),
        }
    }
}

/// A piece of what program `id` printed, or its exit, arrived: the command
/// waiting gets it, or it waits for the next read.
pub(super) fn piece_arrived(lua: &Lua, id: u64, piece: Piece) -> LuaResult<()> {
    let wake: Vec<(u64, mlua::MultiValue)> = {
        let mut state = state_mut(lua);
        let Some(child) = state.children.open.get_mut(&id) else {
            return Ok(());
        };
        match piece {
            Piece::Out(stream, bytes) => {
                if let Some(token) = child.reader.take() {
                    let piece = (lua.create_string(&bytes)?, stream.name());
                    vec![(token, piece.into_lua_multi(lua)?)]
                } else {
                    child.queue.push_back((stream, bytes));
                    vec![]
                }
            }
            Piece::Exited { code, signal } => {
                child.exited = true;
                child.code = code;
                child.signal = signal.and_then(signal_name);
                let mut wake = Vec::new();
                for token in child.waiting.drain(..) {
                    wake.push((token, (code, child.signal).into_lua_multi(lua)?));
                }
                if let Some(token) = child.reader.take() {
                    wake.push((token, mlua::Value::Nil.into_lua_multi(lua)?));
                }
                wake
            }
        }
    };
    for (token, values) in wake {
        tasks::wake(lua, token, values)?;
    }
    Ok(())
}

/// Whether code waits on a program that's still running.
pub(super) fn awaited(lua: &Lua) -> bool {
    state(lua)
        .children
        .open
        .values()
        .any(|child| !child.exited && (child.reader.is_some() || !child.waiting.is_empty()))
}

/// What `read` gives now: `true`, a piece and the output it came from, or
/// `true` and nil once the program exited with nothing left to read;
/// otherwise `false` and the token the next piece wakes.
fn read_now(lua: &Lua, id: u64) -> LuaResult<mlua::MultiValue> {
    let mut state = state_mut(lua);
    let state = &mut *state;
    let Some(child) = state.children.open.get_mut(&id) else {
        return (true, mlua::Value::Nil).into_lua_multi(lua);
    };
    if let Some((stream, bytes)) = child.queue.pop_front() {
        return (true, lua.create_string(&bytes)?, stream.name()).into_lua_multi(lua);
    }
    if child.exited {
        return (true, mlua::Value::Nil).into_lua_multi(lua);
    }
    let token = state.tasks.token();
    child.reader = Some(token);
    (false, token).into_lua_multi(lua)
}

/// How program `id` exited if it has: `true`, its code and the signal that
/// ended it; otherwise `false` and the token its exit wakes.
fn wait_now(lua: &Lua, id: u64) -> LuaResult<mlua::MultiValue> {
    let mut state = state_mut(lua);
    let state = &mut *state;
    let Some(child) = state.children.open.get_mut(&id) else {
        return (true, mlua::Value::Nil).into_lua_multi(lua);
    };
    if child.exited {
        return (true, child.code, child.signal).into_lua_multi(lua);
    }
    let token = state.tasks.token();
    child.waiting.push(token);
    (false, token).into_lua_multi(lua)
}

/// A Luau function that calls `now`, and waits for the token it gives when
/// it isn't ready. It's a child's method, which `handles::methods` wraps,
/// so its errors point two calls up.
fn waiting_call(lua: &Lua, name: &str, now: Function) -> LuaResult<Function> {
    lua.load(
        r"
        local name, now = ...
        return function()
            local ready, a, b = now()
            if ready then
                return a, b
            end
            if not coroutine.isyieldable() then
                error(name .. ' waits, so it only works in a command, an event handler or greed.spawn', 3)
            end
            return coroutine.yield(a)
        end
        ",
    )
    .set_name(format!("={name}"))
    .call((name, now))
}

/// The table a plugin talks to program `id` through.
fn child_to_lua(lua: &Lua, id: u64, pid: u32) -> LuaResult<Table> {
    let child = lua.create_table()?;
    child.set("pid", pid)?;
    child.set(
        "write",
        lua.create_function(move |lua, text: mlua::LuaString| {
            let state = state(lua);
            let sent = state
                .children
                .open
                .get(&id)
                .and_then(|child| child.stdin.as_ref())
                .is_some_and(|stdin| stdin.send(text.as_bytes().to_vec()).is_ok());
            Ok(sent)
        })?,
    )?;
    child.set(
        "close",
        lua.create_function(move |lua, ()| {
            if let Some(child) = state_mut(lua).children.open.get_mut(&id) {
                child.stdin = None;
            }
            Ok(())
        })?,
    )?;
    child.set(
        "kill",
        lua.create_function(move |lua, ()| {
            if let Some(child) = state(lua).children.open.get(&id) {
                child.signal(Signal::SIGKILL);
            }
            Ok(())
        })?,
    )?;
    child.set(
        "signal",
        lua.create_function(move |lua, name: String| {
            let signal = signal_named(&name)?;
            Ok(state(lua)
                .children
                .open
                .get(&id)
                .is_some_and(|child| child.signal(signal)))
        })?,
    )?;
    child.set(
        "stderr",
        lua.create_function(move |lua, ()| {
            let state = state(lua);
            match state
                .children
                .open
                .get(&id)
                .and_then(|child| child.stderr.lock().ok())
            {
                Some(kept) => lua.create_string(&*kept),
                None => lua.create_string(""),
            }
        })?,
    )?;
    let read = lua.create_function(move |lua, ()| read_now(lua, id))?;
    child.set("read", waiting_call(lua, "child.read", read)?)?;
    let wait = lua.create_function(move |lua, ()| wait_now(lua, id))?;
    child.set("wait", waiting_call(lua, "child.wait", wait)?)?;
    super::handles::methods(lua, child)
}

fn spawn(
    lua: &Lua,
    owner: &PluginId,
    command: &[String],
    opts: Option<&Table>,
) -> LuaResult<mlua::MultiValue> {
    let options = match opts {
        Some(opts) => SpawnOptions {
            cwd: opts.get("cwd")?,
            env: env_from_lua(lua, opts.get("env")?)?,
            stream_stderr: match opts.get::<Option<String>>("stderr")?.as_deref() {
                None | Some("keep") => false,
                Some("stream") => true,
                Some(other) => {
                    return Err(mlua::Error::runtime(format!(
                        "stderr = {other:?}: give \"keep\" or \"stream\""
                    )));
                }
            },
            group: opts.get::<Option<bool>>("group")?.unwrap_or(false),
        },
        None => SpawnOptions {
            env: env_from_lua(lua, None)?,
            ..SpawnOptions::default()
        },
    };
    let id = {
        let mut state = state_mut(lua);
        state.children.next += 1;
        state.children.next
    };
    let sender = jobs::sender(lua);
    let started = start_child(command, &options, move |piece| {
        let _ = sender.send(jobs::Done::uncounted(Output::Child(id, piece)));
    });
    match started {
        Ok(started) => {
            state_mut(lua).children.open.insert(
                id,
                Child {
                    owner: owner.clone(),
                    stdin: Some(started.stdin),
                    queue: VecDeque::new(),
                    reader: None,
                    waiting: Vec::new(),
                    exited: false,
                    code: None,
                    signal: None,
                    process: started.process,
                    group: options.group,
                    stderr: started.stderr,
                },
            );
            child_to_lua(lua, id, started.pid)?.into_lua_multi(lua)
        }
        Err(err) => (mlua::Value::Nil, err.to_string()).into_lua_multi(lua),
    }
}
