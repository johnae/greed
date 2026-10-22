//! `greed.plugin`: loading and unloading plugins while the editor runs, and
//! checking a plugin before it's loaded: strict type checking against
//! Greed's API, then its tests, the way `greed test` runs them.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

use mlua::{Function, Lua, Table};

use super::arity::NoArgs;
use super::jobs::{self, Output};
use super::{
    api, capabilities, load_dir, plugin_dirs, plugin_name, plugin_names, state, state_mut,
};
use crate::registry::PluginId;

type LuaResult<T> = mlua::Result<T>;

/// Numbers the folders plugins are type checked in.
static NEXT_CHECK: AtomicUsize = AtomicUsize::new(0);

/// What checking a plugin found.
pub struct Check {
    /// Whether `luau-analyze` passed and what it said, or why it didn't run.
    pub types: Result<(bool, String), String>,
    /// Each test's file, name and failure, if it failed.
    pub tests: Result<Vec<(String, String, Option<String>)>, String>,
    /// What looks wrong once it's loaded with the others, like keys bound
    /// to commands that don't exist.
    pub warnings: Vec<String>,
}

/// What a plugin's registry added for another plugin, to take away when
/// that plugin goes: see `greed.plugin.tie`.
pub(crate) struct Tie {
    /// The plugin whose code added it.
    by: PluginId,
    /// The plugin whose registry it's in, whose code `remove` is.
    owner: PluginId,
    remove: Function,
}

/// Takes the ties of what `name` added, to run, and drops those of its own
/// registries, which go with it.
pub(super) fn untie(ties: &mut Vec<Tie>, name: &str) -> Vec<(PluginId, Function)> {
    let mut removes = Vec::new();
    ties.retain(|tie| {
        if *tie.by == *name {
            removes.push((tie.owner.clone(), tie.remove.clone()));
        }
        *tie.by != *name && *tie.owner != *name
    });
    removes
}

