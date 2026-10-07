//! Errors from plugin code that nothing caught: a command, an event handler
//! or a task failing. Each is kept with the plugin, what it was running and
//! where in its Luau it failed, so `greed.errors()` (and `:errors`) can say
//! more than the one line the status line has room for. A session also
//! writes them to its log.

use std::collections::VecDeque;
use std::time::{SystemTime, UNIX_EPOCH};

use mlua::{Function, Lua, Table, Thread};

use super::{state, state_mut};

type LuaResult<T> = mlua::Result<T>;

/// How many errors are kept.
const KEEP: usize = 100;

/// An error from plugin code.
pub(crate) struct Failure {
    plugin: String,
    what: String,
    message: String,
    traceback: String,
    /// When, in seconds since 1970.
    at: f64,
}

/// The errors kept, oldest first.
#[derive(Default)]
pub(crate) struct Errors {
    kept: VecDeque<Failure>,
}

/// Keeps `err`, which `thread` failed with while running `what` for
/// `plugin`, and gives it back unchanged, so code that reads errors (the
/// agent asking for an approval, say) sees what it always did. Code no
/// plugin owns, like a test's body, isn't kept.
pub(super) fn record(
    lua: &Lua,
    thread: &Thread,
    plugin: Option<&str>,
    what: &str,
    err: mlua::Error,
) -> mlua::Error {
    let Some(plugin) = plugin else {
        return err;
    };
    let message = err.to_string();
    let traceback = traceback(lua, thread).unwrap_or_default();
    if state(lua).session_name.is_some() {
        // A session's output goes to its log.
        eprintln!("{plugin} ({what}): {message}\n{traceback}");
    }
    let at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64());
    let errors = &mut state_mut(lua).errors.kept;
    errors.push_back(Failure {
        plugin: plugin.to_owned(),
        what: what.to_owned(),
        message,
        traceback,
        at,
    });
    while errors.len() > KEEP {
        errors.pop_front();
    }
    err
}

/// Who and what `message` came from, "notes (on buffer.opened)", if it's
/// the error kept last.
pub(super) fn source_of(lua: &Lua, message: &str) -> Option<String> {
    let state = state(lua);
    let last = state.errors.kept.back()?;
    (last.message == message).then(|| format!("{} ({})", last.plugin, last.what))
}

/// Where `thread` was when it failed, from Luau's `debug.traceback`.
fn traceback(lua: &Lua, thread: &Thread) -> LuaResult<String> {
    let debug: Table = lua.globals().get("debug")?;
    let traceback: Function = debug.get("traceback")?;
    traceback.call((thread.clone(), ""))
}

/// `greed.errors()`: the errors kept, newest first.
pub(super) fn list(lua: &Lua) -> LuaResult<Table> {
    let list = lua.create_table()?;
    for failure in state(lua).errors.kept.iter().rev() {
        let t = lua.create_table()?;
        t.set("plugin", failure.plugin.as_str())?;
        t.set("what", failure.what.as_str())?;
        t.set("message", failure.message.as_str())?;
        t.set("traceback", failure.traceback.as_str())?;
        t.set("time", failure.at)?;
        list.push(t)?;
    }
    Ok(list)
}
