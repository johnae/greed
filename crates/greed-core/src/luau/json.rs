//! `greed.json`: JSON for plugins, e.g. for tool results and HTTP bodies.
//! Luau tables become objects or arrays by their keys; an empty table is
//! an object unless it came from `greed.json.array`.

use mlua::{Lua, LuaSerdeExt, Table, Value};

use super::lsp;

type LuaResult<T> = mlua::Result<T>;

pub(super) fn module(lua: &Lua) -> LuaResult<Table> {
    let json = lua.create_table()?;
    json.set(
        "encode",
        lua.create_function(|lua, value: Value| {
            let value: serde_json::Value = lua.from_value(value)?;
            Ok(value.to_string())
        })?,
    )?;
    json.set(
        "decode",
        lua.create_function(|lua, text: String| {
            match serde_json::from_str::<serde_json::Value>(&text) {
                Ok(value) => Ok((lsp::to_lua(lua, &value)?, None)),
                Err(err) => Ok((Value::Nil, Some(err.to_string()))),
            }
        })?,
    )?;
    json.set(
        "array",
        lua.create_function(|lua, items: Option<Table>| {
            let items = match items {
                Some(items) => items,
                None => lua.create_table()?,
            };
            items.set_metatable(Some(lua.array_metatable()))?;
            Ok(items)
        })?,
    )?;
    Ok(json)
}
