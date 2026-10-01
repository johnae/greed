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
pub(crate) struct Tasks {
    next_token: u64,
    waiting: HashMap<u64, Thread>,
    timers: Vec<(Instant, u64)>,
    /// What `kern.now` counts from.
    epoch: Instant,
    /// While timers fire, when they were due. Code they wake sees that as
    /// the time, so timing doesn't drift and tests can step through it.
    firing: Option<Instant>,
    /// The latest time timers fired at.
    latest: Instant,
}

impl Default for Tasks {
    fn default() -> Self {
        let now = Instant::now();
        Self {
            next_token: 0,
            waiting: HashMap::new(),
            timers: Vec::new(),
            epoch: now,
            firing: None,
            latest: now,
        }
    }
}

impl Tasks {
    pub(super) fn token(&mut self) -> u64 {
        self.next_token += 1;
        self.next_token
    }

    /// The editor's clock: when the firing timers were due, otherwise now.
    /// It never goes back, even after tests step past the real time.
    pub(super) fn now(&self) -> Instant {
        self.firing
            .unwrap_or_else(|| Instant::now().max(self.latest))
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
    let at = state.tasks.now() + delay;
    state.tasks.timers.push((at, token));
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
        state.tasks.firing = Some(now);
        state.tasks.latest = state.tasks.latest.max(now);
        due.sort();
        due.into_iter().map(|(_, token)| token).collect()
    };
    let mut first_error = None;
    for token in due {
        if let Err(err) = wake(lua, token, ()) {
            first_error.get_or_insert(err);
        }
    }
    state_mut(lua).tasks.firing = None;
    first_error.map_or(Ok(()), Err)
}

/// Lets time pass until `until`: fires each timer when it's due, in order,
/// including timers the woken code starts. For tests.
pub(super) fn advance(lua: &Lua, until: Instant) -> LuaResult<()> {
    // Bounded, so code that sleeps for 0 in a loop can't hang a test.
    for _ in 0..100_000 {
        match next_timer(lua) {
            Some(at) if at <= until => fire_timers(lua, at)?,
            _ => break,
        }
    }
    let tasks = &mut state_mut(lua).tasks;
    tasks.latest = tasks.latest.max(until);
    Ok(())
}

/// `kern.now()`: milliseconds on the editor's clock.
pub(super) fn now_function(lua: &Lua) -> LuaResult<Function> {
    lua.create_function(|lua, ()| {
        let tasks = &state(lua).tasks;
        Ok(tasks.now().duration_since(tasks.epoch).as_secs_f64() * 1000.0)
    })
}

/// `kern.animate(ms, step)`: calls `step(t)` about once a frame for `ms`
/// milliseconds, with `t` going from 0 to 1.
pub(super) fn animate_function(lua: &Lua, now: Function, sleep: Function) -> LuaResult<Function> {
    lua.load(
        r#"
        local now, sleep = ...
        return function(ms, step)
            if not coroutine.isyieldable() then
                error("kern.animate can only be used in a command or event handler", 2)
            end
            local start = now()
            local t = if ms > 0 then 0 else 1
            while true do
                step(t)
                if t >= 1 then
                    return
                end
                sleep(16)
                t = math.min(1, (now() - start) / ms)
            end
        end
        "#,
    )
    .set_name("=kern.animate")
    .call((now, sleep))
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

/// `kern.next_key()`: waits for the next key press and returns its name,
/// e.g. "g" or "ctrl-s". The key doesn't go through the keymap.
pub(super) fn next_key_function(lua: &Lua) -> LuaResult<Function> {
    let start = lua.create_function(|lua, ()| {
        let mut state = state_mut(lua);
        let token = state.tasks.token();
        state.key_waiter = Some(token);
        Ok(token)
    })?;
    lua.load(
        r#"
        local start = ...
        return function()
            if not coroutine.isyieldable() then
                error("kern.next_key can only be used in a command or event handler", 2)
            end
            return coroutine.yield(start())
        end
        "#,
    )
    .set_name("=kern.next_key")
    .call(start)
}
