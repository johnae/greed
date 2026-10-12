//! `greed.text`: reading lines of text as Greed does, for plugins to read
//! them the same way.

use mlua::{IntoLuaMulti, Lua, MultiValue, Table, Value};

type LuaResult<T> = mlua::Result<T>;

pub(super) fn module(lua: &Lua) -> LuaResult<Table> {
    let text = lua.create_table()?;
    text.set(
        "shape",
        lua.create_function(
            |lua, (line, items): (mlua::LuaString, Option<bool>)| -> LuaResult<MultiValue> {
                let line = line.to_str()?;
                match crate::nested::shape(&line, items.unwrap_or(false)) {
                    Some((indent, key)) => (indent, key).into_lua_multi(lua),
                    None => Value::Nil.into_lua_multi(lua),
                }
            },
        )?,
    )?;
    Ok(text)
}
