//! Arguments an API function doesn't take. mlua drops extra arguments, so
//! `greed.mode.get(61)` would quietly be `greed.mode.get()`; a function that
//! takes none takes [`NoArgs`] instead, and given any it errors with its
//! name.

use mlua::{FromLuaMulti, Function, Lua, MultiValue, Table, Value};

type LuaResult<T> = mlua::Result<T>;

/// What a function that takes no arguments takes: given any but nils, which
/// wrappers passing on what they got can add, it errors.
pub(super) struct NoArgs;

impl FromLuaMulti for NoArgs {
    fn from_lua_multi(values: MultiValue, lua: &Lua) -> LuaResult<Self> {
        let given = values.iter().filter(|value| !value.is_nil()).count();
        if given == 0 {
            return Ok(NoArgs);
        }
        let name = running_name(lua).unwrap_or_else(|| "this function".to_owned());
        Err(mlua::Error::runtime(format!(
            "{name} takes no arguments, but was given {given}"
        )))
    }
}

/// How many frames up from the function running to look for the code
/// calling it, past `pcall` and the like.
const CALLERS: usize = 4;

/// The name of the API function running now, as `greed.mode.get`, found in
/// the `@greed` of the code calling it; `None` for a method, whose name
/// Luau doesn't give. Only an error looks, so calls cost nothing.
fn running_name(lua: &Lua) -> Option<String> {
    // Closures: the method itself is tied to one lifetime of `Debug`.
    #[allow(clippy::redundant_closure_for_method_calls)]
    let running = lua.inspect_stack(0, |debug| debug.function())?;
    (1..=CALLERS).find_map(|level| {
        #[allow(clippy::redundant_closure_for_method_calls)]
        let caller = lua.inspect_stack(level, |debug| debug.function())?;
        let Value::Function(require) = caller.environment()?.raw_get("require").ok()? else {
            return None;
        };
        let greed = require.call::<Table>("@greed").ok()?;
        path_of(&greed, &running, "greed", 2)
    })
}

/// Where `f` is in `table`, looking `depth` modules deep.
fn path_of(table: &Table, f: &Function, path: &str, depth: usize) -> Option<String> {
    table.pairs::<Value, Value>().find_map(|pair| {
        let (Value::String(key), value) = pair.ok()? else {
            return None;
        };
        let path = format!("{path}.{}", key.to_str().ok()?);
        match value {
            Value::Function(found) if found == *f => Some(path),
            Value::Table(module) if depth > 0 => path_of(&module, f, &path, depth - 1),
            _ => None,
        }
    })
}
