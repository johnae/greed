//! `greed.plugin`: loading and unloading plugins while the editor runs, and
//! checking a plugin before it's loaded: strict type checking against
//! Greed's API, then its tests, the way `greed test` runs them.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

use mlua::{Lua, Table};

use super::jobs::{self, Output};
use super::{api, load_dir, plugin_dirs, plugin_name, plugin_names, state};

type LuaResult<T> = mlua::Result<T>;

/// Numbers the folders plugins are type checked in.
static NEXT_CHECK: AtomicUsize = AtomicUsize::new(0);

/// What checking a plugin found.
pub struct Check {
    /// Whether `luau-analyze` passed and what it said, or why it didn't run.
    pub types: Result<(bool, String), String>,
    /// Each test's file, name and failure, if it failed.
    pub tests: Result<Vec<(String, String, Option<String>)>, String>,
}

pub(super) fn module(lua: &Lua) -> LuaResult<Table> {
    let plugin = lua.create_table()?;
    plugin.set(
        "list",
        lua.create_function(|lua, ()| Ok(plugin_names(lua)))?,
    )?;
    plugin.set(
        "unload",
        lua.create_function(|lua, name: String| super::unload(lua, &name).map_err(api::into_lua))?,
    )?;
    plugin.set(
        "load",
        lua.create_function(|lua, (dir, name): (String, Option<String>)| {
            match name {
                Some(name) => super::load_dir_as(lua, Path::new(&dir), &name),
                None => load_dir(lua, Path::new(&dir)),
            }
            .map(|name| name.to_string())
            .map_err(api::into_lua)
        })?,
    )?;
    plugin.set(
        "describe",
        lua.create_function(|lua, dir: String| super::describe(lua, Path::new(&dir)))?,
    )?;
    plugin.set(
        "pending",
        lua.create_function(|lua, ()| {
            let list = lua.create_table()?;
            let pending = state(lua).pending.clone();
            for dir in pending {
                if let Ok(found) = super::describe(lua, &dir) {
                    list.push(found)?;
                }
            }
            Ok(list)
        })?,
    )?;
    plugin.set(
        "approve",
        lua.create_function(|lua, dir: String| {
            super::approve(lua, Path::new(&dir))
                .map(|name| name.to_string())
                .map_err(api::into_lua)
        })?,
    )?;
    plugin.set(
        "dirs",
        lua.create_function(|lua, ()| {
            let dirs = lua.create_table()?;
            for (name, dir) in plugin_dirs(lua) {
                dirs.set(name.to_string(), dir.to_string_lossy().into_owned())?;
            }
            Ok(dirs)
        })?,
    )?;
    let start = lua.create_function(|lua, dir: String| {
        let dir = PathBuf::from(dir);
        let name = plugin_name(&dir).map_err(api::into_lua)?;
        let approved = super::approved_for(lua, &dir);
        // Every loaded plugin but an older version of this one, which the
        // checked one replaces.
        let others: Vec<(String, PathBuf)> = plugin_dirs(lua)
            .into_iter()
            .filter(|(other, _)| **other != *name)
            .map(|(other, dir)| (other.to_string(), dir))
            .collect();
        Ok(jobs::start(lua, move || {
            Output::Check(check(&dir, &others, approved.as_ref()))
        }))
    })?;
    plugin.set(
        "check",
        lua.load(
            r#"
            local start = ...
            return function(dir)
                if not coroutine.isyieldable() then
                    error("greed.plugin.check can only be used in a command or event handler", 2)
                end
                return coroutine.yield(start(dir))
            end
            "#,
        )
        .set_name("=greed.plugin.check")
        .call::<mlua::Function>(start)?,
    )?;
    Ok(plugin)
}

/// Type checks and tests the plugin in `dir` against the `others`. Its
/// tests run with only what was `approved` for it, when it needs approving.
fn check(dir: &Path, others: &[(String, PathBuf)], approved: Option<&BTreeSet<String>>) -> Check {
    let types = analyze(dir, others);
    let mut plugins: Vec<PathBuf> = others.iter().map(|(_, dir)| dir.clone()).collect();
    plugins.push(dir.to_owned());
    let tests = super::testing::run_checked(&plugins, dir, approved)
        .map(|results| {
            results
                .into_iter()
                .map(|r| {
                    let file = r
                        .file
                        .file_name()
                        .map_or_else(String::new, |f| f.to_string_lossy().into_owned());
                    (file, r.name, r.failure)
                })
                .collect()
        })
        .map_err(|err| err.to_string());
    Check { types, tests }
}

