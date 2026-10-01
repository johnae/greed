//! Work that runs on another thread while the editor keeps going, like a
//! project-wide grep. The command that starts a job waits for it the way it
//! waits for `kern.sleep`, and is woken with the result when it's done.

use crossbeam_channel::{Receiver, Sender};
use mlua::{Function, Lua, Value};

use super::{fs, state, state_mut, tasks};
use crate::search::{BadPattern, LineMatch};

type LuaResult<T> = mlua::Result<T>;

/// What a finished job produced.
pub enum Output {
    Grep(Result<Vec<LineMatch>, BadPattern>),
    Check(super::plugin::Check),
    Process(std::io::Result<super::process::Finished>),
}

/// A finished job, to pass to [`crate::luau::Host::finish_job`].
pub struct Done {
    token: u64,
    output: Output,
}

pub(crate) struct Jobs {
    done: Sender<Done>,
    finished: Receiver<Done>,
    /// Jobs started and not yet finished.
    running: usize,
}

impl Default for Jobs {
    fn default() -> Self {
        let (done, finished) = crossbeam_channel::unbounded();
        Self {
            done,
            finished,
            running: 0,
        }
    }
}

impl Jobs {
    pub(super) fn finished(&self) -> &Receiver<Done> {
        &self.finished
    }
}

/// Runs `work` on a new thread and returns the token its result wakes.
pub(super) fn start(lua: &Lua, work: impl FnOnce() -> Output + Send + 'static) -> u64 {
    let mut state = state_mut(lua);
    let token = state.tasks.token();
    state.jobs.running += 1;
    let done = state.jobs.done.clone();
    std::thread::spawn(move || {
        let output = work();
        // The editor may have gone away; then nobody wants the result.
        let _ = done.send(Done { token, output });
    });
    token
}

/// A Luau function named `name` that calls `start` and waits for the job it
/// returns when the caller can yield (in a command), and calls `now` anywhere
/// else.
pub(super) fn now_or_job(
    lua: &Lua,
    name: &str,
    now: Function,
    start: Function,
) -> LuaResult<Function> {
    lua.load(
        r"
        local now, start = ...
        return function(...)
            if coroutine.isyieldable() then
                return coroutine.yield(start(...))
            end
            return now(...)
        end
        ",
    )
    .set_name(format!("={name}"))
    .call((now, start))
}

/// Wakes the command waiting on a finished job with its result.
pub(super) fn finish(lua: &Lua, done: Done) -> LuaResult<()> {
    state_mut(lua).jobs.running -= 1;
    match done.output {
        Output::Grep(Ok(lines)) => tasks::wake(lua, done.token, fs::grep_to_lua(lua, lines)?),
        Output::Grep(Err(err)) => tasks::wake(lua, done.token, (Value::Nil, err.to_string())),
        Output::Check(check) => tasks::wake(lua, done.token, super::plugin::to_lua(lua, check)?),
        Output::Process(result) => {
            tasks::wake(lua, done.token, super::process::to_lua(lua, result)?)
        }
    }
}

/// Waits for every running job and finishes it, for tests, which have no
/// event loop to do it.
pub(super) fn settle(lua: &Lua) -> LuaResult<()> {
    let finished = state(lua).jobs.finished.clone();
    while state(lua).jobs.running > 0 {
        let done = finished.recv().map_err(mlua::Error::external)?;
        finish(lua, done)?;
    }
    Ok(())
}
