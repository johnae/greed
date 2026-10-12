//! `greed.process`: running other programs. `spawn` starts one to talk to
//! over its input and output, like an agent speaking JSON-RPC; `run` runs
//! one to the end on it, like a formatter or `jj`, and gives back what it
//! printed. Either goes with the plugin that started it.

use std::collections::{HashMap, VecDeque};
use std::io::{Read, Write};
use std::os::unix::process::ExitStatusExt;
use std::path::Path;
use std::process::Stdio;
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, RecvTimeoutError, Sender};
use mlua::{Function, IntoLuaMulti, Lua, Table};
use nix::sys::signal::Signal;
use nix::unistd::Pid;

use super::jobs::{self, Output};
use super::{state, state_mut, tasks};
use crate::child;
use crate::registry::PluginId;

type LuaResult<T> = mlua::Result<T>;

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

/// `greed.process.run`, in Luau on `spawn`, so what it runs is the plugin's
/// as a spawned program is, and goes with it.
const RUN: &str = r#"
local spawn, background, sleep, begun, ended = ...
return function(command, opts)
	if not coroutine.isyieldable() then
		error("greed.process.run waits, so it only works in a command, an event handler or greed.spawn", 2)
	end
	opts = opts or {}
	local child, err = spawn(command, { cwd = opts.cwd, env = opts.env, group = opts.group, stderr = "stream" })
	if child == nil then
		return nil, err
	end
	-- A job while it runs, as tests settle once jobs are done.
	local job = begun("greed.process.run " .. table.concat(command, " "))
	if opts.on_start then
		opts.on_start(child)
	end
	if opts.stdin then
		child:write(opts.stdin)
	end
	child:close()
	local finished, timed_out = false, false
	if opts.timeout then
		background(function()
			sleep(opts.timeout)
			if not finished then
				timed_out = true
				child:kill()
			end
		end)
	end
	local out, errors = {}, {}
	while true do
		local piece, from = child:read()
		if piece == nil then
			break
		end
		table.insert(if from == "stderr" then errors else out, piece)
	end
	local code, signal = child:wait()
	finished = true
	ended(job)
	return {
		code = code,
		signal = signal,
		stdout = table.concat(out),
		stderr = table.concat(errors),
		timed_out = timed_out,
	}
end
"#;

/// `greed.process` for `owner`; `greed` gives it `spawn` and `sleep`.
pub(super) fn module(lua: &Lua, owner: &PluginId, greed: &Table) -> LuaResult<Table> {
    let process = lua.create_table()?;
    let owner = owner.clone();
    let spawn =
        lua.create_function(move |lua, (command, opts): (Vec<String>, Option<Table>)| {
            spawn(lua, &owner, &command, opts.as_ref())
        })?;
    let run: Function = lua.load(RUN).set_name("=greed.process.run").call((
        spawn.clone(),
        greed.get::<Function>("spawn")?,
        greed.get::<Function>("sleep")?,
        lua.create_function(|lua, what: String| Ok(jobs::begun(lua, what)))?,
        lua.create_function(|lua, token: u64| {
            jobs::ended(lua, token);
            Ok(())
        })?,
    ))?;
    process.set("run", run)?;
    process.set("spawn", spawn)?;
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
    unread: Arc<Unread>,
    /// Whether the plugin let go of it while it ran: it goes once it exits.
    let_go: bool,
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
        // Holding the lock, the program can't be reaped meanwhile, so its
        // id can't go to another.
        let running = matches!(process.try_wait(), Ok(None));
        if self.group {
            // Once reaped, its id is free, but no new program gets it while
            // any of its group lives: a program with that id means the group
            // is gone and the id is someone else's now.
            let taken = nix::sys::signal::kill(pid, None) != Err(nix::errno::Errno::ESRCH);
            return (running || !taken) && nix::sys::signal::killpg(pid, signal).is_ok();
        }
        running && nix::sys::signal::kill(pid, signal).is_ok()
    }
}

impl Drop for Child {
    fn drop(&mut self) {
        self.unread.close();
        if !self.exited || self.group {
            self.signal(Signal::SIGKILL);
        }
    }
}

/// The most of a program's output that waits to be read. Past it, reading
/// its output stops until the plugin reads some, so a program printing
/// faster than its plugin reads waits, as on a full pipe.
const MAX_UNREAD: usize = 8 * 1024 * 1024;

