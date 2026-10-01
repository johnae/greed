//! The `kern` module plugins get from `require("@kern")`, and running
//! commands and emitting events.

use std::path::Path;
use std::sync::Arc;

use kern_text::Author;
use mlua::{Function, Lua, Table, UserDataRef, Value, Variadic};
use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32Str};

use super::handles::{BufferRef, ViewRef};
use super::{HostError, state, state_mut};
use crate::keymap::{Key, KeyCode, Layer, Mods};
use crate::registry::{Command, OptionDef, PluginId, Source, Value as OptionValue};
use crate::{Anchor, Extent, FloatOptions, KeyOutcome};

type LuaResult<T> = mlua::Result<T>;

/// Runs a command as the user, with `keys` as the sequence that triggered
/// it.
pub(super) fn run_command(lua: &Lua, name: &str, keys: &[Key]) -> Result<(), HostError> {
    let (handler, author, view, buffer) = {
        let state = state(lua);
        let command = state
            .registry
            .command(name)
            .ok_or_else(|| HostError::UnknownCommand(name.into()))?;
        let author = Author::User(state.editor.client());
        let view = state.editor.focus();
        (
            command.handler.clone(),
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
        let text: Vec<String> = keys.iter().map(ToString::to_string).collect();
        ctx.set("keys", text.join(" "))?;
    }
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
    handler.call::<()>(ctx)?;
    Ok(())
}

/// Feeds one key press through the keymap, running whatever it resolves
/// to.
pub(super) fn press(lua: &Lua, key: Key) -> Result<(), HostError> {
    let outcome = state_mut(lua).editor.press(key);
    match outcome {
        KeyOutcome::Command { name, keys } => run_command(lua, &name, &keys),
        KeyOutcome::Pending | KeyOutcome::Unbound(_) => Ok(()),
    }
}

/// Calls every handler for `event` with `payload`. All handlers run even if
/// one fails; the first error is returned.
pub(super) fn emit(lua: &Lua, event: &str, payload: &Table) -> LuaResult<()> {
    let handlers: Vec<Function> = state(lua)
        .registry
        .handlers(event)
        .iter()
        .map(|h| h.handler.clone())
        .collect();
    let mut first_error = None;
    for handler in handlers {
        if let Err(err) = handler.call::<()>(payload.clone()) {
            first_error.get_or_insert(err);
        }
    }
    first_error.map_or(Ok(()), Err)
}

pub(super) fn kern_module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let kern = lua.create_table()?;

    let o = owner.clone();
    kern.set(
        "command",
        lua.create_function(move |lua, spec: Table| {
            let command = Command {
                name: spec.get::<String>("name")?.into(),
                doc: spec
                    .get::<Option<String>>("doc")?
                    .unwrap_or_default()
                    .into(),
                owner: o.clone(),
                source: caller(lua),
                handler: spec.get::<Function>("run")?,
            };
            state_mut(lua).registry.add_command(command);
            Ok(())
        })?,
    )?;

    kern.set(
        "run",
        lua.create_function(|lua, name: String| run_command(lua, &name, &[]).map_err(into_lua))?,
    )?;

    let o = owner.clone();
    kern.set(
        "on",
        lua.create_function(move |lua, (event, handler): (String, Function)| {
            let source = caller(lua);
            state_mut(lua)
                .registry
                .on(event, o.clone(), source, handler);
            Ok(())
        })?,
    )?;

    kern.set(
        "echo",
        lua.create_function(|lua, parts: Variadic<Value>| {
            let text: Vec<String> = parts.iter().map(display).collect();
            state_mut(lua).editor.echo(text.join(" "));
            Ok(())
        })?,
    )?;

    let o = owner.clone();
    kern.set(
        "view",
        lua.create_function(move |lua, ()| {
            Ok(ViewRef {
                id: state(lua).editor.focus(),
                author: Author::Plugin(o.clone()),
            })
        })?,
    )?;

    kern.set(
        "quit",
        lua.create_function(|lua, ()| {
            state_mut(lua).editor.request_quit();
            Ok(())
        })?,
    )?;

    workspace_functions(lua, &kern, owner)?;
    kern.set("keymap", keymap_module(lua, owner)?)?;
    kern.set("mode", mode_module(lua)?)?;
    kern.set("option", option_module(lua, owner)?)?;
    kern.set("history", history_module(lua)?)?;
    Ok(kern)
}

