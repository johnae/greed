//! `greed.debug`: a plugin's own debug lines, and the switches and lines of
//! every topic (see [`crate::debug`]).

use mlua::{Lua, Table, Value, Variadic};

use crate::debug;
use crate::registry::PluginId;

type LuaResult<T> = mlua::Result<T>;

/// The module for plugin `owner`, whose `log` lines are its own.
pub(super) fn module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let module = lua.create_table()?;
    let o = owner.clone();
    module.set(
        "log",
        lua.create_function(move |_, parts: Variadic<Value>| {
            if debug::plugin_on(&o) {
                let text: Vec<String> = parts.iter().map(super::api::display).collect();
                debug::say_for(&o, text.join(" "));
            }
            Ok(())
        })?,
    )?;
    let o = owner.clone();
    module.set(
        "on",
        lua.create_function(move |_, name: Option<String>| match name {
            None => Ok(debug::plugin_on(&o)),
            Some(name) => debug::named_on(&name)
                .ok_or_else(|| mlua::Error::runtime(format!("no debug topic called {name:?}"))),
        })?,
    )?;
    module.set(
        "set",
        lua.create_function(|_, (name, on): (String, bool)| {
            debug::set(&name, on).map_err(mlua::Error::runtime)
        })?,
    )?;
    module.set(
        "switch",
        lua.create_function(|_, words: String| {
            debug::switch(&words).map_err(mlua::Error::runtime)
        })?,
    )?;
    module.set(
        "off",
        lua.create_function(|_, ()| {
            debug::off();
            Ok(())
        })?,
    )?;
    module.set(
        "enabled",
        lua.create_function(|_, ()| Ok(debug::enabled()))?,
    )?;
    module.set(
        "topics",
        lua.create_function(|_, ()| {
            Ok(debug::Topic::ALL
                .iter()
                .map(|t| t.name())
                .collect::<Vec<_>>())
        })?,
    )?;
    module.set("lines", lua.create_function(lines)?)?;
    module.set(
        "clear",
        lua.create_function(|_, ()| {
            debug::clear();
            Ok(())
        })?,
    )?;
    Ok(module)
}

/// `greed.debug.lines({ after, limit, topic, plugin })`: the lines kept,
/// oldest first.
fn lines(lua: &Lua, opts: Option<Table>) -> LuaResult<Table> {
    let opts = match opts {
        Some(opts) => opts,
        None => lua.create_table()?,
    };
    let after = opts.get::<Option<f64>>("after")?.unwrap_or(0.0);
    let limit = opts.get::<Option<f64>>("limit")?.unwrap_or(1000.0);
    let topic = opts.get::<Option<String>>("topic")?;
    let plugin = opts.get::<Option<String>>("plugin")?;
    let list = lua.create_table()?;
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "ids and limits are small whole numbers"
    )]
    let (after, limit) = (after.max(0.0) as u64, limit.max(0.0) as usize);
    let found: Vec<_> = debug::lines(after, usize::MAX)
        .into_iter()
        .filter(|l| topic.as_deref().is_none_or(|t| t == l.topic.name()))
        .filter(|l| plugin.is_none() || l.plugin == plugin)
        .collect();
    for line in &found[found.len().saturating_sub(limit)..] {
        let t = lua.create_table()?;
        #[expect(clippy::cast_precision_loss, reason = "ids stay far below 2^53")]
        t.set("id", line.id as f64)?;
        t.set("at", line.at)?;
        t.set("topic", line.topic.name())?;
        t.set("plugin", line.plugin.as_deref())?;
        t.set("text", line.text.as_str())?;
        list.push(t)?;
    }
    Ok(list)
}
