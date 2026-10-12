//! `greed.compare`: comparing values the way filters do, the same as a
//! view's filter (`level>=warn`) and a table's `where` (`RESTARTS>0`). See
//! [`crate::compare`].

use mlua::{IntoLuaMulti, Lua, MultiValue, Table, Value};

use crate::compare::{self, Op};

type LuaResult<T> = mlua::Result<T>;

/// `sign` as an operator, or an error naming the ones there are.
fn op_named(sign: &str) -> LuaResult<Op> {
    Op::parse(sign).ok_or_else(|| {
        mlua::Error::runtime(format!(
            "{sign:?} isn't an operator; give one of = != ~ !~ < <= > >="
        ))
    })
}

pub(super) fn module(lua: &Lua) -> LuaResult<Table> {
    let module = lua.create_table()?;
    module.set(
        "number",
        lua.create_function(|_, (text, durations): (String, Option<bool>)| {
            Ok(compare::number(&text, durations.unwrap_or(false)))
        })?,
    )?;
    module.set(
        "test",
        lua.create_function(
            |_, (have, sign, want, durations): (String, String, String, Option<bool>)| {
                let durations = durations.unwrap_or_else(|| compare::is_duration(&want));
                Ok(compare::passes(&have, op_named(&sign)?, &want, durations))
            },
        )?,
    )?;
    module.set(
        "order",
        lua.create_function(|_, (a, b, durations): (String, String, Option<bool>)| {
            Ok(compare::order(&a, &b, durations.unwrap_or(false)) as i8)
        })?,
    )?;
    module.set(
        "is_duration",
        lua.create_function(|_, text: String| Ok(compare::is_duration(&text)))?,
    )?;
    module.set(
        "find",
        lua.create_function(|lua, text: String| -> LuaResult<MultiValue> {
            match Op::find(&text) {
                // 1-based, as `string.find` gives: where it starts and ends.
                Some((at, op, len)) => (at + 1, at + len, op.sign()).into_lua_multi(lua),
                None => Value::Nil.into_lua_multi(lua),
            }
        })?,
    )?;
    Ok(module)
}
