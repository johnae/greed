//! The watchdog: every run of plugin code on the editor's thread is timed,
//! and one that held the editor up is kept with the plugin and what it was
//! running, so a freeze can be traced to its cause. `greed.stalls()` lists
//! them; long ones are also said right away.

use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use mlua::{Lua, Table};

use super::{state, state_mut};

type LuaResult<T> = mlua::Result<T>;

/// A run at least this long held the editor up noticeably.
const STALL: Duration = Duration::from_millis(50);

/// One this long is said as it happens.
const SAY: Duration = Duration::from_millis(250);

/// How many stalls are kept.
const KEEP: usize = 50;

/// A run that held the editor up.
pub(crate) struct Stall {
    took: Duration,
    plugin: Option<String>,
    what: String,
    /// When, in seconds since 1970.
    at: f64,
}

/// The stalls kept, oldest first, and the time nested runs took during the
/// run being timed now, which counts against them rather than it. While a
/// profile is being taken, every run is added to it too.
#[derive(Default)]
pub(crate) struct Stalls {
    kept: VecDeque<Stall>,
    inner: Duration,
    profile: Option<HashMap<(Option<String>, String), Spent>>,
    /// Keeps long stalls without saying them, for tests: how long a run
    /// takes depends on how busy the machine is, and a test checking what
    /// was said shouldn't.
    pub(crate) quiet: bool,
}

/// What one plugin doing one thing took while a profile was taken.
#[derive(Default, Clone, Copy)]
struct Spent {
    total: Duration,
    longest: Duration,
    runs: u32,
}

/// Notes that `plugin`'s code ran for `took` running `what` (a command's
/// name, "the status line", ...), keeping it if that held the editor up.
fn note(lua: &Lua, took: Duration, plugin: Option<&str>, what: &str) {
    if let Some(profile) = &mut state_mut(lua).stalls.profile {
        let spent = profile
            .entry((plugin.map(str::to_owned), what.to_owned()))
            .or_default();
        spent.total += took;
        spent.longest = spent.longest.max(took);
        spent.runs += 1;
    }
    if took < STALL {
        return;
    }
    let at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64());
    let state = &mut *state_mut(lua);
    if took >= SAY && !state.stalls.quiet {
        state.editor.echo(format!(
            "{} held the editor up for {} ms ({what}) - :stalls lists these",
            plugin.unwrap_or("Greed"),
            took.as_millis()
        ));
    }
    let kept = &mut state.stalls.kept;
    if kept.len() == KEEP {
        kept.pop_front();
    }
    kept.push_back(Stall {
        took,
        plugin: plugin.map(str::to_owned),
        what: what.to_owned(),
        at,
    });
}

/// `greed.stalls()`: the runs that held the editor up, newest first.
pub(super) fn list(lua: &Lua) -> LuaResult<Table> {
    let list = lua.create_table()?;
    for stall in state(lua).stalls.kept.iter().rev() {
        let t = lua.create_table()?;
        t.set("ms", stall.took.as_secs_f64() * 1000.0)?;
        t.set("plugin", stall.plugin.as_deref())?;
        t.set("what", stall.what.as_str())?;
        t.set("time", stall.at)?;
        list.push(t)?;
    }
    Ok(list)
}

/// `greed.profile`: `start()` begins counting how long every run of plugin
/// code and the editor's own drawing takes; `stop()` ends it and returns
/// what was counted, the most time first.
pub(super) fn profile_module(lua: &Lua) -> LuaResult<Table> {
    let profile = lua.create_table()?;
    profile.set(
        "start",
        lua.create_function(|lua, ()| {
            state_mut(lua).stalls.profile = Some(HashMap::new());
            Ok(())
        })?,
    )?;
    profile.set(
        "stop",
        lua.create_function(|lua, ()| {
            let counted = state_mut(lua).stalls.profile.take().unwrap_or_default();
            let mut rows: Vec<_> = counted.into_iter().collect();
            rows.sort_by_key(|(_, spent)| std::cmp::Reverse(spent.total));
            let list = lua.create_table()?;
            for ((plugin, what), spent) in rows {
                let row = lua.create_table()?;
                row.set("plugin", plugin)?;
                row.set("what", what)?;
                row.set("ms", spent.total.as_secs_f64() * 1000.0)?;
                row.set("longest", spent.longest.as_secs_f64() * 1000.0)?;
                row.set("runs", spent.runs)?;
                list.push(row)?;
            }
            Ok(list)
        })?,
    )?;
    profile.set(
        "running",
        lua.create_function(|lua, ()| Ok(state(lua).stalls.profile.is_some()))?,
    )?;
    Ok(profile)
}

/// Runs `f`, `plugin`'s code doing `what` (a command's name, "the status
/// line", ...), and notes it if it held the editor up. Time spent in timed
/// runs inside it counts against those. Returns what `f` did and how long it
/// took in all.
pub(super) fn timed<R>(
    lua: &Lua,
    plugin: Option<&str>,
    what: &str,
    f: impl FnOnce() -> R,
) -> (R, Duration) {
    let outer = std::mem::take(&mut state_mut(lua).stalls.inner);
    let started = Instant::now();
    let result = f();
    let took = started.elapsed();
    let inner = std::mem::replace(&mut state_mut(lua).stalls.inner, outer + took);
    note(lua, took.saturating_sub(inner), plugin, what);
    (result, took)
}
