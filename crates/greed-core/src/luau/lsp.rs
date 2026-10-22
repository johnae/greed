//! `greed.lsp`: language servers, for plugins. Requests wait for their
//! answer like `greed.sleep` waits for time, so a plugin reads as plain
//! top-to-bottom code:
//!
//! ```luau
//! local result, err = greed.lsp.request(buffer, "textDocument/hover", params)
//! ```

use std::path::PathBuf;

use greed_text::Author;
use mlua::serde::SerializeOptions;
use mlua::{Function, Lua, LuaSerdeExt, Table, UserDataRef, Value};

use super::arity::NoArgs;
use super::handles::BufferRef;
use super::{api, capabilities, state, state_mut, tasks};
use crate::lsp::{self, Event, Handled, ServerConfig};
use crate::registry::PluginId;
use crate::{Buffer, BufferId, Editor};

type LuaResult<T> = mlua::Result<T>;

/// JSON from a server as Luau values: `null` becomes `nil`.
pub(super) fn to_lua(lua: &Lua, json: &serde_json::Value) -> LuaResult<Value> {
    lua.to_value_with(
        json,
        SerializeOptions::new()
            .serialize_none_to_null(false)
            .serialize_unit_to_null(false),
    )
}

/// Handles one event from a language server: wakes the command waiting on a
/// response, or announces new diagnostics.
pub(super) fn handle(lua: &Lua, event: Event) -> LuaResult<()> {
    let handled = {
        let state = &mut *state_mut(lua);
        state.lsp.handle(event, &mut state.editor)
    };
    match handled {
        Handled::Response { server, id, result } => {
            let Some(token) = state_mut(lua).lsp_calls.waiting.remove(&(server, id)) else {
                return Ok(());
            };
            let (result, error) = match &result {
                Ok(value) => (to_lua(lua, value)?, Value::Nil),
                Err(error) => (Value::Nil, to_lua(lua, error)?),
            };
            tasks::deliver(lua, token, (result, error))
        }
        Handled::Diagnostics(buffer) => diagnostics_changed(lua, buffer),
        Handled::Request {
            server,
            id,
            method,
            params,
        } => answer(lua, server, &id, &method, &params),
        Handled::Notification {
            language,
            root,
            method,
            params,
        } => tell(lua, &language, &root.to_string_lossy(), &method, &params),
        Handled::Exited { server } => stopped(lua, server),
        Handled::Nothing => Ok(()),
    }
}

/// Wakes what waited on answers from `server`, which stopped, with an
/// error, since none will come. A server started after it has its own id,
/// so its answers can't wake these.
fn stopped(lua: &Lua, server: lsp::ServerId) -> LuaResult<()> {
    let tokens: Vec<u64> = state_mut(lua)
        .lsp_calls
        .waiting
        .extract_if(|(s, _), _| *s == server)
        .map(|(_, token)| token)
        .collect();
    for token in tokens {
        let error = lua.create_table()?;
        error.set("code", STOPPED)?;
        error.set("message", "the language server stopped")?;
        tasks::deliver(lua, token, (Value::Nil, error))?;
    }
    Ok(())
}

/// The error code a request gets when its server stops before answering:
/// JSON-RPC's internal error.
const STOPPED: i64 = -32603;

