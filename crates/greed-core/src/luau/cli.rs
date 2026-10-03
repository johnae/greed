//! Command line commands plugins add with `kern.cli`, run as `kern NAME
//! ARGS` in an editor with no screen. A command runs as a coroutine, so it
//! can wait on programs, the network and timers; what it echoes and
//! returns is printed.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::time::{Duration, Instant};

use mlua::{Function, Lua, Table, Value};

use super::{jobs, state, state_mut, tasks};
use crate::registry::PluginId;

type LuaResult<T> = mlua::Result<T>;

/// A command line command.
pub(crate) struct CliCommand {
    pub owner: PluginId,
    doc: String,
    /// What follows the name, e.g. "HOST [PLUGIN]".
    usage: String,
    run: Function,
}

/// The command line commands, by name.
pub(crate) type Commands = HashMap<String, CliCommand>;

/// `kern.cli(spec)` for `owner`.
pub(super) fn function(lua: &Lua, owner: &PluginId) -> LuaResult<Function> {
    let owner = owner.clone();
    lua.create_function(move |lua, spec: Table| {
        let name: String = spec.get("name")?;
        let command = CliCommand {
            owner: owner.clone(),
            doc: spec.get::<Option<String>>("doc")?.unwrap_or_default(),
            usage: spec.get::<Option<String>>("usage")?.unwrap_or_default(),
            run: spec.get("run")?,
        };
        state_mut(lua).cli.insert(name, command);
        Ok(())
    })
}

/// How a command line command ended: what it returned, if anything.
type Ended = Rc<RefCell<Option<Option<String>>>>;

/// Runs the command line command `name` with `args` to its end, handing
/// each message it echoes to `say` as it comes. Returns what it returned.
pub(super) fn run(
    lua: &Lua,
    name: &str,
    args: Vec<String>,
    say: &mut dyn FnMut(&str),
) -> LuaResult<Option<String>> {
    let (run, owner) = {
        let state = state(lua);
        let command = state
            .cli
            .get(name)
            .ok_or_else(|| mlua::Error::runtime(format!("there is no command called {name:?}")))?;
        (command.run.clone(), command.owner.clone())
    };
    let ended: Ended = Rc::default();
    let keep = {
        let ended = ended.clone();
        lua.create_function(move |_, value: Value| {
            *ended.borrow_mut() = Some(match value {
                Value::Nil => None,
                other => Some(super::api::display(&other)),
            });
            Ok(())
        })?
    };
    let whole: Function = lua
        .load("local run, keep = ...\nreturn function(args) keep((run(args))) end")
        .set_name("=kern.cli")
        .call((run, keep))?;
    super::budgeted(lua, || {
        tasks::spawn(lua, whole, args, owner, Some(name.into()))
    })?;
    let finished = state(lua).jobs.finished().clone();
    loop {
        for message in state_mut(lua).editor.take_messages() {
            say(&message);
        }
        if let Some(returned) = ended.borrow_mut().take() {
            return Ok(returned);
        }
        let next = tasks::next_timer(lua);
        if next.is_none() && state(lua).jobs.running() == 0 {
            return Err(mlua::Error::runtime(format!(
                "{name} waits for something nothing will bring"
            )));
        }
        let wait = next.map_or(Duration::from_secs(3600), |at| {
            at.saturating_duration_since(Instant::now())
        });
        let done = finished.recv_timeout(wait);
        super::budgeted(lua, || match done {
            Ok(done) => jobs::finish(lua, done),
            Err(_) => tasks::fire_timers(lua, Instant::now()),
        })?;
    }
}

/// Each command line command's name, what follows it and what it does, sorted.
pub(super) fn list(lua: &Lua) -> Vec<(String, String, String)> {
    let mut list: Vec<_> = state(lua)
        .cli
        .iter()
        .map(|(name, c)| (name.clone(), c.usage.clone(), c.doc.clone()))
        .collect();
    list.sort();
    list
}
