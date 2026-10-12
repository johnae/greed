//! Asking before a program in the session signs with one of your ssh
//! keys: the server emits `ssh_agent.use` with an `id`, and a handler
//! answers with `greed.ssh_agent.answer(id, allowed)`. The core plugin
//! asks you, as its `ssh-agent-confirm` option says.

use std::collections::HashSet;

use mlua::{Lua, Table};

use super::{api, state, state_mut};

type LuaResult<T> = mlua::Result<T>;

/// The requests plugins were asked about and haven't answered, and the
/// answers the server hasn't taken yet.
#[derive(Default)]
pub(crate) struct Asks {
    pub pending: HashSet<u64>,
    pub answers: Vec<(u64, bool)>,
}

/// Asks plugins, as the acting client, whether request `id` may sign,
/// from a client on `host` if known. False, asking nothing, when no plugin
/// handles `ssh_agent.use`: then nobody may.
pub(super) fn ask(lua: &Lua, id: u64, host: Option<&str>) -> LuaResult<bool> {
    if state(lua).registry.handlers("ssh_agent.use").is_empty() {
        return Ok(false);
    }
    state_mut(lua).ssh_agent.pending.insert(id);
    let payload = lua.create_table()?;
    payload.set("id", id)?;
    payload.set("host", host)?;
    api::emit_for_client(lua, "ssh_agent.use", &payload)?;
    Ok(true)
}

/// `greed.ssh_agent`.
pub(super) fn module(lua: &Lua) -> LuaResult<Table> {
    let agent = lua.create_table()?;
    agent.set(
        "answer",
        lua.create_function(|lua, (id, allowed): (u64, bool)| {
            let asks = &mut state_mut(lua).ssh_agent;
            let waiting = asks.pending.remove(&id);
            if waiting {
                asks.answers.push((id, allowed));
            }
            Ok(waiting)
        })?,
    )?;
    Ok(agent)
}
