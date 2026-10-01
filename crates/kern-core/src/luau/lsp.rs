//! `kern.lsp`: language servers, for plugins. Requests wait for their
//! answer like `kern.sleep` waits for time, so a plugin reads as plain
//! top-to-bottom code:
//!
//! ```luau
//! local result, err = kern.lsp.request(buffer, "textDocument/hover", params)
//! ```

use kern_text::Author;
use mlua::serde::SerializeOptions;
use mlua::{Function, Lua, LuaSerdeExt, Table, UserDataRef, Value};

use super::handles::BufferRef;
use super::{api, state, state_mut, tasks};
use crate::lsp::{self, Event, Handled, ServerConfig};
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
        state.lsp.handle(event, &state.editor)
    };
    match handled {
        Handled::Response { server, id, result } => {
            let Some(token) = state_mut(lua).lsp_waiting.remove(&(server, id)) else {
                return Ok(());
            };
            let (result, error) = match &result {
                Ok(value) => (to_lua(lua, value)?, Value::Nil),
                Err(error) => (Value::Nil, to_lua(lua, error)?),
            };
            tasks::wake(lua, token, (result, error))
        }
        Handled::Diagnostics(buffer) => diagnostics_changed(lua, buffer),
        Handled::Nothing => Ok(()),
    }
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

pub(super) fn module(lua: &Lua) -> LuaResult<Table> {
    let lsp = lua.create_table()?;

    lsp.set(
        "server",
        lua.create_function(|lua, spec: Table| {
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
            let config = ServerConfig {
                language: spec.get("language")?,
                commands,
                root_markers: strings("root_markers")?,
            };
            state_mut(lua).lsp.configure(config);
            Ok(())
        })?,
    )?;

    lsp.set("request", request_function(lua)?)?;

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
            for d in state.lsp.diagnostics(buffer.buffer) {
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
    )?;
    Ok(lsp)
}

fn buffer_ref<'a>(editor: &'a Editor, buffer: &BufferRef) -> LuaResult<&'a Buffer> {
    editor
        .find_buffer(buffer.buffer)
        .ok_or_else(|| mlua::Error::runtime("this buffer was closed"))
}

/// `kern.lsp.request(buffer, method, params)`: sends a request and waits for
/// the answer, returning `result, error`.
fn request_function(lua: &Lua) -> LuaResult<Function> {
    let start = lua.create_function(
        |lua, (buffer, method, params): (UserDataRef<BufferRef>, String, Value)| {
            let params: serde_json::Value = lua.from_value(params)?;
            let state = &mut *state_mut(lua);
            let b = buffer_ref(&state.editor, &buffer)?;
            let request = state
                .lsp
                .request(b, &method, &params)
                .map_err(mlua::Error::external)?;
            let token = state.tasks.token();
            state.lsp_waiting.insert(request, token);
            Ok(token)
        },
    )?;
    lua.load(
        r#"
        local start = ...
        return function(buffer, method, params)
            if not coroutine.isyieldable() then
                error("kern.lsp.request can only be used in a command or event handler", 2)
            end
            return coroutine.yield(start(buffer, method, params))
        end
        "#,
    )
    .set_name("=kern.lsp.request")
    .call(start)
}
