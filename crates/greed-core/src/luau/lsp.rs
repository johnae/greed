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
            server,
            language,
            name,
            root,
            method,
            params,
        } => {
            let from = From {
                server,
                language: &language,
                name: &name,
                root: &root.to_string_lossy(),
            };
            tell(lua, &from, &method, &params)
        }
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

/// The server a notification came from.
struct From<'a> {
    server: lsp::ServerId,
    language: &'a str,
    name: &'a str,
    root: &'a str,
}

/// Passes a notification from a server to the handlers plugins set for its
/// method, each run the way a command is, with the server's language, root,
/// id and name.
fn tell(lua: &Lua, from: &From, method: &str, params: &serde_json::Value) -> LuaResult<()> {
    let listeners: Vec<(PluginId, Function)> = state(lua)
        .lsp_calls
        .listeners
        .iter()
        .filter(|(m, _, _)| m == method)
        .map(|(_, owner, handler)| (owner.clone(), handler.clone()))
        .collect();
    for (owner, handler) in listeners {
        let run: Function = lua
            .load(
                "local handler, language, root, server, name = ...\n\
                 return function(params) handler(params, language, root, server, name) end",
            )
            .set_name("=lsp.on_notification")
            .call((handler, from.language, from.root, from.server, from.name))?;
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
    add_listings(lua, &lsp)?;
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
        lua.create_function(
            |lua, (buffer, server): (UserDataRef<BufferRef>, Option<lsp::ServerId>)| {
                let state = state(lua);
                let b = buffer_ref(&state.editor, &buffer)?;
                let capabilities = server_for(&state.lsp, b, server)
                    .ok()
                    .and_then(|server| state.lsp.capabilities_of(server));
                match capabilities {
                    Some(capabilities) => to_lua(lua, capabilities),
                    None => Ok(Value::Nil),
                }
            },
        )?,
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
            // One `command`, or `commands` to try in order.
            let mut commands = spec
                .get::<Option<Vec<Vec<String>>>>("commands")?
                .unwrap_or_default();
            commands.insert(0, strings("command")?);
            commands.retain(|c| !c.is_empty());
            if commands.is_empty() {
                return Err(mlua::Error::runtime("a language server needs a command"));
            }
            let json = |key: &str| -> LuaResult<serde_json::Value> {
                lua.from_value(spec.get::<Value>(key)?)
            };
            let config = ServerConfig {
                language: spec.get("language")?,
                name: spec.get::<Option<String>>("name")?.unwrap_or_default(),
                when: strings("when")?,
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
        lua.create_function(|lua, (language, name): (String, Option<String>)| {
            let state = &mut *state_mut(lua);
            state.lsp.remove(&language, name.as_deref());
            state.owned.remove_server(&language, name.as_deref());
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

/// Which servers there are: set up, running, and a buffer's.
fn add_listings(lua: &Lua, lsp: &Table) -> LuaResult<()> {
    lsp.set(
        "servers",
        lua.create_function(|lua, NoArgs| {
            let servers = lua.create_table()?;
            for config in state(lua).lsp.configs() {
                if config.name.is_empty() {
                    servers.set(config.language.as_str(), config.commands.clone())?;
                }
            }
            Ok(servers)
        })?,
    )?;

    lsp.set(
        "servers_of",
        lua.create_function(|lua, buffer: UserDataRef<BufferRef>| {
            let list = lua.create_table()?;
            let state = state(lua);
            let b = buffer_ref(&state.editor, &buffer)?;
            for server in state.lsp.servers_of(b) {
                let entry = lua.create_table()?;
                entry.set("id", server)?;
                entry.set("name", state.lsp.name_of(server))?;
                if let Some(capabilities) = state.lsp.capabilities_of(server) {
                    entry.set("capabilities", to_lua(lua, capabilities)?)?;
                }
                list.push(entry)?;
            }
            Ok(list)
        })?,
    )?;

    lsp.set(
        "running",
        lua.create_function(|lua, NoArgs| {
            let list = lua.create_table()?;
            for server in state(lua).lsp.running() {
                let entry = lua.create_table()?;
                entry.set("id", server.id)?;
                entry.set("language", server.language)?;
                entry.set("name", server.name)?;
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
    )
}

/// The documents servers are about: requests, positions and diagnostics.
fn add_documents(lua: &Lua, lsp: &Table, owner: &PluginId) -> LuaResult<()> {
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
        lua.create_function(
            |lua, (buffer, pos, server): (UserDataRef<BufferRef>, usize, Option<lsp::ServerId>)| {
                let json = {
                    let state = state(lua);
                    let b = buffer_ref(&state.editor, &buffer)?;
                    let encoding = encoding_for(&state.lsp, b, server)?;
                    lsp::position(b.text(), pos, encoding)
                };
                to_lua(lua, &json)
            },
        )?,
    )?;

    lsp.set(
        "offset",
        lua.create_function(
            |lua, (buffer, position, server): (UserDataRef<BufferRef>, Value, Option<lsp::ServerId>)| {
                let position: serde_json::Value = lua.from_value(position)?;
                let state = state(lua);
                let b = buffer_ref(&state.editor, &buffer)?;
                let encoding = encoding_for(&state.lsp, b, server)?;
                lsp::offset(b.text(), &position, encoding).ok_or_else(|| {
                    mlua::Error::runtime("a position is { line = n, character = n }")
                })
            },
        )?,
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
                entry.set("server", d.server)?;
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

/// `server`, which must be one of `buffer`'s running servers, or without one
/// the first of them.
fn server_for(
    lsp: &lsp::Lsp,
    buffer: &Buffer,
    server: Option<lsp::ServerId>,
) -> LuaResult<lsp::ServerId> {
    let servers = lsp.servers_of(buffer);
    match server {
        Some(server) if servers.contains(&server) => Ok(server),
        Some(server) => Err(mlua::Error::runtime(format!(
            "server {server} isn't one of this buffer's"
        ))),
        None => servers.first().copied().ok_or_else(|| {
            mlua::Error::runtime(format!("no language server for buffer {}", buffer.id().0))
        }),
    }
}

/// How `server` (the first of `buffer`'s without one) counts positions.
fn encoding_for(
    lsp: &lsp::Lsp,
    buffer: &Buffer,
    server: Option<lsp::ServerId>,
) -> LuaResult<lsp::Encoding> {
    let server = server_for(lsp, buffer, server)?;
    lsp.encoding_of(server)
        .ok_or_else(|| mlua::Error::runtime("the language server stopped"))
}

/// `greed.lsp.request(buffer, method, params, server)`: sends a request to
/// `server`, one of the buffer's, or its first, and waits for the answer,
/// returning `result, error`. `workspace/executeCommand` takes `proc`, since
/// a server's commands run whatever it wants to.
fn request_function(lua: &Lua, owner: &PluginId) -> LuaResult<Function> {
    let owner = owner.clone();
    let start = lua.create_function(
        move |lua,
              (buffer, method, params, server): (
            UserDataRef<BufferRef>,
            String,
            Value,
            Option<lsp::ServerId>,
        )| {
            if method == "workspace/executeCommand" {
                capabilities::check_for(lua, &owner, "proc")?;
            }
            let params: serde_json::Value = lua.from_value(params)?;
            let state = &mut *state_mut(lua);
            let b = buffer_ref(&state.editor, &buffer)?;
            let server = server_for(&state.lsp, b, server)?;
            let request = state
                .lsp
                .request_to(server, b, &method, &params)
                .map_err(mlua::Error::external)?;
            let token = state.tasks.token();
            state.lsp_calls.waiting.insert(request, token);
            Ok(token)
        },
    )?;
    lua.load(
        r#"
        local start = ...
        return function(buffer, method, params, server)
            if not coroutine.isyieldable() then
                error("greed.lsp.request can only be used in a command or event handler", 2)
            end
            return coroutine.yield(start(buffer, method, params, server))
        end
        "#,
    )
    .set_name("=greed.lsp.request")
    .call(start)
}
