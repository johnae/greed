//! What plugins need to set languages up: file types, the grammars Kern has,
//! and finding programs like language servers.

use std::path::Path;

use mlua::{Lua, Table};

use super::{state, state_mut};

type LuaResult<T> = mlua::Result<T>;

pub(super) fn register(lua: &Lua, kern: &Table) -> LuaResult<()> {
    kern.set(
        "language_of",
        lua.create_function(|lua, path: String| {
            Ok(state(lua)
                .editor
                .file_type(Path::new(&path))
                .map(|l| l.to_string()))
        })?,
    )?;

    kern.set(
        "filetype",
        lua.create_function(|lua, (language, spec): (String, Table)| {
            let list = |key: &str| -> LuaResult<Vec<String>> {
                Ok(spec.get::<Option<Vec<String>>>(key)?.unwrap_or_default())
            };
            let (extensions, names) = (list("extensions")?, list("names")?);
            state_mut(lua)
                .editor
                .set_file_type(&language, &extensions, &names);
            Ok(())
        })?,
    )?;

    kern.set(
        "grammars",
        lua.create_function(|lua, ()| Ok(state(lua).syntax.names()))?,
    )?;

    kern.set(
        "which",
        lua.create_function(|_, program: String| {
            Ok(crate::lsp::which(&program).map(|p| p.to_string_lossy().into_owned()))
        })?,
    )
}