/// Answers a request from a server with the handler a plugin set for it,
/// or with null when there's none. The handler runs as a coroutine, so it
/// can wait, e.g. to ask you; the server gets the answer when it returns.
fn answer(
    lua: &Lua,
    server: lsp::ServerId,
    id: &serde_json::Value,
    method: &str,
    params: &serde_json::Value,
) -> LuaResult<()> {
    let handler = state(lua)
        .lsp_calls
        .handlers
        .get(method)
        .map(|(owner, handler)| (owner.clone(), handler.clone()));
    let Some((owner, handler)) = handler else {
        state_mut(lua)
            .lsp
            .respond(server, id, &serde_json::Value::Null);
        return Ok(());
    };
    let (id, method) = (id.clone(), method.to_owned());
    let reply = lua.create_function(move |lua, (ok, value): (bool, Value)| {
        let result = if ok {
            lua.from_value(value)?
        } else {
            state_mut(lua)
                .editor
                .echo(format!("{method}: {}", api::display(&value)));
            serde_json::Value::Null
        };
        state_mut(lua).lsp.respond(server, &id, &result);
        Ok(())
    })?;
    let run: Function = lua
        .load(
            "local handler, reply = ...\nreturn function(params) reply(pcall(handler, params)) end",
        )
        .set_name("=lsp.on_request")
        .call((handler, reply))?;
    tasks::spawn(lua, run, to_lua(lua, params)?, owner, None)
}

/// Passes a notification from `language`'s server in `root` to the
/// handlers plugins set for its method, each run the way a command is.
fn tell(
    lua: &Lua,
    language: &str,
    root: &str,
    method: &str,
    params: &serde_json::Value,
) -> LuaResult<()> {
    let listeners: Vec<(PluginId, Function)> = state(lua)
        .lsp_calls
        .listeners
        .iter()
        .filter(|(m, _, _)| m == method)
        .map(|(_, owner, handler)| (owner.clone(), handler.clone()))
        .collect();
    for (owner, handler) in listeners {
        let run: Function = lua
            .load("local handler, language, root = ...\nreturn function(params) handler(params, language, root) end")
            .set_name("=lsp.on_notification")
            .call((handler, language, root))?;
        tasks::spawn(lua, run, to_lua(lua, params)?, owner, None)?;
    }
    Ok(())
}

fn diagnostics_changed(lua: &Lua, buffer: BufferId) -> LuaResult<()> {
    let payload = lua.create_table()?;
    payload.set(
        "buffer",
        BufferRef {
            buffer,
            view: None,
            author: Author::User(state(lua).editor.client()),
        },
    )?;
    api::emit(lua, "lsp.diagnostics", &payload)
}

pub(super) fn module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let lsp = lua.create_table()?;
    add_server_side(lua, &lsp, owner)?;
    add_servers(lua, &lsp, owner)?;
    add_documents(lua, &lsp, owner)?;
    Ok(lsp)
}

/// What servers ask, tell, can do and found: `on_request`,
/// `on_notification`, `capabilities` and `problems`.
fn add_server_side(lua: &Lua, lsp: &Table, owner: &PluginId) -> LuaResult<()> {
    let o = owner.clone();
    lsp.set(
        "on_request",
        lua.create_function(move |lua, (method, handler): (String, Function)| {
            state_mut(lua)
                .lsp_calls
                .handlers
                .insert(method, (o.clone(), handler));
            Ok(())
        })?,
    )?;

    let o = owner.clone();
    lsp.set(
        "on_notification",
        lua.create_function(move |lua, (method, handler): (String, Function)| {
            state_mut(lua)
                .lsp_calls
                .listeners
                .push((method, o.clone(), handler));
            Ok(())
        })?,
    )?;

    lsp.set(
        "capabilities",
        lua.create_function(|lua, buffer: UserDataRef<BufferRef>| {
            let state = state(lua);
            let b = buffer_ref(&state.editor, &buffer)?;
            match state.lsp.capabilities(b) {
                Ok(capabilities) => to_lua(lua, capabilities),
                Err(_) => Ok(Value::Nil),
            }
        })?,
    )?;

    lsp.set(
        "problems",
        lua.create_function(|lua, NoArgs| {
            let list = lua.create_table()?;
            let state = state(lua);
            for p in state.lsp.problems(&state.editor) {
                let entry = lua.create_table()?;
                entry.set("uri", p.uri.as_str())?;
                entry.set("range", to_lua(lua, &p.range)?)?;
                entry.set("severity", p.severity)?;
                entry.set("message", p.message.as_str())?;
                entry.set("source", p.source.as_deref())?;
                list.push(entry)?;
            }
            Ok(list)
        })?,
    )
}

