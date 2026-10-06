//! `greed.image`: images for marks to show, e.g. a picture in a note.

use std::sync::Arc;

use mlua::{IntoLuaMulti, Lua, Table, Value};

use super::{state, state_mut};
use crate::image::{Image, ImageId};
use crate::registry::PluginId;

type LuaResult<T> = mlua::Result<T>;

/// Keeps `image` for marks to show, as `owner`'s, returning its id, or nil
/// and why not.
fn keep(
    lua: &Lua,
    owner: &PluginId,
    image: Result<Image, crate::image::Error>,
) -> LuaResult<mlua::MultiValue> {
    match image {
        Ok(image) => {
            let state = &mut *state_mut(lua);
            let id = state.editor.images_mut().insert(Arc::new(image));
            state.owned.image(id, owner.clone());
            id.0.into_lua_multi(lua)
        }
        Err(err) => (Value::Nil, err.to_string()).into_lua_multi(lua),
    }
}

pub(super) fn module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let image = lua.create_table()?;
    let o = owner.clone();
    image.set(
        "load",
        lua.create_function(move |lua, path: String| {
            super::secrets::guard(lua, std::path::Path::new(&path))?;
            match std::fs::read(&path) {
                Ok(bytes) => keep(lua, &o, Image::from_file_bytes(&bytes)),
                Err(err) => (Value::Nil, format!("can't read {path}: {err}")).into_lua_multi(lua),
            }
        })?,
    )?;
    let o = owner.clone();
    image.set(
        "decode",
        lua.create_function(move |lua, bytes: mlua::LuaString| {
            keep(lua, &o, Image::from_file_bytes(&bytes.as_bytes()))
        })?,
    )?;
    image.set(
        "size",
        lua.create_function(|lua, id: u64| {
            let state = state(lua);
            Ok(state
                .editor
                .images()
                .get(ImageId(id))
                .map(|i| (i.width, i.height))
                .unzip())
        })?,
    )?;
    image.set(
        "cells",
        lua.create_function(|lua, id: u64| {
            let state = state(lua);
            let cell = state.editor.cell_size();
            Ok(state
                .editor
                .images()
                .get(ImageId(id))
                .map(|i| i.cells(cell))
                .unzip())
        })?,
    )?;
    image.set(
        "cell_size",
        lua.create_function(|lua, ()| Ok(state(lua).editor.cell_size()))?,
    )?;
    image.set(
        "forget",
        lua.create_function(|lua, id: u64| {
            let state = &mut *state_mut(lua);
            state.editor.images_mut().remove(ImageId(id));
            state.owned.forget_image(ImageId(id));
            Ok(())
        })?,
    )?;
    Ok(image)
}
