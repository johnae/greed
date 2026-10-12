//! The `greed` module plugins get from `require("@greed")`, and running
//! commands and emitting events.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use greed_text::{Author, ClientId};
use mlua::{Function, Lua, Table, UserDataRef, Value, Variadic};
use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32Str};

use super::capabilities::{self, Limit};
use super::fs::UserPath;
use super::handles::{self, BufferRef, ViewRef};
use super::tasks;
use super::{HostError, state, state_mut};
use crate::keymap::{Bound, Found, Key, KeyCode, Layer, Mods, Next, Resolution};
use crate::registry::{Arg, Command, OptionDef, PluginId, Source, Value as OptionValue};
use crate::render::{Menu, MenuItem, Span, StatusLine, Tag};
use crate::{
    Anchor, ClientLayout, CursorShape, Extent, FloatOptions, KeyOutcome, LineNumbers, Notice,
    PanelOptions, Side, VirtualLine,
};

type LuaResult<T> = mlua::Result<T>;

/// Runs a command as the user; `name!` forces it, as on the command line.
pub(super) fn run_command(lua: &Lua, name: &str) -> Result<(), HostError> {
    let (name, force) = name
        .strip_suffix('!')
        .map_or((name, false), |name| (name, true));
    invoke(
        lua,
        name,
        Invocation {
            force,
            ..Invocation::default()
        },
    )
}

/// Runs a command with arguments, as from the command line.
pub(super) fn run_command_with(lua: &Lua, name: &str, args: Vec<String>) -> Result<(), HostError> {
    invoke(
        lua,
        name,
        Invocation {
            args,
            ..Invocation::default()
        },
    )
}

/// How a command was asked to run.
#[derive(Default)]
struct Invocation<'a> {
    /// The keys that ran it.
    keys: &'a [Key],
    /// Arguments, as from the command line.
    args: Vec<String>,
    /// Go ahead even if it would normally refuse, like quitting with unsaved
    /// changes.
    force: bool,
    /// The number typed before the keys.
    count: Option<u32>,
    /// The limit it runs within, when plugin code started it; otherwise
    /// you did.
    limit: Option<Limit>,
}

/// Runs a command as the user.
fn invoke(lua: &Lua, name: &str, how: Invocation) -> Result<(), HostError> {
    invoke_running(lua, name, how).map(|_| ())
}

/// `invoke`, returning the command's coroutine if it's still running, for
/// `greed.run` to wait for.
fn invoke_running(lua: &Lua, name: &str, how: Invocation) -> Result<Option<usize>, HostError> {
    let Invocation {
        keys,
        args,
        force,
        count,
        limit,
    } = how;
    let limit = limit.unwrap_or_else(|| state(lua).floor.clone());
    let (handler, owner, client, view, buffer) = {
        let state = state(lua);
        let command = state
            .registry
            .command(name)
            .ok_or_else(|| HostError::UnknownCommand(name.into()))?;
        let client = state.editor.client();
        let view = state.editor.focus();
        (
            command.handler.clone(),
            command.owner.clone(),
            client,
            view,
            state.editor.view(view).buffer,
        )
    };
    let author = Author::User(client);
    let ctx = lua.create_table()?;
    ctx.set("client", client.0)?;
    ctx.set(
        "view",
        ViewRef {
            id: view,
            author: author.clone(),
        },
    )?;
    ctx.set(
        "buffer",
        BufferRef {
            buffer,
            view: Some(view),
            author,
        },
    )?;
    if !keys.is_empty() {
        ctx.set("keys", keys_text(keys))?;
    }
    ctx.set("args", args)?;
    ctx.set("force", force)?;
    ctx.set("count", count)?;
    if let [
        Key {
            code: KeyCode::Char(c),
            mods,
        },
    ] = keys
        && !mods.contains(Mods::CTRL)
        && !mods.contains(Mods::ALT)
    {
        ctx.set("char", c.to_string())?;
    }
    let event = lua.create_table()?;
    event.set("name", name)?;
    if !keys.is_empty() {
        event.set("keys", keys_text(keys))?;
    }
    event.set("count", count)?;
    emit_for_client(lua, "command.run", &event)?;
    Ok(tasks::spawn_running(
        lua,
        handler,
        ctx,
        owner,
        Some(name.into()),
        limit,
    )?)
}

/// A key typed by the user: kept if keys are being recorded, then fed
/// through the keymap. The command it runs is the one keys typed next wait
/// for while it's at work, unless one before still is. A key a command
/// waited for leaves that as it was.
pub(super) fn press(lua: &Lua, key: Key) -> Result<(), HostError> {
    let (client, answers) = {
        let state = &mut *state_mut(lua);
        let client = state.editor.client();
        let recordings = state.recording.get_mut(&client).into_iter();
        for recording in recordings.flat_map(HashMap::values_mut) {
            recording.keys.push(key);
        }
        (client, state.key_waiter.contains_key(&client))
    };
    let was_at_work = tasks::key_command_at_work(lua, client);
    let running = press_key(lua, key, None)?;
    if !answers && !was_at_work {
        tasks::ran_for_key(lua, running);
    }
    Ok(())
}

/// `key` where it's bound, or else `text`, a key at a time: what the key
/// typed. Plain ASCII, like the `[` and `{` a Swedish Mac types with
/// Option, is always typed: a keyboard puts those there to type them. A
/// command waiting for the next key gets the text too, as it waits for a
/// character.
pub(super) fn press_or_type(lua: &Lua, key: Key, text: &str) -> Result<(), HostError> {
    let typed = {
        let state = state(lua);
        let client = state.editor.client();
        !text.is_empty()
            && (text.chars().all(|c| c.is_ascii_graphic())
                || state.key_waiter.contains_key(&client)
                || !state.editor.binds(key))
    };
    if !typed {
        return press(lua, key);
    }
    crate::debug!(Keys, "{key} types {text:?}");
    for c in text.chars() {
        press(
            lua,
            Key {
                code: KeyCode::Char(c),
                mods: Mods::NONE,
            },
        )?;
    }
    Ok(())
}

/// The keys a `greed.keys.record` keeps.
pub(crate) struct Recording {
    keys: Vec<Key>,
    /// Whether it keeps keys fed by `greed.keys.feed` too, like a macro's.
    fed: bool,
}

/// Feeds one key press through the keymap, running whatever it resolves
/// to, without recording it, within `limit` when plugin code feeds it.
/// Returns the coroutine of the command it ran, if that's still running.
fn press_key(lua: &Lua, key: Key, limit: Option<Limit>) -> Result<Option<usize>, HostError> {
    // A command waiting on greed.next_key for this client gets the key
    // instead of the keymap.
    let waiter = {
        let state = &mut *state_mut(lua);
        let client = state.editor.client();
        state.key_waiter.remove(&client).map(|w| (client, w))
    };
    if let Some((client, (token, waiting))) = waiter {
        let fed = limit.unwrap_or_else(|| state(lua).floor.clone());
        if let Some(by) = capabilities::refused_answer(&fed, &waiting) {
            let error = format!("keys {by} feeds can't answer what waits for you to press a key");
            state_mut(lua).key_waiter.insert(client, (token, waiting));
            return Err(HostError::Lua(mlua::Error::runtime(error)));
        }
        crate::debug!(Keys, "{key} answers a command waiting for a key");
        tasks::wake(lua, token, key.to_string())?;
        return Ok(None);
    }
    let outcome = state_mut(lua).editor.press(key);
    match outcome {
        KeyOutcome::Pending => {
            let pending = keys_text(state(lua).editor.pending());
            crate::debug!(Keys, "{pending}: more keys to come");
            keys_pending(lua, &pending)?;
            Ok(None)
        }
        KeyOutcome::Command { name, keys, count } => {
            crate::debug!(Keys, "{} runs {name}", keys_text(&keys));
            if keys.len() > 1 {
                keys_pending(lua, "")?;
            }
            invoke_running(
                lua,
                &name,
                Invocation {
                    keys: &keys,
                    count,
                    limit,
                    ..Invocation::default()
                },
            )
        }
        KeyOutcome::Unbound(keys) => {
            crate::debug!(Keys, "{} isn't bound here", keys_text(&keys));
            if keys.len() > 1 {
                keys_pending(lua, "")?;
            }
            Ok(None)
        }
    }
}

/// Emits "keys.pending" with the unfinished key sequence, or "" once it ends.
fn keys_pending(lua: &Lua, keys: &str) -> LuaResult<()> {
    let payload = lua.create_table()?;
    payload.set("keys", keys)?;
    emit_for_client(lua, "keys.pending", &payload)
}

fn keys_text(keys: &[Key]) -> String {
    keys.iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(" ")
}

/// Every event the editor emits, the names `greed.on` accepts. Each has an
/// overload of `greed.on` in the type definitions.
pub const EVENTS: &[&str] = &[
    "buffer.changed",
    "buffer.closed",
    "buffer.opened",
    "buffer.saved",
    "client.attached",
    "client.detached",
    "client.paste",
    "command.run",
    "control.closed",
    "control.request",
    "editor.quitting",
    "editor.started",
    "file.changed",
    "keys.pending",
    "lsp.diagnostics",
    "mode.changed",
    "mouse",
    "option.changed",
    "pane.opened",
    "plugin.loaded",
    "plugin.unloaded",
    "selection.changed",
    "terminal.exited",
    "terminal.output",
    "view.closed",
    "view.focused",
    "view.resized",
    "view.scrolled",
];

fn known_event(event: &str) -> LuaResult<()> {
    if EVENTS.contains(&event) {
        Ok(())
    } else {
        Err(mlua::Error::runtime(format!(
            "there is no event called {event:?}"
        )))
    }
}

