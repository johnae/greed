//! `greed.index`: indexes on SQLite that queries run over, read and written
//! on another thread so a big one never holds up the editor. See
//! [`greed_index::index`].

use std::path::PathBuf;
use std::sync::{Arc, Mutex, PoisonError};

use greed_index::index::{Found, Index, Item, Trouble, View};
use greed_index::query::Schema;
use mlua::{IntoLuaMulti, Lua, LuaSerdeExt, MultiValue, Table, Value};

use super::arity::NoArgs;
use super::fs::UserPath;
use super::jobs::{self, Output};
use super::query::{fields, flags, node};

type LuaResult<T> = mlua::Result<T>;

type Shared = Arc<Mutex<Index>>;

/// What a job on an index came back with.
pub enum Done {
    Found(Found),
    Count(usize),
    Wrote,
}

// An item as Luau gives it: `key`, `parent` (the key of the item it's in),
// `name`, `text`, `fields`, `flags` and `words`.
fn item(table: &Table) -> LuaResult<Item> {
    Ok(Item {
        key: table.get("key")?,
        parent: table.get("parent")?,
        name: table.get("name")?,
        text: table.get::<Option<String>>("text")?.unwrap_or_default(),
        fields: fields(table)?,
        flags: flags(table)?,
        words: table.get("words")?,
    })
}

// How results come back, as Luau gives it: `sort` ({ field, descending })
// and `limit`.
fn view(table: Option<Table>) -> LuaResult<View> {
    let Some(table) = table else {
        return Ok(View::default());
    };
    let mut sort = Vec::new();
    if let Some(keys) = table.get::<Option<Table>>("sort")? {
        for key in keys.sequence_values::<Table>() {
            let key = key?;
            sort.push((
                key.get::<String>("field")?,
                key.get::<Option<bool>>("descending")?.unwrap_or(false),
            ));
        }
    }
    Ok(View {
        sort,
        limit: table.get("limit")?,
    })
}

/// The result of a job on an index, as the command waiting for it gets it.
pub(super) fn to_lua(lua: &Lua, done: Result<Done, Trouble>) -> LuaResult<MultiValue> {
    match done {
        Ok(Done::Found(found)) => (
            lua.create_sequence_from(found.keys)?,
            lua.create_sequence_from(found.maybe)?,
        )
            .into_lua_multi(lua),
        Ok(Done::Count(n)) => n.into_lua_multi(lua),
        Ok(Done::Wrote) => true.into_lua_multi(lua),
        Err(Trouble(why)) => (Value::Nil, why).into_lua_multi(lua),
    }
}

// Starts `work` on the index as a job, holding its one connection.
fn on_index(
    lua: &Lua,
    what: &str,
    index: &Shared,
    work: impl FnOnce(&mut Index) -> Result<Done, Trouble> + Send + 'static,
) -> u64 {
    let index = index.clone();
    jobs::start(lua, what, move || {
        let mut index = index.lock().unwrap_or_else(PoisonError::into_inner);
        Output::Index(work(&mut index))
    })
}

// An index as Luau holds it: its methods run as jobs on the one connection.
fn handle(lua: &Lua, index: Index, path: &str) -> LuaResult<Table> {
    let shared: Shared = Arc::new(Mutex::new(index));
    let table = lua.create_table()?;
    let on = |what: &str| format!("greed.index {what} {path}");

    let index = shared.clone();
    let what = on("search");
    let search = lua.create_function(
        move |lua, (tree, schema, shown): (Value, Value, Option<Table>)| {
            let node = node(lua, tree)?;
            let schema: Schema = lua.from_value(schema)?;
            let shown = view(shown)?;
            Ok(on_index(lua, &what, &index, move |index| {
                index
                    .search(node.as_ref(), &schema, &shown)
                    .map(Done::Found)
            }))
        },
    )?;
    table.set("search", jobs::waiting_method(lua, "index:search", search)?)?;

    let index = shared.clone();
    let what = on("write");
    let write = lua.create_function(move |lua, given: Table| {
        let items = given
            .sequence_values::<Table>()
            .map(|t| item(&t?))
            .collect::<LuaResult<Vec<_>>>()?;
        Ok(on_index(lua, &what, &index, move |index| {
            index.write(&items).map(|()| Done::Wrote)
        }))
    })?;
    table.set("write", jobs::waiting_method(lua, "index:write", write)?)?;

    let index = shared.clone();
    let what = on("remove");
    let remove = lua.create_function(move |lua, given: Table| {
        let keys = given
            .sequence_values::<String>()
            .collect::<LuaResult<Vec<_>>>()?;
        Ok(on_index(lua, &what, &index, move |index| {
            index.remove(&keys).map(|()| Done::Wrote)
        }))
    })?;
    table.set("remove", jobs::waiting_method(lua, "index:remove", remove)?)?;

    let index = shared;
    let what = on("count");
    let count = lua.create_function(move |lua, NoArgs| {
        Ok(on_index(lua, &what, &index, |index| {
            index.count().map(Done::Count)
        }))
    })?;
    table.set("count", jobs::waiting_method(lua, "index:count", count)?)?;
    super::handles::methods(lua, table)
}

// The handle for an index just opened, or nil and why it couldn't be.
fn opened(lua: &Lua, index: Result<Index, Trouble>, path: &str) -> LuaResult<MultiValue> {
    match index {
        Ok(index) => handle(lua, index, path)?.into_lua_multi(lua),
        Err(Trouble(why)) => (Value::Nil, why).into_lua_multi(lua),
    }
}

pub(super) fn module(lua: &Lua) -> LuaResult<Table> {
    let module = lua.create_table()?;
    module.set(
        "open",
        lua.create_function(|lua, UserPath(path): UserPath| {
            opened(lua, Index::open_read(&PathBuf::from(&path)), &path)
        })?,
    )?;
    module.set(
        "writer",
        lua.create_function(|lua, UserPath(path): UserPath| -> LuaResult<MultiValue> {
            let file = PathBuf::from(&path);
            super::fs::guard_write(lua, &file)?;
            if let Err(err) = super::fs::create_parent(&file) {
                return (
                    Value::Nil,
                    format!("can't make the folder for {path}: {err}"),
                )
                    .into_lua_multi(lua);
            }
            opened(lua, Index::open(&file), &path)
        })?,
    )?;
    Ok(module)
}