/// Setting servers up, each as `owner`'s.
fn add_servers(lua: &Lua, lsp: &Table, owner: &PluginId) -> LuaResult<()> {
    let owner = owner.clone();
    lsp.set(
        "server",
        lua.create_function(move |lua, spec: Table| {
            let strings = |key: &str| -> LuaResult<Vec<String>> {
                Ok(spec.get::<Option<Vec<String>>>(key)?.unwrap_or_default())
            };
            let json = |key: &str| -> LuaResult<Option<serde_json::Value>> {
                spec.get::<Option<Value>>(key)?
                    .map(|value| lua.from_value(value))
                    .transpose()
            };
            // One `command`, or `commands` to try in order.
            let mut commands = spec
                .get::<Option<Vec<Vec<String>>>>("commands")?
                .unwrap_or_default();
            commands.insert(0, strings("command")?);
            commands.retain(|c| !c.is_empty());
            if commands.is_empty() {
                return Err(mlua::Error::runtime("a language server needs a command"));
            }
            let config = ServerConfig {
                language: spec.get("language")?,
                commands,
                root_markers: strings("root_markers")?,
                reads_only: spec.get::<Option<bool>>("reads_only")?.unwrap_or(false),
                settings: json("settings")?,
                init_options: json("init_options")?,
            };
            let state = &mut *state_mut(lua);
            state.owned.server(owner.clone(), config.clone());
            state.lsp.configure(config);
            Ok(())
        })?,
    )?;

    lsp.set(
        "remove",
        lua.create_function(|lua, language: String| {
            let state = &mut *state_mut(lua);
            state.lsp.remove(&language);
            state.owned.remove_server(&language);
            Ok(())
        })?,
    )?;
    lsp.set(
        "restart",
        lua.create_function(|lua, language: Option<String>| {
            Ok(state_mut(lua).lsp.restart(language.as_deref()))
        })?,
    )?;
    lsp.set(
        "trust",
        lua.create_function(|lua, folders: Option<Vec<String>>| {
            let folders = folders.map(|list| list.into_iter().map(PathBuf::from).collect());
            state_mut(lua).lsp.trust(folders);
            Ok(())
        })?,
    )?;
    lsp.set(
        "waits",
        lua.create_function(|lua, buffer: UserDataRef<BufferRef>| {
            let state = state(lua);
            let b = buffer_ref(&state.editor, &buffer)?;
            Ok(state.lsp.waits(b, &state.editor))
        })?,
    )
}