/// Calls every handler for `event` with `payload`. All handlers run even if
/// one fails; the first error is returned.
pub(super) fn emit(lua: &Lua, event: &str, payload: &Table) -> LuaResult<()> {
    debug_assert!(EVENTS.contains(&event), "{event} is missing from EVENTS");
    let handlers: Vec<(Function, PluginId)> = state(lua)
        .registry
        .handlers(event)
        .iter()
        .map(|h| (h.handler.clone(), h.owner.clone()))
        .collect();
    let mut first_error = None;
    let label: Arc<str> = format!("on {event}").into();
    for (handler, owner) in handlers {
        if let Err(err) = tasks::spawn_labelled(lua, handler, payload.clone(), owner, label.clone())
        {
            first_error.get_or_insert(err);
        }
    }
    first_error.map_or(Ok(()), Err)
}

/// Emits `event`, which concerns the acting client, with its id as
/// `client`. The handlers run as that client.
pub(super) fn emit_for_client(lua: &Lua, event: &str, payload: &Table) -> LuaResult<()> {
    payload.set("client", state(lua).editor.client().0)?;
    emit(lua, event, payload)
}

/// `greed.on(event, handler)` and `greed.off(event, handler)`, which removes
/// only `owner`'s own handlers.
fn add_event_functions(lua: &Lua, greed: &Table, owner: &PluginId) -> LuaResult<()> {
    let o = owner.clone();
    greed.set(
        "on",
        lua.create_function(move |lua, (event, handler): (String, Function)| {
            known_event(&event)?;
            let source = caller(lua);
            state_mut(lua)
                .registry
                .on(event, o.clone(), source, handler);
            Ok(())
        })?,
    )?;
    let o = owner.clone();
    greed.set(
        "off",
        lua.create_function(move |lua, (event, handler): (String, Function)| {
            known_event(&event)?;
            state_mut(lua).registry.off(&event, &o, |h| *h == handler);
            Ok(())
        })?,
    )
}

/// Refuses command names that can't be typed on the command line: empty
/// ones, and ones with spaces or control characters.
pub(super) fn check_command_name(name: &str) -> LuaResult<()> {
    if name.is_empty() || name.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(mlua::Error::runtime(format!(
            "{name:?} can't be a command name: use letters, digits and dashes, e.g. \"word-count\""
        )));
    }
    Ok(())
}

/// What looks wrong in what plugins registered, as lines to show: commands
/// a plugin replaced from another (your config may), and keys bound to
/// commands that don't exist.
pub(super) fn registry_warnings(lua: &Lua) -> Vec<String> {
    let state = state(lua);
    let mut warnings: Vec<String> = state
        .registry
        .commands()
        .flat_map(|command| {
            state
                .registry
                .definitions(&command.name)
                .iter()
                .filter_map(|earlier| replacing(&command.owner, &earlier.owner, &command.name))
        })
        .collect();
    let mut shadows: Vec<String> = state
        .editor
        .keymap()
        .shadowed()
        .iter()
        .filter_map(|s| shadowing(&s.layer, &s.over, &s.under))
        .collect();
    shadows.sort();
    warnings.extend(shadows);
    warnings.extend(unknown_bindings(lua));
    warnings
}

/// What to say when plugin `owner` defines command `name` over `earlier`'s,
/// if anything: not for its own, and not for your config.
fn replacing(owner: &str, earlier: &str, name: &str) -> Option<String> {
    (owner != earlier && !owner.starts_with("user/"))
        .then(|| format!("the {owner} plugin replaces the {earlier} plugin's command {name}"))
}

/// What to say when the binding `over` hides `under` in `layer`, if
/// anything: not when it's your config's.
fn shadowing(layer: &Layer, over: &Bound, under: &Bound) -> Option<String> {
    if over.owner.starts_with("user/") {
        return None;
    }
    let whose = if over.owner == under.owner {
        "its own".to_owned()
    } else {
        format!("the {} plugin's", under.owner)
    };
    Some(format!(
        "{} in {layer}: the {} plugin's {} hides {whose} {}{}",
        keys_text(&over.keys),
        over.owner,
        over.command,
        under.command,
        if under.keys == over.keys {
            String::new()
        } else {
            format!(" on {}", keys_text(&under.keys))
        },
    ))
}

/// Keys bound to commands that don't exist, as lines to show.
pub(super) fn unknown_bindings(lua: &Lua) -> Vec<String> {
    let state = state(lua);
    let mut found: Vec<String> = state
        .editor
        .keymap()
        .bindings()
        .into_iter()
        .filter(|(_, _, command)| state.registry.command(command).is_none())
        .map(|(layer, keys, command)| {
            format!(
                "{} in {layer} runs {command}, which doesn't exist",
                keys_text(&keys)
            )
        })
        .collect();
    found.sort();
    found
}

/// `greed.command(spec)` for `owner`, which says when it replaces another
/// plugin's command.
fn command_function(lua: &Lua, owner: &PluginId) -> LuaResult<Function> {
    let o = owner.clone();
    lua.create_function(move |lua, spec: Table| {
        let name: String = spec.get("name")?;
        check_command_name(&name)?;
        let command = Command {
            name: name.into(),
            doc: spec
                .get::<Option<String>>("doc")?
                .unwrap_or_default()
                .into(),
            args: command_args(spec.get("args")?)?,
            owner: o.clone(),
            source: caller(lua),
            handler: spec.get::<Function>("run")?,
        };
        let state = &mut *state_mut(lua);
        let said = state
            .registry
            .command(&command.name)
            .and_then(|earlier| replacing(&o, &earlier.owner, &command.name));
        if let Some(said) = said {
            state.editor.echo(said);
        }
        state.registry.add_command(command);
        Ok(())
    })
}

pub(super) fn greed_module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let greed = lua.create_table()?;

    greed.set("cli", super::cli::function(lua, owner)?)?;
    greed.set("command", command_function(lua, owner)?)?;
    greed.set("run", run_function(lua, owner)?)?;

    add_event_functions(lua, &greed, owner)?;

    greed.set(
        "echo",
        lua.create_function(|lua, parts: Variadic<Value>| {
            let text: Vec<String> = parts.iter().map(display).collect();
            state_mut(lua).editor.echo(text.join(" "));
            Ok(())
        })?,
    )?;

    greed.set(
        "messages",
        lua.create_function(|lua, ()| {
            let state = state(lua);
            let list: Vec<String> = state.editor.recent_messages().map(str::to_owned).collect();
            Ok(list)
        })?,
    )?;

    let o = owner.clone();
    greed.set(
        "view",
        lua.create_function(move |lua, ()| {
            Ok(ViewRef {
                id: state(lua).editor.focus(),
                author: Author::Plugin(o.clone()),
            })
        })?,
    )?;

    let sleep = tasks::sleep_function(lua)?;
    let now = tasks::now_function(lua)?;
    greed.set(
        "animate",
        tasks::animate_function(lua, now.clone(), sleep.clone())?,
    )?;
    greed.set("sleep", sleep)?;
    greed.set("spawn", spawn_function(lua, owner)?)?;
    greed.set(
        "stalls",
        lua.create_function(|lua, ()| super::stalls::list(lua))?,
    )?;
    greed.set("profile", super::stalls::profile_module(lua)?)?;
    greed.set("debug", super::debug::module(lua, owner)?)?;
    greed.set(
        "errors",
        lua.create_function(|lua, ()| super::errors::list(lua))?,
    )?;
    greed.set("now", now)?;
    greed.set("next_key", tasks::next_key_function(lua)?)?;

    greed.set("quit", quit_function(lua)?)?;

    greed.set("line_numbers", line_numbers_function(lua)?)?;
    greed.set("reveal", reveal_function(lua)?)?;

    greed.set(
        "eval",
        lua.create_function(|lua, (source, opts): (String, Option<Table>)| {
            let sandbox = match opts {
                Some(opts) => opts.get::<Option<bool>>("sandbox")?.unwrap_or(false),
                None => false,
            };
            let ran = if sandbox {
                super::eval_sandboxed(lua, &source)
            } else {
                super::capabilities::trusted_eval(lua, || super::eval_repl(lua, &source))
            };
            Ok(match ran {
                Ok(values) => (true, values),
                Err(err) => (false, err.to_string()),
            })
        })?,
    )?;

    let o = owner.clone();
    greed.set(
        "statusline",
        lua.create_function(move |lua, build: Function| {
            state_mut(lua).statusline = Some((o.clone(), build));
            Ok(())
        })?,
    )?;

    greed.set("set_menus", menus_function(lua, owner)?)?;

    workspace_functions(lua, &greed, owner)?;
    submodules(lua, &greed, owner)?;
    Ok(greed)
}

/// `greed.set_menus(menus)`: the menus a window shows as its menu bar.
fn menus_function(lua: &Lua, owner: &PluginId) -> LuaResult<Function> {
    let owner = owner.clone();
    lua.create_function(move |lua, list: Vec<Table>| {
        let menus = list
            .iter()
            .map(|menu| {
                let items = menu
                    .get::<Vec<Table>>("items")?
                    .iter()
                    .map(|item| {
                        Ok(MenuItem {
                            label: item.get("label")?,
                            command: item.get("command")?,
                        })
                    })
                    .collect::<LuaResult<_>>()?;
                Ok(Menu {
                    title: menu.get("title")?,
                    items,
                })
            })
            .collect::<LuaResult<_>>()?;
        let mut state = state_mut(lua);
        state.editor.set_menus(menus);
        state.menus_owner = Some(owner.clone());
        Ok(())
    })
}

