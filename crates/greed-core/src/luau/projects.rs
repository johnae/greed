//! `greed.project`: the projects open in the editor, each a folder with its
//! own main view and panels. Plugins decide what opens a project and how
//! switching looks; this is just the bookkeeping.

use std::path::PathBuf;

use mlua::{Lua, Table};

use super::handles::view_closed;
use super::{state, state_mut};
use crate::{Project, ProjectId};

type LuaResult<T> = mlua::Result<T>;

fn project_to_lua(lua: &Lua, project: &Project, current: ProjectId) -> LuaResult<Table> {
    let table = lua.create_table()?;
    table.set("id", project.id().0)?;
    table.set("root", project.root().to_string_lossy().into_owned())?;
    table.set("current", project.id() == current)?;
    Ok(table)
}

pub(super) fn module(lua: &Lua) -> LuaResult<Table> {
    let project = lua.create_table()?;
    project.set(
        "list",
        lua.create_function(|lua, ()| {
            let state = state(lua);
            let current = state.editor.current_project().id();
            let list = lua.create_table()?;
            for p in state.editor.projects() {
                list.push(project_to_lua(lua, p, current)?)?;
            }
            Ok(list)
        })?,
    )?;
    project.set(
        "current",
        lua.create_function(|lua, ()| {
            let state = state(lua);
            let current = state.editor.current_project();
            project_to_lua(lua, &current, current.id())
        })?,
    )?;
    project.set(
        "open",
        lua.create_function(|lua, root: String| {
            Ok(state_mut(lua).editor.open_project(PathBuf::from(root)).0)
        })?,
    )?;
    project.set(
        "switch",
        lua.create_function(|lua, id: u32| {
            Ok(state_mut(lua).editor.switch_project(ProjectId(id)))
        })?,
    )?;
    project.set(
        "close",
        lua.create_function(|lua, id: u32| {
            let id = ProjectId(id);
            let views: Vec<_> = state(lua)
                .editor
                .projects()
                .iter()
                .find(|p| p.id() == id)
                .map(|p| p.views().collect())
                .unwrap_or_default();
            let closed = state_mut(lua).editor.close_project(id);
            if closed {
                for view in views {
                    view_closed(lua, view)?;
                }
            }
            Ok(closed)
        })?,
    )?;
    Ok(project)
}
