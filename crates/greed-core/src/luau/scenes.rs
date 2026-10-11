//! `greed.scene`: small vector drawings for marks to place, as charts are,
//! which each client draws as well as it can (see `crate::scene`).

use mlua::{Lua, LuaSerdeExt, Table, Value};

use super::state_mut;
use crate::registry::PluginId;
use crate::scene::{SceneId, Spec};

type LuaResult<T> = mlua::Result<T>;

// A scene's spec from Luau: `{ alt, items }`, a list of items each with its
// `kind`.
fn spec_from_lua(lua: &Lua, value: Value) -> LuaResult<Spec> {
    lua.from_value(value).map_err(|err| {
        mlua::Error::runtime(format!(
            "a scene is {{ alt = \"what it shows\", items = {{ ... }} }}: {err}"
        ))
    })
}

pub(super) fn module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let scene = lua.create_table()?;
    let o = owner.clone();
    scene.set(
        "new",
        lua.create_function(move |lua, spec: Value| {
            let spec = spec_from_lua(lua, spec)?;
            let state = &mut *state_mut(lua);
            let id = state.editor.scenes_mut().insert(spec);
            state.owned.scene(id, o.clone());
            Ok(id.0)
        })?,
    )?;
    scene.set(
        "set",
        lua.create_function(|lua, (id, spec): (u64, Value)| {
            let spec = spec_from_lua(lua, spec)?;
            Ok(state_mut(lua).editor.scenes_mut().set(SceneId(id), spec))
        })?,
    )?;
    scene.set(
        "forget",
        lua.create_function(|lua, id: u64| {
            let state = &mut *state_mut(lua);
            state.editor.scenes_mut().remove(SceneId(id));
            state.owned.forget_scene(SceneId(id));
            Ok(())
        })?,
    )?;
    Ok(scene)
}
