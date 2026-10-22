//! What a plugin may use beyond the editor itself. A plugin lists it in its
//! `plugin.toml` as `capabilities = ["proc", "fs.read"]`, and the parts of
//! its `@greed` it didn't list raise an error that names the line to add.
//! Config (an `init.luau`, a trusted project's `.greed`) and code typed at
//! the REPL get everything.
//!
//! Capabilities follow the code, and don't pass from one plugin to another:
//!
//! - A plugin's `@greed` is built for it alone, with what it didn't declare
//!   taken out.
//! - What's left also checks every plugin whose code is on the stack, so a
//!   plugin calling another's exports, or a function one plugin handed
//!   another, can do only what both may. Coroutines a plugin makes remember
//!   whose code made them.
//! - A command plugin code starts, or keys it feeds, and what it starts with
//!   `greed.spawn`, run within the [`Limit`] of the code that started them.
//!   Holders of `commands`, like the command line, pass on what they were
//!   started with, since they run what you typed.
//! - Event handlers run with their own plugin's capabilities whatever caused
//!   the event: they're that plugin reacting to what happened, and plugins
//!   can't send events of their own.
//! - A plugin can vouch for an operation of its own with `greed.vouch`:
//!   then only its capabilities count, as for a service like the models
//!   plugin sending a request with your key. Code handed to it still counts.

use std::collections::BTreeSet;
use std::path::{Component, Path};

use mlua::{Function, Lua, Table, Value};

use super::arity::NoArgs;
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
    (
        "plugins",
        "load, approve and unload other plugins, which can then do anything",
    ),
    ("secrets", "read and keep any secret, like API keys"),
    (
        "commands",
        "run any command or keys as if you typed them, with what their plugins may do",
    ),
    (
        "control",
        "answer agents and editors connected to the session, as Greed",
    ),
    (
        "ssh-agent",
        "let programs in the session sign with your ssh keys",
    ),
];