/// How much of a program's output was read from it and not yet by its
/// plugin, and whether anyone still will.
#[derive(Default)]
struct Unread {
    count: Mutex<UnreadCount>,
    room: Condvar,
}

#[derive(Default)]
struct UnreadCount {
    bytes: usize,
    closed: bool,
}

impl Unread {
    fn count(&self) -> std::sync::MutexGuard<'_, UnreadCount> {
        self.count.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Counts `n` more bytes, once there's room for them.
    fn add(&self, n: usize) {
        let mut count = self
            .room
            .wait_while(self.count(), |count| {
                count.bytes >= MAX_UNREAD && !count.closed
            })
            .unwrap_or_else(PoisonError::into_inner);
        count.bytes += n;
    }

    /// The plugin read `n` bytes.
    fn read(&self, n: usize) {
        let mut count = self.count();
        count.bytes = count.bytes.saturating_sub(n);
        self.room.notify_all();
    }

    /// Nobody will read any more: reading goes on, uncounted.
    fn close(&self) {
        self.count().closed = true;
        self.room.notify_all();
    }
}

/// Held by each function of a program's handle. When Luau has collected
/// them all, the plugin can't reach the program anymore, so it's let go.
struct Handle {
    id: u64,
    dropped: Arc<Mutex<Vec<u64>>>,
}

impl Drop for Handle {
    fn drop(&mut self) {
        self.dropped
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push(self.id);
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
    /// Programs whose handles Luau collected since the last look.
    dropped: Arc<Mutex<Vec<u64>>>,
}

impl Children {
    /// Ends the programs plugin `name` started.
    pub fn remove_owned_by(&mut self, name: &str) {
        self.open.retain(|_, child| &*child.owner != name);
    }

    /// Forgets the programs no plugin holds anymore once they exited,
    /// leaving what they started to run on.
    fn sweep(&mut self) {
        let dropped =
            std::mem::take(&mut *self.dropped.lock().unwrap_or_else(PoisonError::into_inner));
        for id in dropped {
            if let Some(child) = self.open.get_mut(&id) {
                // Nobody reads what it prints from now on.
                child.let_go = true;
                child.queue.clear();
                child.unread.close();
                if child.exited {
                    self.forget(id);
                }
            }
        }
    }

