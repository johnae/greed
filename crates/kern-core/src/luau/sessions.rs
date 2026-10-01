//! `kern.session`: the sessions running on this machine, and sending the
//! attached client to another one. Each session is its own editor process;
//! switching moves the client, and whoever holds its connection (the
//! terminal, or the bridge on the far end of `kern ssh`) reconnects.

use mlua::{Lua, Table};

use super::{state, state_mut};
use crate::{SwitchTo, control};

type LuaResult<T> = mlua::Result<T>;

pub(super) fn module(lua: &Lua) -> LuaResult<Table> {
    let session = lua.create_table()?;
    session.set(
        "list",
        lua.create_function(|lua, ()| {
            let current = state(lua).session_name.clone();
            let list = lua.create_table()?;
            for info in control::sessions().map_err(mlua::Error::external)? {
                let entry = lua.create_table()?;
                entry.set("current", current.as_deref() == Some(info.name.as_str()))?;
                entry.set("name", info.name)?;
                entry.set("root", info.root.map(|r| r.to_string_lossy().into_owned()))?;
                list.push(entry)?;
            }
            Ok(list)
        })?,
    )?;
    session.set(
        "current",
        lua.create_function(|lua, ()| Ok(state(lua).session_name.clone()))?,
    )?;
    session.set(
        "switch",
        lua.create_function(|lua, to: Table| {
            let to = SwitchTo {
                session: to.get("name")?,
                path: to.get("path")?,
            };
            if to.session.is_none() && to.path.is_none() {
                return Err(mlua::Error::runtime(
                    "switch to what? give a session name or a path",
                ));
            }
            state_mut(lua).editor.request_switch(to);
            Ok(())
        })?,
    )?;
    Ok(session)
}