/// The parts of `@greed` each capability opens, as paths into the table.
const GATED: &[(&str, &str)] = &[
    ("process.run", "proc"),
    ("process.spawn", "proc"),
    ("rpc.start", "proc"),
    ("terminal.spawn", "proc"),
    ("lsp.server", "proc"),
    ("lsp.restart", "proc"),
    ("lsp.trust", "proc"),
    ("fs.read", "fs.read"),
    ("index.open", "fs.read"),
    ("index.writer", "fs.write"),
    ("fs.read_bytes", "fs.read"),
    ("fs.list", "fs.read"),
    ("fs.stat", "fs.read"),
    ("fs.grep", "fs.read"),
    ("fs.scan", "fs.read"),
    ("fs.watch", "fs.read"),
    ("files", "fs.read"),
    ("syntax.tags", "fs.read"),
    ("syntax.load_grammar", "fs.read"),
    ("load", "fs.read"),
    ("open", "fs.read"),
    ("image.load", "fs.read"),
    ("pdf.open", "fs.read"),
    ("hash.sha256_file", "fs.read"),
    ("fs.copy", "fs.read"),
    ("fs.write", "fs.write"),
    ("fs.mkdir", "fs.write"),
    ("fs.remove", "fs.write"),
    ("fs.rename", "fs.write"),
    ("fs.copy", "fs.write"),
    ("clipboard.get", "clipboard"),
    ("clipboard.history", "clipboard"),
    ("clipboard.image", "clipboard"),
    ("eval", "eval"),
    ("plugin.load", "plugins"),
    ("plugin.unload", "plugins"),
    ("plugin.check", "plugins"),
    ("plugin.approve", "plugins"),
    ("control.reply", "control"),
    ("control.send", "control"),
    ("control.notify", "control"),
    ("control.serve_ide", "control"),
    ("control.serve_ide", "net"),
    ("control.ide_folders", "control"),
    ("ssh_agent.answer", "ssh-agent"),
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

/// [`what`], falling back to the capability's name.
fn describe(capability: &str) -> String {
    what(capability).unwrap_or_else(|| capability.to_owned())
}

/// The error for `owner` using what `capability` opens.
fn denied(lua: &Lua, owner: &str, capability: &str) -> mlua::Error {
    let what = describe(capability);
    if owner == SANDBOX {
        return needs_approval(&what);
    }
    if checking(lua, owner) {
        return unapproved(owner, &what, capability);
    }
    mlua::Error::runtime(format!(
        "{owner} can't {what}: add \"{capability}\" to capabilities in its plugin.toml"
    ))
}

/// The error for a plugin being checked before you approved `capability`.
fn unapproved(owner: &str, what: &str, capability: &str) -> mlua::Error {
    needs_approval(&format!(
        "{what}, and you haven't approved \"{capability}\" for {owner}"
    ))
}

/// Whether `owner` is the plugin a check runs, with only what you approved
/// for it: its place in the floor.
pub(super) fn checking(lua: &Lua, owner: &str) -> bool {
    state(lua).floor.iter().any(|(by, _)| &**by == owner)
}

/// The plugins whose code started what runs now, each with its grant: what
/// runs may use only what every one of them may. Empty for what you
/// started, by keys, the command line or config.
pub(crate) type Limit = Vec<(PluginId, Grant)>;

/// The limit for a command `caller`'s code starts, or keys it feeds: what
/// [`inherited`] gives, unless they all may pass on what you typed
/// (`commands`), when it's the limit the code runs within.
pub(super) fn limit_for(lua: &Lua, caller: &PluginId) -> Limit {
    let limit = inherited(lua, caller);
    if limit.iter().all(|(_, grant)| grant.allows("commands")) {
        current_limit(lua)
    } else {
        limit
    }
}

/// The limit for what `caller`'s code starts that runs on its own, like a
/// task: the limit the code runs within, narrowed to the grants of `caller`
/// and of every plugin whose code is on the stack.
pub(super) fn inherited(lua: &Lua, caller: &PluginId) -> Limit {
    let callers = on_stack(lua);
    let mut limit = current_limit(lua);
    let state = state(lua);
    for name in std::iter::once(caller).chain(&callers) {
        if let Some(grant @ Grant::Only(_)) = state.grants.get(name)
            && !limit.iter().any(|(by, _)| by == name)
        {
            limit.push((name.clone(), grant.clone()));
        }
    }
    limit
}

/// Whether keys fed within `fed` may answer code waiting for a key within
/// `waiting`: when that code is limited at least as much, as when the same
/// keys started it. Keys from plugin code never answer what waits for you.
/// Returns the plugin they're refused for.
pub(super) fn refused_answer<'a>(fed: &'a Limit, waiting: &Limit) -> Option<&'a PluginId> {
    fed.iter()
        .map(|(by, _)| by)
        .find(|by| !waiting.iter().any(|(other, _)| other == *by))
}

