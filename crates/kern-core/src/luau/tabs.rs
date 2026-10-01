//! `kern.tab`: the shown project's tabs, each a layout of panes. Splitting
//! and moving between panes is on views (`view:split`, `view:neighbor`).

use kern_text::Author;
use mlua::{Lua, Table, UserDataRef};

use super::handles::{BufferRef, ViewRef, view_closed};
use super::{state, state_mut};
use crate::registry::PluginId;
use crate::{Tab, TabId};

type LuaResult<T> = mlua::Result<T>;

fn tab_to_lua(lua: &Lua, tab: &Tab, shown: TabId, author: &Author) -> LuaResult<Table> {
    let t = lua.create_table()?;
    t.set("id", tab.id().0)?;
    t.set("name", tab.name())?;
    t.set("current", tab.id() == shown)?;
    t.set("zoomed", tab.zoomed())?;
    t.set("panes", views(lua, tab.panes(), author)?)?;
    t.set("active", view(tab.active(), author))?;
    Ok(t)
}

fn view(id: crate::ViewId, author: &Author) -> ViewRef {
    ViewRef {
        id,
        author: author.clone(),
    }
}

fn views(lua: &Lua, ids: Vec<crate::ViewId>, author: &Author) -> LuaResult<Table> {
    let list = lua.create_table()?;
    for id in ids {
        list.push(view(id, author))?;
    }
    Ok(list)
}

pub(super) fn module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let tab = lua.create_table()?;
    let author = Author::Plugin(owner.clone());

    let a = author.clone();
    tab.set(
        "list",
        lua.create_function(move |lua, ()| {
            let state = state(lua);
            let shown = state.editor.current_tab().id();
            let list = lua.create_table()?;
            for t in state.editor.tabs() {
                list.push(tab_to_lua(lua, t, shown, &a)?)?;
            }
            Ok(list)
        })?,
    )?;
    let a = author.clone();
    tab.set(
        "current",
        lua.create_function(move |lua, ()| {
            let state = state(lua);
            let current = state.editor.current_tab();
            tab_to_lua(lua, current, current.id(), &a)
        })?,
    )?;
    tab.set(
        "new",
        lua.create_function(|lua, buffer: Option<UserDataRef<BufferRef>>| {
            let buffer = buffer
                .map(|b| b.with_buffer(lua, |_| Ok(b.buffer)))
                .transpose()?;
            Ok(state_mut(lua).editor.new_tab(buffer).0)
        })?,
    )?;
    tab.set(
        "switch",
        lua.create_function(|lua, id: u32| Ok(state_mut(lua).editor.switch_tab(TabId(id))))?,
    )?;
    tab.set(
        "close",
        lua.create_function(|lua, id: u32| {
            let closed = state_mut(lua).editor.close_tab(TabId(id));
            for view in closed.iter().flatten() {
                view_closed(lua, *view)?;
            }
            Ok(closed.is_some())
        })?,
    )?;
    tab.set(
        "rename",
        lua.create_function(|lua, (id, name): (u32, Option<String>)| {
            let name = name.filter(|n| !n.is_empty()).map(Into::into);
            Ok(state_mut(lua).editor.rename_tab(TabId(id), name))
        })?,
    )?;
    tab.set(
        "set_zoomed",
        lua.create_function(|lua, zoomed: bool| {
            state_mut(lua).editor.set_zoomed(zoomed);
            Ok(())
        })?,
    )?;
    Ok(tab)
}
