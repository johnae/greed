//! Commands and event handlers run as coroutines, so they can wait for a
//! timer or a reply without blocking the editor.
//!
//! Waiting yields a token. The coroutine is parked until something resolves
//! that token, such as a timer firing, and is then resumed with the result.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::{Duration, Instant};

use greed_text::ClientId;
use mlua::thread::ThreadStatus;
use mlua::{Function, IntoLuaMulti, Lua, MultiValue, Thread, Value};

use super::capabilities::Limit;
use super::{state, state_mut};
use crate::registry::PluginId;

type LuaResult<T> = mlua::Result<T>;

/// How long a command or handler may work, across slices, before it is
/// stopped: long enough for real work, short of a loop that never ends.
const WORK_LIMIT: Duration = Duration::from_secs(60);

/// Parked coroutines and the timers some of them wait on.
pub(crate) struct Tasks {
    next_token: u64,
    waiting: HashMap<u64, Thread>,
    /// Values sent to signals nobody waits on yet.
    sent: HashMap<u64, Value>,
    /// Results of jobs that finished before the coroutine that started them
    /// waited, because its time slice ran out in between.
    early: HashMap<u64, MultiValue>,
    timers: Vec<(Instant, u64)>,
    /// What `greed.now` counts from.
    epoch: Instant,
    /// While timers fire, when they were due. Code they wake sees that as
    /// the time, so timing doesn't drift and tests can step through it.
    firing: Option<Instant>,
    /// The latest time timers fired at.
    latest: Instant,
    /// Why each running coroutine edits: the command it runs for, or what
    /// was running when it started. Set as the editor's cause while it runs.
    causes: HashMap<usize, Arc<str>>,
    /// The plugin each running coroutine's code belongs to, for capability
    /// checks while it runs.
    owners: HashMap<usize, PluginId>,
    /// The [`Limit`] each running coroutine runs within.
    limits: HashMap<usize, Limit>,
    /// What each running coroutine does, when it says, like "on buffer.changed"
    /// for an event handler: how the watchdog and the profile name it.
    labels: HashMap<usize, Arc<str>>,
    /// How long each coroutine has worked across the slices it was cut into.
    worked: HashMap<usize, Duration>,
    /// Tokens to resolve when a coroutine finishes, by its id.
    finished: HashMap<usize, Vec<u64>>,
    /// The timers of coroutines whose time slice ran out, which carry on as
    /// soon as the editor had a turn.
    sliced: HashSet<u64>,
    /// The client each running coroutine acts for: the one acting when it
    /// started. The editor acts for it while it runs.
    clients: HashMap<usize, ClientId>,
    /// The coroutine of the command the last key each client typed ran,
    /// while it runs, so keys that client types after it wait their turn.
    key_command: HashMap<ClientId, usize>,
}