/// The plugins whose code is on the running coroutine's stack, innermost
/// first, those whose code made that coroutine, and the plugin it runs for
/// (whose command, handler or task it is). Frames that aren't a plugin's,
/// like Greed's own, add nothing, so a stack of only those still counts the
/// plugin it runs for.
fn on_stack(lua: &Lua) -> Vec<PluginId> {
    let vouch = vouched(lua);
    // Frames outside what a plugin vouches for don't count: only it does,
    // and code its vouched function calls into.
    let levels = match &vouch {
        Some((outside, _)) => depth(lua).saturating_sub(*outside),
        None => usize::MAX,
    };
    let mut chunks: Vec<String> = Vec::new();
    for level in 0..levels {
        let Some(source) = lua.inspect_stack(level, |debug| {
            debug.source().source.map(std::borrow::Cow::into_owned)
        }) else {
            break;
        };
        // Plugin files are named "@plugin/file"; Greed's own chunks "=...".
        if let Some(chunk) = source.as_deref().and_then(|s| s.strip_prefix('@'))
            && !chunks.iter().any(|c| c == chunk)
        {
            chunks.push(chunk.to_owned());
        }
    }
    let state = state(lua);
    let mut found: Vec<PluginId> = Vec::new();
    for chunk in &chunks {
        let owner = state
            .grants
            .keys()
            .filter(|name| {
                chunk
                    .strip_prefix(&***name)
                    .is_some_and(|rest| rest.is_empty() || rest.starts_with('/'))
            })
            .max_by_key(|name| name.len());
        if let Some(owner) = owner
            && !found.contains(owner)
        {
            found.push(owner.clone());
        }
    }
    if let Some((_, owner)) = vouch {
        if !found.contains(&owner) {
            found.push(owner);
        }
        return found;
    }
    let makers: Option<Vec<String>> = state.makers.get(lua.current_thread()).ok().flatten();
    for maker in makers.unwrap_or_default() {
        if !found.iter().any(|f| **f == *maker) {
            found.push(maker.into());
        }
    }
    if let Some(running) = &state.running
        && !found.contains(running)
    {
        found.push(running.clone());
    }
    found
}

/// How many frames the running coroutine's stack has.
fn depth(lua: &Lua) -> usize {
    let mut levels = 0;
    while lua.inspect_stack(levels, |_| ()).is_some() {
        levels += 1;
    }
    levels
}

/// The plugin vouching for what runs now (`greed.vouch`), innermost, and
/// how many frames of the stack lie outside what it vouches for.
fn vouched(lua: &Lua) -> Option<(usize, PluginId)> {
    let list: Table = state(lua).vouches.get(lua.current_thread()).ok()?;
    (1..=list.raw_len()).rev().find_map(|i| {
        let entry: Table = list.get(i).ok()?;
        let outside: usize = entry.get("outside").ok()?;
        let owner: String = entry.get("owner").ok()?;
        Some((outside, owner.into()))
    })
}

/// The plugins `greed.plugin.within` runs the running coroutine's code
/// within, innermost first, up to the innermost vouch with `stop_at_vouch`,
/// and whether one was found.
fn withins(lua: &Lua, stop_at_vouch: bool) -> (Limit, bool) {
    let state = state(lua);
    let mut out = Limit::new();
    let Ok(list) = state.vouches.get::<Table>(lua.current_thread()) else {
        return (out, false);
    };
    for i in (1..=list.raw_len()).rev() {
        let Ok(entry) = list.get::<Table>(i) else {
            continue;
        };
        if let Ok(name) = entry.get::<String>("within") {
            let name: PluginId = name.into();
            if let Some(grant @ Grant::Only(_)) = state.grants.get(&name) {
                out.push((name, grant.clone()));
            }
        } else if stop_at_vouch && entry.contains_key("outside").unwrap_or(false) {
            return (out, true);
        }
    }
    (out, false)
}

/// `limit` with what's in `more` and not in it already.
fn joined(mut limit: Limit, more: Limit) -> Limit {
    for (name, grant) in more {
        if !limit.iter().any(|(by, _)| *by == name) {
            limit.push((name, grant));
        }
    }
    limit
}

/// What runs within: the limit what started it set, except where a plugin
/// vouches for it, which sets none, and the plugins `greed.plugin.within`
/// adds inside either.
fn current_limit(lua: &Lua) -> Limit {
    let (added, vouched) = withins(lua, true);
    let base = if vouched {
        Vec::new()
    } else {
        state(lua).limit.clone()
    };
    joined(base, added)
}

/// What started what runs now, whatever vouches for it: the limit, and the
/// plugins `greed.plugin.within` adds. What it starts runs within this.
pub(super) fn started_by(lua: &Lua) -> Limit {
    let base = state(lua).limit.clone();
    joined(base, withins(lua, false).0)
}

