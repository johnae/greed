//! Work that runs on another thread while the editor keeps going, like a
//! project-wide grep. The command that starts a job waits for it the way it
//! waits for `greed.sleep`, and is woken with the result when it's done.

use std::collections::BTreeMap;
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, RecvTimeoutError, Sender};
use mlua::{Function, Lua, Value};

use super::{fs, state, state_mut, tasks};
use crate::search::{BadPattern, LineMatch};

type LuaResult<T> = mlua::Result<T>;

/// What a finished job produced.
pub enum Output {
    Grep(Result<Vec<LineMatch>, BadPattern>),
    Check(super::plugin::Check),
    Http(Result<super::http::Fetched, String>),
    /// A stream's status and headers, for the command waiting on `token`.
    StreamHead(u64, u64, Result<super::http::Head, String>),
    /// A piece of stream `id`'s body, its end, or why it failed.
    StreamChunk(u64, super::http::Chunk),
    /// A secret, or where one was kept; nil when there's none.
    Secret(Result<Option<String>, String>),
    /// What program `id`, started with `greed.process.spawn`, printed, or
    /// its exit. Programs run for as long as they like, so they don't count
    /// as running jobs.
    Child(u64, super::process::Piece),
    Pdf(super::pdf::Done),
    Tags(Vec<crate::syntax::FileTags>),
    /// The image on a client's system clipboard, as PNG; none when it has
    /// none, or didn't say.
    ClipboardImage(Option<Vec<u8>>),
}

/// A finished job, to pass to [`crate::luau::Host::finish_job`].
pub struct Done {
    token: u64,
    output: Output,
}

impl Done {
    /// Output that wakes no job of its own, like a program's.
    pub(super) fn uncounted(output: Output) -> Self {
        Self { token: 0, output }
    }
}

/// Where output from other threads goes, for work that isn't a job.
pub(super) fn sender(lua: &Lua) -> Sender<Done> {
    state(lua).jobs.done.clone()
}

pub(crate) struct Jobs {
    done: Sender<Done>,
    finished: Receiver<Done>,
    /// Jobs started and not yet finished: what each does, by its token.
    running: BTreeMap<u64, String>,
    /// The coroutine each job [`begun`] by code is for, by its token.
    begun: BTreeMap<u64, usize>,
}

impl Default for Jobs {
    fn default() -> Self {
        let (done, finished) = crossbeam_channel::unbounded();
        Self {
            done,
            finished,
            running: BTreeMap::new(),
            begun: BTreeMap::new(),
        }
    }
}

impl Jobs {
    pub(super) fn finished(&self) -> &Receiver<Done> {
        &self.finished
    }

    /// How many jobs are running.
    pub(super) fn running(&self) -> usize {
        self.running.len()
    }

    /// Whether the job `token` wakes is still running.
    pub(super) fn is_running(&self, token: u64) -> bool {
        self.running.contains_key(&token)
    }

    /// Whether coroutine `id` has a job [`begun`] running, so it's at work.
    pub(super) fn begun_by(&self, id: usize) -> bool {
        self.begun.values().any(|by| *by == id)
    }
}

/// Counts work the running coroutine does elsewhere, like a program run to
/// its end, as a running job doing `what` until [`ended`] with the token it
/// returns: tests settle once it's done, and keys wait for it.
pub(super) fn begun(lua: &Lua, what: impl Into<String>) -> u64 {
    let by = tasks::key(&lua.current_thread());
    let mut state = state_mut(lua);
    let token = state.tasks.token();
    state.jobs.running.insert(token, what.into());
    state.jobs.begun.insert(token, by);
    token
}

/// The work [`begun`] gave `token` ended.
pub(super) fn ended(lua: &Lua, token: u64) {
    let jobs = &mut state_mut(lua).jobs;
    jobs.running.remove(&token);
    jobs.begun.remove(&token);
}