impl Default for Tasks {
    fn default() -> Self {
        let now = Instant::now();
        Self {
            next_token: 0,
            waiting: HashMap::new(),
            sent: HashMap::new(),
            early: HashMap::new(),
            timers: Vec::new(),
            epoch: now,
            firing: None,
            latest: now,
            causes: HashMap::new(),
            owners: HashMap::new(),
            limits: HashMap::new(),
            labels: HashMap::new(),
            worked: HashMap::new(),
            finished: HashMap::new(),
            sliced: HashSet::new(),
            clients: HashMap::new(),
            key_command: HashMap::new(),
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

    /// Drops what's kept about the coroutine `id`, once it's done.
    fn forget(&mut self, id: usize) {
        self.causes.remove(&id);
        self.owners.remove(&id);
        self.limits.remove(&id);
        self.labels.remove(&id);
        self.worked.remove(&id);
        self.clients.remove(&id);
        self.key_command.retain(|_, running| *running != id);
    }

    /// Stops keys of client `id`, which went, waiting for anything.
    pub(super) fn forget_client(&mut self, id: ClientId) {
        self.key_command.remove(&id);
    }

    /// Whether coroutine `id` is at work: cut into time slices, or waiting
    /// on a timer, a job, or another coroutine that is. Waiting on anything
    /// else, like a key or a signal (a prompt's answer), is waiting for the
    /// user.
    fn at_work(&self, mut id: usize, jobs: &super::jobs::Jobs) -> bool {
        // Bounded, in case coroutines wait on each other in a ring.
        for _ in 0..64 {
            let Some(token) = self
                .waiting
                .iter()
                .find(|(_, thread)| key(thread) == id)
                .map(|(token, _)| *token)
            else {
                return false;
            };
            if self.timers.iter().any(|(_, t)| *t == token) || jobs.is_running(token) {
                return true;
            }
            match self
                .finished
                .iter()
                .find(|(_, tokens)| tokens.contains(&token))
            {
                Some((other, _)) => id = *other,
                None => return false,
            }
        }
        false
    }

    /// Stops every coroutine running `owner`'s code: those waiting are
    /// dropped, and one running now stops when it next waits. Returns the
    /// tokens they waited on and the tokens of what waits for them to end.
    fn stop_owned_by(&mut self, owner: &str) -> (Vec<u64>, Vec<u64>) {
        let ids: HashSet<usize> = self
            .owners
            .iter()
            .filter(|(_, o)| &***o == owner)
            .map(|(id, _)| *id)
            .collect();
        let mut waiters = Vec::new();
        for &id in &ids {
            self.forget(id);
            waiters.extend(self.finished.remove(&id).unwrap_or_default());
        }
        let dropped: Vec<u64> = self
            .waiting
            .iter()
            .filter(|(_, thread)| ids.contains(&key(thread)))
            .map(|(token, _)| *token)
            .collect();
        for token in &dropped {
            self.waiting.remove(token);
            self.sliced.remove(token);
        }
        self.timers.retain(|(_, token)| !dropped.contains(token));
        (dropped, waiters)
    }
}

/// Whether the command the last key `client` typed ran is still at work
/// (see `Tasks::at_work`), so the keys it types after it should wait.
pub(super) fn key_command_at_work(lua: &Lua, client: ClientId) -> bool {
    let state = state(lua);
    state
        .tasks
        .key_command
        .get(&client)
        .is_some_and(|id| state.tasks.at_work(*id, &state.jobs))
}

/// Keeps `running`, the coroutine of the command a key the acting client
/// typed just ran, as the one its keys wait for.
pub(super) fn ran_for_key(lua: &Lua, running: Option<usize>) {
    let state = &mut *state_mut(lua);
    let client = state.editor.client();
    match running {
        Some(id) => state.tasks.key_command.insert(client, id),
        None => state.tasks.key_command.remove(&client),
    };
}

/// Stops `client`'s keys waiting for the command its last key ran, though
/// it's still at work.
pub(super) fn let_keys_through(lua: &Lua, client: ClientId) {
    state_mut(lua).tasks.key_command.remove(&client);
}

/// Stops every command, handler and task of plugin `owner`'s, letting what
/// waits for them to end carry on.
pub(super) fn stop_owned_by(lua: &Lua, owner: &str) -> LuaResult<()> {
    let waiters = {
        let state = &mut *state_mut(lua);
        let (dropped, waiters) = state.tasks.stop_owned_by(owner);
        state
            .key_waiter
            .retain(|_, (token, _)| !dropped.contains(token));
        waiters
    };
    for token in waiters {
        wake(lua, token, ())?;
    }
    Ok(())
}

/// Runs `f`, code `owner` registered, as a coroutine whose edits are made
/// for `cause` (by default, whatever the code starting it edits for), within
/// the limit of the code starting it. If it waits, it's parked until its
/// token resolves.
pub(super) fn spawn(
    lua: &Lua,
    f: Function,
    args: impl IntoLuaMulti,
    owner: PluginId,
    cause: Option<Arc<str>>,
) -> LuaResult<()> {
    let limit = super::capabilities::started_by(lua);
    spawn_running(lua, f, args, owner, cause, limit).map(|_| ())
}

/// An event handler: `spawn` with no limit, unless `owner` is a plugin being
/// checked, naming what the coroutine does as `label` for the watchdog and
/// the profile, like "on buffer.changed".
pub(super) fn spawn_labelled(
    lua: &Lua,
    f: Function,
    args: impl IntoLuaMulti,
    owner: PluginId,
    label: Arc<str>,
) -> LuaResult<()> {
    let limit = if super::capabilities::checking(lua, &owner) {
        state(lua).floor.clone()
    } else {
        Vec::new()
    };
    spawn_with(lua, f, args, owner, None, Some(label), limit).map(|_| ())
}

/// `spawn` within `limit`, returning the coroutine's id if it's still
/// running (waiting on something), for `wait_for`.
pub(super) fn spawn_running(
    lua: &Lua,
    f: Function,
    args: impl IntoLuaMulti,
    owner: PluginId,
    cause: Option<Arc<str>>,
    limit: Limit,
) -> LuaResult<Option<usize>> {
    spawn_with(lua, f, args, owner, cause, None, limit)
}

fn spawn_with(
    lua: &Lua,
    f: Function,
    args: impl IntoLuaMulti,
    owner: PluginId,
    cause: Option<Arc<str>>,
    label: Option<Arc<str>>,
    limit: Limit,
) -> LuaResult<Option<usize>> {
    let thread = lua.create_thread(f)?;
    let id = key(&thread);
    {
        let state = &mut *state_mut(lua);
        if let Some(cause) = cause.or_else(|| state.editor.cause().cloned()) {
            state.tasks.causes.insert(id, cause);
        }
        state.tasks.owners.insert(id, owner);
        state.tasks.limits.insert(id, limit);
        state.tasks.clients.insert(id, state.editor.client());
        if let Some(label) = label {
            state.tasks.labels.insert(id, label);
        }
    }
    resume(lua, thread.clone(), args)?;
    Ok((thread.status() == ThreadStatus::Resumable).then_some(id))
}

/// A token resolved when the running coroutine `id` finishes, so another
/// coroutine can wait for it by yielding the token.
pub(super) fn wait_for(lua: &Lua, id: usize) -> u64 {
    let tasks = &mut state_mut(lua).tasks;
    let token = tasks.token();
    tasks.finished.entry(id).or_default().push(token);
    token
}

/// Sets why the running code edits, for the rest of its coroutine too.
pub(super) fn set_cause(lua: &Lua, cause: Option<Arc<str>>) {
    let thread = key(&lua.current_thread());
    let state = &mut *state_mut(lua);
    match &cause {
        Some(cause) => state.tasks.causes.insert(thread, cause.clone()),
        None => state.tasks.causes.remove(&thread),
    };
    state.editor.set_cause(cause);
}

fn key(thread: &Thread) -> usize {
    thread.to_pointer() as usize
}

fn resume(lua: &Lua, thread: Thread, args: impl IntoLuaMulti) -> LuaResult<()> {
    let id = key(&thread);
    let (outer, outer_owner, outer_limit, outer_client, owner, cause, label) = {
        let state = &mut *state_mut(lua);
        let outer_client = state.editor.client();
        // A test's body, which nothing spawned, acts for whoever is acting.
        if let Some(client) = state.tasks.clients.get(&id).copied() {
            // One that's gone is replaced by the last active one, from now on.
            let acting = state.editor.act_as(client);
            state.tasks.clients.insert(id, acting);
        }
        let cause = state.tasks.causes.get(&id).cloned();
        let owner = state.tasks.owners.get(&id).cloned();
        let label = state.tasks.labels.get(&id).cloned();
        // A test's body, which nothing spawned, runs as what you start does.
        let limit = state
            .tasks
            .limits
            .get(&id)
            .cloned()
            .unwrap_or_else(|| state.floor.clone());
        let outer = state.editor.cause().cloned();
        state.editor.set_cause(cause.clone());
        let outer_owner = std::mem::replace(&mut state.running, owner.clone());
        let outer_limit = std::mem::replace(&mut state.limit, limit);
        (
            outer,
            outer_owner,
            outer_limit,
            outer_client,
            owner,
            cause,
            label,
        )
    };
    let what = label.as_deref().or(cause.as_deref()).unwrap_or("a handler");
    let (yielded, ran) = super::stalls::timed(lua, owner.as_deref(), what, || {
        super::sliced(lua, id, || {
            // A bug the plugin's call ran into is its error, kept like one.
            crate::panics::catching(|| thread.resume::<Value>(args))
                .unwrap_or_else(|panic| Err(mlua::Error::runtime(panic)))
        })
    });
    // An error nothing caught is kept with who and what ran, and where.
    let yielded =
        yielded.map_err(|err| super::errors::record(lua, &thread, owner.as_deref(), what, err));
    let stopped = {
        let state = &mut *state_mut(lua);
        state.editor.set_cause(outer);
        state.editor.act_as(outer_client);
        state.running = outer_owner;
        state.limit = outer_limit;
        // Its plugin was unloaded while it ran.
        owner.is_some() && !state.tasks.owners.contains_key(&id)
    };
    if stopped {
        return Ok(());
    }
    if thread.status() != ThreadStatus::Resumable {
        finish(lua, id)?;
        yielded?;
        return Ok(());
    }
    let token = match yielded? {
        Value::Integer(n) => u64::try_from(n).ok(),
        // Its slice ran out: it carries on once the editor had a turn,
        // unless it has worked so long it looks like it never ends.
        Value::Nil => {
            let worked = state(lua)
                .tasks
                .worked
                .get(&id)
                .copied()
                .unwrap_or_default()
                + ran;
            if worked > WORK_LIMIT {
                let who = owner.as_deref().unwrap_or("a plugin");
                state_mut(lua).editor.echo(format!(
                    "stopped {what} ({who}) after {}s of work without finishing",
                    WORK_LIMIT.as_secs()
                ));
                return finish(lua, id);
            }
            state_mut(lua).tasks.worked.insert(id, worked);
            let token = start_timer(lua, Duration::ZERO);
            state_mut(lua).tasks.sliced.insert(token);
            Some(token)
        }
        _ => None,
    }
    .ok_or_else(|| {
        mlua::Error::runtime("a command can only wait through greed functions like greed.sleep")
    })?;
    let early = state_mut(lua).tasks.early.remove(&token);
    if let Some(result) = early {
        return resume(lua, thread, result);
    }
    state_mut(lua).tasks.waiting.insert(token, thread);
    Ok(())
}

/// Drops what's kept about the coroutine `id`, which is done or stopped,
/// and lets whatever waits for it carry on, whether it finished or failed.
fn finish(lua: &Lua, id: usize) -> LuaResult<()> {
    let waiters = {
        let tasks = &mut state_mut(lua).tasks;
        tasks.forget(id);
        tasks.finished.remove(&id).unwrap_or_default()
    };
    for token in waiters {
        wake(lua, token, ())?;
    }
    Ok(())
}

/// Resumes the coroutine waiting on `token`, if there is one, with `value`.
pub(super) fn wake(lua: &Lua, token: u64, value: impl IntoLuaMulti) -> LuaResult<()> {
    let thread = {
        let tasks = &mut state_mut(lua).tasks;
        tasks.sliced.remove(&token);
        tasks.waiting.remove(&token)
    };
    match thread {
        Some(thread) => resume(lua, thread, value),
        None => Ok(()),
    }
}

/// Wakes the coroutine waiting on job `token` with its result. If it isn't
/// waiting yet, its slice having run out between starting the job and
/// waiting for it, the result is kept until it does.
pub(super) fn deliver(lua: &Lua, token: u64, value: impl IntoLuaMulti) -> LuaResult<()> {
    if state(lua).tasks.waiting.contains_key(&token) {
        return wake(lua, token, value);
    }
    let value = value.into_lua_multi(lua)?;
    state_mut(lua).tasks.early.insert(token, value);
    Ok(())
}

/// Carries on every coroutine whose time slice ran out, without waiting for
/// its timer. Returns whether there were any. For code with no event loop
/// around it, like tests, which look at the editor once a key's work is
/// done. Every one carries on even if one before it fails; the first error
/// is returned.
pub(super) fn resume_sliced(lua: &Lua) -> LuaResult<bool> {
    let tokens: Vec<u64> = {
        let tasks = &mut state_mut(lua).tasks;
        let mut tokens: Vec<u64> = tasks.sliced.drain().collect();
        // Oldest first, as their timers would fire.
        tokens.sort_unstable();
        tasks.timers.retain(|(_, token)| !tokens.contains(token));
        tokens
    };
    let mut first_error = None;
    for &token in &tokens {
        if let Err(err) = wake(lua, token, ()) {
            first_error.get_or_insert(err);
        }
    }
    first_error.map_or(Ok(!tokens.is_empty()), Err)
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

/// `greed.now()`: milliseconds on the editor's clock.
pub(super) fn now_function(lua: &Lua) -> LuaResult<Function> {
    lua.create_function(|lua, ()| {
        let tasks = &state(lua).tasks;
        Ok(tasks.now().duration_since(tasks.epoch).as_secs_f64() * 1000.0)
    })
}

/// `greed.animate(ms, step)`: calls `step(t)` about once a frame for `ms`
/// milliseconds, with `t` going from 0 to 1.
pub(super) fn animate_function(lua: &Lua, now: Function, sleep: Function) -> LuaResult<Function> {
    lua.load(
        r#"
        local now, sleep = ...
        return function(ms, step)
            if not coroutine.isyieldable() then
                error("greed.animate can only be used in a command or event handler", 2)
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
    .set_name("=greed.animate")
    .call((now, sleep))
}

/// `greed.sleep(ms)`: waits without blocking the editor.
pub(super) fn sleep_function(lua: &Lua) -> LuaResult<Function> {
    let start = lua.create_function(|lua, ms: f64| Ok(start_timer(lua, super::millis(ms))))?;
    lua.load(
        r#"
        local start = ...
        return function(ms)
            if not coroutine.isyieldable() then
                error("greed.sleep can only be used in a command or event handler", 2)
            end
            return coroutine.yield(start(ms))
        end
        "#,
    )
    .set_name("=greed.sleep")
    .call(start)
}

/// `greed.next_key()`: waits for the next key the acting client presses and
/// returns its name, e.g. "g" or "ctrl-s". The key doesn't go through the
/// keymap.
pub(super) fn next_key_function(lua: &Lua) -> LuaResult<Function> {
    let start = lua.create_function(|lua, ()| {
        let state = &mut *state_mut(lua);
        let token = state.tasks.token();
        let client = state.editor.client();
        state
            .key_waiter
            .insert(client, (token, state.limit.clone()));
        Ok(token)
    })?;
    lua.load(
        r#"
        local start = ...
        return function()
            if not coroutine.isyieldable() then
                error("greed.next_key can only be used in a command or event handler", 2)
            end
            return coroutine.yield(start())
        end
        "#,
    )
    .set_name("=greed.next_key")
    .call(start)
}

/// `greed.signal()`: a one-shot value one piece of code waits for and
/// another sends, e.g. a tool waiting for the user to review an edit. A
/// value sent before anyone waits is kept for the first wait.
pub(super) fn signal_function(lua: &Lua) -> LuaResult<Function> {
    let new = lua.create_function(|lua, ()| Ok(state_mut(lua).tasks.token()))?;
    let send = lua.create_function(|lua, (token, value): (u64, Value)| {
        if state(lua).tasks.waiting.contains_key(&token) {
            wake(lua, token, value)
        } else {
            state_mut(lua).tasks.sent.entry(token).or_insert(value);
            Ok(())
        }
    })?;
    let take = lua.create_function(|lua, token: u64| {
        Ok(match state_mut(lua).tasks.sent.remove(&token) {
            Some(value) => (true, value),
            None => (false, Value::Nil),
        })
    })?;
    lua.load(
        r#"
        local new, send, take = ...
        return function()
            local token = new()
            local sent = false
            local signal
            -- Both signal:send(value) and signal.send(value) work.
            signal = {
                wait = function()
                    local ready, value = take(token)
                    if ready then
                        return value
                    end
                    if not coroutine.isyieldable() then
                        error("a signal can only be waited on in a command or event handler", 2)
                    end
                    return coroutine.yield(token)
                end,
                send = function(first, ...)
                    local value = if rawequal(first, signal) then ... else first
                    if not sent then
                        sent = true
                        send(token, value)
                    end
                end,
            }
            return signal
        end
        "#,
    )
    .set_name("=greed.signal")
    .call((new, send, take))
}

/// Runs `f` as a coroutine and sees it to its end, finishing the jobs and
/// firing the timers it waits on, for code that has no event loop around it:
/// a test's body. Fails if it waits for something nothing will bring, like
/// a key.
pub(super) fn run_to_end(lua: &Lua, f: Function, args: impl IntoLuaMulti) -> LuaResult<()> {
    let thread = lua.create_thread(f)?;
    resume(lua, thread.clone(), args)?;
    while thread.status() == ThreadStatus::Resumable {
        let waited = Instant::now();
        super::jobs::settle(lua)?;
        if thread.status() == ThreadStatus::Resumable {
            match next_timer(lua) {
                Some(at) => advance(lua, at)?,
                None if super::jobs::await_child(lua)? => {}
                None => {
                    return Err(mlua::Error::runtime(
                        "the test waits for something nothing will bring, like a key; use t:keys",
                    ));
                }
            }
        }
        super::extend_deadline(lua, waited.elapsed());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Editor;
    use greed_text::ClientId;

    #[test]
    fn a_job_done_before_its_coroutine_waits_still_wakes_it() {
        let host = super::super::Host::new(Editor::new(ClientId(1))).unwrap();
        let lua = &host.lua;
        // As when a coroutine's slice runs out between starting a job and
        // waiting for it, and the job finishes in between.
        let token = state_mut(lua).tasks.token();
        deliver(lua, token, 42).unwrap();
        let waits = lua
            .load("local token = ...; result = coroutine.yield(token)")
            .into_function()
            .unwrap();
        resume(lua, lua.create_thread(waits).unwrap(), token).unwrap();
        assert_eq!(lua.globals().get::<i64>("result").unwrap(), 42);
    }
}