/// `greed.vouch` for `owner`: runs a function as `owner`'s own action, so
/// only its capabilities count, not those of the code that called it or
/// what started that.
fn vouch_function(lua: &Lua, owner: &PluginId) -> LuaResult<Function> {
    let name = owner.to_string();
    let enter = lua.create_function(move |lua, NoArgs| {
        // Below this function and the Luau wrapper that called it.
        let outside = depth(lua).saturating_sub(2);
        push_vouch(lua, outside, &name)
    })?;
    let leave = lua.create_function(|lua, NoArgs| pop_vouch(lua))?;
    // In Luau, so what it runs can wait.
    lua.load(
        r"
        local enter, leave = ...
        return function(f, ...)
            enter()
            local results = table.pack(pcall(f, ...))
            leave()
            if not results[1] then
                error(results[2], 0)
            end
            return table.unpack(results, 2, results.n)
        end
        ",
    )
    .set_name("=greed.vouch")
    .call((enter, leave))
}

/// Runs `f`, the Luau a plugin passes to `greed.eval`, with every
/// capability, as `eval` promises: the frames below it and the limit what
/// started them set stop counting. Only when every plugin on the stack and
/// in that limit may `eval`, though; otherwise a plugin without it could
/// get anything through one that has it, and `f` runs as any code would.
pub(super) fn trusted_eval<R>(lua: &Lua, f: impl FnOnce() -> LuaResult<R>) -> LuaResult<R> {
    let callers = on_stack(lua);
    let limit = current_limit(lua);
    let trusted = {
        let state = state(lua);
        limit.iter().all(|(_, grant)| grant.allows("eval"))
            && callers
                .iter()
                .all(|name| state.grants.get(name).is_none_or(|g| g.allows("eval")))
    };
    if !trusted {
        return f();
    }
    // Everything below `greed.eval` itself.
    push_vouch(lua, depth(lua).saturating_sub(1), super::REPL)?;
    let result = f();
    pop_vouch(lua)?;
    result
}

/// `greed.plugin.within(name, f, ...)`: runs `f` within the limit of the
/// plugin `name` too, as when it started it, so what a plugin registered
/// (a formatter, a runner) can do no more than it may when another plugin
/// runs it later. Unknown names and config add nothing.
pub(super) fn within_function(lua: &Lua) -> LuaResult<Function> {
    let enter = lua.create_function(|lua, name: Option<String>| {
        let entry = lua.create_table()?;
        entry.set("within", name.unwrap_or_default())?;
        push_entry(lua, entry)
    })?;
    let leave = lua.create_function(|lua, NoArgs| pop_vouch(lua))?;
    // In Luau, so what it runs can wait.
    lua.load(
        r"
        local enter, leave = ...
        return function(name, f, ...)
            enter(name)
            local results = table.pack(pcall(f, ...))
            leave()
            if not results[1] then
                error(results[2], 0)
            end
            return table.unpack(results, 2, results.n)
        end
        ",
    )
    .set_name("=greed.plugin.within")
    .call((enter, leave))
}

/// Starts vouching for what the running coroutine runs as `owner`, with
/// `outside` frames of its stack outside what's vouched for.
fn push_vouch(lua: &Lua, outside: usize, owner: &str) -> LuaResult<()> {
    let entry = lua.create_table()?;
    entry.set("outside", outside)?;
    entry.set("owner", owner)?;
    push_entry(lua, entry)
}

/// Adds `entry`, a vouch or a `within`, innermost to the running
/// coroutine's list.
fn push_entry(lua: &Lua, entry: Table) -> LuaResult<()> {
    let vouches = state(lua).vouches.clone();
    let thread = lua.current_thread();
    let list = if let Some(list) = vouches.get::<Option<Table>>(&thread)? {
        list
    } else {
        let list = lua.create_table()?;
        vouches.set(&thread, &list)?;
        list
    };
    list.push(entry)
}

