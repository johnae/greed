//! `kern.fs`: the file system, for file trees, previews, project search and the
//! like. Failures return `nil` and a message, since a missing file is
//! usually something to show rather than a bug.

use std::cmp::Ordering;
use std::io::Read;
use std::path::Path;

use mlua::{Function, IntoLuaMulti, Lua, MultiValue, Table};

use super::jobs::{self, Output};
use crate::search::{self, GrepOptions, LineMatch};

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

    fs.set(
        "write",
        lua.create_function(|lua, (path, text): (String, mlua::LuaString)| {
            match std::fs::write(&path, text.as_bytes()) {
                Ok(()) => true.into_lua_multi(lua),
                Err(err) => failure(lua, format!("can't write {path}: {err}")),
            }
        })?,
    )?;

    fs.set(
        "cwd",
        lua.create_function(|_, ()| {
            Ok(std::env::current_dir()
                .map_or_else(|_| ".".to_owned(), |dir| dir.to_string_lossy().into_owned()))
        })?,
    )?;

    fs.set("grep", grep_function(lua)?)?;
    Ok(fs)
}

/// `kern.fs.grep`, which waits for a background search when it can, so a
/// command searching a big project doesn't hold up the editor, and
/// searches right away anywhere else.
fn grep_function(lua: &Lua) -> LuaResult<Function> {
    let now = lua.create_function(
        |lua, (pattern, dir, opts): (String, Option<String>, Option<Table>)| {
            let (dir, options) = grep_args(dir, opts.as_ref())?;
            match search::grep(Path::new(&dir), &pattern, options) {
                Ok(lines) => grep_to_lua(lua, lines)?.into_lua_multi(lua),
                Err(err) => failure(lua, err),
            }
        },
    )?;
    let start = lua.create_function(
        |lua, (pattern, dir, opts): (String, Option<String>, Option<Table>)| {
            let (dir, options) = grep_args(dir, opts.as_ref())?;
            Ok(jobs::start(lua, move || {
                Output::Grep(search::grep(Path::new(&dir), &pattern, options))
            }))
        },
    )?;
    lua.load(
        r"
        local now, start = ...
        return function(...)
            if coroutine.isyieldable() then
                return coroutine.yield(start(...))
            end
            return now(...)
        end
        ",
    )
    .set_name("=kern.fs.grep")
    .call((now, start))
}

/// The directory and options from `kern.fs.grep`'s arguments.
fn grep_args(dir: Option<String>, opts: Option<&Table>) -> LuaResult<(String, GrepOptions)> {
    let get =
        |key: &str| -> LuaResult<Option<mlua::Value>> { opts.map_or(Ok(None), |o| o.get(key)) };
    let flag = |key: &str| -> LuaResult<bool> {
        Ok(get(key)?.and_then(|v| v.as_boolean()).unwrap_or(false))
    };
    let options = GrepOptions {
        hidden: flag("hidden")?,
        ignored: flag("ignored")?,
        limit: get("limit")?
            .and_then(|v| v.as_usize())
            .unwrap_or(DEFAULT_GREP_LIMIT),
    };
    Ok((dir.unwrap_or_else(|| ".".to_owned()), options))
}

/// How many matching lines `kern.fs.grep` returns unless told otherwise.
const DEFAULT_GREP_LIMIT: usize = 10_000;

pub(super) fn grep_to_lua(lua: &Lua, lines: Vec<LineMatch>) -> LuaResult<Table> {
    let list = lua.create_table()?;
    for found in lines {
        let entry = lua.create_table()?;
        entry.set("path", found.path)?;
        entry.set("line", found.line)?;
        entry.set("text", found.text)?;
        let matches = lua.create_table()?;
        for m in found.matches {
            let range = lua.create_table()?;
            range.set("from", m.start)?;
            range.set("to", m.end)?;
            matches.push(range)?;
        }
        entry.set("matches", matches)?;
        list.push(entry)?;
    }
    Ok(list)
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