/// `greed.keymap`, `greed.mode` and the other tables in `greed`.
fn submodules(lua: &Lua, greed: &Table, owner: &PluginId) -> LuaResult<()> {
    greed.set("keymap", keymap_module(lua, owner)?)?;
    greed.set("mode", mode_module(lua)?)?;
    greed.set("option", option_module(lua, owner)?)?;
    greed.set("history", history_module(lua)?)?;
    greed.set("base64", base64_module(lua)?)?;
    greed.set("clipboard", clipboard_module(lua)?)?;
    greed.set("client", client_module(lua)?)?;
    greed.set("lsp", super::lsp::module(lua, owner)?)?;
    greed.set("fs", super::fs::module(lua, owner)?)?;
    greed.set("hash", super::hash::module(lua)?)?;
    greed.set(
        "hostname",
        lua.create_function(|_, ()| Ok(gethostname::gethostname().into_string().ok()))?,
    )?;
    greed.set("control", super::requests::module(lua, owner)?)?;
    greed.set("json", super::json::module(lua)?)?;
    greed.set("project", super::projects::module(lua)?)?;
    greed.set("tab", super::tabs::module(lua, owner)?)?;
    greed.set("session", super::sessions::module(lua)?)?;
    greed.set("keys", keys_module(lua, owner)?)?;
    greed.set("process", super::process::module(lua, owner)?)?;
    greed.set("http", super::http::module(lua, owner)?)?;
    greed.set("secrets", super::secrets::module(lua, owner)?)?;
    greed.set("terminal", super::terminal::module(lua, owner)?)?;
    greed.set("image", super::images::module(lua, owner)?)?;
    greed.set("scene", super::scenes::module(lua, owner)?)?;
    greed.set("pdf", super::pdf::module(lua)?)?;
    greed.set("diff", super::diff::diff_function(lua)?)?;
    greed.set("signal", tasks::signal_function(lua)?)?;
    greed.set(
        "detach",
        lua.create_function(|lua, ()| {
            state_mut(lua).editor.request_detach();
            Ok(())
        })?,
    )?;
    super::languages::register(lua, greed, owner)?;
    greed.set("plugin", super::plugin::module(lua, owner)?)?;
    greed.set("syntax", super::syntax::module(lua, owner)?)?;
    greed.set("theme", super::theme::module(lua, owner)?)
}

/// A mode name, or `{ mode = ..., kind = ... }`, where a named layer can
/// stand in for the mode: the leader (`{ layer = "leader" }`), an editing
/// role in every style (`{ role = "typing" }`) or in one
/// (`{ style = "vim", role = "command" }`).
fn layer_from_lua(layer: Value) -> LuaResult<Layer> {
    match layer {
        Value::String(mode) => Ok(Layer::mode(&mode.to_str()?)),
        Value::Table(t) => {
            let role = t.get::<Option<String>>("role")?;
            let style = t.get::<Option<String>>("style")?;
            let mode = match (role, style) {
                (Some(role), Some(style)) => Some(Layer::style_role_name(&style, &role)),
                (Some(role), None) => Some(Layer::role_name(&role)),
                (None, Some(_)) => {
                    return Err(mlua::Error::runtime(
                        "a style's keymap layer needs a role, e.g. { style = \"vim\", role = \"command\" }",
                    ));
                }
                (None, None) => t
                    .get::<Option<String>>("mode")?
                    .or(t.get::<Option<String>>("layer")?),
            };
            Ok(Layer {
                mode: mode.map(Into::into),
                kind: t.get::<Option<String>>("kind")?.map(Into::into),
            })
        }
        other => Err(mlua::Error::runtime(format!(
            "keymap layer must be a mode name or {{ mode = ..., kind = ... }}, not {}",
            other.type_name()
        ))),
    }
}

/// The mode or named layer `parent` (a name, or a layer without a kind)
/// stands for, for `greed.keymap.inherit`.
fn parent_from_lua(parent: Value) -> LuaResult<String> {
    let layer = layer_from_lua(parent)?;
    match (layer.mode, layer.kind) {
        (Some(mode), None) => Ok(mode.to_string()),
        _ => Err(mlua::Error::runtime(
            "a mode can inherit a mode or a named layer, not a buffer kind's keys",
        )),
    }
}

/// The `greed.keymap` functions that change a layer or how a mode uses
/// layers: `unbind`, `clear`, `counts`, `inherit`, `enter`, `isolate` and
/// `fallback`.
fn layer_functions(lua: &Lua, keymap: &Table, owner: &PluginId) -> LuaResult<()> {
    let o = owner.clone();
    keymap.set(
        "fallback",
        lua.create_function(move |lua, (mode, command): (String, String)| {
            state_mut(lua)
                .editor
                .keymap_mut()
                .set_fallback(&mode, command, o.clone());
            Ok(())
        })?,
    )?;

    let o = owner.clone();
    keymap.set(
        "unbind",
        lua.create_function(move |lua, (layer, sequences): (Value, Vec<String>)| {
            let layer = layer_from_lua(layer)?;
            let mut state = state_mut(lua);
            for keys in sequences {
                let parsed = Key::parse_sequence(&keys).map_err(mlua::Error::external)?;
                state
                    .editor
                    .keymap_mut()
                    .unbind(layer.clone(), &parsed, o.clone());
            }
            Ok(())
        })?,
    )?;

    let o = owner.clone();
    keymap.set(
        "clear",
        lua.create_function(move |lua, layer: Value| {
            let layer = layer_from_lua(layer)?;
            state_mut(lua).editor.keymap_mut().clear(layer, o.clone());
            Ok(())
        })?,
    )?;

    let o = owner.clone();
    keymap.set(
        "counts",
        lua.create_function(move |lua, mode: String| {
            state_mut(lua)
                .editor
                .keymap_mut()
                .enable_counts(&mode, o.clone());
            Ok(())
        })?,
    )?;

    let o = owner.clone();
    keymap.set(
        "inherit_first",
        lua.create_function(move |lua, (mode, parent): (String, Value)| {
            let parent = parent_from_lua(parent)?;
            state_mut(lua)
                .editor
                .keymap_mut()
                .inherit_first(&mode, &parent, o.clone());
            Ok(())
        })?,
    )?;

    let o = owner.clone();
    keymap.set(
        "enter",
        lua.create_function(move |lua, (mode, keys, layer): (String, String, String)| {
            let keys = Key::parse_sequence(&keys).map_err(mlua::Error::external)?;
            state_mut(lua)
                .editor
                .keymap_mut()
                .enter(&mode, keys, &layer, o.clone());
            Ok(())
        })?,
    )?;

    let o = owner.clone();
    keymap.set(
        "isolate",
        lua.create_function(move |lua, mode: String| {
            state_mut(lua).editor.keymap_mut().isolate(&mode, o.clone());
            Ok(())
        })?,
    )?;

    let o = owner.clone();
    keymap.set(
        "inherit",
        lua.create_function(
            move |lua, (mode, parent, prefixes): (String, Value, Option<Vec<String>>)| {
                let parent = parent_from_lua(parent)?;
                let prefixes = prefixes
                    .unwrap_or_default()
                    .iter()
                    .map(|p| Key::parse_sequence(p))
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(mlua::Error::external)?;
                state_mut(lua)
                    .editor
                    .keymap_mut()
                    .inherit(&mode, &parent, prefixes, o.clone());
                Ok(())
            },
        )?,
    )
}

/// `greed.keymap.describe(keys)`: the binding of `keys` in each layer of
/// the current mode and buffer, each followed by those it hides there.
fn describe_keys(lua: &Lua, keys: &str) -> LuaResult<Table> {
    let keys = Key::parse_sequence(keys).map_err(mlua::Error::external)?;
    let found: Vec<Found> = {
        let state = state(lua);
        let editor = &state.editor;
        let kind = editor.buffer(editor.view(editor.focus()).buffer).kind();
        let keymap = editor.keymap();
        let shadows = keymap.shadowed();
        let mut found = Vec::new();
        for f in keymap.describe(editor.mode(), kind, &keys) {
            let hidden: Vec<Found> = shadows
                .iter()
                .filter(|s| {
                    s.layer == f.layer && s.over.command == f.command && s.over.owner == f.owner
                })
                .map(|s| Found {
                    layer: s.layer.clone(),
                    command: s.under.command.clone(),
                    owner: s.under.owner.clone(),
                })
                .collect();
            found.push(f);
            found.extend(hidden);
        }
        found
    };
    let list = lua.create_table()?;
    for f in found {
        let entry = lua.create_table()?;
        entry.set("layer", f.layer.to_string())?;
        entry.set("command", &*f.command)?;
        entry.set("plugin", &*f.owner)?;
        list.push(entry)?;
    }
    Ok(list)
}

/// `greed.keymap.bind(layer, map)` for `owner`, which says when a binding
/// hides another plugin's.
fn bind_function(lua: &Lua, owner: &PluginId) -> LuaResult<Function> {
    let o = owner.clone();
    lua.create_function(move |lua, (layer, map): (Value, Table)| {
        let layer = layer_from_lua(layer)?;
        // Keys from another plugin's module, like core's text objects.
        let map = super::modules::plain(lua, map)?;
        let mut state = state_mut(lua);
        for pair in map.pairs::<String, String>() {
            let (keys, command) = pair?;
            let over = Bound {
                keys: Key::parse_sequence(&keys).map_err(mlua::Error::external)?,
                command: command.into(),
                owner: o.clone(),
            };
            let said: Vec<String> = state
                .editor
                .keymap()
                .hides(&layer, &over.keys, &over.command)
                .iter()
                .filter_map(|under| shadowing(&layer, &over, under))
                .collect();
            state
                .editor
                .keymap_mut()
                .bind(layer.clone(), &over.keys, over.command, o.clone())
                .map_err(mlua::Error::external)?;
            for line in said {
                state.editor.echo(line);
            }
        }
        Ok(())
    })
}