fn keymap_module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let keymap = lua.create_table()?;

    let o = owner.clone();
    keymap.set(
        "bind",
        lua.create_function(move |lua, (layer, map): (Value, Table)| {
            let layer = match layer {
                Value::String(mode) => Layer::mode(&mode.to_str()?),
                Value::Table(t) => Layer {
                    mode: t.get::<Option<String>>("mode")?.map(Into::into),
                    kind: t.get::<Option<String>>("kind")?.map(Into::into),
                },
                other => {
                    return Err(mlua::Error::runtime(format!(
                        "keymap layer must be a mode name or {{ mode = ..., kind = ... }}, not {}",
                        other.type_name()
                    )));
                }
            };
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
    Ok(mode)
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
            let value = option_value(value)?;
            state_mut(lua)
                .registry
                .set_option(&name, value)
                .map_err(mlua::Error::external)
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

/// Where the Luau code calling into Rust is.
fn caller(lua: &Lua) -> Option<Source> {
    lua.inspect_stack(1, |debug| {
        let file = debug.source().short_src?.into_owned();
        let line = u32::try_from(debug.current_line()?).ok()?;
        Some(Source {
            file: file.into(),
            line,
        })
    })
    .flatten()
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
fn workspace_functions(lua: &Lua, kern: &Table, owner: &PluginId) -> LuaResult<()> {
    let o = owner.clone();
    kern.set(
        "create_buffer",
        lua.create_function(move |lua, (kind, text): (String, Option<String>)| {
            let buffer = state_mut(lua)
                .editor
                .create_buffer(&kind, text.as_deref().unwrap_or_default());
            Ok(BufferRef {
                buffer,
                view: None,
                author: Author::Plugin(o.clone()),
            })
        })?,
    )?;

    let o = owner.clone();
    kern.set(
        "float",
        lua.create_function(
            move |lua, (buffer, spec): (UserDataRef<BufferRef>, Option<Table>)| {
                let options = float_options(spec)?;
                buffer.with_buffer(lua, |_| Ok(()))?;
                Ok(ViewRef {
                    id: state_mut(lua).editor.float(buffer.buffer, options),
                    author: Author::Plugin(o.clone()),
                })
            },
        )?,
    )?;

    let o = owner.clone();
    kern.set(
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

    kern.set(
        "open",
        lua.create_function(|lua, path: String| {
            let mut state = state_mut(lua);
            let buffer = state
                .editor
                .open_file(Path::new(&path))
                .map_err(|err| mlua::Error::runtime(format!("can't open {path}: {err}")))?;
            let main = state.editor.main();
            state.editor.show(main, buffer);
            state.editor.set_focus(main);
            Ok(())
        })?,
    )?;

    kern.set(
        "commands",
        lua.create_function(|lua, ()| {
            let list = lua.create_table()?;
            for command in state(lua).registry.commands() {
                let entry = lua.create_table()?;
                entry.set("name", &*command.name)?;
                entry.set("doc", &*command.doc)?;
                entry.set("owner", &*command.owner)?;
                list.push(entry)?;
            }
            Ok(list)
        })?,
    )?;

    kern.set(
        "fuzzy",
        lua.create_function(|_, (query, items): (String, Vec<String>)| Ok(fuzzy(&query, &items)))?,
    )?;

    kern.set(
        "files",
        lua.create_function(|_, dir: Option<String>| {
            Ok(files(Path::new(dir.as_deref().unwrap_or("."))))
        })?,
    )?;
    Ok(())
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

/// Reads `{ title, width, height, anchor }`. Sizes are cells, or a string
/// like "60%".
fn float_options(spec: Option<Table>) -> LuaResult<FloatOptions> {
    let extent = |value: Value| -> LuaResult<Extent> {
        match value {
            Value::Nil => Ok(DEFAULT_FLOAT_SIZE),
            Value::Integer(n) => Ok(Extent::Cells(u16::try_from(n).unwrap_or(u16::MAX))),
            Value::Number(n) if n >= 0.0 =>
            {
                #[expect(
                    clippy::cast_possible_truncation,
                    clippy::cast_sign_loss,
                    reason = "clamped below"
                )]
                Ok(Extent::Cells(n.min(f64::from(u16::MAX)) as u16))
            }
            Value::String(s) => s
                .to_str()?
                .strip_suffix('%')
                .and_then(|p| p.trim().parse().ok())
                .map(Extent::Percent)
                .ok_or_else(|| {
                    mlua::Error::runtime("sizes are a number of cells or a string like \"60%\"")
                }),
            other => Err(mlua::Error::runtime(format!(
                "sizes are a number of cells or a string like \"60%\", not {}",
                other.type_name()
            ))),
        }
    };
    let Some(spec) = spec else {
        return Ok(FloatOptions {
            title: None,
            width: DEFAULT_FLOAT_SIZE,
            height: DEFAULT_FLOAT_SIZE,
            anchor: Anchor::Center,
        });
    };
    let anchor = match spec.get::<Option<String>>("anchor")?.as_deref() {
        None | Some("center") => Anchor::Center,
        Some("top") => Anchor::Top,
        Some("bottom") => Anchor::Bottom,
        Some(other) => {
            return Err(mlua::Error::runtime(format!(
                "anchor must be \"center\", \"top\" or \"bottom\", not {other:?}"
            )));
        }
    };
    Ok(FloatOptions {
        title: spec.get::<Option<String>>("title")?.map(Arc::from),
        width: extent(spec.get("width")?)?,
        height: extent(spec.get("height")?)?,
        anchor,
    })
}
