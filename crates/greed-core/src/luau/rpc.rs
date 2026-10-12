//! `greed.rpc`: JSON-RPC 2.0 with a program over its input and output, on
//! the transport language servers use ([`crate::rpc`]), its messages framed
//! with `Content-Length` headers (language servers, debug adapters) or one
//! a line (agents over ACP). A request waits for its answer; the program's
//! requests and notifications go to handlers, each in a coroutine of its
//! own so one that waits doesn't hold up the rest. A connection belongs to
//! the plugin that made it and goes with it.

use std::collections::HashMap;
use std::path::Path;

use mlua::{Function, IntoLuaMulti, Lua, LuaSerdeExt, MultiValue, Table, Value};

use super::arity::NoArgs;
use super::jobs::{self, Output};
use super::{state, state_mut, tasks};
use crate::registry::PluginId;
use crate::rpc::{Connection, Event, Framing, Transport};

type LuaResult<T> = mlua::Result<T>;

/// A program talked to, and who answers it.
struct Peer {
    owner: PluginId,
    connection: Connection,
    /// The token each request waiting for its answer wakes, by its id.
    waiting: HashMap<i64, u64>,
    /// Answers a request: `(id, method, params)`, in a coroutine.
    on_request: Option<Function>,
    on_notify: Option<Function>,
    on_exit: Option<Function>,
}

/// The connections open, by id.
#[derive(Default)]
pub(crate) struct Peers {
    next: u64,
    open: HashMap<u64, Peer>,
}

impl Peers {
    /// Closes the connections plugin `name` made.
    pub(crate) fn remove_owned_by(&mut self, name: &str) {
        self.open.retain(|_, peer| &*peer.owner != name);
    }
}

/// What a request's handler answers with, as a Luau function: calls
/// `handler(method, params)` and responds with what it returns, or the
/// error it raised or gave as a second value.
const ANSWER: &str = r"
local handler, respond = ...
return function(id, method, params)
	local ok, result, problem = pcall(handler, method, params)
	if not ok then
		respond(id, nil, tostring(result))
	elseif problem ~= nil then
		respond(id, nil, tostring(problem))
	else
		respond(id, result, nil)
	end
end
";

/// The connection `id`, for `f`, or an error saying it's closed.
fn with_peer<R>(lua: &Lua, id: u64, f: impl FnOnce(&mut Peer) -> R) -> LuaResult<R> {
    let mut state = state_mut(lua);
    let peer = state
        .rpcs
        .open
        .get_mut(&id)
        .ok_or_else(|| mlua::Error::runtime("this connection was closed"))?;
    Ok(f(peer))
}

