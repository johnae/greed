//! Files plugins watch: `greed.fs.watch(path)`, then a "file.changed" event
//! whenever the file changes, from inside the editor or out. The session
//! looks every half second; a few `stat`s, so there is no watcher thread.

use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use mlua::{Lua, Table};

use super::api::emit;
use super::fs::UserPath;
use super::{state, state_mut};
use crate::registry::PluginId;

type LuaResult<T> = mlua::Result<T>;

/// What a file looked like: when it was last written, how big it was and
/// which file it was (its inode, new each time a write puts a new file in
/// its place, as Greed's writes do, wherever the clock is too coarse to
/// tell two writes apart), or nothing while it doesn't exist.
type Stamp = Option<(Option<SystemTime>, u64, u64)>;

fn stamp(path: &Path) -> Stamp {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(path)
        .ok()
        .map(|meta| (meta.modified().ok(), meta.len(), meta.ino()))
}

/// The watched files, each with how it looked when last checked and the
/// plugins watching it.
#[derive(Default)]
pub(crate) struct Watches {
    files: HashMap<PathBuf, (Stamp, BTreeSet<PluginId>)>,
}

impl Watches {
    /// Stops `owner`'s watches, and those of files nobody else watches.
    pub fn remove_owned_by(&mut self, owner: &str) {
        self.files.retain(|_, (_, owners)| {
            owners.remove(owner);
            !owners.is_empty()
        });
    }
}

/// Adds `watch(path)` to `fs`, the `greed.fs` table: starts watching `path`
/// for `owner`, if it isn't already.
pub(super) fn add_to(lua: &Lua, fs: &Table, owner: &PluginId) -> LuaResult<()> {
    let owner = owner.clone();
    fs.set(
        "watch",
        lua.create_function(move |lua, UserPath(path): UserPath| {
            let path = PathBuf::from(path);
            let now = stamp(&path);
            state_mut(lua)
                .watches
                .files
                .entry(path)
                .or_insert((now, BTreeSet::new()))
                .1
                .insert(owner.clone());
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
            .filter_map(|(path, (before, _))| {
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
