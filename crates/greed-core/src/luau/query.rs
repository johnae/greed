//! `greed.query`: running a query `core.query` parsed over rows, in Rust.
//! See [`greed_index::query`].

use std::collections::HashMap;

use greed_index::query::{self, Node, Query, Row, Rows, Schema};
use mlua::{IntoLuaMulti, Lua, LuaSerdeExt, MultiValue, Table, Value};

type LuaResult<T> = mlua::Result<T>;

// A field's values as Luau gives them: one string, or a list of them.
fn values(value: Value) -> LuaResult<Vec<String>> {
    Ok(match value {
        Value::Nil => Vec::new(),
        Value::Table(list) => list.sequence_values::<String>().collect::<LuaResult<_>>()?,
        Value::String(s) => vec![s.to_str()?.to_string()],
        Value::Integer(n) => vec![n.to_string()],
        Value::Number(n) => vec![n.to_string()],
        other => {
            return Err(mlua::Error::runtime(format!(
                "a field's value should be a string or a list of them, not a {}",
                other.type_name()
            )));
        }
    })
}

// A row as Luau gives it: `text`, `fields` (by name, a string or a list),
// `flags` (a list), `name`, and `parent`, the 1-based index of its row.
fn row(table: &Table) -> LuaResult<Row> {
    let mut fields = HashMap::new();
    if let Some(given) = table.get::<Option<Table>>("fields")? {
        for pair in given.pairs::<String, Value>() {
            let (name, value) = pair?;
            fields.insert(name.to_lowercase(), values(value)?);
        }
    }
    let flags = match table.get::<Option<Table>>("flags")? {
        Some(list) => list.sequence_values::<String>().collect::<LuaResult<_>>()?,
        None => Vec::new(),
    };
    let parent: Option<usize> = table.get("parent")?;
    Ok(Row {
        text: table.get::<Option<String>>("text")?.unwrap_or_default(),
        fields,
        flags,
        name: table.get("name")?,
        parent: parent.and_then(|p| p.checked_sub(1)),
    })
}

pub(super) fn module(lua: &Lua) -> LuaResult<Table> {
    let module = lua.create_table()?;
    module.set(
        "run",
        lua.create_function(
            |lua, (tree, given, schema): (Value, Table, Value)| -> LuaResult<MultiValue> {
                let node: Option<Node> = match tree {
                    Value::Nil => None,
                    tree => Some(lua.from_value(tree)?),
                };
                let schema: Schema = lua.from_value(schema)?;
                let rows = Rows::new(
                    given
                        .sequence_values::<Table>()
                        .map(|table| row(&table?))
                        .collect::<LuaResult<_>>()?,
                );
                let compiled = match node.as_ref().map(|n| Query::new(n, &schema)).transpose() {
                    Ok(q) => q,
                    Err(query::Bad(why)) => {
                        return (Value::Nil, Value::Nil, why).into_lua_multi(lua);
                    }
                };
                let (matching, maybe) = query::run(compiled.as_ref(), &rows);
                let one_based = |list: Vec<usize>| -> LuaResult<Table> {
                    lua.create_sequence_from(list.into_iter().map(|i| i + 1))
                };
                (one_based(matching)?, one_based(maybe)?).into_lua_multi(lua)
            },
        )?,
    )?;
    Ok(module)
}
