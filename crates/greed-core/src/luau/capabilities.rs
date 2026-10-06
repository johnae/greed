//! What a plugin may use beyond the editor itself. A plugin lists it in its
//! `plugin.toml` as `capabilities = ["proc", "fs.read"]`, and the parts of
//! its `@greed` it didn't list raise an error that names the line to add.
//! Config (an `init.luau`, a trusted project's `.greed`) and code typed at
//! the REPL get everything.
//!
//! Capabilities follow the code: a plugin's `@greed` is built for it alone,
//! so what another plugin's exported function does with its own `@greed`
//! counts against that plugin, which `requires` makes visible.

use std::collections::BTreeSet;
use std::path::{Component, Path};

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
    ("secrets", "read and keep any secret, like API keys"),
];

/// The parts of `@greed` each capability opens, as paths into the table.
const GATED: &[(&str, &str)] = &[
    ("process.run", "proc"),
    ("process.spawn", "proc"),
    ("terminal.spawn", "proc"),
    ("lsp.server", "proc"),
    ("fs.read", "fs.read"),
    ("fs.list", "fs.read"),
    ("fs.stat", "fs.read"),
    ("fs.grep", "fs.read"),
    ("fs.watch", "fs.read"),
    ("files", "fs.read"),
    ("syntax.tags", "fs.read"),
    ("load", "fs.read"),
    ("open", "fs.read"),
    ("image.load", "fs.read"),
    ("pdf.open", "fs.read"),
    ("fs.write", "fs.write"),
    ("clipboard.get", "clipboard"),
    ("clipboard.history", "clipboard"),
    ("eval", "eval"),
    ("plugin.load", "plugins"),
    ("plugin.unload", "plugins"),
    ("plugin.check", "plugins"),
    ("plugin.approve", "plugins"),
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
    /// Besides the known ones, `net:HOST` opens the network to one host.
    pub fn listed(listed: &[String]) -> Result<Grant, String> {
        if let Some(unknown) = listed.iter().find(|c| what(c).is_none()) {
            let known: Vec<&str> = KNOWN.iter().map(|(name, _)| *name).collect();
            return Err(format!(
                "there is no capability {unknown:?}; there are {}, net:HOST and secrets:NAME",
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

    /// Whether it opens the network to `host`: `net`, or `net:HOST`.
    pub fn allows_host(&self, host: &str) -> bool {
        self.allows("net") || self.allows(&format!("net:{host}"))
    }
}

/// What `capability` lets a plugin do, in words; `None` if it isn't one.
pub fn what(capability: &str) -> Option<String> {
    if let Some(name) = super::secrets::named(capability) {
        return Some(format!("read the secret {name}"));
    }
    if let Some(host) = capability.strip_prefix("net:") {
        return (!host.is_empty()).then(|| format!("use the network, only {host}"));
    }
    KNOWN
        .iter()
        .find(|(name, _)| *name == capability)
        .map(|(_, what)| (*what).to_owned())
}

/// The error for `owner` using what `capability` opens.
fn denied(owner: &str, capability: &str) -> mlua::Error {
    let what = what(capability).unwrap_or_else(|| capability.to_owned());
    if owner == SANDBOX {
        return needs_approval(&what);
    }
    mlua::Error::runtime(format!(
        "{owner} can't {what}: add \"{capability}\" to capabilities in its plugin.toml"
    ))
}

/// Who sandboxed code runs as: with no capabilities, and without the parts
/// of `@greed` that act beyond the buffers' text.
pub const SANDBOX: &str = "sandbox";

/// What sandboxed code can't use, with what using it would do: what runs
/// other code (commands, handlers, keys, tasks), changes how the editor
/// works, or reaches outside it. A module's listed functions only read, and
/// stay; the rest of it, including what's added to it later, is refused.
const SANDBOXED: &[(&str, &str, &[&str])] = &[
    ("run", "run a command", &[]),
    ("command", "add a command", &[]),
    ("cli", "add a command line command", &[]),
    ("on", "add an event handler", &[]),
    ("spawn", "start work in the background", &[]),
    ("eval", "run Luau with every capability", &[]),
    ("quit", "quit the editor", &[]),
    ("detach", "let the client go", &[]),
    ("statusline", "replace the status line", &[]),
    ("set_menus", "replace the menus", &[]),
    ("keys", "type keys or record them", &[]),
    ("keymap", "change the keys", &["next", "find", "resolve"]),
    ("option", "change options", &["get", "list"]),
    ("theme", "change the theme", &["get"]),
    (
        "plugin",
        "load, unload or check plugins",
        &["list", "dirs", "describe", "pending"],
    ),
    ("process", "run programs", &[]),
    ("terminal", "use terminals", &[]),
    ("http", "use the network", &[]),
    ("secrets", "read or keep secrets", &[]),
    ("fs", "read or write files", &["cwd", "dirs"]),
    ("files", "read files", &[]),
    ("image", "read files", &[]),
    ("pdf", "read files", &[]),
    (
        "lsp",
        "talk to language servers",
        &[
            "servers",
            "uri",
            "path",
            "position",
            "offset",
            "diagnostics",
            "problems",
            "capabilities",
        ],
    ),
    ("control", "use the session's connections", &[]),
    (
        "session",
        "use other sessions",
        &["current", "list", "remote", "attached"],
    ),
    ("clipboard", "use the clipboard", &[]),
    ("client", "send you desktop notifications", &[]),
];

/// The error for sandboxed code doing `what`, which says it needs approval;
/// the agent plugin reads the start of it to ask for that.
pub(super) fn needs_approval(what: &str) -> mlua::Error {
    mlua::Error::runtime(format!("needs approval: it would {what}"))
}

/// Replaces what sandboxed code can't use in its `@greed` with functions
/// that say it needs approval: whole modules as tables of them, single
/// functions as one. What's left reads the editor and edits buffers.
pub(super) fn sandbox(lua: &Lua, greed: &Table) -> LuaResult<()> {
    for &(key, what, readable) in SANDBOXED {
        let deny = lua.create_function(move |_, _: mlua::MultiValue| -> LuaResult<()> {
            Err(needs_approval(what))
        })?;
        if let Value::Table(original) = greed.get::<Value>(key)? {
            let module = lua.create_table()?;
            for name in readable {
                module.set(*name, original.get::<Value>(*name)?)?;
            }
            let meta = lua.create_table()?;
            meta.set(
                "__index",
                lua.create_function(move |_, _: mlua::MultiValue| Ok(deny.clone()))?,
            )?;
            module.set_metatable(Some(meta))?;
            greed.set(key, module)?;
        } else {
            greed.set(key, deny)?;
        }
    }
    // Files in the project open as buffers, to read and edit; others need
    // approval.
    for key in ["load", "open"] {
        let original: mlua::Function = greed.get(key)?;
        greed.set(
            key,
            lua.create_function(move |lua, (path, rest): (String, mlua::MultiValue)| {
                if !in_project(lua, &path) {
                    return Err(needs_approval("open a file outside the project"));
                }
                original.call::<mlua::MultiValue>((path, rest))
            })?,
        )?;
    }
    Ok(())
}

/// Whether `path` is in the current project's folder, without `..` to
/// climb out of it.
fn in_project(lua: &Lua, path: &str) -> bool {
    let path = Path::new(path);
    if path.components().any(|c| c == Component::ParentDir) {
        return false;
    }
    let state = state(lua);
    let root = state.editor.current_project().root();
    // A relative path is read from the editor's folder.
    let full = if path.is_absolute() {
        path.to_owned()
    } else {
        std::env::current_dir().unwrap_or_default().join(path)
    };
    full.starts_with(root)
}

/// What sandboxed code is granted: `fs.read`, which only its `load` and
/// `open` keep, for files in the project; [`sandbox`] takes the rest out.
pub(super) fn sandbox_grant() -> Grant {
    Grant::Only(BTreeSet::from(["fs.read".to_owned()]))
}

/// Fails if the code running now is sandboxed, which can't do `what`.
pub(super) fn unless_sandboxed(lua: &Lua, what: &str) -> LuaResult<()> {
    if state(lua).running.as_deref() == Some(SANDBOX) {
        Err(needs_approval(what))
    } else {
        Ok(())
    }
}

/// Replaces what `grant` doesn't open in `greed`, `owner`'s `@greed`, with
/// functions that say what to declare.
pub(super) fn gate(lua: &Lua, greed: &Table, owner: &PluginId, grant: &Grant) -> LuaResult<()> {
    for (path, capability) in GATED {
        if grant.allows(capability) {
            continue;
        }
        let (table, key) = match path.split_once('.') {
            Some((module, key)) => match greed.get::<Value>(module)? {
                Value::Table(table) => (table, key),
                _ => continue,
            },
            None => (greed.clone(), *path),
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

/// Runs `f` as `owner`'s code, for [`check`], doing `what` ("the status
/// line", ...), for the watchdog.
pub(super) fn running_as<R>(
    lua: &Lua,
    owner: Option<&PluginId>,
    what: &str,
    f: impl FnOnce() -> R,
) -> R {
    let outer = std::mem::replace(&mut state_mut(lua).running, owner.cloned());
    let (result, _) = super::stalls::timed(lua, owner.map(|o| &**o), what, f);
    state_mut(lua).running = outer;
    result
}

/// Fails unless `owner` may reach `host`, naming the line to add.
pub(super) fn check_host(lua: &Lua, owner: &PluginId, host: &str) -> LuaResult<()> {
    let allowed = state(lua)
        .grants
        .get(owner)
        .is_none_or(|g| g.allows_host(host));
    if allowed {
        Ok(())
    } else {
        Err(mlua::Error::runtime(format!(
            "{owner} can't use the network: add \"net:{host}\" (or \"net\" for any host) to capabilities in its plugin.toml"
        )))
    }
}
