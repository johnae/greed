//! `kern.fs`: reading the file system, for file trees, previews and the
//! like. Failures return `nil` and a message, since a missing file is
//! usually something to show rather than a bug.

use std::cmp::Ordering;
use std::io::Read;
use std::path::Path;

use mlua::{IntoLuaMulti, Lua, MultiValue, Table};

type LuaResult<T> = mlua::Result<T>;

/// `nil, message`.
fn failure(lua: &Lua, err: impl std::fmt::Display) -> LuaResult<MultiValue> {
    (mlua::Value::Nil, err.to_string()).into_lua_multi(lua)
}

pub(super) fn module(lua: &Lua) -> LuaResult<Table> {
    let fs = lua.create_table()?;

    fs.set(
        "list",
        lua.create_function(|lua, (dir, opts): (String, Option<Table>)| {
            let flag = |key: &str| -> LuaResult<bool> {
                Ok(match &opts {
                    Some(opts) => opts.get::<Option<bool>>(key)?.unwrap_or(false),
                    None => false,
                })
            };
            match list(Path::new(&dir), flag("hidden")?, flag("ignored")?) {
                Ok(entries) => {
                    let list = lua.create_table()?;
                    for (name, is_dir) in entries {
                        let entry = lua.create_table()?;
                        entry.set("name", name)?;
                        entry.set("dir", is_dir)?;
                        list.push(entry)?;
                    }
                    list.into_lua_multi(lua)
                }
                Err(err) => failure(lua, format!("can't list {dir}: {err}")),
            }
        })?,
    )?;

    fs.set(
        "read",
        lua.create_function(|lua, (path, limit): (String, Option<usize>)| {
            match read(Path::new(&path), limit) {
                Ok(text) => text.into_lua_multi(lua),
                Err(err) => failure(lua, format!("can't read {path}: {err}")),
            }
        })?,
    )?;

    fs.set(
        "stat",
        lua.create_function(|lua, path: String| {
            let Ok(meta) = std::fs::metadata(&path) else {
                return Ok(None);
            };
            let kind = if meta.is_dir() {
                "dir"
            } else if meta.is_file() {
                "file"
            } else {
                "other"
            };
            let stat = lua.create_table()?;
            stat.set("kind", kind)?;
            stat.set("size", if meta.is_dir() { 0 } else { meta.len() })?;
            Ok(Some(stat))
        })?,
    )?;
    Ok(fs)
}

/// The entries directly in `dir` as `(name, is_dir)`: folders first, then
/// by name ignoring case. Hidden entries and ones `.gitignore` excludes are
/// left out unless asked for.
fn list(dir: &Path, hidden: bool, ignored: bool) -> std::io::Result<Vec<(String, bool)>> {
    // Fail on a missing directory, which the walker would skip silently.
    std::fs::read_dir(dir)?;
    let mut entries: Vec<(String, bool)> = ignore::WalkBuilder::new(dir)
        .max_depth(Some(1))
        .hidden(!hidden)
        .git_ignore(!ignored)
        .git_exclude(!ignored)
        .git_global(!ignored)
        .ignore(!ignored)
        .parents(!ignored)
        .require_git(false)
        .build()
        .filter_map(Result::ok)
        .filter(|entry| entry.depth() == 1)
        .map(|entry| {
            let is_dir = entry.path().is_dir();
            (entry.file_name().to_string_lossy().into_owned(), is_dir)
        })
        .collect();
    entries.sort_by(|(a, a_dir), (b, b_dir)| b_dir.cmp(a_dir).then_with(|| compare_names(a, b)));
    Ok(entries)
}

fn compare_names(a: &str, b: &str) -> Ordering {
    a.to_lowercase()
        .cmp(&b.to_lowercase())
        .then_with(|| a.cmp(b))
}

/// The file's text, or its first `limit` bytes, cut back to a character
/// boundary. Invalid UTF-8 is replaced.
fn read(path: &Path, limit: Option<usize>) -> std::io::Result<String> {
    let Some(limit) = limit else {
        return Ok(String::from_utf8_lossy(&std::fs::read(path)?).into_owned());
    };
    let mut bytes = Vec::new();
    std::fs::File::open(path)?
        .take(limit as u64)
        .read_to_end(&mut bytes)?;
    // Drop a character the limit cut in half.
    if let Err(err) = std::str::from_utf8(&bytes)
        && err.error_len().is_none()
    {
        bytes.truncate(err.valid_up_to());
    }
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}