fn keymap_module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let keymap = lua.create_table()?;

    keymap.set("bind", bind_function(lua, owner)?)?;

    layer_functions(lua, &keymap, owner)?;

    keymap.set(
        "resolve",
        lua.create_function(|lua, keys: String| {
            let keys = Key::parse_sequence(&keys).map_err(mlua::Error::external)?;
            let state = state(lua);
            let editor = &state.editor;
            let kind = editor.buffer(editor.view(editor.focus()).buffer).kind();
            Ok(match editor.keymap().resolve(editor.mode(), kind, &keys) {
                Resolution::Command(command) => (Some(command.to_string()), false),
                Resolution::Pending => (None, true),
                Resolution::Unbound => (None, false),
            })
        })?,
    )?;

    keymap.set(
        "describe",
        lua.create_function(|lua, keys: String| describe_keys(lua, &keys))?,
    )?;

    keymap.set("overlay", lua.create_function(set_overlay)?)?;

    keymap.set(
        "find",
        lua.create_function(|lua, command: Option<String>| {
            let mut found: Vec<_> = {
                let state = state(lua);
                let keymap = state.editor.keymap();
                match &command {
                    Some(command) => keymap
                        .bindings_for(command)
                        .into_iter()
                        .map(|(layer, keys)| (layer, keys, Arc::<str>::from(command.as_str())))
                        .collect(),
                    None => keymap.bindings(),
                }
            };
            found.sort_by_cached_key(|(layer, keys, _)| (layer.to_string(), keys_text(keys)));
            let list = lua.create_table()?;
            for (layer, keys, command) in found {
                let entry = lua.create_table()?;
                entry.set("layer", layer.to_string())?;
                entry.set("keys", keys_text(&keys))?;
                entry.set("command", &*command)?;
                list.push(entry)?;
            }
            Ok(list)
        })?,
    )?;

    keymap.set(
        "next",
        lua.create_function(|lua, keys: Option<String>| {
            let prefix = match keys.as_deref().map(str::trim) {
                None | Some("") => Vec::new(),
                Some(keys) => Key::parse_sequence(keys).map_err(mlua::Error::external)?,
            };
            let next = {
                let state = state(lua);
                let editor = &state.editor;
                let kind = editor.buffer(editor.view(editor.focus()).buffer).kind();
                editor.keymap().continuations(editor.mode(), kind, &prefix)
            };
            let list = lua.create_table()?;
            for (key, next) in next {
                let entry = lua.create_table()?;
                entry.set("key", key.to_string())?;
                if let Next::Command(command) = next {
                    entry.set("command", &*command)?;
                }
                list.push(entry)?;
            }
            Ok(list)
        })?,
    )?;

    keymap.set("active", lua.create_function(active_keys)?)?;
    Ok(keymap)
}

/// `greed.keymap.active()`: what runs a command in the current mode and
/// buffer, as `{ keys, command }`.
fn active_keys(lua: &Lua, (): ()) -> LuaResult<Table> {
    let found = {
        let state = state(lua);
        let editor = &state.editor;
        let kind = editor.buffer(editor.view(editor.focus()).buffer).kind();
        editor.keymap().reachable(editor.mode(), kind)
    };
    let list = lua.create_table()?;
    for (keys, command) in found {
        let entry = lua.create_table()?;
        entry.set("keys", keys_text(&keys))?;
        entry.set("command", &*command)?;
        list.push(entry)?;
    }
    Ok(list)
}

fn mode_module(lua: &Lua) -> LuaResult<Table> {
    let mode = lua.create_table()?;
    mode.set(
        "get",
        lua.create_function(|lua, ()| Ok(state(lua).editor.mode().to_owned()))?,
    )?;
    mode.set(
        "set",
        lua.create_function(|lua, name: String| {
            let from = {
                let mut state = state_mut(lua);
                let from = state.editor.mode().to_owned();
                if !state.editor.set_mode(&name) {
                    return Ok(());
                }
                from
            };
            let payload = lua.create_table()?;
            payload.set("from", from)?;
            payload.set("to", name)?;
            emit_for_client(lua, "mode.changed", &payload)
        })?,
    )?;
    let set_cursor = lua.create_function(|lua, (name, shape): (String, String)| {
        let shape = match shape.as_str() {
            "block" => CursorShape::Block,
            "bar" => CursorShape::Bar,
            "underline" => CursorShape::Underline,
            other => {
                return Err(mlua::Error::runtime(format!(
                    "cursor shapes are \"block\", \"bar\" or \"underline\", not {other:?}"
                )));
            }
        };
        state_mut(lua).editor.set_cursor_shape(&name, shape);
        Ok(())
    })?;
    let cursor_of = lua.create_function(|lua, name: Option<String>| {
        let state = state(lua);
        let editor = &state.editor;
        Ok(
            match editor.cursor_shape_of(name.as_deref().unwrap_or(editor.mode())) {
                CursorShape::Block => "block",
                CursorShape::Bar => "bar",
                CursorShape::Underline => "underline",
            },
        )
    })?;
    // `cursor` and `shape` are the older names.
    mode.set("cursor", set_cursor.clone())?;
    mode.set("set_cursor", set_cursor)?;
    mode.set("shape", cursor_of.clone())?;
    mode.set("cursor_of", cursor_of)?;
    Ok(mode)
}

fn base64_module(lua: &Lua) -> LuaResult<Table> {
    use base64::Engine;
    let base64 = lua.create_table()?;
    base64.set(
        "encode",
        lua.create_function(|_, bytes: mlua::LuaString| {
            Ok(base64::engine::general_purpose::STANDARD.encode(bytes.as_bytes()))
        })?,
    )?;
    base64.set(
        "decode",
        lua.create_function(|lua, text: String| {
            match base64::engine::general_purpose::STANDARD.decode(text.trim()) {
                Ok(bytes) => Ok(Some(lua.create_string(bytes)?)),
                Err(_) => Ok(None),
            }
        })?,
    )?;
    Ok(base64)
}

fn clipboard_module(lua: &Lua) -> LuaResult<Table> {
    let clipboard = lua.create_table()?;
    clipboard.set(
        "set",
        lua.create_function(|lua, pieces: Value| {
            let pieces = match pieces {
                Value::String(s) => vec![s.to_str()?.to_owned()],
                Value::Table(t) => t.sequence_values::<String>().collect::<LuaResult<_>>()?,
                other => {
                    return Err(mlua::Error::runtime(format!(
                        "the clipboard takes a string or a list of strings, not {}",
                        other.type_name()
                    )));
                }
            };
            state_mut(lua).editor.copy(pieces);
            Ok(())
        })?,
    )?;
    clipboard.set(
        "get",
        lua.create_function(|lua, ()| Ok(state(lua).editor.clipboard().map(<[String]>::to_vec)))?,
    )?;
    clipboard.set(
        "history",
        lua.create_function(|lua, ()| {
            Ok(state(lua)
                .editor
                .clipboard_history()
                .map(<[String]>::to_vec)
                .collect::<Vec<_>>())
        })?,
    )?;
    // The client reads its own clipboard, on its own machine, and answers;
    // one that doesn't within a few seconds has none to give.
    let ask = lua.create_function(|lua, ()| {
        const WAIT: std::time::Duration = std::time::Duration::from_secs(5);
        let answer = state_mut(lua).editor.ask_clipboard_image();
        Ok(super::jobs::start(
            lua,
            "greed.clipboard.image",
            move || super::jobs::Output::ClipboardImage(answer.recv_timeout(WAIT).ok().flatten()),
        ))
    })?;
    clipboard.set(
        "image",
        super::jobs::waiting(lua, "greed.clipboard.image", ask)?,
    )?;
    Ok(clipboard)
}

/// What `greed.client.current` and `.list` say about a client.
fn client_to_lua(lua: &Lua, client: &crate::ClientState) -> LuaResult<Table> {
    let t = lua.create_table()?;
    t.set("id", client.id().0)?;
    t.set("name", client.name())?;
    t.set("kind", client.kind())?;
    t.set("remote", client.remote())?;
    if let Some((width, height)) = client.size() {
        let size = lua.create_table()?;
        size.set("width", width)?;
        size.set("height", height)?;
        t.set("size", size)?;
    }
    t.set("layout", client.layout().name())?;
    t.set("color", client.color())?;
    // Every client is the session owner's until sessions can be shared.
    t.set("person", "owner")?;
    Ok(t)
}

/// `greed.client`: the clients you see the editor through, and the acting
/// one as your desktop.
fn client_module(lua: &Lua) -> LuaResult<Table> {
    let client = lua.create_table()?;
    client.set(
        "current",
        lua.create_function(|lua, ()| {
            let state = state(lua);
            let editor = &state.editor;
            let current = editor
                .client_state(editor.client())
                .ok_or_else(|| mlua::Error::runtime("no client is acting"))?;
            client_to_lua(lua, current)
        })?,
    )?;
    client.set(
        "list",
        lua.create_function(|lua, ()| {
            let state = state(lua);
            state
                .editor
                .clients()
                .map(|c| client_to_lua(lua, c))
                .collect::<LuaResult<Vec<_>>>()
        })?,
    )?;
    client.set(
        "notify",
        lua.create_function(|lua, (title, body): (String, Option<String>)| {
            let body = body.unwrap_or_default();
            state_mut(lua).editor.notify(Notice { title, body });
            Ok(())
        })?,
    )?;
    client.set(
        "id",
        lua.create_function(|lua, ()| Ok(state(lua).editor.client().0))?,
    )?;
    client.set(
        "set_layout",
        lua.create_function(|lua, (layout, id): (String, Option<u32>)| {
            let layout = ClientLayout::parse(&layout).ok_or_else(|| {
                mlua::Error::runtime(format!(
                    "a layout is \"follow\" or \"independent\", not {layout:?}"
                ))
            })?;
            let id = id.map_or_else(|| state(lua).editor.client(), ClientId);
            if state(lua).editor.client_state(id).is_none() {
                return Err(mlua::Error::runtime(format!("there is no client {}", id.0)));
            }
            set_client_layout(lua, id, layout)
        })?,
    )?;
    Ok(client)
}

/// Lays client `id` out as `layout` says: the views of its own layout
/// belong to the plugins the views they copy do, and plugins hear of those
/// that close as it goes back to following. Whether anything changed.
pub(super) fn set_client_layout(lua: &Lua, id: ClientId, layout: ClientLayout) -> LuaResult<bool> {
    let change = {
        let state = &mut *state_mut(lua);
        let Some(change) = state.editor.set_layout(id, layout) else {
            return Ok(false);
        };
        for &(original, copy) in &change.opened {
            state.owned.copied_view(original, copy);
        }
        change
    };
    for view in change.closed {
        handles::view_closed(lua, view)?;
    }
    Ok(true)
}