fn start(
    lua: &Lua,
    owner: &PluginId,
    command: &[String],
    opts: Option<&Table>,
) -> LuaResult<MultiValue> {
    let get = |key: &str| -> LuaResult<Value> { opts.map_or(Ok(Value::Nil), |o| o.get(key)) };
    let cwd: Option<String> = opts.map_or(Ok(None), |o| o.get("cwd"))?;
    let env = super::process::env_from_lua(lua, opts.map_or(Ok(None), |o| o.get("env"))?)?;
    let framing = match opts
        .map_or(Ok(None), |o| o.get::<Option<String>>("framing"))?
        .as_deref()
    {
        None | Some("headers") => Framing::Headers,
        Some("lines") => Framing::Lines,
        Some(other) => {
            return Err(mlua::Error::runtime(format!(
                "framing = {other:?}: give \"headers\" or \"lines\""
            )));
        }
    };
    let function = |key: &str| -> LuaResult<Option<Function>> {
        match get(key)? {
            Value::Nil => Ok(None),
            Value::Function(f) => Ok(Some(f)),
            other => Err(mlua::Error::runtime(format!(
                "{key} is a {}; give a function",
                other.type_name()
            ))),
        }
    };
    let on_request = function("on_request")?;
    let on_notify = function("on_notify")?;
    let on_exit = function("on_exit")?;
    let transport = match Transport::start(command, cwd.as_deref().map(Path::new), &env) {
        Ok(transport) => transport.framed(framing),
        Err(err) => {
            let program = command.first().map_or("", String::as_str);
            return (
                Value::Nil,
                crate::child::cant_run(program, &err).to_string(),
            )
                .into_lua_multi(lua);
        }
    };
    let id = {
        let mut state = state_mut(lua);
        state.rpcs.next += 1;
        state.rpcs.next
    };
    // Its events come with the editor's other work, as a program's output
    // does.
    let (events, received) = crossbeam_channel::unbounded();
    let done = jobs::sender(lua);
    std::thread::spawn(move || {
        for event in received {
            if done
                .send(jobs::Done::uncounted(Output::Rpc(id, event)))
                .is_err()
            {
                return;
            }
        }
    });
    let connection = Connection::open(
        usize::try_from(id).unwrap_or(usize::MAX),
        transport,
        &events,
    );
    let answer = match on_request {
        Some(handler) => Some(
            lua.load(ANSWER)
                .set_name("=greed.rpc.answer")
                .call::<Function>((handler, respond_function(lua, id)?))?,
        ),
        None => None,
    };
    state_mut(lua).rpcs.open.insert(
        id,
        Peer {
            owner: owner.clone(),
            connection,
            waiting: HashMap::new(),
            on_request: answer,
            on_notify,
            on_exit,
        },
    );
    handle_to_lua(lua, id)?.into_lua_multi(lua)
}

/// Whether a test may be waiting on a program it talks to: one still
/// running.
pub(super) fn awaited(lua: &Lua) -> bool {
    state(lua)
        .rpcs
        .open
        .values()
        .any(|peer| peer.connection.is_alive())
}

/// Responds to request `id` of connection `conn`: with `result`, or with an
/// error saying `problem`.
fn respond_function(lua: &Lua, conn: u64) -> LuaResult<Function> {
    lua.create_function(
        move |lua, (id, result, problem): (Value, Value, Option<String>)| {
            let id: serde_json::Value = lua.from_value(id)?;
            let result: serde_json::Value = lua.from_value(result)?;
            let error =
                problem.map(|message| serde_json::json!({ "code": -32603, "message": message }));
            let outcome = match &error {
                Some(error) => Err(error),
                None => Ok(&result),
            };
            // Gone meanwhile: nobody to answer.
            let _ = with_peer(lua, conn, |peer| peer.connection.respond(&id, outcome));
            Ok(())
        },
    )
}

/// The table a plugin talks to connection `id` through.
fn handle_to_lua(lua: &Lua, id: u64) -> LuaResult<Table> {
    let conn = lua.create_table()?;
    let request = lua.create_function(move |lua, (method, params): (String, Value)| {
        let params: serde_json::Value = lua.from_value(params)?;
        // Not counted as a job: a request can be answered whenever the
        // program likes, as an agent's prompt is once it has done its turn.
        let token = state_mut(lua).tasks.token();
        let sent = with_peer(lua, id, |peer| {
            if !peer.connection.is_alive() {
                return Err("it isn't running".to_owned());
            }
            let request = peer
                .connection
                .request(&method, &params)
                .map_err(|err| err.to_string())?;
            peer.waiting.insert(request, token);
            Ok(())
        })
        .unwrap_or_else(|_| Err("this connection was closed".to_owned()));
        if let Err(why) = sent {
            tasks::deliver(lua, token, (Value::Nil, why))?;
        }
        Ok(token)
    })?;
    conn.set(
        "request",
        jobs::waiting_method(lua, "conn.request", request)?,
    )?;
    conn.set(
        "notify",
        lua.create_function(move |lua, (method, params): (String, Value)| {
            let params: serde_json::Value = lua.from_value(params)?;
            // Closed meanwhile: there's nobody left to tell.
            Ok(with_peer(lua, id, |peer| {
                peer.connection.notify(&method, &params).is_ok()
            })
            .unwrap_or(false))
        })?,
    )?;
    conn.set(
        "alive",
        lua.create_function(move |lua, NoArgs| {
            Ok(state(lua)
                .rpcs
                .open
                .get(&id)
                .is_some_and(|peer| peer.connection.is_alive()))
        })?,
    )?;
    conn.set(
        "stderr",
        lua.create_function(move |lua, NoArgs| {
            Ok(state(lua)
                .rpcs
                .open
                .get(&id)
                .map(|peer| peer.connection.stderr().join("\n"))
                .unwrap_or_default())
        })?,
    )?;
    conn.set(
        "close",
        lua.create_function(move |lua, NoArgs| {
            let peer = state_mut(lua).rpcs.open.remove(&id);
            if let Some(peer) = peer {
                fail_waiting(lua, peer.waiting, "it was closed")?;
            }
            Ok(())
        })?,
    )?;
    super::handles::methods(lua, conn)
}

