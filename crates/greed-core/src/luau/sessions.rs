//! `greed.session`: the sessions running on this machine, and sending the
//! attached client to another one. Each session is its own editor process;
//! switching moves the client, and whoever holds its connection (the
//! terminal, or the bridge on the far end of `greed ssh`) reconnects.

use std::path::Path;

use mlua::{Lua, Table};

use super::arity::NoArgs;
use super::jobs::{self, Output};
use super::{state, state_mut};
use crate::{SwitchTo, control, project};

type LuaResult<T> = mlua::Result<T>;

pub(super) fn module(lua: &Lua) -> LuaResult<Table> {
    let session = lua.create_table()?;
    session.set(
        "list",
        lua.create_function(|lua, NoArgs| {
            let current = state(lua).session_name.clone();
            let list = lua.create_table()?;
            for info in control::sessions().map_err(mlua::Error::external)? {
                let entry = lua.create_table()?;
                entry.set("current", current.as_deref() == Some(info.name.as_str()))?;
                entry.set("name", info.name)?;
                entry.set("root", info.root.map(|r| r.to_string_lossy().into_owned()))?;
                entry.set("build", info.build)?;
                list.push(entry)?;
            }
            Ok(list)
        })?,
    )?;
    session.set(
        "current",
        lua.create_function(|lua, NoArgs| Ok(state(lua).session_name.clone()))?,
    )?;
    session.set(
        "build",
        lua.create_function(|_, NoArgs| Ok(control::build()))?,
    )?;
    session.set(
        "fresh",
        lua.create_function(|_, NoArgs| Ok(control::fresh()))?,
    )?;
    session.set(
        "remote",
        lua.create_function(|lua, NoArgs| {
            // Before any client attached, whether `greed ssh` started it.
            Ok(state(lua)
                .remote
                .unwrap_or_else(|| std::env::var_os(control::REMOTE_ENV).is_some()))
        })?,
    )?;
    session.set(
        "attached",
        lua.create_function(|lua, NoArgs| Ok(state(lua).attached))?,
    )?;
    session.set(
        "program",
        lua.create_function(|_, NoArgs| {
            Ok(std::env::current_exe()
                .ok()
                .map(|path| path.to_string_lossy().into_owned()))
        })?,
    )?;
    let start_status = lua.create_function(|lua, name: String| {
        Ok(jobs::start(
            lua,
            format!("greed.session.status {name:?}"),
            move || Output::Status(control::status_of(&name, control::STATUS_WAIT)),
        ))
    })?;
    session.set(
        "status",
        jobs::waiting(lua, "greed.session.status", start_status)?,
    )?;
    session.set(
        "switch",
        lua.create_function(|lua, spec: Table| switch(lua, &spec))?,
    )?;
    Ok(session)
}

/// `greed.session.switch(spec)`: asks for the attached client to go where
/// `spec` says.
fn switch(lua: &Lua, spec: &Table) -> LuaResult<()> {
    let flag =
        |name: &str| -> LuaResult<bool> { Ok(spec.get::<Option<bool>>(name)?.unwrap_or(false)) };
    let mut to = SwitchTo {
        session: spec.get("name")?,
        path: spec.get("path")?,
        host: spec.get("host")?,
        window: flag("window")?,
        back: flag("back")?,
        home: flag("home")?,
    };
    let somewhere = to.session.is_some() || to.path.is_some() || to.host.is_some();
    if to.back || to.home {
        if somewhere || to.window || (to.back && to.home) {
            return Err(mlua::Error::runtime(
                "back and home go on their own: no name, path, host, window or each other",
            ));
        }
    } else if !somewhere {
        return Err(mlua::Error::runtime(
            "switch to what? give a session name, a path or a host, or back or home",
        ));
    }
    // A session of its own, even if one runs for that project here.
    if to.host.is_none()
        && flag("new")?
        && let Some(path) = &to.path
    {
        let taken: Vec<String> = control::sessions()
            .map_err(mlua::Error::external)?
            .into_iter()
            .map(|s| s.name)
            .collect();
        let root = project::root_of(Path::new(path));
        to.session = Some(project::session_name(&root, &taken));
    }
    state_mut(lua).editor.request_switch(to);
    Ok(())
}
