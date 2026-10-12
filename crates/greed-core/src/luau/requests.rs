//! Requests from the session socket, for plugins to answer. Each one is a
//! `control.request` event with an `id`, a `method` and `params`; a handler
//! answers it with `greed.control.reply(id, result)` or
//! `greed.control.reply(id, nil, message)`. It can wait first, so a request
//! can take as long as it needs, e.g. for the user to review an edit.

use std::path::PathBuf;

use mlua::{Lua, LuaSerdeExt, Table, Value};

use super::{api, lsp, state, state_mut};

use crate::control::Request;
use crate::ide;
use crate::registry::PluginId;

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
    payload.set("client", request.client)?;
    payload.set("method", request.method.as_str())?;
    payload.set("params", lsp::to_lua(lua, &request.params)?)?;
    if let Some(connection) = &request.connection {
        payload.set("connection", connection.id)?;
    }
    let id = {
        let mut state = state_mut(lua);
        if let Some(connection) = &request.connection
            && !state.control.connections.contains_key(&connection.id)
        {
            state.control.connections.retain(|_, known| known.is_open());
            state
                .control
                .connections
                .insert(connection.id, connection.clone());
        }
        state.control.next += 1;
        let id = state.control.next;
        state.control.pending.insert(id, request);
        id
    };
    payload.set("id", id)?;
    api::emit(lua, "control.request", &payload)
}

/// `greed.control` for `owner`.
pub(super) fn module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let control = lua.create_table()?;
    control.set(
        "reply",
        lua.create_function(|lua, (id, result, error): (u64, Value, Option<String>)| {
            let Some(request) = state_mut(lua).control.pending.remove(&id) else {
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
    let o = owner.clone();
    control.set(
        "serve_ide",
        lua.create_function(move |lua, (folders, dir): (Vec<String>, Option<String>)| {
            let sender = state(lua).control.sender.clone().ok_or_else(|| {
                mlua::Error::runtime("Claude Code can only connect to an editor with a session")
            })?;
            let dir = dir
                .map(PathBuf::from)
                .or_else(ide::lock_dir)
                .ok_or_else(|| {
                    mlua::Error::runtime("can't tell where Claude Code looks for editors")
                })?;
            // A new connection replaces the old one, and its lock file.
            state_mut(lua).ide = None;
            let ide = ide::listen(&dir, &folders, sender).map_err(mlua::Error::external)?;
            let port = ide.port;
            state_mut(lua).ide = Some((o.clone(), ide));
            Ok(port)
        })?,
    )?;
    control.set(
        "send",
        lua.create_function(
            |lua, (connection, method, params): (Option<u64>, String, Value)| {
                let params: serde_json::Value = lua.from_value(params)?;
                let sent = connection
                    .and_then(|id| state(lua).control.connections.get(&id).cloned())
                    .is_some_and(|notifier| notifier.notify(&method, &params));
                if !sent && let Some(id) = connection {
                    state_mut(lua).control.connections.remove(&id);
                }
                Ok(sent)
            },
        )?,
    )?;
    control.set(
        "ide_folders",
        lua.create_function(|lua, folders: Vec<String>| match &state(lua).ide {
            Some((_, ide)) => ide.set_folders(&folders).map_err(mlua::Error::external),
            None => Err(mlua::Error::runtime("Greed isn't serving Claude Code")),
        })?,
    )?;
    control.set(
        "notify",
        lua.create_function(|lua, (method, params): (String, Value)| {
            let params: serde_json::Value = lua.from_value(params)?;
            if let Some((_, ide)) = &state(lua).ide {
                ide.notify(&method, &params);
            }
            Ok(())
        })?,
    )?;
    Ok(control)
}
