//! `greed.tab`: the shown project's tabs, each a layout of panes. Splitting
//! and moving between panes is on views (`view:split`, `view:neighbor`).

use greed_text::Author;
use mlua::{Lua, Table, UserDataRef, Value};

use super::handles::{BufferRef, ViewRef, view_closed};
use super::{state, state_mut};
use crate::layout::{Axis, Node};
use crate::registry::PluginId;
use crate::{TabId, TabView};

type LuaResult<T> = mlua::Result<T>;

fn tab_to_lua(lua: &Lua, tab: &TabView, shown: TabId, author: &Author) -> LuaResult<Table> {
    let t = lua.create_table()?;
    t.set("id", tab.id().0)?;
    t.set("name", tab.name())?;
    t.set("current", tab.id() == shown)?;
    t.set("zoomed", tab.zoomed())?;
    t.set("panes", views(lua, tab.panes(), author)?)?;
    t.set("active", view(tab.active(), author))?;
    Ok(t)
}

/// A layout as Luau sees it: a pane is its view, a split
/// `{ split = "row" | "column", children = {...}, sizes = {...} }`.
fn layout_to_lua(lua: &Lua, node: &Node, author: &Author) -> LuaResult<Value> {
    match node {
        Node::Pane(id) => Ok(Value::UserData(lua.create_userdata(view(*id, author))?)),
        Node::Split { axis, children } => {
            let t = lua.create_table()?;
            t.set(
                "split",
                match axis {
                    Axis::Across => "row",
                    Axis::Down => "column",
                },
            )?;
            let (nodes, sizes) = (lua.create_table()?, lua.create_table()?);
            let total: f64 = children.iter().map(|(_, w)| f64::from(*w)).sum();
            for (child, weight) in children {
                nodes.push(layout_to_lua(lua, child, author)?)?;
                // Shares of the split, adding up to 1.
                sizes.push(f64::from(*weight) / total)?;
            }
            t.set("children", nodes)?;
            t.set("sizes", sizes)?;
            Ok(Value::Table(t))
        }
    }
}

/// A layout from Luau. Sizes are relative to each other, equal if left out.
/// Splits nest at most `depth` deep.
fn layout_from_lua(value: Value, depth: usize) -> LuaResult<Node> {
    match value {
        Value::UserData(ud) => Ok(Node::Pane(ud.borrow::<ViewRef>()?.id)),
        Value::Table(_) if depth == 0 => Err(mlua::Error::runtime("splits nest too deep")),
        Value::Table(t) => {
            let axis = match t.get::<String>("split")?.as_str() {
                "row" => Axis::Across,
                "column" => Axis::Down,
                other => {
                    return Err(mlua::Error::runtime(format!(
                        "a split is \"row\" (side by side) or \"column\" (one above another), not {other:?}"
                    )));
                }
            };
            let nodes: Vec<Value> = t
                .get::<Table>("children")?
                .sequence_values::<Value>()
                .collect::<LuaResult<_>>()?;
            let given = t.get::<Option<Vec<f64>>>("sizes")?.unwrap_or_default();
            let sizes: Vec<f64> = (0..nodes.len())
                .map(|i| given.get(i).copied().unwrap_or(1.0).max(0.0))
                .collect();
            let total = sizes.iter().sum::<f64>().max(f64::MIN_POSITIVE);
            let mut children = nodes
                .into_iter()
                .zip(sizes)
                .map(|(child, size)| {
                    // Each child's share of a whole that halves many times.
                    let weight = (size / total * 1024.0 * 64.0).round().max(1.0);
                    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
                    Ok((layout_from_lua(child, depth - 1)?, weight as u32))
                })
                .collect::<LuaResult<Vec<_>>>()?;
            // A split of one is that one, so closing it leaves no empty split.
            if children.len() == 1
                && let Some((only, _)) = children.pop()
            {
                return Ok(only);
            }
            Ok(Node::Split { axis, children })
        }
        _ => Err(mlua::Error::runtime(
            "a layout is a view (a pane) or a split table",
        )),
    }
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
                list.push(tab_to_lua(lua, &t, shown, &a)?)?;
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
            tab_to_lua(lua, &current, current.id(), &a)
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
    let a = author.clone();
    tab.set(
        "layout",
        lua.create_function(move |lua, id: Option<u32>| {
            let state = state(lua);
            let id = id.map_or_else(|| state.editor.current_tab().id(), TabId);
            let layout = state
                .editor
                .tab_layout(id)
                .ok_or_else(|| mlua::Error::runtime("there's no such tab"))?;
            layout_to_lua(lua, layout, &a)
        })?,
    )?;
    tab.set(
        "set_layout",
        lua.create_function(|lua, (layout, id): (Value, Option<u32>)| {
            let layout = layout_from_lua(layout, 64)?;
            let mut state = state_mut(lua);
            let id = id.map_or_else(|| state.editor.current_tab().id(), TabId);
            state
                .editor
                .set_tab_layout(id, layout)
                .map_err(mlua::Error::runtime)
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
