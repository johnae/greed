//! `kern.diff`: line changes between two texts, e.g. to show a new version
//! of a file as changes to review.

use mlua::Lua;

type LuaResult<T> = mlua::Result<T>;

/// `kern.diff(old, new)`: the line changes that turn `old` into `new`, as
/// `{ from, to, text }` with byte offsets into `old`.
pub(super) fn diff_function(lua: &Lua) -> LuaResult<mlua::Function> {
    lua.create_function(|lua, (old, new): (mlua::LuaString, mlua::LuaString)| {
        let (old, new) = (old.to_str()?, new.to_str()?);
        let list = lua.create_table()?;
        for (range, text) in crate::diff::line_changes(&old, &new) {
            let change = lua.create_table()?;
            change.set("from", range.start)?;
            change.set("to", range.end)?;
            change.set("text", text)?;
            list.push(change)?;
        }
        Ok(list)
    })
}