/// Runs `work`, which does `what`, like "greed.fs.grep", on a new thread and
/// returns the token its result wakes.
pub(super) fn start(
    lua: &Lua,
    what: impl Into<String>,
    work: impl FnOnce() -> Output + Send + 'static,
) -> u64 {
    let mut state = state_mut(lua);
    let token = state.tasks.token();
    state.jobs.running.insert(token, what.into());
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
    what: impl Into<String>,
    work: impl FnOnce(u64, &dyn Fn(Output)) + Send + 'static,
) -> u64 {
    let mut state = state_mut(lua);
    let token = state.tasks.token();
    state.jobs.running.insert(token, what.into());
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
/// handler or `greed.spawn`. It never does the work on the editor's thread,
/// so nothing that calls it can hold the editor up.
pub(super) fn waiting(lua: &Lua, name: &str, start: Function) -> LuaResult<Function> {
    waiting_at(lua, name, start, 2)
}

/// `waiting`, for a function in a handle that `handles::methods` wraps, so
/// its errors point at the code calling the method.
pub(super) fn waiting_method(lua: &Lua, name: &str, start: Function) -> LuaResult<Function> {
    waiting_at(lua, name, start, 3)
}

fn waiting_at(lua: &Lua, name: &str, start: Function, level: u8) -> LuaResult<Function> {
    lua.load(
        r"
        local name, start, level = ...
        return function(...)
            if not coroutine.isyieldable() then
                error(name .. ' waits, so it only works in a command, an event handler or greed.spawn', level)
            end
            return coroutine.yield(start(...))
        end
        ",
    )
    .set_name(format!("={name}"))
    .call((name, start, level))
}

/// Wakes the command waiting on a finished job with its result.
pub(super) fn finish(lua: &Lua, done: Done) -> LuaResult<()> {
    // A stream's job goes on after its head, until its body ends.
    let last = !matches!(
        done.output,
        Output::StreamHead(_, _, Ok(_))
            | Output::StreamChunk(_, super::http::Chunk::Data(_))
            | Output::Child(..)
    );
    if last {
        state_mut(lua).jobs.running.remove(&done.token);
    }
    match done.output {
        Output::Http(result) => {
            tasks::deliver(lua, done.token, super::http::fetched_to_lua(lua, result)?)
        }
        Output::StreamHead(token, id, head) => super::http::stream_started(lua, token, id, head),
        Output::StreamChunk(id, chunk) => super::http::chunk_arrived(lua, id, chunk),
        Output::Grep(Ok(lines)) => tasks::deliver(lua, done.token, fs::grep_to_lua(lua, lines)?),
        Output::Grep(Err(err)) => tasks::deliver(lua, done.token, (Value::Nil, err.to_string())),
        Output::Check(check) => tasks::deliver(lua, done.token, super::plugin::to_lua(lua, check)?),
        Output::Secret(result) => {
            tasks::deliver(lua, done.token, super::secrets::to_lua(lua, result)?)
        }
        Output::Child(id, piece) => super::process::piece_arrived(lua, id, piece),
        Output::Pdf(pdf) => super::pdf::finish(lua, done.token, pdf),
        Output::Tags(files) => {
            tasks::deliver(lua, done.token, super::syntax::tags_to_lua(lua, files)?)
        }
        Output::ClipboardImage(png) => {
            let png = png.map(|bytes| lua.create_string(bytes)).transpose()?;
            tasks::deliver(lua, done.token, png)
        }
    }
}

/// Waits for what a program prints next when code may wait on one, for
/// tests, up to a while. Returns whether there was something to wait for.
pub(super) fn await_child(lua: &Lua) -> LuaResult<bool> {
    const LIMIT: Duration = Duration::from_secs(10);
    if !awaited(lua) {
        return Ok(false);
    }
    if !await_child_for(lua, LIMIT)? {
        return Err(mlua::Error::runtime(
            "a program waited on said nothing for 10s",
        ));
    }
    Ok(true)
}

/// Waits up to `wait` for what a program prints next, through a pipe or in
/// a terminal, for tests, and handles it. Returns whether something came.
pub(super) fn await_child_for(lua: &Lua, wait: Duration) -> LuaResult<bool> {
    let (finished, events) = {
        let state = state(lua);
        (state.jobs.finished.clone(), state.terminals.events.clone())
    };
    crossbeam_channel::select! {
        recv(finished) -> done => {
            finish(lua, done.map_err(mlua::Error::external)?)?;
            Ok(true)
        }
        recv(events) -> event => {
            super::terminal::handle(lua, event.map_err(mlua::Error::external)?)?;
            Ok(true)
        }
        default(wait) => Ok(false),
    }
}

/// Whether a test may be waiting on a program: one it reads from, or one
/// running in a terminal.
pub(super) fn awaited(lua: &Lua) -> bool {
    super::process::awaited(lua) || state(lua).terminals.running()
}

/// Waits for every running job and finishes it, and lets work cut into time
/// slices finish, for tests, which have no event loop to do it. Time spent
/// waiting for a job doesn't count against the test's budget. Gives up,
/// naming the jobs still running, when none has finished for a minute.
pub(super) fn settle(lua: &Lua) -> LuaResult<()> {
    settle_within(lua, Duration::from_secs(60))
}

fn settle_within(lua: &Lua, limit: Duration) -> LuaResult<()> {
    let finished = state(lua).jobs.finished.clone();
    loop {
        // When a job last said something.
        let mut heard = Instant::now();
        while state(lua).jobs.running() > 0 {
            let waited = Instant::now();
            // Timers fire as the real time reaches them, as the editor fires
            // them while it waits, so a job's timeout can end it.
            let now = state(lua).tasks.now();
            let due = tasks::next_timer(lua).map(|at| at.saturating_duration_since(now));
            let received = finished.recv_timeout(due.unwrap_or(limit).min(limit));
            super::extend_deadline(lua, waited.elapsed());
            match received {
                Ok(done) => {
                    heard = Instant::now();
                    finish(lua, done)?;
                }
                Err(RecvTimeoutError::Timeout) if heard.elapsed() >= limit => {
                    let running: Vec<String> = state(lua).jobs.running.values().cloned().collect();
                    return Err(mlua::Error::runtime(format!(
                        "gave up after {limit:?} waiting for {} ({})",
                        running.join(", "),
                        super::process::summary(lua)
                    )));
                }
                // The time waited goes by for the editor too, even where a
                // test has moved its clock ahead of the real time.
                Err(RecvTimeoutError::Timeout) => tasks::advance(lua, now + waited.elapsed())?,
                Err(err) => return Err(mlua::Error::external(err)),
            }
        }
        // What programs printed so far, without waiting for more.
        let mut more = false;
        for done in finished.try_iter() {
            finish(lua, done)?;
            more = true;
        }
        // Work cut into time slices finishes too, which may start more jobs.
        if !super::tasks::resume_sliced(lua)? && !more {
            return Ok(());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Editor;
    use greed_text::ClientId;

    #[test]
    fn settling_gives_up_on_a_job_that_never_ends_naming_it() {
        let host = super::super::Host::new(Editor::new(ClientId(1))).unwrap();
        let lua = &host.lua;
        start(lua, "a quick job", || Output::Tags(Vec::new()));
        start(lua, "a job that never ends", || {
            std::thread::sleep(Duration::from_secs(5));
            Output::Tags(Vec::new())
        });
        let err = settle_within(lua, Duration::from_millis(200))
            .unwrap_err()
            .to_string();
        assert!(err.contains("waiting for a job that never ends"), "{err}");
        assert!(!err.contains("quick"), "{err}");
    }

    #[test]
    fn settling_finishes_every_job() {
        let host = super::super::Host::new(Editor::new(ClientId(1))).unwrap();
        let lua = &host.lua;
        for _ in 0..3 {
            start(lua, "a job", || {
                std::thread::sleep(Duration::from_millis(20));
                Output::Tags(Vec::new())
            });
        }
        settle_within(lua, Duration::from_secs(60)).unwrap();
        assert_eq!(state(lua).jobs.running(), 0);
    }
}
