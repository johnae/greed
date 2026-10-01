//! `kern.image`: images for marks to show, e.g. a picture in a note.

use std::sync::Arc;

use mlua::{IntoLuaMulti, Lua, Table, Value};

use super::{state, state_mut};
use crate::image::{Image, ImageId};

type LuaResult<T> = mlua::Result<T>;

/// Keeps `image` for marks to show, returning its id, or nil and why not.
fn keep(lua: &Lua, image: Result<Image, crate::image::Error>) -> LuaResult<mlua::MultiValue> {
    match image {
        Ok(image) => {
            let id = state_mut(lua).editor.images_mut().insert(Arc::new(image));
            id.0.into_lua_multi(lua)
        }
        Err(err) => (Value::Nil, err.to_string()).into_lua_multi(lua),
    }
}

pub(super) fn module(lua: &Lua) -> LuaResult<Table> {
    let image = lua.create_table()?;
    image.set(
        "load",
        lua.create_function(|lua, path: String| match std::fs::read(&path) {
            Ok(bytes) => keep(lua, Image::from_file_bytes(&bytes)),
            Err(err) => (Value::Nil, format!("can't read {path}: {err}")).into_lua_multi(lua),
        })?,
    )?;
    image.set(
        "decode",
        lua.create_function(|lua, bytes: mlua::LuaString| {
            keep(lua, Image::from_file_bytes(&bytes.as_bytes()))
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
        "forget",
        lua.create_function(|lua, id: u64| {
            state_mut(lua).editor.images_mut().remove(ImageId(id));
            Ok(())
        })?,
    )?;
    Ok(image)
}
