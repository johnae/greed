//! Files plugins watch: `kern.fs.watch(path)`, then a "file.changed" event
//! whenever the file changes, from inside the editor or out. The session
//! looks every half second; a few `stat`s, so there is no watcher thread.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use mlua::{Lua, Table};

use super::api::emit;
use super::{state, state_mut};

type LuaResult<T> = mlua::Result<T>;

/// What a file looked like: when it was last written and how big it was,
/// or nothing while it doesn't exist.
type Stamp = Option<(Option<SystemTime>, u64)>;

fn stamp(path: &Path) -> Stamp {
    std::fs::metadata(path)
        .ok()
        .map(|meta| (meta.modified().ok(), meta.len()))
}

/// The watched files, each with how it looked when last checked.
#[derive(Default)]
pub(crate) struct Watches {
    files: HashMap<PathBuf, Stamp>,
}

/// Adds `watch(path)` to `fs`, the `kern.fs` table: starts watching `path`,
/// if it isn't already.
pub(super) fn add_to(lua: &Lua, fs: &Table) -> LuaResult<()> {
    fs.set(
        "watch",
        lua.create_function(|lua, path: String| {
            let path = PathBuf::from(path);
            let now = stamp(&path);
            state_mut(lua).watches.files.entry(path).or_insert(now);
            Ok(())
        })?,
    )
}

/// Tells plugins about each watched file that changed since the last look.
pub(super) fn check(lua: &Lua) -> LuaResult<()> {
    let changed: Vec<PathBuf> = {
        let mut state = state_mut(lua);
        state
            .watches
            .files
            .iter_mut()
            .filter_map(|(path, before)| {
                let now = stamp(path);
                (now != *before).then(|| {
                    *before = now;
                    path.clone()
                })
            })
            .collect()
    };
    for path in changed {
        let event = lua.create_table()?;
        event.set("path", path.to_string_lossy())?;
        emit(lua, "file.changed", &event)?;
    }
    Ok(())
}

/// Whether any file is watched, so the session knows to look.
pub(super) fn watching(lua: &Lua) -> bool {
    !state(lua).watches.files.is_empty()
}
