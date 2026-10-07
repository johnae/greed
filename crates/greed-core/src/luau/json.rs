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
            let value: serde_json::Value = match lua.from_value(value.clone()) {
                Ok(value) => value,
                // Bytes that aren't UTF-8 can't be JSON: they become U+FFFD.
                Err(_) => lua.from_value(lossy(lua, value, 0)?)?,
            };
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

/// How deep [`lossy`] copies tables, past any JSON worth writing; deeper,
/// or a table that holds itself, is left for the encoder to refuse.
const DEEPEST: usize = 128;

/// `value` with every string, key or value, that isn't UTF-8 made so, its
/// broken bytes as U+FFFD. Tables are copied with their metatables, so
/// arrays stay arrays.
fn lossy(lua: &Lua, value: Value, depth: usize) -> LuaResult<Value> {
    match value {
        Value::String(s) => match s.to_str() {
            Ok(_) => Ok(Value::String(s)),
            Err(_) => Ok(Value::String(
                lua.create_string(String::from_utf8_lossy(&s.as_bytes()).as_bytes())?,
            )),
        },
        Value::Table(table) if depth < DEEPEST => {
            let copy = lua.create_table()?;
            for pair in table.pairs::<Value, Value>() {
                let (key, value) = pair?;
                copy.raw_set(lossy(lua, key, depth + 1)?, lossy(lua, value, depth + 1)?)?;
            }
            copy.set_metatable(table.metatable())?;
            Ok(Value::Table(copy))
        }
        other => Ok(other),
    }
}