/// Runs `luau-analyze` in strict mode on the plugin's files, with
/// `require("@greed")` and `require("@name")` for each other plugin pointing
/// at their types. Returns whether it passed and what it said, or why it
/// couldn't run.
fn analyze(dir: &Path, others: &[(String, PathBuf)]) -> Result<(bool, String), String> {
    let analyzer = crate::lsp::which("luau-analyze")
        .ok_or("luau-analyze isn't installed, so types weren't checked")?;
    let mut aliases = serde_json::Map::new();
    for (name, plugin) in others {
        // Names like "user/config" can't be required, and aren't valid
        // aliases.
        if !name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        {
            continue;
        }
        // luau-analyze runs in a temporary folder, so relative paths break.
        let plugin = &std::fs::canonicalize(plugin).unwrap_or_else(|_| plugin.clone());
        aliases.insert(name.clone(), plugin.to_string_lossy().into());
        // Greed's types live next to the default plugins.
        if name == "core"
            && let Some(runtime) = plugin.parent().and_then(Path::parent)
        {
            aliases.insert(
                "greed".to_owned(),
                runtime.join("types/greed").to_string_lossy().into(),
            );
        }
    }
    let luaurc = serde_json::json!({ "languageMode": "strict", "aliases": aliases });
    // luau-analyze only applies a .luaurc above a file's own folder, and
    // follows links, so the plugin's code is checked from a copy inside a
    // folder holding one. That also leaves the plugin's folder as it was.
    let wrapper = std::env::temp_dir().join(format!(
        "greed-check-{}-{}",
        std::process::id(),
        NEXT_CHECK.fetch_add(1, Ordering::Relaxed)
    ));
    let result = (|| {
        std::fs::create_dir_all(&wrapper)?;
        std::fs::write(wrapper.join(".luaurc"), luaurc.to_string())?;
        let mut sources = Vec::new();
        collect_luau(dir, &mut sources);
        let mut files = Vec::with_capacity(sources.len());
        for source in &sources {
            let Ok(relative) = source.strip_prefix(dir) else {
                continue;
            };
            let file = Path::new("plugin").join(relative);
            let copy = wrapper.join(&file);
            std::fs::create_dir_all(copy.parent().unwrap_or(&wrapper))?;
            std::fs::copy(source, copy)?;
            files.push(file);
        }
        // One thread: luau-analyze's worker threads race on shared state.
        Command::new(analyzer)
            .arg("-j1")
            .current_dir(&wrapper)
            .args(&files)
            .output()
    })();
    let _ = std::fs::remove_dir_all(&wrapper);
    let output = result.map_err(|err| err.to_string())?;
    let said = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    Ok((output.status.success(), said.trim().to_owned()))
}

fn collect_luau(dir: &Path, files: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for path in entries.flatten().map(|entry| entry.path()) {
        if path.is_dir() {
            collect_luau(&path, files);
        } else if path.extension().is_some_and(|ext| ext == "luau") {
            files.push(path);
        }
    }
}

/// The check as `{ types = { ok, output } or { skipped }, tests = { passed,
/// failed = { { file, name, message } } } or { error } }`.
pub(super) fn to_lua(lua: &Lua, check: Check) -> LuaResult<Table> {
    let report = lua.create_table()?;
    let types = lua.create_table()?;
    match check.types {
        Ok((ok, output)) => {
            types.set("ok", ok)?;
            types.set("output", output)?;
        }
        Err(why) => types.set("skipped", why)?,
    }
    report.set("types", types)?;
    let tests = lua.create_table()?;
    match check.tests {
        Ok(results) => {
            let failed = lua.create_table()?;
            let mut passed = 0;
            for (file, name, failure) in results {
                match failure {
                    None => passed += 1,
                    Some(message) => {
                        let entry = lua.create_table()?;
                        entry.set("file", file)?;
                        entry.set("name", name)?;
                        entry.set("message", message)?;
                        failed.push(entry)?;
                    }
                }
            }
            tests.set("passed", passed)?;
            tests.set("failed", failed)?;
        }
        Err(error) => tests.set("error", error)?,
    }
    report.set("tests", tests)?;
    Ok(report)
}