fn history_module(lua: &Lua) -> LuaResult<Table> {
    let history = lua.create_table()?;
    history.set(
        "start_group",
        lua.create_function(|lua, ()| {
            state_mut(lua).editor.start_group();
            Ok(())
        })?,
    )?;
    history.set(
        "end_group",
        lua.create_function(|lua, ()| {
            state_mut(lua).editor.end_group();
            Ok(())
        })?,
    )?;
    history.set(
        "new_group",
        lua.create_function(|lua, ()| Ok(state_mut(lua).editor.new_group()))?,
    )?;
    history.set(
        "group",
        lua.create_function(|lua, ()| Ok(state(lua).editor.group()))?,
    )?;
    history.set(
        "set_group",
        lua.create_function(|lua, group: Option<u64>| {
            state_mut(lua).editor.set_group(group);
            Ok(())
        })?,
    )?;
    history.set(
        "cause",
        lua.create_function(|lua, ()| Ok(state(lua).editor.cause().map(ToString::to_string)))?,
    )?;
    history.set(
        "set_cause",
        lua.create_function(|lua, cause: Option<String>| {
            tasks::set_cause(lua, cause.map(Into::into));
            Ok(())
        })?,
    )?;
    history.set(
        "undo_group",
        lua.create_function(|lua, group: u64| {
            let author = Author::User(state(lua).editor.client());
            let undone = state_mut(lua).editor.undo_group(group, &author);
            match undone {
                Ok(buffers) => {
                    for &buffer in &buffers {
                        handles::buffer_changed(lua, buffer, &author)?;
                    }
                    Ok((Some(buffers.len()), None))
                }
                Err(err) => Ok((None, Some(err.to_string()))),
            }
        })?,
    )?;
    Ok(history)
}

fn option_module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let option = lua.create_table()?;

    let o = owner.clone();
    option.set(
        "define",
        lua.create_function(move |lua, spec: Table| define_option(lua, &o, &spec))?,
    )?;
    option.set(
        "get",
        lua.create_function(|lua, name: String| {
            let state = state(lua);
            let value = state
                .registry
                .option_for(state.editor.client(), &name)
                .cloned();
            drop(state);
            value.map(|v| option_to_lua(lua, v)).transpose()
        })?,
    )?;
    option.set("set", lua.create_function(set_option)?)?;
    option.set(
        "list",
        lua.create_function(|lua, ()| {
            let state = state(lua);
            let mut options: Vec<_> = state.registry.option_states().collect();
            options.sort_by(|a, b| a.def.name.cmp(&b.def.name));
            let list = lua.create_table()?;
            for option in options {
                let entry = lua.create_table()?;
                entry.set("name", &*option.def.name)?;
                entry.set("doc", &*option.def.doc)?;
                let value = state
                    .registry
                    .option_for(state.editor.client(), &option.def.name)
                    .unwrap_or(option.value);
                entry.set("value", option_to_lua(lua, value.clone())?)?;
                entry.set("default", option_to_lua(lua, option.def.default.clone())?)?;
                let choices: Vec<Value> = option
                    .def
                    .choices
                    .iter()
                    .map(|c| option_to_lua(lua, c.clone()))
                    .collect::<LuaResult<_>>()?;
                entry.set("choices", choices)?;
                entry.set("owner", &*option.def.owner)?;
                entry.set("set_by", option.set_by.map(|by| &**by))?;
                set_source(&entry, &state.sources, option.def.source.as_ref())?;
                list.push(entry)?;
            }
            Ok(list)
        })?,
    )?;
    Ok(option)
}

/// `greed.option.define(spec)` for `o`'s code.
fn define_option(lua: &Lua, o: &PluginId, spec: &Table) -> LuaResult<()> {
    let name: String = spec.get("name")?;
    let default = option_value(spec.get("default")?)?;
    let choices = spec
        .get::<Option<Vec<Value>>>("choices")?
        .unwrap_or_default()
        .into_iter()
        .map(option_value)
        .collect::<LuaResult<Vec<_>>>()?;
    if let Some(odd) = choices
        .iter()
        .find(|c| std::mem::discriminant(*c) != std::mem::discriminant(&default))
    {
        return Err(mlua::Error::runtime(format!(
            "option {name:?}: the choice \"{odd}\" isn't a {}",
            default.type_name()
        )));
    }
    if !choices.is_empty() && !choices.contains(&default) {
        return Err(mlua::Error::runtime(format!(
            "option {name:?}: the default \"{default}\" isn't one of its choices"
        )));
    }
    let needs = spec.get::<Option<String>>("needs")?;
    if let Some(needs) = &needs
        && capabilities::what(needs).is_none()
    {
        return Err(mlua::Error::runtime(format!(
            "option {name:?}: there is no capability {needs:?}"
        )));
    }
    {
        // Another plugin's option stays as it defined it: taken
        // over, its default or what it needs could change.
        let state = state(lua);
        if let Some(def) = state.registry.option_def(&name)
            && def.owner != *o
            && state
                .grants
                .get(o)
                .is_some_and(|g| *g != capabilities::Grant::All)
        {
            return Err(mlua::Error::runtime(format!(
                "option {name:?} is {}'s",
                def.owner
            )));
        }
    }
    let def = OptionDef {
        needs: needs.map(Into::into),
        name: name.into(),
        doc: spec
            .get::<Option<String>>("doc")?
            .unwrap_or_default()
            .into(),
        owner: o.clone(),
        source: caller(lua),
        default,
        choices,
    };
    state_mut(lua).registry.define_option(def);
    Ok(())
}

/// `greed.option.set(name, value, { client })`: sets an option for every
/// client, or with `client` a value of the acting client's own (nil takes
/// it away), and tells plugins.
fn set_option(lua: &Lua, (name, value, opts): (String, Value, Option<Table>)) -> LuaResult<()> {
    let own = match opts {
        Some(opts) => opts.get::<Option<bool>>("client")?.unwrap_or(false),
        None => false,
    };
    let needs = state(lua)
        .registry
        .option_def(&name)
        .and_then(|def| def.needs.clone());
    if let Some(needs) = needs {
        capabilities::check_setting(lua, &needs)?;
    }
    let client = {
        let state = &mut *state_mut(lua);
        let client = state.editor.client();
        if own {
            let value = (!value.is_nil()).then(|| option_value(value.clone()));
            state
                .registry
                .set_option_for(client, &name, value.transpose()?)
                .map_err(mlua::Error::external)?;
        } else {
            let by = state.running.clone();
            state
                .registry
                .set_option_by(&name, option_value(value.clone())?, by)
                .map_err(mlua::Error::external)?;
        }
        client
    };
    let payload = lua.create_table()?;
    payload.set("name", name.as_str())?;
    let now = state(lua).registry.option_for(client, &name).cloned();
    payload.set("value", now.map(|v| option_to_lua(lua, v)).transpose()?)?;
    if own {
        payload.set("client", client.0)?;
    }
    emit(lua, "option.changed", &payload)
}

fn option_value(value: Value) -> LuaResult<OptionValue> {
    Ok(match value {
        Value::Boolean(b) => OptionValue::Bool(b),
        Value::Integer(i) => OptionValue::Int(i),
        Value::Number(n) if n.fract() == 0.0 && n.abs() < 2f64.powi(53) =>
        {
            #[expect(
                clippy::cast_possible_truncation,
                reason = "checked to be a whole number in range"
            )]
            OptionValue::Int(n as i64)
        }
        Value::Number(n) => OptionValue::Float(n),
        Value::String(s) => OptionValue::String(s.to_str()?.as_ref().into()),
        other => {
            return Err(mlua::Error::runtime(format!(
                "options can be booleans, numbers or strings, not {}",
                other.type_name()
            )));
        }
    })
}

fn option_to_lua(lua: &Lua, value: OptionValue) -> LuaResult<Value> {
    Ok(match value {
        OptionValue::Bool(b) => Value::Boolean(b),
        #[expect(clippy::cast_precision_loss, reason = "Luau numbers are doubles")]
        OptionValue::Int(i) => Value::Number(i as f64),
        OptionValue::Float(f) => Value::Number(f),
        OptionValue::String(s) => Value::String(lua.create_string(&*s)?),
    })
}

/// Reads a command's `args = { { name, doc, complete } }`.
fn command_args(spec: Option<Table>) -> LuaResult<Vec<Arg>> {
    let Some(spec) = spec else {
        return Ok(Vec::new());
    };
    spec.sequence_values::<Table>()
        .map(|arg| {
            let arg = arg?;
            Ok(Arg {
                name: arg.get::<String>("name")?.into(),
                doc: arg.get::<Option<String>>("doc")?.unwrap_or_default().into(),
                complete: arg.get::<Option<String>>("complete")?.map(Into::into),
            })
        })
        .collect()
}

/// Where the Luau code calling into Rust was written: the outermost call in
/// the calling file, so a command defined through a helper points at the
/// helper's call rather than inside the helper.
fn caller(lua: &Lua) -> Option<Source> {
    let frame = |level| {
        lua.inspect_stack(level, |debug| {
            let file = debug.source().short_src?.into_owned();
            let line = u32::try_from(debug.current_line()?).ok()?;
            Some((file, line))
        })
        .flatten()
    };
    let (file, mut line) = frame(1)?;
    for level in 2.. {
        match frame(level) {
            Some((outer, outer_line)) if outer == file => line = outer_line,
            _ => break,
        }
    }
    Some(Source {
        file: file.into(),
        line,
    })
}

/// A value as text, falling back to its debug form when `tostring` fails.
pub(super) fn display(value: &Value) -> String {
    value.to_string().unwrap_or_else(|_| format!("{value:?}"))
}

pub(super) fn into_lua(err: HostError) -> mlua::Error {
    match err {
        HostError::Lua(err) => err,
        other => mlua::Error::external(other),
    }
}

