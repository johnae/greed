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
    Http(Result<super::http::Fetched, String>),
    /// A stream's status and headers, for the command waiting on `token`.
    StreamHead(u64, u64, Result<super::http::Head, String>),
    /// A piece of stream `id`'s body, its end, or why it failed.
    StreamChunk(u64, super::http::Chunk),
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

/// Runs `work` on a new thread, giving it the token of the command waiting
/// and a way to send any number of results, like a stream's pieces. The
/// job counts as running until it sends its last.
pub(super) fn start_streaming(
    lua: &Lua,
    work: impl FnOnce(u64, &dyn Fn(Output)) + Send + 'static,
) -> u64 {
    let mut state = state_mut(lua);
    let token = state.tasks.token();
    state.jobs.running += 1;
    let done = state.jobs.done.clone();
    std::thread::spawn(move || {
        work(token, &|output| {
            let _ = done.send(Done { token, output });
        });
    });
    token
}

/// A Luau function named `name` that calls `start` and waits for the job it
/// returns. It only works where code can wait: in a command, an event
/// handler or `kern.spawn`. It never does the work on the editor's thread,
/// so nothing that calls it can hold the editor up.
pub(super) fn waiting(lua: &Lua, name: &str, start: Function) -> LuaResult<Function> {
    lua.load(
        r"
        local name, start = ...
        return function(...)
            if not coroutine.isyieldable() then
                error(name .. ' waits, so it only works in a command, an event handler or kern.spawn', 2)
            end
            return coroutine.yield(start(...))
        end
        ",
    )
    .set_name(format!("={name}"))
    .call((name, start))
}

/// Wakes the command waiting on a finished job with its result.
pub(super) fn finish(lua: &Lua, done: Done) -> LuaResult<()> {
    // A stream's job goes on after its head, until its body ends.
    let last = !matches!(
        done.output,
        Output::StreamHead(_, _, Ok(_)) | Output::StreamChunk(_, super::http::Chunk::Data(_))
    );
    if last {
        state_mut(lua).jobs.running -= 1;
    }
    match done.output {
        Output::Http(result) => {
            tasks::wake(lua, done.token, super::http::fetched_to_lua(lua, result)?)
        }
        Output::StreamHead(token, id, head) => super::http::stream_started(lua, token, id, head),
        Output::StreamChunk(id, chunk) => super::http::chunk_arrived(lua, id, chunk),
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
