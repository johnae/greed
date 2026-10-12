//! `greed.fs`: the file system, for file trees, previews, project search and the
//! like. Failures return `nil` and a message, since a missing file is
//! usually something to show rather than a bug.

use std::cmp::Ordering;
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::path::{Component, Path, PathBuf};

use mlua::{FromLua, Function, IntoLuaMulti, Lua, MultiValue, Table, Value};

use super::jobs::{self, Output};
use super::state;
use crate::registry::PluginId;
use crate::search::{self, GrepOptions, LineMatch};

type LuaResult<T> = mlua::Result<T>;

/// `nil, message`.
pub(super) fn failure(lua: &Lua, err: impl std::fmt::Display) -> LuaResult<MultiValue> {
    (mlua::Value::Nil, err.to_string()).into_lua_multi(lua)
}

/// Creates the folder `path` goes in.
pub(super) fn create_parent(path: &Path) -> std::io::Result<()> {
    path.parent().map_or(Ok(()), std::fs::create_dir_all)
}

pub(super) fn module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let fs = lua.create_table()?;

    fs.set(
        "list",
        lua.create_function(|lua, (UserPath(dir), opts): (UserPath, Option<Table>)| {
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
        lua.create_function(|lua, (UserPath(path), limit): (UserPath, Option<usize>)| {
            super::secrets::guard(lua, Path::new(&path))?;
            match read(Path::new(&path), limit) {
                Ok(text) => text.into_lua_multi(lua),
                Err(err) => failure(lua, format!("can't read {path}: {err}")),
            }
        })?,
    )?;
    fs.set(
        "read_bytes",
        lua.create_function(|lua, UserPath(path): UserPath| {
            super::secrets::guard(lua, Path::new(&path))?;
            match std::fs::read(&path) {
                Ok(bytes) => lua.create_string(bytes)?.into_lua_multi(lua),
                Err(err) => failure(lua, format!("can't read {path}: {err}")),
            }
        })?,
    )?;

    fs.set(
        "stat",
        lua.create_function(|lua, UserPath(path): UserPath| {
            let meta = match std::fs::metadata(&path) {
                Ok(meta) => meta,
                Err(err)
                    if matches!(
                        err.kind(),
                        std::io::ErrorKind::NotFound | std::io::ErrorKind::NotADirectory
                    ) =>
                {
                    return mlua::Value::Nil.into_lua_multi(lua);
                }
                Err(err) => return failure(lua, format!("can't look at {path}: {err}")),
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
            stat.set("mode", meta.permissions().mode() & 0o7777)?;
            if let Some(since) = meta
                .modified()
                .ok()
                .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
            {
                stat.set("modified", since.as_secs_f64())?;
            }
            stat.into_lua_multi(lua)
        })?,
    )?;

    super::watch::add_to(lua, &fs, owner)?;
    add_writes(lua, &fs)?;

    fs.set(
        "cwd",
        lua.create_function(|_, ()| {
            Ok(std::env::current_dir()
                .map_or_else(|_| ".".to_owned(), |dir| dir.to_string_lossy().into_owned()))
        })?,
    )?;

    fs.set("dirs", lua.create_function(|lua, ()| dirs(lua))?)?;

    fs.set("grep", grep_function(lua)?)?;
    Ok(fs)
}

/// The functions in `greed.fs` that change files.
fn add_writes(lua: &Lua, fs: &Table) -> LuaResult<()> {
    fs.set(
        "write",
        lua.create_function(
            |lua, (UserPath(path), text, opts): (UserPath, mlua::LuaString, Option<Table>)| {
                guard_write(lua, Path::new(&path))?;
                let private = match opts {
                    Some(opts) => opts.get::<Option<bool>>("private")?.unwrap_or(false),
                    None => false,
                };
                let target = Path::new(&path);
                let contents = |out: &mut dyn std::io::Write| out.write_all(&text.as_bytes());
                let written = if private {
                    crate::files::write_private(target, contents)
                } else {
                    create_parent(target).and_then(|()| crate::files::write(target, contents))
                };
                match written {
                    Ok(()) => true.into_lua_multi(lua),
                    Err(err) => failure(lua, format!("can't write {path}: {err}")),
                }
            },
        )?,
    )?;

    fs.set(
        "mkdir",
        lua.create_function(|lua, UserPath(path): UserPath| {
            guard_write(lua, Path::new(&path))?;
            match std::fs::create_dir_all(&path) {
                Ok(()) => true.into_lua_multi(lua),
                Err(err) => failure(lua, format!("can't make {path}: {err}")),
            }
        })?,
    )?;

    fs.set(
        "remove",
        lua.create_function(|lua, (UserPath(path), opts): (UserPath, Option<Table>)| {
            let recursive = match opts {
                Some(opts) => opts.get::<Option<bool>>("recursive")?.unwrap_or(false),
                None => false,
            };
            guard_removal(lua, Path::new(&path), "remove")?;
            match remove(Path::new(&path), recursive) {
                Ok(()) => true.into_lua_multi(lua),
                Err(err) => failure(lua, format!("can't remove {path}: {err}")),
            }
        })?,
    )?;

    fs.set(
        "rename",
        lua.create_function(
            |lua, (UserPath(from), UserPath(to)): (UserPath, UserPath)| {
                guard_removal(lua, Path::new(&from), "move")?;
                guard_write(lua, Path::new(&to))?;
                match std::fs::rename(&from, &to) {
                    Ok(()) => true.into_lua_multi(lua),
                    Err(err) => failure(lua, format!("can't move {from} to {to}: {err}")),
                }
            },
        )?,
    )?;

    fs.set(
        "copy",
        lua.create_function(
            |lua, (UserPath(from), UserPath(to)): (UserPath, UserPath)| {
                super::secrets::guard(lua, Path::new(&from))?;
                guard_write(lua, Path::new(&to))?;
                let copied = create_parent(Path::new(&to)).and_then(|()| std::fs::copy(&from, &to));
                match copied {
                    Ok(_) => true.into_lua_multi(lua),
                    Err(err) => failure(lua, format!("can't copy {from} to {to}: {err}")),
                }
            },
        )?,
    )
}

/// `greed.fs.grep`, which searches in the background and waits, so a command
/// searching a big project never holds up the editor.
fn grep_function(lua: &Lua) -> LuaResult<Function> {
    let start = lua.create_function(
        |lua, (pattern, dir, opts): (String, Option<UserPath>, Option<Table>)| {
            let (dir, options) = grep_args(dir, opts.as_ref())?;
            // Greed's secrets file is read only through greed.secrets.
            let secrets = super::secrets::file(lua);
            Ok(jobs::start(
                lua,
                format!("greed.fs.grep {pattern:?} in {dir}"),
                move || {
                    let mut found = search::grep(Path::new(&dir), &pattern, options);
                    if let (Ok(lines), Some(secrets)) = (&mut found, &secrets) {
                        let root = Path::new(&dir);
                        lines
                            .retain(|m| !super::approvals::same_file(&root.join(&m.path), secrets));
                    }
                    Output::Grep(found)
                },
            ))
        },
    )?;
    jobs::waiting(lua, "greed.fs.grep", start)
}

/// The directory and options from `greed.fs.grep`'s arguments.
fn grep_args(dir: Option<UserPath>, opts: Option<&Table>) -> LuaResult<(String, GrepOptions)> {
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
    let dir = dir.map_or_else(|| ".".to_owned(), |UserPath(dir)| dir);
    Ok((dir, options))
}

/// How many matching lines `greed.fs.grep` returns unless told otherwise.
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

/// Fails if `path` is Greed's approvals or secrets file, which plugins
/// mustn't write.
pub(super) fn guard_write(lua: &Lua, path: &Path) -> LuaResult<()> {
    super::approvals::guard(lua, path)?;
    super::secrets::guard(lua, path)
}

/// Fails if removing or moving `path` (`what`) could take far more than
/// meant, as a computed path gone wrong would: the root, a home folder, a
/// path that climbs with `..`, or one holding Greed's approvals or secrets.
fn guard_removal(lua: &Lua, path: &Path, what: &str) -> LuaResult<()> {
    let refuse = |why: String| Err(mlua::Error::runtime(format!("won't {what} {why}")));
    if path.as_os_str().is_empty() {
        return refuse("an empty path".to_owned());
    }
    if path.components().any(|c| c == Component::ParentDir) {
        return refuse(format!("{}: it has ..", path.display()));
    }
    let resolved = super::approvals::resolved(path);
    if resolved.parent().is_none() {
        return refuse("the root folder".to_owned());
    }
    let test_home = state(lua).dirs.clone();
    for home in test_home
        .into_iter()
        .chain(std::env::var_os("HOME").map(PathBuf::from))
    {
        if super::approvals::resolved(&home) == resolved
            || home.canonicalize().is_ok_and(|h| h == resolved)
        {
            return refuse("the home folder".to_owned());
        }
    }
    guard_write(lua, path)?;
    if resolved.is_dir() {
        let approvals = state(lua).approvals.as_ref().map(|a| a.path().to_owned());
        for file in approvals.into_iter().chain(super::secrets::file(lua)) {
            if file.canonicalize().is_ok_and(|f| f.starts_with(&resolved)) {
                return refuse(format!("{}: it holds Greed's own files", path.display()));
            }
        }
    }
    Ok(())
}

/// Removes the file, link or empty folder at `path`, or with `recursive`
/// the folder and all in it. Nothing being there is fine.
fn remove(path: &Path, recursive: bool) -> std::io::Result<()> {
    let meta = match std::fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(err) => return Err(err),
    };
    if !meta.is_dir() {
        std::fs::remove_file(path)
    } else if recursive {
        std::fs::remove_dir_all(path)
    } else {
        std::fs::remove_dir(path)
    }
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

/// A path a plugin gave, with a leading `~` as the home folder: what every
/// `greed.fs` function, `greed.open` and `greed.load` take.
pub(super) struct UserPath(pub String);

impl FromLua for UserPath {
    fn from_lua(value: Value, lua: &Lua) -> LuaResult<Self> {
        Ok(Self(expand_home(lua, String::from_lua(value, lua)?)))
    }
}

/// `path` with a leading `~` as the home folder (a test's own, in tests), as
/// a shell would have it, so `:open ~/notes.md` opens that file and not one
/// in a folder called `~`.
pub(super) fn expand_home(lua: &Lua, path: String) -> String {
    let rest = match path.strip_prefix('~') {
        Some(rest) if rest.is_empty() || rest.starts_with('/') => rest,
        _ => return path,
    };
    let home = match &state(lua).dirs {
        Some(root) => Some(root.clone()),
        None => std::env::var_os("HOME").map(std::path::PathBuf::from),
    };
    match home {
        Some(home) => format!("{}{rest}", home.to_string_lossy().trim_end_matches('/')),
        None => path,
    }
}

/// `greed.fs.dirs()`: home, config, cache and data folders, and the config
/// greed ssh brought; for tests, folders of their own.
fn dirs(lua: &Lua) -> LuaResult<Table> {
    let dirs = lua.create_table()?;
    if let Some(root) = state(lua).dirs.clone() {
        for (name, dir) in [
            ("home", ""),
            ("config", "config"),
            ("cache", "cache"),
            ("data", "data"),
        ] {
            dirs.set(name, root.join(dir).to_string_lossy().trim_end_matches('/'))?;
        }
        return Ok(dirs);
    }
    dirs.set("home", std::env::var("HOME").ok())?;
    let folder = |kind| crate::dirs::dir(kind).map(|dir| dir.to_string_lossy().into_owned());
    // This machine's own config, where plugins agents write go.
    dirs.set("config", folder(crate::dirs::Kind::Config))?;
    dirs.set("cache", folder(crate::dirs::Kind::Cache))?;
    // Where plugins made in the editor go when the config can't be written,
    // like one Nix manages.
    dirs.set("data", folder(crate::dirs::Kind::Data))?;
    // The copy of your config `greed ssh` brought, on its far end.
    dirs.set("brought", std::env::var("GREED_SSH_CONFIG_DIR").ok())?;
    Ok(dirs)
}