/// `greed.buffers` and `greed.buffer_for`: open buffers, all or by path.
fn buffer_functions(lua: &Lua, greed: &Table, owner: &PluginId) -> LuaResult<()> {
    let o = owner.clone();
    greed.set(
        "buffers",
        lua.create_function(move |lua, ()| {
            let ids: Vec<_> = state(lua).editor.buffers().map(crate::Buffer::id).collect();
            let list = lua.create_table()?;
            for buffer in ids {
                list.push(BufferRef {
                    buffer,
                    view: None,
                    author: Author::Plugin(o.clone()),
                })?;
            }
            Ok(list)
        })?,
    )?;
    let o = owner.clone();
    greed.set(
        "buffer_for",
        lua.create_function(move |lua, UserPath(path): UserPath| {
            Ok(state(lua)
                .editor
                .buffer_for(Path::new(&path))
                .map(|buffer| BufferRef {
                    buffer,
                    view: None,
                    author: Author::Plugin(o.clone()),
                }))
        })?,
    )?;
    Ok(())
}

/// Buffers, floating views, files and commands: what pickers and other UI
/// plugins are built from.
fn workspace_functions(lua: &Lua, greed: &Table, owner: &PluginId) -> LuaResult<()> {
    greed.set("create_buffer", create_buffer_function(lua, owner)?)?;
    greed.set("panel", panel_function(lua, owner)?)?;
    greed.set("floats", lua.create_function(floats)?)?;

    let o = owner.clone();
    greed.set(
        "float",
        lua.create_function(
            move |lua, (buffer, spec): (UserDataRef<BufferRef>, Option<Table>)| {
                let options = float_options(DEFAULT_FLOAT, spec)?;
                buffer.with_buffer(lua, |_| Ok(()))?;
                let state = &mut *state_mut(lua);
                let id = state.editor.float(buffer.buffer, options);
                state.owned.view(id, o.clone());
                Ok(ViewRef {
                    id,
                    author: Author::Plugin(o.clone()),
                })
            },
        )?,
    )?;

    buffer_functions(lua, greed, owner)?;
    greed.set("load", load_function(lua, owner)?)?;

    greed.set(
        "open",
        lua.create_function(|lua, UserPath(path): UserPath| {
            super::secrets::guard(lua, Path::new(&path))?;
            open_file(lua, &path)
        })?,
    )?;

    greed.set("handlers", lua.create_function(handlers)?)?;

    greed.set(
        "commands",
        lua.create_function(|lua, ()| {
            let list = lua.create_table()?;
            let state = state(lua);
            for command in state.registry.commands() {
                let entry = lua.create_table()?;
                entry.set("name", &*command.name)?;
                entry.set("doc", &*command.doc)?;
                entry.set("owner", &*command.owner)?;
                let args = lua.create_table()?;
                for arg in &command.args {
                    let spec = lua.create_table()?;
                    spec.set("name", &*arg.name)?;
                    spec.set("doc", &*arg.doc)?;
                    spec.set("complete", arg.complete.as_deref())?;
                    args.push(spec)?;
                }
                entry.set("args", args)?;
                set_source(&entry, &state.sources, command.source.as_ref())?;
                list.push(entry)?;
            }
            Ok(list)
        })?,
    )?;

    greed.set(
        "fuzzy",
        lua.create_function(
            |_, (query, items, opts): (String, Vec<String>, Option<Table>)| {
                Ok(fuzzy(&query, &items, case_matching(opts.as_ref())?))
            },
        )?,
    )?;
    greed.set(
        "fuzzy_positions",
        lua.create_function(|_, (query, text, opts): (String, String, Option<Table>)| {
            Ok(fuzzy_positions(
                &query,
                &text,
                case_matching(opts.as_ref())?,
            ))
        })?,
    )?;

    greed.set(
        "files",
        lua.create_function(|_, dir: Option<String>| {
            let home = std::env::var_os("HOME").map(PathBuf::from);
            Ok(files(
                Path::new(dir.as_deref().unwrap_or(".")),
                home.as_deref(),
            ))
        })?,
    )?;
    Ok(())
}

/// `greed.panel(buffer, { side, width, title, focus })`: a view beside the
/// main one. It's on the left, 30 cells wide and focused unless the spec says
/// otherwise.
fn panel_function(lua: &Lua, owner: &PluginId) -> LuaResult<Function> {
    let owner = owner.clone();
    lua.create_function(
        move |lua, (buffer, spec): (UserDataRef<BufferRef>, Option<Table>)| {
            let mut options = PanelOptions {
                side: Side::Left,
                width: Extent::Cells(30),
                title: None,
                focus: true,
            };
            if let Some(spec) = spec {
                options.side = match spec.get::<Option<String>>("side")?.as_deref() {
                    None | Some("left") => Side::Left,
                    Some("right") => Side::Right,
                    Some(other) => {
                        return Err(mlua::Error::runtime(format!(
                            "a panel's side is \"left\" or \"right\", not {other:?}"
                        )));
                    }
                };
                options.width = extent(spec.get("width")?)?.unwrap_or(options.width);
                options.title = spec.get::<Option<String>>("title")?.map(Into::into);
                options.focus = spec.get::<Option<bool>>("focus")?.unwrap_or(options.focus);
            }
            // Checked last: reading the spec can run Luau that closes it.
            buffer.with_buffer(lua, |_| Ok(()))?;
            let state = &mut *state_mut(lua);
            let id = state.editor.panel(buffer.buffer, options);
            state.owned.view(id, owner.clone());
            Ok(ViewRef {
                id,
                author: Author::Plugin(owner.clone()),
            })
        },
    )
}

/// `greed.create_buffer(kind, text, { readonly, language })`.
fn create_buffer_function(lua: &Lua, owner: &PluginId) -> LuaResult<Function> {
    let owner = owner.clone();
    lua.create_function(
        move |lua, (kind, text, opts): (String, Option<String>, Option<Table>)| {
            let (readonly, language) = match opts {
                Some(opts) => (
                    opts.get::<Option<bool>>("readonly")?.unwrap_or(false),
                    opts.get::<Option<String>>("language")?,
                ),
                None => (false, None),
            };
            let mut state = state_mut(lua);
            let buffer = state
                .editor
                .create_buffer(&kind, text.as_deref().unwrap_or_default());
            state.editor.set_readonly(buffer, readonly);
            state.editor.set_language(buffer, language.map(Into::into));
            Ok(BufferRef {
                buffer,
                view: None,
                author: Author::Plugin(owner.clone()),
            })
        },
    )
}

/// How a fuzzy query minds case, from its options' `case`: "smart" (the
/// default: only when the query has a capital letter), "ignore" or "match".
fn case_matching(opts: Option<&Table>) -> LuaResult<CaseMatching> {
    let case: Option<String> = opts.map(|o| o.get("case")).transpose()?.flatten();
    match case.as_deref() {
        None | Some("smart") => Ok(CaseMatching::Smart),
        Some("ignore") => Ok(CaseMatching::Ignore),
        Some("match") => Ok(CaseMatching::Respect),
        Some(other) => Err(mlua::Error::runtime(format!(
            "case is \"smart\", \"ignore\" or \"match\", not \"{other}\""
        ))),
    }
}

/// The byte offsets of the characters in `text` that `query` matches, in
/// order; empty if it doesn't match.
fn fuzzy_positions(query: &str, text: &str, case: CaseMatching) -> Vec<usize> {
    let mut matcher = Matcher::new(Config::DEFAULT.match_paths());
    let pattern = Pattern::parse(query, case, Normalization::Smart);
    let mut buf = Vec::new();
    let mut indices = Vec::new();
    if pattern
        .indices(Utf32Str::new(text, &mut buf), &mut matcher, &mut indices)
        .is_none()
    {
        return Vec::new();
    }
    indices.sort_unstable();
    indices.dedup();
    let offsets: Vec<usize> = text.char_indices().map(|(offset, _)| offset).collect();
    indices
        .iter()
        .filter_map(|&i| offsets.get(usize::try_from(i).ok()?).copied())
        .collect()
}

/// The 1-based indices of `items` matching `query`, best match first.
fn fuzzy(query: &str, items: &[String], case: CaseMatching) -> Vec<usize> {
    let mut matcher = Matcher::new(Config::DEFAULT.match_paths());
    let pattern = Pattern::parse(query, case, Normalization::Smart);
    let mut buf = Vec::new();
    let mut scored: Vec<(usize, u32)> = items
        .iter()
        .enumerate()
        .filter_map(|(i, item)| {
            let score = pattern.score(Utf32Str::new(item, &mut buf), &mut matcher)?;
            Some((i + 1, score))
        })
        .collect();
    scored.sort_by_key(|&(i, score)| (std::cmp::Reverse(score), i));
    scored.into_iter().map(|(i, _)| i).collect()
}

/// At most this many files are listed.
const MAX_FILES: usize = 100_000;

/// The folders of a home folder that hold no one's work, and that macOS
/// asks before letting a program read (iCloud Drive and other cloud storage
/// are under Library): finding files there takes long and pops up prompts.
const HOME_SKIPPED: [&str; 6] = [
    "Library",
    "Applications",
    "Music",
    "Movies",
    "Pictures",
    "Public",
];

/// Files under `dir`, relative to it and sorted, skipping hidden files and
/// anything `.gitignore` excludes, and when it's the `home` folder, what
/// [`HOME_SKIPPED`] names.
pub(crate) fn files(dir: &Path, home: Option<&Path>) -> Vec<String> {
    let real = |path: &Path| std::fs::canonicalize(path).ok();
    let in_home = home.is_some_and(|home| real(home).is_some_and(|home| real(dir) == Some(home)));
    let mut files: Vec<String> = ignore::WalkBuilder::new(dir)
        .require_git(false)
        .filter_entry(move |entry| {
            !(in_home
                && entry.depth() == 1
                && entry
                    .file_name()
                    .to_str()
                    .is_some_and(|name| HOME_SKIPPED.contains(&name)))
        })
        .build()
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().is_some_and(|t| t.is_file()))
        .filter_map(|entry| {
            let path = entry.path().strip_prefix(dir).ok()?;
            Some(path.to_string_lossy().into_owned())
        })
        .take(MAX_FILES)
        .collect();
    files.sort();
    files
}