/// Wakes each request in `waiting` with nil and `why`.
fn fail_waiting(lua: &Lua, waiting: HashMap<i64, u64>, why: &str) -> LuaResult<()> {
    for token in waiting.into_values() {
        tasks::deliver(lua, token, (Value::Nil, why.to_owned()))?;
    }
    Ok(())
}

/// An event from connection `id`: wakes the request it answers, or hands a
/// request or notification to its handler.
pub(super) fn event_arrived(lua: &Lua, id: u64, event: Event) -> LuaResult<()> {
    let Ok((Some(event), owner)) = with_peer(lua, id, |peer| {
        (peer.connection.receive(event), peer.owner.clone())
    }) else {
        return Ok(());
    };
    match event {
        Event::Response {
            id: request,
            result,
            ..
        } => {
            let token = with_peer(lua, id, |peer| peer.waiting.remove(&request))?;
            if let Some(token) = token {
                let values = match result {
                    Ok(value) => super::lsp::to_lua(lua, &value)?.into_lua_multi(lua)?,
                    Err(error) => {
                        let message = error["message"].as_str().unwrap_or("error").to_owned();
                        (Value::Nil, message).into_lua_multi(lua)?
                    }
                };
                tasks::deliver(lua, token, values)?;
            }
        }
        Event::Request {
            id: request,
            method,
            params,
            ..
        } => {
            let answer = with_peer(lua, id, |peer| peer.on_request.clone())?;
            if let Some(answer) = answer {
                let request = lua.to_value(&request)?;
                let params = super::lsp::to_lua(lua, &params)?;
                tasks::spawn(lua, answer, (request, method, params), owner, None)?;
            } else {
                let message = format!("{method} isn't supported");
                let error = serde_json::json!({ "code": -32601, "message": message });
                let _ = with_peer(lua, id, |peer| {
                    peer.connection.respond(&request, Err(&error))
                });
            }
        }
        Event::Notification { method, params, .. } => {
            let handler = with_peer(lua, id, |peer| peer.on_notify.clone())?;
            if let Some(handler) = handler {
                let params = super::lsp::to_lua(lua, &params)?;
                tasks::spawn(lua, handler, (method, params), owner, None)?;
            }
        }
        Event::Exited { .. } => {
            let (waiting, on_exit, stderr) = with_peer(lua, id, |peer| {
                (
                    std::mem::take(&mut peer.waiting),
                    peer.on_exit.clone(),
                    peer.connection.stderr().join("\n"),
                )
            })?;
            // Told first: what waits on a request may go on to wait for it.
            if let Some(on_exit) = on_exit {
                tasks::spawn(lua, on_exit, stderr, owner, None)?;
            }
            fail_waiting(lua, waiting, "it exited")?;
        }
    }
    Ok(())
}

/// `greed.rpc` for `owner`.
pub(super) fn module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let rpc = lua.create_table()?;
    let owner = owner.clone();
    rpc.set(
        "start",
        lua.create_function(move |lua, (command, opts): (Vec<String>, Option<Table>)| {
            start(lua, &owner, &command, opts.as_ref())
        })?,
    )?;
    Ok(rpc)
}
