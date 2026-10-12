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
    text.set(
        "width",
        lua.create_function(|_, (line, tab_width): (mlua::LuaString, Option<usize>)| {
            let tab_width = tab_width.unwrap_or(crate::render::TAB_WIDTH).max(1);
            Ok(crate::render::width(
                &String::from_utf8_lossy(&line.as_bytes()),
                tab_width,
            ))
        })?,
    )?;
    text.set(
        "matches",
        lua.create_function(
            |lua, (subject, pattern, limit): (mlua::LuaString, String, Option<usize>)| {
                let regex = match regex::Regex::new(&pattern) {
                    Ok(regex) => regex,
                    Err(err) => return (Value::Nil, err.to_string()).into_lua_multi(lua),
                };
                let subject = subject.to_string_lossy();
                let found = lua.create_table()?;
                for captures in regex
                    .captures_iter(&subject)
                    .take(limit.unwrap_or(usize::MAX))
                {
                    let whole = captures.get(0).expect("a match has its whole");
                    let groups = lua.create_table()?;
                    for (i, group) in captures.iter().enumerate().skip(1) {
                        match group {
                            Some(group) => groups.raw_set(i, group.as_str())?,
                            None => groups.raw_set(i, false)?,
                        }
                    }
                    let one = lua.create_table()?;
                    one.set("from", whole.start() + 1)?;
                    one.set("to", whole.end())?;
                    one.set("text", whole.as_str())?;
                    one.set("groups", groups)?;
                    found.raw_push(one)?;
                }
                found.into_lua_multi(lua)
            },
        )?,
    )?;
    Ok(text)
}
