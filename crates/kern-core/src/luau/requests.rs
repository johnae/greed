//! Requests from the session socket, for plugins to answer. Each one is a
//! `control.request` event with an `id`, a `method` and `params`; a handler
//! answers it with `kern.control.reply(id, result)` or
//! `kern.control.reply(id, nil, message)`. It can wait first, so a request
//! can take as long as it needs, e.g. for the user to review an edit.

use mlua::{Lua, LuaSerdeExt, Table, Value};

use super::{api, lsp, state, state_mut};
use crate::control::Request;

type LuaResult<T> = mlua::Result<T>;

/// Passes a request to the plugins handling `control.request`.
pub(super) fn handle(lua: &Lua, request: Request) -> LuaResult<()> {
    if state(lua).registry.handlers("control.request").is_empty() {
        request.respond(Err(
            "no plugin answers requests; is the agent plugin loaded?".to_owned(),
        ));
        return Ok(());
    }
    let payload = lua.create_table()?;
    payload.set("method", request.method.as_str())?;
    payload.set("params", lsp::to_lua(lua, &request.params)?)?;
    let id = {
        let mut state = state_mut(lua);
        state.next_request += 1;
        let id = state.next_request;
        state.requests.insert(id, request);
        id
    };
    payload.set("id", id)?;
    api::emit(lua, "control.request", &payload)
}

pub(super) fn module(lua: &Lua) -> LuaResult<Table> {
    let control = lua.create_table()?;
    control.set(
        "reply",
        lua.create_function(|lua, (id, result, error): (u64, Value, Option<String>)| {
            let Some(request) = state_mut(lua).requests.remove(&id) else {
                return Err(mlua::Error::runtime(format!(
                    "request {id} was already answered"
                )));
            };
            let answer = match error {
                Some(message) => Err(message),
                None => Ok(lua.from_value::<serde_json::Value>(result)?),
            };
            request.respond(answer);
            Ok(())
        })?,
    )?;
    Ok(control)
}