/// Ends the innermost vouch or `within` [`push_entry`] started.
fn pop_vouch(lua: &Lua) -> LuaResult<()> {
    let list: Option<Table> = state(lua).vouches.get(lua.current_thread())?;
    if let Some(list) = list {
        list.raw_remove(list.raw_len())?;
    }
    Ok(())
}

/// The plugin whose code called into Greed: the innermost plugin on the
/// stack other than `except`, falling back to those that made the running
/// coroutine and the plugin it runs for.
pub(super) fn caller(lua: &Lua, except: Option<&str>) -> Option<PluginId> {
    on_stack(lua)
        .into_iter()
        .find(|name| except.is_none_or(|except| **name != *except))
}

/// Remembers whose code made `thread`, so what runs in it later counts
/// against them as if they were on its stack.
fn made(lua: &Lua, thread: &mlua::Thread) -> LuaResult<()> {
    let names: Vec<String> = on_stack(lua).iter().map(ToString::to_string).collect();
    let makers = state(lua).makers.clone();
    makers.set(thread, names)
}

/// `coroutine` for plugins, whose `create` and `wrap` remember whose code
/// made each coroutine.
pub(super) fn coroutine_module(lua: &Lua) -> LuaResult<Table> {
    let tag = lua.create_function(|lua, thread: mlua::Thread| made(lua, &thread))?;
    lua.load(
        r"
        local tag = ...
        local base = coroutine
        local co = table.clone(base)
        function co.create(f)
            local thread = base.create(f)
            tag(thread)
            return thread
        end
        function co.wrap(f)
            local thread = co.create(f)
            return function(...)
                local results = table.pack(base.resume(thread, ...))
                if not results[1] then
                    error(results[2], 0)
                end
                return table.unpack(results, 2, results.n)
            end
        end
        return table.freeze(co)
        ",
    )
    .set_name("=greed.coroutine")
    .call(tag)
}

/// Fails unless everything that started the code running now, and every
/// plugin whose code is on the stack, may do what `allows` checks, which
/// `capability` opens; `owner` is whose code it is.
fn within_limit(
    lua: &Lua,
    owner: &str,
    capability: &str,
    allows: impl Fn(&Grant) -> bool,
) -> LuaResult<()> {
    let callers = on_stack(lua);
    let limit = current_limit(lua);
    let state = state(lua);
    let started = limit
        .iter()
        .find(|(_, grant)| !allows(grant))
        .map(|(by, _)| by);
    let called = callers
        .iter()
        .find(|name| state.grants.get(*name).is_some_and(|grant| !allows(grant)));
    let Some(by) = started.or(called) else {
        return Ok(());
    };
    let what = describe(capability);
    if checking(lua, by) {
        return Err(unapproved(by, &what, capability));
    }
    Err(mlua::Error::runtime(if started.is_some() {
        format!("{owner} can't {what}: {by} started it, and doesn't have \"{capability}\"")
    } else {
        format!(
            "{owner} can't {what} for {by}: add \"{capability}\" to capabilities in {by}'s plugin.toml"
        )
    }))
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
    ("object_finder", "change how commands find objects", &[]),
    ("set_menus", "replace the menus", &[]),
    ("keys", "type keys or record them", &[]),
    (
        "keymap",
        "change the keys",
        &["next", "find", "resolve", "active"],
    ),
    ("option", "change options", &["get", "list"]),
    ("theme", "change the theme", &["get"]),
    (
        "plugin",
        "load, unload or check plugins",
        &[
            "list",
            "dirs",
            "describe",
            "pending",
            "caller",
            "started_within",
        ],
    ),
    ("process", "run programs", &[]),
    ("rpc", "run programs", &[]),
    ("terminal", "use terminals", &[]),
    ("http", "use the network", &[]),
    ("secrets", "read or keep secrets", &[]),
    ("fs", "read or write files", &["cwd", "dirs"]),
    // Switching to a project elsewhere would move what counts as in it.
    (
        "project",
        "open, switch or close projects",
        &["list", "current"],
    ),
    ("hash", "read files", &["sha256", "random"]),
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
    ("ssh_agent", "let programs use your ssh keys", &[]),
    (
        "session",
        "use other sessions",
        &["current", "list", "remote", "attached"],
    ),
    ("clipboard", "use the clipboard", &[]),
    (
        "client",
        "send you desktop notifications or change how a client lays out views",
        &["current", "list", "id"],
    ),
    ("mode", "change the mode", &["get", "cursor_of"]),
    ("tab", "change the tabs", &["list", "current", "layout"]),
];

