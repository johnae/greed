//! Commands and event handlers run as coroutines, so they can wait for a
//! timer or a reply without blocking the editor.
//!
//! Waiting yields a token. The coroutine is parked until something resolves
//! that token, such as a timer firing, and is then resumed with the result.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use mlua::thread::ThreadStatus;
use mlua::{Function, IntoLuaMulti, Lua, Thread, Value};

use super::{state, state_mut};

type LuaResult<T> = mlua::Result<T>;

/// Parked coroutines and the timers some of them wait on.
#[derive(Default)]
pub(crate) struct Tasks {
    next_token: u64,
    waiting: HashMap<u64, Thread>,
    timers: Vec<(Instant, u64)>,
}

impl Tasks {
    pub(super) fn token(&mut self) -> u64 {
        self.next_token += 1;
        self.next_token
    }
}

/// Runs `f` as a coroutine. If it waits, it's parked until its token
/// resolves.
pub(super) fn spawn(lua: &Lua, f: Function, args: impl IntoLuaMulti) -> LuaResult<()> {
    resume(lua, lua.create_thread(f)?, args)
}

fn resume(lua: &Lua, thread: Thread, args: impl IntoLuaMulti) -> LuaResult<()> {
    let yielded: Value = thread.resume(args)?;
    if thread.status() != ThreadStatus::Resumable {
        return Ok(());
    }
    let token = match yielded {
        Value::Integer(n) => u64::try_from(n).ok(),
        _ => None,
    }
    .ok_or_else(|| {
        mlua::Error::runtime("a command can only wait through kern functions like kern.sleep")
    })?;
    state_mut(lua).tasks.waiting.insert(token, thread);
    Ok(())
}

/// Resumes the coroutine waiting on `token`, if there is one, with `value`.
pub(super) fn wake(lua: &Lua, token: u64, value: impl IntoLuaMulti) -> LuaResult<()> {
    let thread = state_mut(lua).tasks.waiting.remove(&token);
    match thread {
        Some(thread) => resume(lua, thread, value),
        None => Ok(()),
    }
}

/// Starts a timer and returns the token it resolves.
fn start_timer(lua: &Lua, delay: Duration) -> u64 {
    let mut state = state_mut(lua);
    let token = state.tasks.token();
    state.tasks.timers.push((Instant::now() + delay, token));
    token
}

/// When the next timer is due.
pub(super) fn next_timer(lua: &Lua) -> Option<Instant> {
    state(lua).tasks.timers.iter().map(|(at, _)| *at).min()
}

/// Resumes everything waiting on a timer that's due by `now`. Every due
/// timer fires even if one of them fails; the first error is returned.
pub(super) fn fire_timers(lua: &Lua, now: Instant) -> LuaResult<()> {
    let due: Vec<u64> = {
        let mut state = state_mut(lua);
        let (mut due, later): (Vec<_>, Vec<_>) =
            state.tasks.timers.drain(..).partition(|(at, _)| *at <= now);
        state.tasks.timers = later;
        due.sort();
        due.into_iter().map(|(_, token)| token).collect()
    };
    let mut first_error = None;
    for token in due {
        if let Err(err) = wake(lua, token, ()) {
            first_error.get_or_insert(err);
        }
    }
    first_error.map_or(Ok(()), Err)
}

/// `kern.sleep(ms)`: waits without blocking the editor.
pub(super) fn sleep_function(lua: &Lua) -> LuaResult<Function> {
    let start = lua.create_function(|lua, ms: f64| {
        let ms = if ms.is_finite() { ms.max(0.0) } else { 0.0 };
        Ok(start_timer(lua, Duration::from_secs_f64(ms / 1000.0)))
    })?;
    lua.load(
        r#"
        local start = ...
        return function(ms)
            if not coroutine.isyieldable() then
                error("kern.sleep can only be used in a command or event handler", 2)
            end
            return coroutine.yield(start(ms))
        end
        "#,
    )
    .set_name("=kern.sleep")
    .call(start)
}
