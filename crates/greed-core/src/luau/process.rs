//! `greed.process`: running other programs. `run` runs one to the end,
//! like a formatter or `jj`, waiting for it on another thread so the editor
//! keeps going. `spawn` starts one to talk to over its input and output,
//! like an agent speaking JSON-RPC.

use std::collections::{HashMap, VecDeque};
use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};

use crossbeam_channel::Sender;
use mlua::{Function, IntoLuaMulti, Lua, Table};

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

/// How to run a program: its command line, its input and its folder.
struct Run {
    command: Vec<String>,
    stdin: Option<Vec<u8>>,
    cwd: Option<String>,
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
pub(super) fn env_from_lua(env: Option<Table>) -> LuaResult<Vec<(String, Option<String>)>> {
    let Some(env) = env else {
        return Ok(Vec::new());
    };
    env.pairs::<String, mlua::Value>()
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
        .collect()
}

fn run_from_lua(command: Vec<String>, opts: Option<&Table>) -> LuaResult<Run> {
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
        let how = run_from_lua(command, opts.as_ref())?;
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

/// What a running program's reader thread sends: a piece of what it
/// printed, or how it exited once it closed its output.
pub(crate) enum Piece {
    Out(Vec<u8>),
    Exited(Option<i32>),
}

/// The most of a program's error output kept, from the end.
const STDERR_KEPT: usize = 64 * 1024;

/// A program started with `spawn`, talking over its input and output.
struct Child {
    owner: PluginId,
    /// Where its input goes, until closed.
    stdin: Option<Sender<Vec<u8>>>,
    /// What it printed and nobody read yet.
    queue: VecDeque<Vec<u8>>,
    /// The command waiting for the next piece, and those waiting for it to
    /// exit.
    reader: Option<u64>,
    waiting: Vec<u64>,
    /// Whether it exited, and its code if it had one.
    exited: bool,
    code: Option<i32>,
    process: Arc<Mutex<std::process::Child>>,
    stderr: Arc<Mutex<Vec<u8>>>,
}

impl Child {
    fn kill(&self) {
        if let Ok(mut process) = self.process.lock() {
            let _ = process.kill();
        }
    }
}

impl Drop for Child {
    fn drop(&mut self) {
        if !self.exited {
            self.kill();
        }
    }
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

/// Starts `command` with piped input and output, and threads that write
/// its input, read its output (sending each piece with `send`) and keep the
/// end of its error output.
fn start_child(
    command: &[String],
    cwd: Option<&str>,
    env: &HashMap<String, String>,
    send: impl Fn(Piece) + Send + 'static,
) -> std::io::Result<Started> {
    let (program, args) = command
        .split_first()
        .ok_or_else(|| std::io::Error::other("an empty command line"))?;
    let mut builder = Command::new(program);
    builder
        .args(args)
        .envs(env)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(cwd) = cwd {
        builder.current_dir(cwd);
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
    let kept = Arc::new(Mutex::new(Vec::new()));
    let errors = kept.clone();
    // Dropped when all the error output is read.
    let (reading, read) = crossbeam_channel::bounded::<()>(0);
    std::thread::spawn(move || {
        let _reading = reading;
        let mut buffer = [0; 4096];
        while let Ok(n @ 1..) = stderr.read(&mut buffer) {
            if let Ok(mut kept) = errors.lock() {
                kept.extend_from_slice(&buffer[..n]);
                let over = kept.len().saturating_sub(STDERR_KEPT);
                kept.drain(..over);
            }
        }
    });
    let watched = process.clone();
    std::thread::spawn(move || {
        let mut buffer = vec![0; 16 * 1024];
        while let Ok(n @ 1..) = stdout.read(&mut buffer) {
            send(Piece::Out(buffer[..n].to_vec()));
        }
        let code = loop {
            match watched.lock().map(|mut p| p.try_wait()) {
                Ok(Ok(Some(status))) => break status.code(),
                Ok(Ok(None)) => std::thread::sleep(std::time::Duration::from_millis(20)),
                _ => break None,
            }
        };
        // What it said last is there when its exit is, unless something it
        // started keeps its error output open.
        let _ = read.recv_timeout(std::time::Duration::from_secs(1));
        send(Piece::Exited(code));
    });
    Ok(Started {
        pid,
        stdin: input,
        process,
        stderr: kept,
    })
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
            Piece::Out(bytes) => {
                if let Some(token) = child.reader.take() {
                    vec![(token, lua.create_string(&bytes)?.into_lua_multi(lua)?)]
                } else {
                    child.queue.push_back(bytes);
                    vec![]
                }
            }
            Piece::Exited(code) => {
                child.exited = true;
                child.code = code;
                let mut wake = Vec::new();
                for token in child.waiting.drain(..) {
                    wake.push((token, code.into_lua_multi(lua)?));
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

/// What `read` gives now: `true` and a piece, or `true` and nil once the
/// program exited with nothing left to read; otherwise `false` and the
/// token the next piece wakes.
fn read_now(lua: &Lua, id: u64) -> LuaResult<mlua::MultiValue> {
    let mut state = state_mut(lua);
    let state = &mut *state;
    let Some(child) = state.children.open.get_mut(&id) else {
        return (true, mlua::Value::Nil).into_lua_multi(lua);
    };
    if let Some(bytes) = child.queue.pop_front() {
        return (true, lua.create_string(&bytes)?).into_lua_multi(lua);
    }
    if child.exited {
        return (true, mlua::Value::Nil).into_lua_multi(lua);
    }
    let token = state.tasks.token();
    child.reader = Some(token);
    (false, token).into_lua_multi(lua)
}

/// How program `id` exited if it has: `true` and its code; otherwise
/// `false` and the token its exit wakes.
fn wait_now(lua: &Lua, id: u64) -> LuaResult<mlua::MultiValue> {
    let mut state = state_mut(lua);
    let state = &mut *state;
    let Some(child) = state.children.open.get_mut(&id) else {
        return (true, mlua::Value::Nil).into_lua_multi(lua);
    };
    if child.exited {
        return (true, child.code).into_lua_multi(lua);
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
            local ready, a = now()
            if ready then
                return a
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
                child.kill();
            }
            Ok(())
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
    let (cwd, env): (Option<String>, HashMap<String, String>) = match opts {
        Some(opts) => (
            opts.get("cwd")?,
            opts.get::<Option<_>>("env")?.unwrap_or_default(),
        ),
        None => (None, HashMap::new()),
    };
    let id = {
        let mut state = state_mut(lua);
        state.children.next += 1;
        state.children.next
    };
    let sender = jobs::sender(lua);
    let started = start_child(command, cwd.as_deref(), &env, move |piece| {
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
                    process: started.process,
                    stderr: started.stderr,
                },
            );
            child_to_lua(lua, id, started.pid)?.into_lua_multi(lua)
        }
        Err(err) => (mlua::Value::Nil, err.to_string()).into_lua_multi(lua),
    }
}