/// The error for sandboxed code doing `what`, which says it needs approval;
/// the agent plugin reads the start of it to ask for that.
pub(super) fn needs_approval(what: &str) -> mlua::Error {
    mlua::Error::runtime(approval(what))
}

fn approval(what: &str) -> String {
    format!("needs approval: it would {what}")
}

/// Replaces what sandboxed code can't use in its `@greed` with functions
/// that say it needs approval: whole modules as tables of them, single
/// functions as one. What's left reads the editor and edits buffers.
/// Iterating a module, which would show only what's left of it, says it
/// needs approval too; `globals` gets a `pairs` that does.
pub(super) fn sandbox(lua: &Lua, greed: &Table, globals: &Table) -> LuaResult<()> {
    // Each module taken in part, with the error iterating it gives.
    let modules = lua.create_table()?;
    for &(key, what, readable) in SANDBOXED {
        let deny = lua.create_function(move |_, _: mlua::MultiValue| -> LuaResult<()> {
            Err(needs_approval(what))
        })?;
        if let Value::Table(original) = greed.get::<Value>(key)? {
            let module = lua.create_table()?;
            for name in readable {
                module.set(*name, original.get::<Value>(*name)?)?;
            }
            let listing = format!("greed.{key} {}", approval(what));
            let meta = lua.create_table()?;
            meta.set(
                "__index",
                lua.create_function(move |_, _: mlua::MultiValue| Ok(deny.clone()))?,
            )?;
            let error = listing.clone();
            meta.set(
                "__iter",
                lua.create_function(move |_, _: mlua::MultiValue| -> LuaResult<()> {
                    Err(mlua::Error::runtime(&error))
                })?,
            )?;
            module.set_metatable(Some(meta))?;
            modules.raw_set(&module, listing)?;
            greed.set(key, module)?;
        } else {
            greed.set(key, deny)?;
        }
    }
    // In Luau, so the modules it holds go with the sandbox: held by a Rust
    // closure they'd be roots, and keep it all.
    let pairs: Function = lua
        .load(
            r"
            local pairs, modules = ...
            return function(t, ...)
                local listing = modules[t]
                if listing then
                    error(listing, 2)
                end
                return pairs(t, ...)
            end
            ",
        )
        .set_name("=greed.sandbox")
        .call((lua.globals().get::<Function>("pairs")?, modules))?;
    globals.set("pairs", pairs)?;
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
    // Links are followed, so one in the project can't lead out of it.
    real(&full).starts_with(real(root))
}

