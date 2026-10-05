//! The `greed` module plugins get from `require("@greed")`, and running
//! commands and emitting events.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use greed_text::Author;
use mlua::{Function, Lua, Table, UserDataRef, Value, Variadic};
use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32Str};

use super::handles::{self, BufferRef, ViewRef};
use super::tasks;
use super::{HostError, state, state_mut};
use crate::keymap::{Key, KeyCode, Layer, Mods, Next, Resolution};
use crate::registry::{Arg, Command, OptionDef, PluginId, Source, Value as OptionValue};
use crate::render::{Menu, MenuItem, Span, StatusLine, Tag};
use crate::{Anchor, CursorShape, Extent, FloatOptions, KeyOutcome, PanelOptions, Side};

type LuaResult<T> = mlua::Result<T>;

/// Runs a command as the user.
pub(super) fn run_command(lua: &Lua, name: &str) -> Result<(), HostError> {
    invoke(lua, name, Invocation::default())
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
    } = how;
    let (handler, owner, author, view, buffer) = {
        let state = state(lua);
        let command = state
            .registry
            .command(name)
            .ok_or_else(|| HostError::UnknownCommand(name.into()))?;
        let author = Author::User(state.editor.client());
        let view = state.editor.focus();
        (
            command.handler.clone(),
            command.owner.clone(),
            author,
            view,
            state.editor.view(view).buffer,
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
    emit(lua, "command.run", &event)?;
    Ok(tasks::spawn_running(
        lua,
        handler,
        ctx,
        owner,
        Some(name.into()),
    )?)
}

/// A key typed by the user: kept if keys are being recorded, then fed
/// through the keymap.
pub(super) fn press(lua: &Lua, key: Key) -> Result<(), HostError> {
    for recording in state_mut(lua).recording.values_mut() {
        recording.keys.push(key);
    }
    press_key(lua, key)
}

/// The keys a `greed.keys.record` keeps.
pub(crate) struct Recording {
    keys: Vec<Key>,
    /// Whether it keeps keys fed by `greed.keys.feed` too, like a macro's.
    fed: bool,
}

/// Feeds one key press through the keymap, running whatever it resolves
/// to, without recording it.
fn press_key(lua: &Lua, key: Key) -> Result<(), HostError> {
    // A command waiting on greed.next_key gets the key instead of the keymap.
    let waiter = state_mut(lua).key_waiter.take();
    if let Some(token) = waiter {
        tasks::wake(lua, token, key.to_string())?;
        return Ok(());
    }
    let outcome = state_mut(lua).editor.press(key);
    match outcome {
        KeyOutcome::Pending => {
            let pending = keys_text(state(lua).editor.pending());
            keys_pending(lua, &pending)?;
            Ok(())
        }
        KeyOutcome::Command { name, keys, count } => {
            if keys.len() > 1 {
                keys_pending(lua, "")?;
            }
            invoke(
                lua,
                &name,
                Invocation {
                    keys: &keys,
                    count,
                    ..Invocation::default()
                },
            )
        }
        KeyOutcome::Unbound(keys) => {
            if keys.len() > 1 {
                keys_pending(lua, "")?;
            }
            Ok(())
        }
    }
}

/// Emits "keys.pending" with the unfinished key sequence, or "" once it ends.
fn keys_pending(lua: &Lua, keys: &str) -> LuaResult<()> {
    let payload = lua.create_table()?;
    payload.set("keys", keys)?;
    emit(lua, "keys.pending", &payload)
}

fn keys_text(keys: &[Key]) -> String {
    keys.iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(" ")
}

/// Calls every handler for `event` with `payload`. All handlers run even if
/// one fails; the first error is returned.
pub(super) fn emit(lua: &Lua, event: &str, payload: &Table) -> LuaResult<()> {
    let handlers: Vec<(Function, PluginId)> = state(lua)
        .registry
        .handlers(event)
        .iter()
        .map(|h| (h.handler.clone(), h.owner.clone()))
        .collect();
    let mut first_error = None;
    for (handler, owner) in handlers {
        if let Err(err) = tasks::spawn(lua, handler, payload.clone(), owner, None) {
            first_error.get_or_insert(err);
        }
    }
    first_error.map_or(Ok(()), Err)
}

pub(super) fn greed_module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let greed = lua.create_table()?;

    greed.set("cli", super::cli::function(lua, owner)?)?;

    let o = owner.clone();
    greed.set(
        "command",
        lua.create_function(move |lua, spec: Table| {
            let command = Command {
                name: spec.get::<String>("name")?.into(),
                doc: spec
                    .get::<Option<String>>("doc")?
                    .unwrap_or_default()
                    .into(),
                args: command_args(spec.get("args")?)?,
                owner: o.clone(),
                source: caller(lua),
                handler: spec.get::<Function>("run")?,
            };
            state_mut(lua).registry.add_command(command);
            Ok(())
        })?,
    )?;

    greed.set("run", run_function(lua)?)?;

    let o = owner.clone();
    greed.set(
        "on",
        lua.create_function(move |lua, (event, handler): (String, Function)| {
            let source = caller(lua);
            state_mut(lua)
                .registry
                .on(event, o.clone(), source, handler);
            Ok(())
        })?,
    )?;

    greed.set(
        "echo",
        lua.create_function(|lua, parts: Variadic<Value>| {
            let text: Vec<String> = parts.iter().map(display).collect();
            state_mut(lua).editor.echo(text.join(" "));
            Ok(())
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
    greed.set("now", now)?;
    greed.set("next_key", tasks::next_key_function(lua)?)?;

    greed.set("quit", quit_function(lua)?)?;

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
                super::eval_repl(lua, &source)
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

    greed.set("set_menus", menus_function(lua)?)?;

    workspace_functions(lua, &greed, owner)?;
    submodules(lua, &greed, owner)?;
    Ok(greed)
}

/// `greed.set_menus(menus)`: the menus a window shows as its menu bar.
fn menus_function(lua: &Lua) -> LuaResult<Function> {
    lua.create_function(|lua, list: Vec<Table>| {
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
        state_mut(lua).editor.set_menus(menus);
        Ok(())
    })
}

/// `greed.keymap`, `greed.mode` and the other tables in `greed`.
fn submodules(lua: &Lua, greed: &Table, owner: &PluginId) -> LuaResult<()> {
    greed.set("keymap", keymap_module(lua, owner)?)?;
    greed.set("mode", mode_module(lua)?)?;
    greed.set("option", option_module(lua, owner)?)?;
    greed.set("history", history_module(lua)?)?;
    greed.set("clipboard", clipboard_module(lua)?)?;
    greed.set("lsp", super::lsp::module(lua, owner)?)?;
    greed.set("fs", super::fs::module(lua)?)?;
    greed.set("control", super::requests::module(lua)?)?;
    greed.set("json", super::json::module(lua)?)?;
    greed.set("project", super::projects::module(lua)?)?;
    greed.set("tab", super::tabs::module(lua, owner)?)?;
    greed.set("session", super::sessions::module(lua)?)?;
    greed.set("keys", keys_module(lua)?)?;
    greed.set("process", super::process::module(lua, owner)?)?;
    greed.set("http", super::http::module(lua, owner)?)?;
    greed.set("secrets", super::secrets::module(lua, owner)?)?;
    greed.set("terminal", super::terminal::module(lua, owner)?)?;
    greed.set("image", super::images::module(lua)?)?;
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
    super::languages::register(lua, greed)?;
    greed.set("plugin", super::plugin::module(lua)?)?;
    greed.set("syntax", super::syntax::module(lua, owner)?)?;
    greed.set("theme", super::theme::module(lua, owner)?)
}

/// A mode name, or `{ mode = ..., kind = ... }`.
fn layer_from_lua(layer: Value) -> LuaResult<Layer> {
    match layer {
        Value::String(mode) => Ok(Layer::mode(&mode.to_str()?)),
        Value::Table(t) => Ok(Layer {
            mode: t.get::<Option<String>>("mode")?.map(Into::into),
            kind: t.get::<Option<String>>("kind")?.map(Into::into),
        }),
        other => Err(mlua::Error::runtime(format!(
            "keymap layer must be a mode name or {{ mode = ..., kind = ... }}, not {}",
            other.type_name()
        ))),
    }
}

/// `greed.keymap.unbind`, `greed.keymap.clear`, `greed.keymap.counts` and
/// `greed.keymap.inherit`.
fn unbinding_functions(lua: &Lua, keymap: &Table, owner: &PluginId) -> LuaResult<()> {
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
        "inherit_kinds",
        lua.create_function(move |lua, (mode, parent): (String, String)| {
            state_mut(lua)
                .editor
                .keymap_mut()
                .inherit_kinds(&mode, &parent, o.clone());
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
            move |lua, (mode, parent, prefixes): (String, String, Option<Vec<String>>)| {
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

fn keymap_module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let keymap = lua.create_table()?;

    let o = owner.clone();
    keymap.set(
        "bind",
        lua.create_function(move |lua, (layer, map): (Value, Table)| {
            let layer = layer_from_lua(layer)?;
            let mut state = state_mut(lua);
            for pair in map.pairs::<String, String>() {
                let (keys, command) = pair?;
                let parsed = Key::parse_sequence(&keys).map_err(mlua::Error::external)?;
                state
                    .editor
                    .keymap_mut()
                    .bind(layer.clone(), &parsed, command, o.clone())
                    .map_err(mlua::Error::external)?;
            }
            Ok(())
        })?,
    )?;

    unbinding_functions(lua, &keymap, owner)?;

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
    Ok(keymap)
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
            emit(lua, "mode.changed", &payload)
        })?,
    )?;
    mode.set(
        "cursor",
        lua.create_function(|lua, (name, shape): (String, String)| {
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
        })?,
    )?;
    mode.set(
        "shape",
        lua.create_function(|lua, name: Option<String>| {
            let state = state(lua);
            let editor = &state.editor;
            Ok(
                match editor.cursor_shape_of(name.as_deref().unwrap_or(editor.mode())) {
                    CursorShape::Block => "block",
                    CursorShape::Bar => "bar",
                    CursorShape::Underline => "underline",
                },
            )
        })?,
    )?;
    Ok(mode)
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
    Ok(clipboard)
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
        lua.create_function(move |lua, spec: Table| {
            let def = OptionDef {
                name: spec.get::<String>("name")?.into(),
                doc: spec
                    .get::<Option<String>>("doc")?
                    .unwrap_or_default()
                    .into(),
                owner: o.clone(),
                source: caller(lua),
                default: option_value(spec.get("default")?)?,
            };
            state_mut(lua).registry.define_option(def);
            Ok(())
        })?,
    )?;
    option.set(
        "get",
        lua.create_function(|lua, name: String| {
            let value = state(lua).registry.option(&name).cloned();
            value.map(|v| option_to_lua(lua, v)).transpose()
        })?,
    )?;
    option.set(
        "set",
        lua.create_function(|lua, (name, value): (String, Value)| {
            {
                let state = &mut *state_mut(lua);
                let by = state.running.clone();
                state
                    .registry
                    .set_option_by(&name, option_value(value.clone())?, by)
                    .map_err(mlua::Error::external)?;
            }
            let payload = lua.create_table()?;
            payload.set("name", name)?;
            payload.set("value", value)?;
            emit(lua, "option.changed", &payload)
        })?,
    )?;
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
                entry.set("value", option_to_lua(lua, option.value.clone())?)?;
                entry.set("default", option_to_lua(lua, option.def.default.clone())?)?;
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

/// Buffers, floating views, files and commands: what pickers and other UI
/// plugins are built from.
fn workspace_functions(lua: &Lua, greed: &Table, owner: &PluginId) -> LuaResult<()> {
    greed.set("create_buffer", create_buffer_function(lua, owner)?)?;
    greed.set("panel", panel_function(lua, owner)?)?;
    greed.set("floats", lua.create_function(|lua, ()| Ok(floats(lua)))?)?;

    let o = owner.clone();
    greed.set(
        "float",
        lua.create_function(
            move |lua, (buffer, spec): (UserDataRef<BufferRef>, Option<Table>)| {
                let options = float_options(DEFAULT_FLOAT, spec)?;
                buffer.with_buffer(lua, |_| Ok(()))?;
                Ok(ViewRef {
                    id: state_mut(lua).editor.float(buffer.buffer, options),
                    author: Author::Plugin(o.clone()),
                })
            },
        )?,
    )?;

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
    greed.set("load", load_function(lua, owner)?)?;

    greed.set(
        "open",
        lua.create_function(|lua, path: String| {
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
        lua.create_function(|_, (query, items): (String, Vec<String>)| Ok(fuzzy(&query, &items)))?,
    )?;
    greed.set(
        "fuzzy_positions",
        lua.create_function(|_, (query, text): (String, String)| {
            Ok(fuzzy_positions(&query, &text))
        })?,
    )?;

    greed.set(
        "files",
        lua.create_function(|_, dir: Option<String>| {
            Ok(files(Path::new(dir.as_deref().unwrap_or("."))))
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
            buffer.with_buffer(lua, |_| Ok(()))?;
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
            Ok(ViewRef {
                id: state_mut(lua).editor.panel(buffer.buffer, options),
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

/// The byte offsets of the characters in `text` that `query` matches, in
/// order; empty if it doesn't match.
fn fuzzy_positions(query: &str, text: &str) -> Vec<usize> {
    let mut matcher = Matcher::new(Config::DEFAULT.match_paths());
    let pattern = Pattern::parse(query, CaseMatching::Smart, Normalization::Smart);
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
fn fuzzy(query: &str, items: &[String]) -> Vec<usize> {
    let mut matcher = Matcher::new(Config::DEFAULT.match_paths());
    let pattern = Pattern::parse(query, CaseMatching::Smart, Normalization::Smart);
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

/// Files under `dir`, relative to it and sorted, skipping hidden files and
/// anything `.gitignore` excludes.
fn files(dir: &Path) -> Vec<String> {
    let mut files: Vec<String> = ignore::WalkBuilder::new(dir)
        .require_git(false)
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

const DEFAULT_FLOAT_SIZE: Extent = Extent::Percent(60);

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
};

/// Reads `{ title, width, height, anchor, focus, x, y }` onto `base`;
/// fields left out keep their value in `base`. Sizes are cells, or a string
/// like "60%".
pub(super) fn float_options(base: FloatOptions, spec: Option<Table>) -> LuaResult<FloatOptions> {
    let Some(spec) = spec else {
        return Ok(base);
    };
    let anchor = match spec.get::<Option<String>>("anchor")?.as_deref() {
        None => base.anchor,
        Some("center") => Anchor::Center,
        Some("top") => Anchor::Top,
        Some("bottom") => Anchor::Bottom,
        Some("cursor") => Anchor::Cursor,
        Some("above-cursor") => Anchor::AboveCursor,
        Some(other) => {
            return Err(mlua::Error::runtime(format!(
                "anchor must be \"center\", \"top\", \"bottom\", \"cursor\" or \"above-cursor\", not {other:?}"
            )));
        }
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
    })
}

/// `greed.floats()`: the floating views, the one in front last.
fn floats(lua: &Lua) -> Vec<ViewRef> {
    let state = state(lua);
    let author = Author::User(state.editor.client());
    state
        .editor
        .floats()
        .iter()
        .map(|f| ViewRef {
            id: f.view,
            author: author.clone(),
        })
        .collect()
}

/// `options` as a spec `greed.float` and `view:configure` take.
pub(super) fn float_spec(lua: &Lua, options: &FloatOptions) -> LuaResult<Table> {
    let to_lua = |extent: Extent| -> LuaResult<Value> {
        match extent {
            Extent::Cells(n) => Ok(Value::Integer(n.into())),
            Extent::Percent(p) => lua.create_string(format!("{p}%")).map(Value::String),
        }
    };
    let spec = lua.create_table()?;
    spec.set("title", options.title.as_deref())?;
    spec.set("width", to_lua(options.width)?)?;
    spec.set("height", to_lua(options.height)?)?;
    spec.set(
        "anchor",
        match options.anchor {
            Anchor::Center => "center",
            Anchor::Top => "top",
            Anchor::Bottom => "bottom",
            Anchor::Cursor => "cursor",
            Anchor::AboveCursor => "above-cursor",
        },
    )?;
    spec.set("focus", options.focus)?;
    spec.set("tab", options.tab)?;
    if let Some(x) = options.x {
        spec.set("x", to_lua(x)?)?;
    }
    if let Some(y) = options.y {
        spec.set("y", to_lua(y)?)?;
    }
    Ok(spec)
}

/// A size: a number of cells, or a string like "60%".
fn extent(value: Value) -> LuaResult<Option<Extent>> {
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
        Value::String(s) => s
            .to_str()?
            .strip_suffix('%')
            .and_then(|p| p.trim().parse().ok())
            .map(|p| Some(Extent::Percent(p)))
            .ok_or_else(|| {
                mlua::Error::runtime("sizes are a number of cells or a string like \"60%\"")
            }),
        other => Err(mlua::Error::runtime(format!(
            "sizes are a number of cells or a string like \"60%\", not {}",
            other.type_name()
        ))),
    }
}

/// Calls the plugin's status line function, if one is set. It gets
/// `{ view, buffer, mode, message, width }` for the main view and returns
/// `{ left = segments, right = segments }`, where a segment is a string or
/// `{ text = ..., style = "mode" | "message" | "status" }`.
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
        let view = state.editor.main();
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
    ctx.set("message", message)?;
    ctx.set("width", width)?;
    let line: Table =
        super::capabilities::running_as(lua, Some(&owner), "the status line", || build.call(ctx))?;
    Ok(Some(StatusLine {
        left: segments(line.get("left")?)?,
        right: segments(line.get("right")?)?,
    }))
}

fn segments(list: Option<Table>) -> LuaResult<Vec<Span>> {
    let Some(list) = list else {
        return Ok(Vec::new());
    };
    list.sequence_values::<Value>()
        .map(|segment| {
            let (text, style) = match segment? {
                Value::String(s) => (s.to_str()?.to_owned(), None),
                Value::Table(t) => (t.get::<String>("text")?, t.get::<Option<String>>("style")?),
                other => {
                    return Err(mlua::Error::runtime(format!(
                        "status line segments are strings or {{ text = ..., style = ... }}, not {}",
                        other.type_name()
                    )));
                }
            };
            let mut tags = smallvec::smallvec![Tag::STATUS];
            if let Some(style) = style {
                tags.push(Tag::from(style.as_str()));
            }
            Ok(Span::new(text, tags))
        })
        .collect()
}

/// `greed.spawn(f, ...)`: runs `f` as a coroutine of `owner`'s, so it can
/// wait, and returns at once.
fn spawn_function(lua: &Lua, owner: &PluginId) -> LuaResult<Function> {
    let owner = owner.clone();
    lua.create_function(move |lua, (f, args): (Function, mlua::MultiValue)| {
        tasks::spawn(lua, f, args, owner.clone(), None)
    })
}

/// `greed.load(path)`: the buffer for a file, opened without being shown.
fn load_function(lua: &Lua, owner: &PluginId) -> LuaResult<Function> {
    let owner = owner.clone();
    lua.create_function(move |lua, path: String| {
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

/// `greed.quit`, which tells plugins with "editor.quitting" first.
fn quit_function(lua: &Lua) -> LuaResult<Function> {
    lua.create_function(|lua, ()| {
        emit(lua, "editor.quitting", &lua.create_table()?)?;
        state_mut(lua).editor.request_quit();
        Ok(())
    })
}

/// `greed.keys`: recording what's typed and feeding keys back, for macros.
fn keys_module(lua: &Lua) -> LuaResult<Table> {
    let keys = lua.create_table()?;
    keys.set(
        "record",
        lua.create_function(|lua, (name, opts): (Option<String>, Option<Table>)| {
            let fed = match opts {
                Some(opts) => opts.get::<Option<bool>>("fed")?.unwrap_or(false),
                None => false,
            };
            state_mut(lua).recording.insert(
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
            Ok(state_mut(lua)
                .recording
                .remove(&name.unwrap_or_default())
                .map(|r| r.keys.iter().map(ToString::to_string).collect::<Vec<_>>()))
        })?,
    )?;
    keys.set(
        "recording",
        lua.create_function(|lua, name: Option<String>| {
            Ok(state(lua).recording.contains_key(&name.unwrap_or_default()))
        })?,
    )?;
    keys.set(
        "feed",
        lua.create_function(|lua, sequence: String| {
            for key in Key::parse_sequence(&sequence).map_err(mlua::Error::external)? {
                for recording in state_mut(lua).recording.values_mut() {
                    if recording.fed {
                        recording.keys.push(key);
                    }
                }
                press_key(lua, key).map_err(into_lua)?;
            }
            Ok(())
        })?,
    )?;
    Ok(keys)
}

/// `greed.open`: shows the file at `path` in the main view, opening it if it
/// isn't open, and tells plugins with "buffer.opened".
fn open_file(lua: &Lua, path: &str) -> LuaResult<()> {
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
/// handler waits until it has finished.
fn run_function(lua: &Lua) -> LuaResult<Function> {
    // Returns a token to yield until the command finishes, when it's asked
    // to wait and the command is still running.
    let start = lua.create_function(|lua, (name, opts): (String, Option<Table>)| {
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
    let overlay = bindings
        .map(|bindings| {
            bindings
                .into_iter()
                .map(|(key, command)| {
                    Key::parse(&key)
                        .map(|key| (key, Arc::<str>::from(command)))
                        .map_err(mlua::Error::external)
                })
                .collect::<LuaResult<HashMap<_, _>>>()
        })
        .transpose()?;
    state_mut(lua).editor.set_overlay(overlay);
    Ok(())
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