pub(super) fn module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let plugin = lua.create_table()?;
    add_registry_functions(lua, &plugin, owner)?;
    plugin.set(
        "list",
        lua.create_function(|lua, NoArgs| Ok(plugin_names(lua)))?,
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
        lua.create_function(|lua, NoArgs| {
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
            if !super::capabilities::started_within(lua, "plugins") {
                return Err(mlua::Error::runtime(
                    "a plugin started this, and approving plugins is yours to do: :plugins-approve",
                ));
            }
            super::approve(lua, Path::new(&dir))
                .map(|name| name.to_string())
                .map_err(api::into_lua)
        })?,
    )?;
    plugin.set(
        "dirs",
        lua.create_function(|lua, NoArgs| {
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
        // checked one replaces. A config's folder has no manifest, and isn't
        // something other plugins build on.
        let others: Vec<(String, PathBuf)> = plugin_dirs(lua)
            .into_iter()
            .filter(|(other, dir)| **other != *name && dir.join("plugin.toml").is_file())
            .map(|(other, dir)| (other.to_string(), dir))
            .collect();
        Ok(jobs::start(
            lua,
            format!("greed.plugin.check {}", dir.display()),
            move || Output::Check(check(&dir, &others, approved.as_ref())),
        ))
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
    // A plugin that fails to load says so in its tests.
    let warnings = super::testing::warnings(&plugins, approved).unwrap_or_default();
    Check {
        types,
        tests,
        warnings,
    }
}

/// Runs `luau-analyze` in strict mode on the plugin's files, with
/// `require("@greed")` and `require("@name")` for each other plugin pointing
/// at their types. Returns whether it passed and what it said, or why it
/// couldn't run.
fn analyze(dir: &Path, others: &[(String, PathBuf)]) -> Result<(bool, String), String> {
    let analyzer = crate::lsp::which("luau-analyze")
        .ok_or("luau-analyze isn't installed, so types weren't checked")?;
    // Names like "user/config" can't be required, and aren't valid aliases.
    let requirable = |name: &str| {
        name.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    };
    let mut aliases = serde_json::Map::new();
    for (name, plugin) in others {
        if !requirable(name) {
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
    // luau-analyze only applies a .luaurc above a file's own folder, and
    // follows links, so the plugin's code is checked from a copy inside a
    // folder holding one. That also leaves the plugin's folder as it was.
    // Canonical, as luau-analyze resolves macOS's linked temporary folder.
    let temp = std::env::temp_dir();
    let wrapper = std::fs::canonicalize(&temp).unwrap_or(temp).join(format!(
        "greed-check-{}-{}",
        std::process::id(),
        NEXT_CHECK.fetch_add(1, Ordering::Relaxed)
    ));
    // Its tests require the plugin by its name, as they do when they run.
    if let Ok(name) = super::plugin_name(dir)
        && requirable(&name)
    {
        aliases.insert(name, wrapper.join("plugin").to_string_lossy().into());
    }
    let luaurc = serde_json::json!({ "languageMode": "strict", "aliases": aliases });
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
        let mut argv = vec![analyzer.as_os_str(), "-j1".as_ref()];
        argv.extend(files.iter().map(|file| file.as_os_str()));
        crate::child::command(&argv, Some(&wrapper), &[], false)?.output()
    })();
    let _ = std::fs::remove_dir_all(&wrapper);
    let output = result.map_err(|err| err.to_string())?;
    let said = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    Ok(own_reports(&said))
}

/// The reports in luau-analyze's output `said` about the checked plugin's
/// own files (copied under `plugin/`), each with the lines that carry it
/// on, and whether there are none. Errors in a plugin it requires are that
/// plugin's to fix, so they don't fail this one's check.
fn own_reports(said: &str) -> (bool, String) {
    let mut kept = Vec::new();
    let mut ours = false;
    for line in said.lines() {
        // A report starts with its file and place, `file(line,col): `.
        let starts = !line.starts_with([' ', '\t'])
            && line.split_once("): ").is_some_and(|(at, _)| {
                at.contains('(') && at.ends_with(|c: char| c.is_ascii_digit())
            });
        if starts {
            ours = line.starts_with("./plugin/") || line.starts_with("plugin/");
        }
        if ours {
            kept.push(line);
        }
    }
    (kept.is_empty(), kept.join("\n"))
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
    report.set("warnings", check.warnings)?;
    Ok(report)
}

/// `caller` and `tie`, for registries other plugins add to.
fn add_registry_functions(lua: &Lua, plugin: &Table, owner: &PluginId) -> LuaResult<()> {
    let o = owner.clone();
    plugin.set(
        "caller",
        lua.create_function(move |lua, NoArgs| {
            Ok(capabilities::caller(lua, Some(&o)).map(|name| name.to_string()))
        })?,
    )?;
    plugin.set("within", capabilities::within_function(lua)?)?;
    plugin.set(
        "started_within",
        lua.create_function(|lua, capability: String| {
            Ok(capabilities::started_within(lua, &capability))
        })?,
    )?;
    let o = owner.clone();
    plugin.set(
        "tie",
        lua.create_function(move |lua, remove: Function| {
            let Some(by) = capabilities::caller(lua, Some(&o)) else {
                return Ok(None);
            };
            state_mut(lua).ties.push(Tie {
                by: by.clone(),
                owner: o.clone(),
                remove,
            });
            Ok(Some(by.to_string()))
        })?,
    )
}

#[cfg(test)]
mod tests {
    use super::own_reports;

    #[test]
    fn only_the_checked_plugins_own_errors_count() {
        let said = "./plugin/init.luau(3,5): TypeError: Expected this to be\n\t'number'\nbut got 'string'\n\
            /src/runtime/plugins/core/mouse.luau(45,20): TypeError: Expected 'number'\n\
            plugin/test/a.luau(1,1): LintWarning: unused";
        let (ok, kept) = own_reports(said);
        assert!(!ok);
        assert_eq!(
            kept,
            "./plugin/init.luau(3,5): TypeError: Expected this to be\n\t'number'\nbut got 'string'\n\
             plugin/test/a.luau(1,1): LintWarning: unused"
        );
        let (ok, kept) = own_reports("/src/core/mouse.luau(45,20): TypeError: Expected 'number'");
        assert!(ok && kept.is_empty(), "{kept}");
    }
}