/// `path` with its links followed, as far as it exists: a file not made yet
/// is taken as in its folder.
fn real(path: &Path) -> std::path::PathBuf {
    if let Ok(real) = std::fs::canonicalize(path) {
        return real;
    }
    match (path.parent(), path.file_name()) {
        (Some(parent), Some(name)) => real(parent).join(name),
        _ => path.to_owned(),
    }
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
/// functions that say what to declare, and wraps what it does open so it
/// also checks the limit it runs within.
pub(super) fn gate(lua: &Lua, greed: &Table, owner: &PluginId, grant: &Grant) -> LuaResult<()> {
    greed.set("vouch", vouch_function(lua, owner)?)?;
    let o = owner.clone();
    let check = lua.create_function(move |lua, capability: String| {
        within_limit(lua, &o, &capability, |g| g.allows(&capability))
    })?;
    // In Luau, so what it wraps can still wait.
    let wrap: Function = lua
        .load(
            r"
            local check = ...
            return function(f, capability)
                return function(...)
                    check(capability)
                    return f(...)
                end
            end
            ",
        )
        .set_name("=greed.gate")
        .call(check)?;
    for (path, capability) in GATED {
        // A gated name that isn't there is a bug: failing beats leaving
        // what it was meant to guard open under another name.
        let missing = || mlua::Error::runtime(format!("{path} is gated but isn't in @greed"));
        let (table, key) = match path.split_once('.') {
            Some((module, key)) => match greed.get::<Value>(module)? {
                Value::Table(table) => (table, key),
                _ => return Err(missing()),
            },
            None => (greed.clone(), *path),
        };
        let Value::Function(original) = table.get(key)? else {
            return Err(missing());
        };
        if grant.allows(capability) {
            table.set(key, wrap.call::<Function>((original, *capability))?)?;
            continue;
        }
        let owner = owner.clone();
        table.set(
            key,
            lua.create_function(move |lua, _: mlua::MultiValue| -> LuaResult<()> {
                Err(denied(lua, &owner, capability))
            })?,
        )?;
    }
    Ok(())
}

/// Fails unless the plugin whose code is running may use `capability`, and
/// what started it may too. Code no plugin owns, like the host's own, may.
pub(super) fn check(lua: &Lua, capability: &str) -> LuaResult<()> {
    let Some(owner) = state(lua).running.clone() else {
        return Ok(());
    };
    check_for(lua, &owner, capability)
}

/// Fails unless the code running may set an option that needs
/// `capability`: code that has it, or what you typed yourself, like `:set`,
/// which only holders of `commands` passed on and nothing started.
pub(super) fn check_setting(lua: &Lua, capability: &str) -> LuaResult<()> {
    let Some(owner) = state(lua).running.clone() else {
        return Ok(());
    };
    match check_for(lua, &owner, capability) {
        Err(_) if by_you(lua) => Ok(()),
        checked => checked,
    }
}

/// Whether everything that started what runs now may use `capability`: you,
/// or plugins that have it. Unlike the checks, a vouch doesn't hide what
/// started it, so a plugin can't get it by starting one that vouches.
pub(super) fn started_within(lua: &Lua, capability: &str) -> bool {
    started_by(lua)
        .iter()
        .all(|(_, grant)| grant.allows(capability))
}

/// Whether what runs now is what you did yourself, with keys, the command
/// line or your config: nothing started it, and every plugin whose code is
/// running only passes on what you typed (`commands`).
pub(super) fn by_you(lua: &Lua) -> bool {
    current_limit(lua).is_empty() && {
        let callers = on_stack(lua);
        let state = state(lua);
        callers
            .iter()
            .all(|name| state.grants.get(name).is_none_or(|g| g.allows("commands")))
    }
}

/// [`check`] for `owner`'s code, whether or not it's the code running.
pub(super) fn check_for(lua: &Lua, owner: &PluginId, capability: &str) -> LuaResult<()> {
    allowed(lua, owner, capability, |g| g.allows(capability))
}

/// Fails unless `owner` may do what `allows` checks, which `capability`
/// opens, and what started the code running now may too.
pub(super) fn allowed(
    lua: &Lua,
    owner: &PluginId,
    capability: &str,
    allows: impl Fn(&Grant) -> bool,
) -> LuaResult<()> {
    let refused = state(lua).grants.get(owner).is_some_and(|g| !allows(g));
    if refused {
        return Err(denied(lua, owner, capability));
    }
    within_limit(lua, owner, capability, allows)
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
    if !allowed {
        return Err(mlua::Error::runtime(format!(
            "{owner} can't use the network: add \"net:{host}\" (or \"net\" for any host) to capabilities in its plugin.toml"
        )));
    }
    within_limit(lua, owner, &format!("net:{host}"), |g| g.allows_host(host))
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::GATED;
    use crate::Editor;
    use crate::luau::Host;

    /// Functions that need no capability, in the modules holding ones that
    /// do. A function added beside gated ones must be gated or named here,
    /// so none is left open by forgetting.
    const FREE: &[&str] = &[
        // The editor itself: buffers, views, commands, keys, events, time.
        "animate",
        "buffer",
        "buffer_for",
        "buffers",
        "cli",
        "command",
        "commands",
        "create_buffer",
        "detach",
        "diff",
        "echo",
        "errors",
        "filetype",
        "float",
        "floats",
        "fuzzy",
        "fuzzy_positions",
        "grammars",
        "handlers",
        "hostname",
        "language_of",
        "line_numbers",
        "messages",
        "next_key",
        "now",
        "object_finder",
        "off",
        "on",
        "panel",
        "quit",
        "reveal",
        "set_menus",
        "signal",
        "sleep",
        "spawn",
        "stalls",
        "statusline",
        "view",
        "vouch",
        "which",
        // `run` runs commands within what the plugin's calling chain may do.
        "run",
        // Copying, hashing text and images already in hand.
        "clipboard.set",
        "hash.random",
        "hash.sha256",
        "image.cell_size",
        "image.cells",
        "image.decode",
        "image.forget",
        "image.size",
        // Where things are, not what's in them.
        "fs.cwd",
        "fs.dirs",
        // Servers already running; starting one is gated, and a request to
        // run a command on one checks `proc`.
        "lsp.capabilities",
        "lsp.diagnostics",
        "lsp.offset",
        "lsp.on_notification",
        "lsp.on_request",
        "lsp.path",
        "lsp.position",
        "lsp.problems",
        "lsp.remove",
        "lsp.request",
        "lsp.root",
        "lsp.running",
        "lsp.servers",
        "lsp.uri",
        "lsp.waits",
        // About plugins, and tying a plugin's own things to it.
        "plugin.caller",
        "plugin.describe",
        "plugin.dirs",
        "plugin.list",
        "plugin.pending",
        "plugin.started_within",
        "plugin.tie",
        "plugin.within",
        "syntax.query",
        "syntax.set_query",
    ];

    #[test]
    fn every_function_beside_a_gated_one_is_gated_or_named_free() {
        let host = Host::new(Editor::new(greed_text::ClientId(1))).unwrap();
        let modules: BTreeSet<&str> = GATED
            .iter()
            .filter_map(|(path, _)| path.split_once('.').map(|(module, _)| module))
            .collect();
        let listed = host
            .eval(&format!(
                "local greed, out = require('@greed'), {{}}
                 for _, module in {{ {} }} do
                     for key, value in greed[module] do
                         if type(value) == 'function' then
                             table.insert(out, module .. '.' .. key)
                         end
                     end
                 end
                 for key, value in greed do
                     if type(value) == 'function' then
                         table.insert(out, key)
                     end
                 end
                 table.sort(out)
                 return table.concat(out, ' ')",
                modules
                    .iter()
                    .map(|m| format!("{m:?}"))
                    .collect::<Vec<_>>()
                    .join(", ")
            ))
            .unwrap();
        let found: BTreeSet<&str> = listed.split(' ').collect();
        let gated: BTreeSet<&str> = GATED.iter().map(|(path, _)| *path).collect();
        let open: Vec<&str> = found
            .difference(&gated)
            .filter(|name| !FREE.contains(name))
            .copied()
            .collect();
        assert!(open.is_empty(), "neither gated nor named free: {open:?}");
        let missing: Vec<&str> = gated.difference(&found).copied().collect();
        assert!(missing.is_empty(), "gated but not in @greed: {missing:?}");
    }
}
