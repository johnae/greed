//! What a plugin may use beyond the editor itself. A plugin lists it in its
//! `plugin.toml` as `capabilities = ["proc", "fs.read"]`, and the parts of
//! its `@kern` it didn't list raise an error that names the line to add.
//! Config (an `init.luau`, a trusted project's `.kern`) and code typed at
//! the REPL get everything.
//!
//! Capabilities follow the code: a plugin's `@kern` is built for it alone,
//! so what another plugin's exported function does with its own `@kern`
//! counts against that plugin, which `requires` makes visible.

use std::collections::BTreeSet;

use mlua::{Lua, Table, Value};

use super::{state, state_mut};
use crate::registry::PluginId;

type LuaResult<T> = mlua::Result<T>;

/// Every capability, with what it lets a plugin do, in words for a review.
pub const KNOWN: &[(&str, &str)] = &[
    ("proc", "run programs, which can do anything you can"),
    ("fs.read", "read any file, by path"),
    ("fs.write", "write any file, by path"),
    ("net", "use the network"),
    ("clipboard", "read what you copied"),
    ("eval", "run Luau with every capability"),
    ("plugins", "load, unload and check other plugins"),
];

/// The parts of `@kern` each capability opens, as paths into the table.
const GATED: &[(&str, &str)] = &[
    ("process.run", "proc"),
    ("terminal.spawn", "proc"),
    ("lsp.server", "proc"),
    ("fs.read", "fs.read"),
    ("fs.list", "fs.read"),
    ("fs.stat", "fs.read"),
    ("fs.grep", "fs.read"),
    ("fs.watch", "fs.read"),
    ("files", "fs.read"),
    ("load", "fs.read"),
    ("open", "fs.read"),
    ("image.load", "fs.read"),
    ("fs.write", "fs.write"),
    ("clipboard.get", "clipboard"),
    ("clipboard.history", "clipboard"),
    ("eval", "eval"),
    ("plugin.load", "plugins"),
    ("plugin.unload", "plugins"),
    ("plugin.check", "plugins"),
    ("control.serve_ide", "net"),
];

/// What a plugin was granted.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Grant {
    /// Config, the REPL and tests: everything.
    All,
    /// A plugin with a `plugin.toml`: what it lists.
    Only(BTreeSet<String>),
}

impl Grant {
    /// The grant for `listed` capabilities, or why one of them isn't one.
    pub fn listed(listed: &[String]) -> Result<Grant, String> {
        if let Some(unknown) = listed
            .iter()
            .find(|c| !KNOWN.iter().any(|(name, _)| name == c))
        {
            let known: Vec<&str> = KNOWN.iter().map(|(name, _)| *name).collect();
            return Err(format!(
                "there is no capability {unknown:?}; there are {}",
                known.join(", ")
            ));
        }
        Ok(Grant::Only(listed.iter().cloned().collect()))
    }

    pub fn allows(&self, capability: &str) -> bool {
        match self {
            Grant::All => true,
            Grant::Only(set) => set.contains(capability),
        }
    }
}

/// The error for `owner` using what `capability` opens.
fn denied(owner: &str, capability: &str) -> mlua::Error {
    let what = KNOWN
        .iter()
        .find(|(name, _)| *name == capability)
        .map_or(capability, |(_, what)| what);
    mlua::Error::runtime(format!(
        "{owner} can't {what}: add \"{capability}\" to capabilities in its plugin.toml"
    ))
}

/// Replaces what `grant` doesn't open in `kern`, `owner`'s `@kern`, with
/// functions that say what to declare.
pub(super) fn gate(lua: &Lua, kern: &Table, owner: &PluginId, grant: &Grant) -> LuaResult<()> {
    for (path, capability) in GATED {
        if grant.allows(capability) {
            continue;
        }
        let (table, key) = match path.split_once('.') {
            Some((module, key)) => match kern.get::<Value>(module)? {
                Value::Table(table) => (table, key),
                _ => continue,
            },
            None => (kern.clone(), *path),
        };
        let owner = owner.clone();
        table.set(
            key,
            lua.create_function(move |_, _: mlua::MultiValue| -> LuaResult<()> {
                Err(denied(&owner, capability))
            })?,
        )?;
    }
    Ok(())
}

/// Fails unless the plugin whose code is running may use `capability`.
/// Code no plugin owns, like the host's own, may.
pub(super) fn check(lua: &Lua, capability: &str) -> LuaResult<()> {
    let state = state(lua);
    let Some(owner) = &state.running else {
        return Ok(());
    };
    match state.grants.get(owner) {
        Some(grant) if !grant.allows(capability) => Err(denied(owner, capability)),
        _ => Ok(()),
    }
}

/// Runs `f` as `owner`'s code, for [`check`].
pub(super) fn running_as<R>(lua: &Lua, owner: Option<PluginId>, f: impl FnOnce() -> R) -> R {
    let outer = std::mem::replace(&mut state_mut(lua).running, owner);
    let result = f();
    state_mut(lua).running = outer;
    result
}
