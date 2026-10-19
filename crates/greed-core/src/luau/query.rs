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

// The `fields` of a row or an index's item as Luau gives them: by name, a
// string or a list.
pub(super) fn fields(table: &Table) -> LuaResult<HashMap<String, Vec<String>>> {
    let mut fields = HashMap::new();
    if let Some(given) = table.get::<Option<Table>>("fields")? {
        for pair in given.pairs::<String, Value>() {
            let (name, value) = pair?;
            fields.insert(name.to_lowercase(), values(value)?);
        }
    }
    Ok(fields)
}

// The `flags` of a row or an index's item as Luau gives them: a list.
pub(super) fn flags(table: &Table) -> LuaResult<Vec<String>> {
    match table.get::<Option<Table>>("flags")? {
        Some(list) => list.sequence_values::<String>().collect(),
        None => Ok(Vec::new()),
    }
}

// A query `core.query` parsed, or nil for one every row matches.
pub(super) fn node(lua: &Lua, tree: Value) -> LuaResult<Option<Node>> {
    match tree {
        Value::Nil => Ok(None),
        tree => lua.from_value(tree).map(Some),
    }
}

// A row as Luau gives it: `text`, `fields`, `flags`, `name`, and `parent`,
// the 1-based index of its row.
fn row(table: &Table) -> LuaResult<Row> {
    let parent: Option<usize> = table.get("parent")?;
    Ok(Row {
        text: table.get::<Option<String>>("text")?.unwrap_or_default(),
        fields: fields(table)?,
        flags: flags(table)?,
        name: table.get("name")?,
        parent: parent.and_then(|p| p.checked_sub(1)),
        ..Row::default()
    })
}

pub(super) fn module(lua: &Lua) -> LuaResult<Table> {
    let module = lua.create_table()?;
    module.set(
        "run",
        lua.create_function(
            |lua, (tree, given, schema): (Value, Table, Value)| -> LuaResult<MultiValue> {
                let node = node(lua, tree)?;
                let schema: Schema = lua.from_value(schema)?;
                let rows = Rows::new(
                    given
                        .sequence_values::<Table>()
                        .map(|table| row(&table?))
                        .collect::<LuaResult<_>>()?,
                );
                let compiled = match node.map(|n| Query::new(n, schema)).transpose() {
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
    module.set(
        "fold",
        lua.create_function(|_, text: String| Ok(query::fold(&text)))?,
    )?;
    Ok(module)
}
