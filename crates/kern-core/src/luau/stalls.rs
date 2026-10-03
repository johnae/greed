//! The watchdog: every run of plugin code on the editor's thread is timed,
//! and one that held the editor up is kept with the plugin and what it was
//! running, so a freeze can be traced to its cause. `kern.stalls()` lists
//! them; long ones are also said right away.

use std::collections::VecDeque;
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
/// run being timed now, which counts against them rather than it.
#[derive(Default)]
pub(crate) struct Stalls {
    kept: VecDeque<Stall>,
    inner: Duration,
}

/// Notes that `plugin`'s code ran for `took` running `what` (a command's
/// name, "the status line", ...), keeping it if that held the editor up.
fn note(lua: &Lua, took: Duration, plugin: Option<&str>, what: &str) {
    if took < STALL {
        return;
    }
    let at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64());
    let state = &mut *state_mut(lua);
    if took >= SAY {
        state.editor.echo(format!(
            "{} held the editor up for {} ms ({what}) - :stalls lists these",
            plugin.unwrap_or("Kern"),
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

/// `kern.stalls()`: the runs that held the editor up, newest first.
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
