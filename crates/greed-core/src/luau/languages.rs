//! What plugins need to set languages up: file types, the grammars Greed has,
//! and finding programs like language servers.

use std::path::Path;

use mlua::{Lua, Table};

use super::{state, state_mut};
use crate::registry::PluginId;

type LuaResult<T> = mlua::Result<T>;

pub(super) fn register(lua: &Lua, greed: &Table, owner: &PluginId) -> LuaResult<()> {
    greed.set(
        "language_of",
        lua.create_function(|lua, path: String| {
            Ok(state(lua)
                .editor
                .file_type(Path::new(&path))
                .map(|l| l.to_string()))
        })?,
    )?;

    let owner = owner.clone();
    greed.set(
        "filetype",
        lua.create_function(move |lua, (language, spec): (String, Table)| {
            let list = |key: &str| -> LuaResult<Vec<String>> {
                Ok(spec.get::<Option<Vec<String>>>(key)?.unwrap_or_default())
            };
            let (extensions, names) = (list("extensions")?, list("names")?);
            let state = &mut *state_mut(lua);
            state.editor.set_file_type(&language, &extensions, &names);
            state
                .owned
                .file_type(owner.clone(), &language, &extensions, &names);
            Ok(())
        })?,
    )?;

    greed.set(
        "grammars",
        lua.create_function(|lua, ()| Ok(state(lua).syntax.names()))?,
    )?;

    greed.set(
        "which",
        lua.create_function(|_, program: String| {
            Ok(crate::lsp::which(&program).map(|p| p.to_string_lossy().into_owned()))
        })?,
    )
}