    /// Takes program `id` out without signalling it or its group.
    fn forget(&mut self, id: u64) {
        if let Some(mut child) = self.open.remove(&id) {
            child.exited = true;
            child.group = false;
        }
    }
}

/// A program `start_child` started.
struct Started {
    pid: u32,
    stdin: Sender<Vec<u8>>,
    process: Arc<Mutex<std::process::Child>>,
    stderr: Arc<Mutex<Vec<u8>>>,
    unread: Arc<Unread>,
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
    let cwd = options.cwd.as_deref().map(Path::new);
    let mut child = child::command(command, cwd, &options.env, options.group)?
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|err| child::cant_run(&command[0], &err))?;
    crate::debug!(Jobs, "started {}", command.join(" "));
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
    let unread = Arc::new(Unread::default());
    let (sender, counted) = (send.clone(), unread.clone());
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
                counted.add(n);
                sender(Piece::Out(Stream::Stderr, buffer[..n].to_vec()));
            }
        }
    });
    let (sender, counted) = (send.clone(), unread.clone());
    std::thread::spawn(move || {
        let _reading = stdout_reading;
        let mut buffer = vec![0; 16 * 1024];
        while let Ok(n @ 1..) = stdout.read(&mut buffer) {
            counted.add(n);
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
        unread,
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
        let children = &mut state.children;
        children.sweep();
        let Some(child) = children.open.get_mut(&id) else {
            return Ok(());
        };
        match piece {
            Piece::Out(stream, bytes) => {
                if let Some(token) = child.reader.take() {
                    child.unread.read(bytes.len());
                    let piece = (lua.create_string(&bytes)?, stream.name());
                    vec![(token, piece.into_lua_multi(lua)?)]
                } else {
                    if !child.let_go {
                        child.queue.push_back((stream, bytes));
                    }
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
                if child.let_go {
                    children.forget(id);
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

/// The programs started and not let go, each as how far it got, for saying
/// what a test waits on.
pub(super) fn summary(lua: &Lua) -> String {
    let state = state(lua);
    let mut lines: Vec<String> = state
        .children
        .open
        .iter()
        .map(|(id, child)| {
            let pid = child.process.lock().map_or(0, |p| p.id());
            format!(
                "program {id} (pid {pid}): {}, {} unread pieces, {}",
                if child.exited { "exited" } else { "running" },
                child.queue.len(),
                if child.reader.is_some() {
                    "read waiting"
                } else {
                    "no read waiting"
                },
            )
        })
        .collect();
    lines.sort();
    lines.join("; ")
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
        child.unread.read(bytes.len());
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

/// The table a plugin talks to a program through. Each of its functions
/// holds `handle`, so the program is let go once Luau collected them all.
fn child_to_lua(lua: &Lua, handle: &Arc<Handle>, pid: u32) -> LuaResult<Table> {
    let child = lua.create_table()?;
    child.set("pid", pid)?;
    let h = handle.clone();
    child.set(
        "write",
        lua.create_function(move |lua, text: mlua::LuaString| {
            let state = state(lua);
            let sent = state
                .children
                .open
                .get(&h.id)
                .and_then(|child| child.stdin.as_ref())
                .is_some_and(|stdin| stdin.send(text.as_bytes().to_vec()).is_ok());
            Ok(sent)
        })?,
    )?;
    let h = handle.clone();
    child.set(
        "close",
        lua.create_function(move |lua, ()| {
            if let Some(child) = state_mut(lua).children.open.get_mut(&h.id) {
                child.stdin = None;
            }
            Ok(())
        })?,
    )?;
    let h = handle.clone();
    child.set(
        "kill",
        lua.create_function(move |lua, ()| {
            if let Some(child) = state(lua).children.open.get(&h.id) {
                child.signal(Signal::SIGKILL);
            }
            Ok(())
        })?,
    )?;
    let h = handle.clone();
    child.set(
        "signal",
        lua.create_function(move |lua, name: String| {
            let signal = signal_named(&name)?;
            Ok(state(lua)
                .children
                .open
                .get(&h.id)
                .is_some_and(|child| child.signal(signal)))
        })?,
    )?;
    let h = handle.clone();
    child.set(
        "stderr",
        lua.create_function(move |lua, ()| {
            let state = state(lua);
            match state
                .children
                .open
                .get(&h.id)
                .and_then(|child| child.stderr.lock().ok())
            {
                Some(kept) => lua.create_string(&*kept),
                None => lua.create_string(""),
            }
        })?,
    )?;
    let h = handle.clone();
    let read = lua.create_function(move |lua, ()| read_now(lua, h.id))?;
    child.set("read", waiting_call(lua, "child.read", read)?)?;
    let h = handle.clone();
    let wait = lua.create_function(move |lua, ()| wait_now(lua, h.id))?;
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
    let (id, dropped) = {
        let mut state = state_mut(lua);
        let children = &mut state.children;
        children.sweep();
        children.next += 1;
        (children.next, children.dropped.clone())
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
                    unread: started.unread,
                    let_go: false,
                },
            );
            let handle = Arc::new(Handle { id, dropped });
            child_to_lua(lua, &handle, started.pid)?.into_lua_multi(lua)
        }
        Err(err) => (mlua::Value::Nil, err.to_string()).into_lua_multi(lua),
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::state;
    use crate::Editor;
    use crate::luau::Host;

    #[test]
    fn programs_nobody_holds_go_once_they_exit() {
        let host = Host::new(Editor::new(greed_text::ClientId(1))).unwrap();
        let open = || state(&host.lua).children.open.len();
        host.eval("require('@greed').process.spawn({ 'true' })")
            .unwrap();
        host.eval("held = require('@greed').process.spawn({ 'true' })")
            .unwrap();
        let exited = || state(&host.lua).children.open.values().all(|c| c.exited);
        let jobs = host.finished_jobs();
        while !exited() {
            let done = jobs.recv_timeout(Duration::from_secs(10)).unwrap();
            host.finish_job(done).unwrap();
        }
        assert_eq!(open(), 2);
        host.luau_memory();
        host.eval("require('@greed').process.spawn({ 'true' })")
            .unwrap();
        assert_eq!(open(), 2, "the one held stays, with the new one");
    }
}