/// The documents servers are about: requests, positions and diagnostics.
fn add_documents(lua: &Lua, lsp: &Table, owner: &PluginId) -> LuaResult<()> {
    lsp.set(
        "servers",
        lua.create_function(|lua, NoArgs| {
            let servers = lua.create_table()?;
            for config in state(lua).lsp.configs() {
                servers.set(config.language.as_str(), config.commands.clone())?;
            }
            Ok(servers)
        })?,
    )?;

    lsp.set(
        "running",
        lua.create_function(|lua, NoArgs| {
            let list = lua.create_table()?;
            for server in state(lua).lsp.running() {
                let entry = lua.create_table()?;
                entry.set("language", server.language)?;
                entry.set("root", server.root.to_string_lossy())?;
                entry.set("command", server.command)?;
                entry.set("ready", server.ready)?;
                entry.set("stderr", server.stderr)?;
                list.push(entry)?;
            }
            Ok(list)
        })?,
    )?;

    lsp.set(
        "root",
        lua.create_function(|lua, buffer: UserDataRef<BufferRef>| {
            let state = state(lua);
            let b = buffer_ref(&state.editor, &buffer)?;
            Ok(state
                .lsp
                .root(b, &state.editor)
                .map(|root| root.to_string_lossy().into_owned()))
        })?,
    )?;

    lsp.set("request", request_function(lua, owner)?)?;

    lsp.set(
        "uri",
        lua.create_function(|lua, buffer: UserDataRef<BufferRef>| {
            let state = state(lua);
            let path = buffer_ref(&state.editor, &buffer)?
                .path()
                .ok_or_else(|| mlua::Error::runtime("this buffer has no file"))?;
            Ok(lsp::file_uri(path))
        })?,
    )?;

    lsp.set(
        "path",
        lua.create_function(|_, uri: String| {
            Ok(lsp::uri_path(&uri).map(|p| p.to_string_lossy().into_owned()))
        })?,
    )?;

    lsp.set(
        "position",
        lua.create_function(|lua, (buffer, pos): (UserDataRef<BufferRef>, usize)| {
            let json = {
                let state = state(lua);
                let b = buffer_ref(&state.editor, &buffer)?;
                let encoding = state.lsp.encoding(b).map_err(mlua::Error::external)?;
                lsp::position(b.text(), pos, encoding)
            };
            to_lua(lua, &json)
        })?,
    )?;

    lsp.set(
        "offset",
        lua.create_function(|lua, (buffer, position): (UserDataRef<BufferRef>, Value)| {
            let position: serde_json::Value = lua.from_value(position)?;
            let state = state(lua);
            let b = buffer_ref(&state.editor, &buffer)?;
            let encoding = state.lsp.encoding(b).map_err(mlua::Error::external)?;
            lsp::offset(b.text(), &position, encoding)
                .ok_or_else(|| mlua::Error::runtime("a position is { line = n, character = n }"))
        })?,
    )?;

    lsp.set(
        "diagnostics",
        lua.create_function(|lua, buffer: UserDataRef<BufferRef>| {
            let list = lua.create_table()?;
            let state = state(lua);
            let Some(b) = state.editor.find_buffer(buffer.buffer) else {
                return Ok(list);
            };
            for d in lsp::diagnostics(b) {
                let entry = lua.create_table()?;
                entry.set("from", d.from)?;
                entry.set("to", d.to)?;
                entry.set("severity", d.severity)?;
                entry.set("message", d.message.as_str())?;
                entry.set("source", d.source.as_deref())?;
                list.push(entry)?;
            }
            Ok(list)
        })?,
    )
}

fn buffer_ref<'a>(editor: &'a Editor, buffer: &BufferRef) -> LuaResult<&'a Buffer> {
    editor
        .find_buffer(buffer.buffer)
        .ok_or_else(|| mlua::Error::runtime("this buffer was closed"))
}

/// `greed.lsp.request(buffer, method, params)`: sends a request and waits for
/// the answer, returning `result, error`. `workspace/executeCommand` takes
/// `proc`, since a server's commands run whatever it wants to.
fn request_function(lua: &Lua, owner: &PluginId) -> LuaResult<Function> {
    let owner = owner.clone();
    let start = lua.create_function(
        move |lua, (buffer, method, params): (UserDataRef<BufferRef>, String, Value)| {
            if method == "workspace/executeCommand" {
                capabilities::check_for(lua, &owner, "proc")?;
            }
            let params: serde_json::Value = lua.from_value(params)?;
            let state = &mut *state_mut(lua);
            let b = buffer_ref(&state.editor, &buffer)?;
            let request = state
                .lsp
                .request(b, &method, &params)
                .map_err(mlua::Error::external)?;
            let token = state.tasks.token();
            state.lsp_calls.waiting.insert(request, token);
            Ok(token)
        },
    )?;
    lua.load(
        r#"
        local start = ...
        return function(buffer, method, params)
            if not coroutine.isyieldable() then
                error("greed.lsp.request can only be used in a command or event handler", 2)
            end
            return coroutine.yield(start(buffer, method, params))
        end
        "#,
    )
    .set_name("=greed.lsp.request")
    .call(start)
}