const DEFAULT_FLOAT_SIZE: Extent = Extent::percent(60);

/// How a float looks when its spec leaves everything out.
pub(super) const DEFAULT_FLOAT: FloatOptions = FloatOptions {
    title: None,
    width: DEFAULT_FLOAT_SIZE,
    height: DEFAULT_FLOAT_SIZE,
    anchor: Anchor::Center,
    focus: true,
    x: None,
    y: None,
    tab: false,
    label: None,
    footer: None,
    border: true,
    hidden: false,
    shared: false,
};

/// A border label from a spec: text or styled pieces, or nil to keep
/// `base`. Empty text takes it off.
fn border_text(value: Value, base: Option<VirtualLine>) -> LuaResult<Option<VirtualLine>> {
    if value.is_nil() {
        return Ok(base);
    }
    let line = super::handles::virtual_line_from_lua(value)?;
    Ok((!line.text.is_empty()).then_some(line))
}

/// Reads `{ title, width, height, anchor, focus, x, y, tab, label, footer,
/// border, hidden, shared }` onto `base`; fields left out keep their value
/// in `base`. Sizes and places are cells, or a share of the screen as a
/// string like "60%" or "37.5%".
pub(super) fn float_options(base: FloatOptions, spec: Option<Table>) -> LuaResult<FloatOptions> {
    let Some(spec) = spec else {
        return Ok(base);
    };
    let anchor = match spec.get::<Option<String>>("anchor")?.as_deref() {
        None => base.anchor,
        Some(name) => Anchor::parse(name).ok_or_else(|| {
            let names: Vec<String> = Anchor::names().map(|n| format!("{n:?}")).collect();
            mlua::Error::runtime(format!(
                "anchor must be one of {}, not {name:?}",
                names.join(", ")
            ))
        })?,
    };
    Ok(FloatOptions {
        title: spec
            .get::<Option<String>>("title")?
            .map(Into::into)
            .or(base.title),
        width: extent(spec.get("width")?)?.unwrap_or(base.width),
        height: extent(spec.get("height")?)?.unwrap_or(base.height),
        anchor,
        focus: spec.get::<Option<bool>>("focus")?.unwrap_or(base.focus),
        x: extent(spec.get("x")?)?.or(base.x),
        y: extent(spec.get("y")?)?.or(base.y),
        tab: spec.get::<Option<bool>>("tab")?.unwrap_or(base.tab),
        label: border_text(spec.get("label")?, base.label)?,
        footer: border_text(spec.get("footer")?, base.footer)?,
        border: spec.get::<Option<bool>>("border")?.unwrap_or(base.border),
        hidden: spec.get::<Option<bool>>("hidden")?.unwrap_or(base.hidden),
        shared: spec.get::<Option<bool>>("shared")?.unwrap_or(base.shared),
    })
}

/// `greed.floats(opts)`: the floating views, the one in front last; the
/// hidden ones too with `hidden = true`.
fn floats(lua: &Lua, opts: Option<Table>) -> LuaResult<Vec<ViewRef>> {
    let hidden = match opts {
        Some(opts) => opts.get::<Option<bool>>("hidden")?.unwrap_or(false),
        None => false,
    };
    let state = state(lua);
    let author = Author::User(state.editor.client());
    let floats = if hidden {
        state.editor.floats_hidden_too()
    } else {
        state.editor.floats()
    };
    Ok(floats
        .iter()
        .map(|f| ViewRef {
            id: f.view,
            author: author.clone(),
        })
        .collect())
}

/// `options` as a spec `greed.float` and `view:configure` take.
pub(super) fn float_spec(lua: &Lua, options: &FloatOptions) -> LuaResult<Table> {
    let to_lua = |extent: Extent| -> LuaResult<Value> {
        match extent {
            Extent::Cells(n) => Ok(Value::Integer(n.into())),
            Extent::Share(share) => lua.create_string(share_text(share)).map(Value::String),
        }
    };
    let spec = lua.create_table()?;
    spec.set("title", options.title.as_deref())?;
    spec.set("width", to_lua(options.width)?)?;
    spec.set("height", to_lua(options.height)?)?;
    spec.set("anchor", options.anchor.name())?;
    spec.set("focus", options.focus)?;
    spec.set("tab", options.tab)?;
    spec.set("border", options.border)?;
    spec.set("hidden", options.hidden)?;
    spec.set("shared", options.shared)?;
    for (key, text) in [("label", &options.label), ("footer", &options.footer)] {
        if let Some(text) = text {
            spec.set(key, super::handles::virtual_line_to_lua(lua, text)?)?;
        }
    }
    if let Some(x) = options.x {
        spec.set("x", to_lua(x)?)?;
    }
    if let Some(y) = options.y {
        spec.set("y", to_lua(y)?)?;
    }
    Ok(spec)
}

/// A share of the screen, in hundredths of a percent, as Luau writes it:
/// "60%", "37.5%", "33.33%".
fn share_text(share: u16) -> String {
    let (whole, part) = (share / 100, share % 100);
    match part {
        0 => format!("{whole}%"),
        _ if part % 10 == 0 => format!("{whole}.{}%", part / 10),
        _ => format!("{whole}.{part:02}%"),
    }
}

/// A share of the screen written like "37.5%", in hundredths of a percent,
/// to two decimals; more than 100% is all of it.
fn parse_share(text: &str) -> Option<u16> {
    let percent: f64 = text.strip_suffix('%')?.trim().parse().ok()?;
    if percent.is_nan() || percent < 0.0 {
        return None;
    }
    let percent = percent.min(100.0);
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "between 0 and 10000"
    )]
    Some((percent * 100.0).round() as u16)
}

/// A size or a place: a number of cells, or a string like "60%".
fn extent(value: Value) -> LuaResult<Option<Extent>> {
    const SAY: &str = "sizes and places are a number of cells or a share of the screen, \
                       a string like \"60%\" or \"37.5%\"";
    match value {
        Value::Nil => Ok(None),
        Value::Integer(n) => Ok(Some(Extent::Cells(u16::try_from(n).unwrap_or(u16::MAX)))),
        Value::Number(n) if n >= 0.0 =>
        {
            #[expect(
                clippy::cast_possible_truncation,
                clippy::cast_sign_loss,
                reason = "clamped below"
            )]
            Ok(Some(Extent::Cells(n.min(f64::from(u16::MAX)) as u16)))
        }
        Value::String(s) => parse_share(&s.to_str()?)
            .map(|share| Some(Extent::Share(share)))
            .ok_or_else(|| mlua::Error::runtime(SAY)),
        other => Err(mlua::Error::runtime(format!(
            "{SAY}, not {}",
            other.type_name()
        ))),
    }
}

/// Calls the plugin's status line function, if one is set. It gets
/// `{ view, buffer, mode, message, width }` for the view it's about (see
/// [`crate::Editor::status_view`]) and returns `{ left = segments, right =
/// segments }`, where a segment is a string or `{ text = ..., style =
/// "mode" | "message" | "status" }`.
pub(super) fn status_line(
    lua: &Lua,
    message: Option<&str>,
    width: u16,
) -> LuaResult<Option<StatusLine>> {
    let (build, owner, view, buffer, mode, author) = {
        let state = state(lua);
        let Some((owner, build)) = &state.statusline else {
            return Ok(None);
        };
        let view = state.editor.status_view();
        (
            build.clone(),
            owner.clone(),
            view,
            state.editor.view(view).buffer,
            state.editor.mode().to_owned(),
            Author::Plugin(owner.clone()),
        )
    };
    let ctx = lua.create_table()?;
    ctx.set(
        "view",
        ViewRef {
            id: view,
            author: author.clone(),
        },
    )?;
    ctx.set(
        "buffer",
        BufferRef {
            buffer,
            view: Some(view),
            author,
        },
    )?;
    ctx.set("mode", mode)?;
    ctx.set(
        "message",
        message.map(|m| crate::render::status_message(m).into_owned()),
    )?;
    ctx.set("width", width)?;
    let line: Table =
        super::capabilities::running_as(lua, Some(&owner), "the status line", || build.call(ctx))?;
    let mut actions = Vec::new();
    let left = segments(line.get("left")?, &mut actions)?;
    let right = segments(line.get("right")?, &mut actions)?;
    if actions.iter().all(Option::is_none) {
        actions.clear();
    }
    Ok(Some(StatusLine {
        left,
        right,
        actions,
    }))
}

/// The spans of a side of the status line, adding each one's action to
/// `actions`.
fn segments(list: Option<Table>, actions: &mut Vec<Option<Arc<str>>>) -> LuaResult<Vec<Span>> {
    let Some(list) = list else {
        return Ok(Vec::new());
    };
    list.sequence_values::<Value>()
        .map(|segment| {
            let (text, style, action) = match segment? {
                Value::String(s) => (s.to_str()?.to_owned(), None, None),
                Value::Table(t) => (
                    t.get::<String>("text")?,
                    t.get::<Option<String>>("style")?,
                    t.get::<Option<String>>("action")?,
                ),
                other => {
                    return Err(mlua::Error::runtime(format!(
                        "status line segments are strings or {{ text = ..., style = ... }}, not {}",
                        other.type_name()
                    )));
                }
            };
            actions.push(action.map(Into::into));
            let mut tags = smallvec::smallvec![Tag::STATUS];
            if let Some(style) = style {
                tags.push(Tag::from(style.as_str()));
            }
            Ok(Span::new(text, tags))
        })
        .collect()
}

/// `greed.spawn(f, ...)`: runs `f` as a coroutine of `owner`'s, so it can
/// wait, and returns at once. It runs within what the code starting it may.
fn spawn_function(lua: &Lua, owner: &PluginId) -> LuaResult<Function> {
    let owner = owner.clone();
    lua.create_function(move |lua, (f, args): (Function, mlua::MultiValue)| {
        let limit = capabilities::inherited(lua, &owner);
        tasks::spawn_running(lua, f, args, owner.clone(), None, limit).map(|_| ())
    })
}

/// `greed.load(path)`: the buffer for a file, opened without being shown.
fn load_function(lua: &Lua, owner: &PluginId) -> LuaResult<Function> {
    let owner = owner.clone();
    lua.create_function(move |lua, UserPath(path): UserPath| {
        super::secrets::guard(lua, Path::new(&path))?;
        let buffer = state_mut(lua)
            .editor
            .open_file(Path::new(&path))
            .map_err(|err| mlua::Error::runtime(format!("can't open {path}: {err}")))?;
        Ok(BufferRef {
            buffer,
            view: None,
            author: Author::Plugin(owner.clone()),
        })
    })
}

/// `greed.line_numbers(style)`: how line numbers count.
fn line_numbers_function(lua: &Lua) -> LuaResult<Function> {
    lua.create_function(|lua, style: String| {
        let style = match style.as_str() {
            "absolute" => LineNumbers::Absolute,
            "relative" => LineNumbers::Relative,
            "hybrid" => LineNumbers::Hybrid,
            other => {
                return Err(mlua::Error::runtime(format!(
                    "line numbers are \"absolute\", \"relative\" or \"hybrid\", not {other:?}"
                )));
            }
        };
        state_mut(lua).editor.set_line_numbers_style(style);
        Ok(())
    })
}

/// `greed.reveal(how)`: when marks with `reveal = "auto"` show what they
/// hide.
fn reveal_function(lua: &Lua) -> LuaResult<Function> {
    lua.create_function(|lua, how: String| {
        let reveal = match how.as_str() {
            "line" => crate::Reveal::Line,
            "cursor" => crate::Reveal::Cursor,
            "never" => crate::Reveal::Never,
            other => {
                return Err(mlua::Error::runtime(format!(
                    "reveal is \"line\", \"cursor\" or \"never\", not {other:?}"
                )));
            }
        };
        state_mut(lua).editor.set_reveal(reveal);
        Ok(())
    })
}

/// `greed.quit`, which tells plugins with "editor.quitting" first.
fn quit_function(lua: &Lua) -> LuaResult<Function> {
    lua.create_function(|lua, ()| {
        emit(lua, "editor.quitting", &lua.create_table()?)?;
        state_mut(lua).editor.request_quit();
        Ok(())
    })
}

/// `greed.keys`: recording what's typed and feeding keys back, for macros.
/// What fed keys run is limited to what `owner` may do; see
/// [`capabilities::limit_for`].
fn keys_module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let keys = lua.create_table()?;
    keys.set(
        "record",
        lua.create_function(|lua, (name, opts): (Option<String>, Option<Table>)| {
            let fed = match opts {
                Some(opts) => opts.get::<Option<bool>>("fed")?.unwrap_or(false),
                None => false,
            };
            let state = &mut *state_mut(lua);
            let client = state.editor.client();
            state.recording.entry(client).or_default().insert(
                name.unwrap_or_default(),
                Recording {
                    keys: Vec::new(),
                    fed,
                },
            );
            Ok(())
        })?,
    )?;
    keys.set(
        "stop",
        lua.create_function(|lua, name: Option<String>| {
            let state = &mut *state_mut(lua);
            let client = state.editor.client();
            Ok(state
                .recording
                .get_mut(&client)
                .and_then(|r| r.remove(&name.unwrap_or_default()))
                .map(|r| r.keys.iter().map(ToString::to_string).collect::<Vec<_>>()))
        })?,
    )?;
    keys.set(
        "recording",
        lua.create_function(|lua, name: Option<String>| {
            let state = state(lua);
            let client = state.editor.client();
            Ok(state
                .recording
                .get(&client)
                .is_some_and(|r| r.contains_key(&name.unwrap_or_default())))
        })?,
    )?;
    let owner = owner.clone();
    keys.set(
        "feed",
        lua.create_function(move |lua, sequence: String| {
            let limit = capabilities::limit_for(lua, &owner);
            for key in Key::parse_sequence(&sequence).map_err(mlua::Error::external)? {
                {
                    let state = &mut *state_mut(lua);
                    let client = state.editor.client();
                    let recordings = state.recording.get_mut(&client).into_iter();
                    for recording in recordings.flat_map(HashMap::values_mut) {
                        if recording.fed {
                            recording.keys.push(key);
                        }
                    }
                }
                press_key(lua, key, Some(limit.clone())).map_err(into_lua)?;
                // A command a key started that ran out of time and yielded
                // finishes before the next key, which may count on it, as a
                // macro's keys do.
                while tasks::resume_sliced(lua)? {}
            }
            Ok(())
        })?,
    )?;
    Ok(keys)
}

/// `greed.open`: shows the file at `path` in the main view, opening it if it
/// isn't open, and tells plugins with "buffer.opened".
pub(super) fn open_file(lua: &Lua, path: &str) -> LuaResult<()> {
    let mut state = state_mut(lua);
    let buffer = state
        .editor
        .open_file(Path::new(path))
        .map_err(|err| mlua::Error::runtime(format!("can't open {path}: {err}")))?;
    let main = state.editor.main();
    state.editor.show(main, buffer);
    state.editor.set_focus(main);
    let author = Author::User(state.editor.client());
    drop(state);
    let payload = lua.create_table()?;
    payload.set(
        "buffer",
        BufferRef {
            buffer,
            view: None,
            author,
        },
    )?;
    emit(lua, "buffer.opened", &payload)
}

/// `greed.run(name, opts)`: starts a command; with `wait`, a command or
/// handler waits until it has finished. It runs within what `owner` may do;
/// see [`capabilities::limit_for`].
fn run_function(lua: &Lua, owner: &PluginId) -> LuaResult<Function> {
    let owner = owner.clone();
    // Returns a token to yield until the command finishes, when it's asked
    // to wait and the command is still running.
    let start = lua.create_function(move |lua, (name, opts): (String, Option<Table>)| {
        let limit = Some(capabilities::limit_for(lua, &owner));
        let (how, wait) = match opts {
            Some(opts) => (
                Invocation {
                    args: opts.get::<Option<Vec<String>>>("args")?.unwrap_or_default(),
                    force: opts.get::<Option<bool>>("force")?.unwrap_or(false),
                    count: opts.get("count")?,
                    ..Invocation::default()
                },
                opts.get::<Option<bool>>("wait")?.unwrap_or(false),
            ),
            None => (Invocation::default(), false),
        };
        let how = Invocation { limit, ..how };
        let running = invoke_running(lua, &name, how).map_err(into_lua)?;
        Ok(running.filter(|_| wait).map(|id| tasks::wait_for(lua, id)))
    })?;
    lua.load(
        r"
        local start = ...
        return function(name, opts)
            local token = start(name, opts)
            -- Outside a command or handler there's nothing to wait in.
            if token and coroutine.isyieldable() then
                coroutine.yield(token)
            end
        end
        ",
    )
    .set_name("=greed.run")
    .call(start)
}

/// `greed.keymap.overlay(bindings)`: binds single keys for the next key
/// press only, or drops such bindings with nil.
fn set_overlay(lua: &Lua, bindings: Option<HashMap<String, String>>) -> LuaResult<()> {
    let overlay = bindings.map(single_keys).transpose()?;
    state_mut(lua).editor.set_overlay(overlay);
    Ok(())
}

/// Bindings of single keys, like `{ y = "yes" }`, parsed.
pub(super) fn single_keys(bindings: HashMap<String, String>) -> LuaResult<HashMap<Key, Arc<str>>> {
    bindings
        .into_iter()
        .map(|(key, command)| {
            Key::parse(&key)
                .map(|key| (key, Arc::<str>::from(command)))
                .map_err(mlua::Error::external)
        })
        .collect()
}

/// Sets `source` (`"file:line"`), and `path` and `line` when the file is on
/// disk, on `entry`, for what a plugin defined.
fn set_source(
    entry: &Table,
    sources: &HashMap<String, PathBuf>,
    source: Option<&Source>,
) -> LuaResult<()> {
    let Some(source) = source else {
        return Ok(());
    };
    entry.set("source", format!("{}:{}", source.file, source.line))?;
    if let Some(path) = sources.get(&*source.file) {
        entry.set("path", path.to_string_lossy().as_ref())?;
        entry.set("line", source.line)?;
    }
    Ok(())
}

/// `greed.handlers()`: every event handler, by event and then the order
/// they were added, with the plugin that added it and where.
fn handlers(lua: &Lua, (): ()) -> LuaResult<Table> {
    let state = state(lua);
    let mut events: Vec<_> = state.registry.events().collect();
    events.sort_by_key(|(event, _)| *event);
    let list = lua.create_table()?;
    for (event, handlers) in events {
        for handler in handlers {
            let entry = lua.create_table()?;
            entry.set("event", event)?;
            entry.set("owner", &*handler.owner)?;
            set_source(&entry, &state.sources, handler.source.as_ref())?;
            list.push(entry)?;
        }
    }
    Ok(list)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn files_in_the_home_folder_leave_out_its_library_and_media_but_not_elsewhere() {
        let home = std::env::temp_dir().join(format!("greed-files-home-{}", std::process::id()));
        for path in [
            "notes.md",
            "code/main.rs",
            "Library/Mobile Documents/x.txt",
            "Music/a.mp3",
        ] {
            let path = home.join(path);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, "").unwrap();
        }
        assert_eq!(files(&home, Some(&home)), ["code/main.rs", "notes.md"]);
        // Anywhere else, a folder called Library is a folder like any other.
        let elsewhere = files(&home, None);
        assert!(
            elsewhere.contains(&"Music/a.mp3".to_owned()),
            "{elsewhere:?}"
        );
        assert!(elsewhere.contains(&"Library/Mobile Documents/x.txt".to_owned()));
        std::fs::remove_dir_all(&home).unwrap();
    }
}
