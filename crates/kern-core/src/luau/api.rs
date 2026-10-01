//! The `kern` module plugins get from `require("@kern")`, and running
//! commands and emitting events.

use std::path::Path;
use std::sync::Arc;

use kern_text::Author;
use mlua::{Function, Lua, Table, UserDataRef, Value, Variadic};
use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32Str};

use super::handles::{BufferRef, ViewRef};
use super::tasks;
use super::{HostError, state, state_mut};
use crate::keymap::{Key, KeyCode, Layer, Mods, Next, Resolution};
use crate::registry::{Arg, Command, OptionDef, PluginId, Source, Value as OptionValue};
use crate::render::{Span, StatusLine, Tag};
use crate::{Anchor, Extent, FloatOptions, KeyOutcome};

type LuaResult<T> = mlua::Result<T>;

/// Runs a command as the user, with `keys` as the sequence that triggered
/// it.
pub(super) fn run_command(lua: &Lua, name: &str, keys: &[Key]) -> Result<(), HostError> {
    invoke(lua, name, keys, Vec::new(), false)
}

/// Runs a command as the user with arguments, as from the command line.
/// `force` asks it to go ahead even if it would normally refuse, like
/// quitting with unsaved changes.
fn invoke(
    lua: &Lua,
    name: &str,
    keys: &[Key],
    args: Vec<String>,
    force: bool,
) -> Result<(), HostError> {
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
        ctx.set("keys", keys_text(keys))?;
    }
    ctx.set("args", args)?;
    ctx.set("force", force)?;
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
    emit(lua, "command.run", &event)?;
    tasks::spawn(lua, handler, ctx)?;
    Ok(())
}

/// Feeds one key press through the keymap, running whatever it resolves
/// to.
pub(super) fn press(lua: &Lua, key: Key) -> Result<(), HostError> {
    // A command waiting on kern.next_key gets the key instead of the keymap.
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
        KeyOutcome::Command { name, keys } => {
            if keys.len() > 1 {
                keys_pending(lua, "")?;
            }
            run_command(lua, &name, &keys)
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
    let handlers: Vec<Function> = state(lua)
        .registry
        .handlers(event)
        .iter()
        .map(|h| h.handler.clone())
        .collect();
    let mut first_error = None;
    for handler in handlers {
        if let Err(err) = tasks::spawn(lua, handler, payload.clone()) {
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
                args: command_args(spec.get("args")?)?,
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
        lua.create_function(|lua, (name, opts): (String, Option<Table>)| {
            let (args, force) = match opts {
                Some(opts) => (
                    opts.get::<Option<Vec<String>>>("args")?.unwrap_or_default(),
                    opts.get::<Option<bool>>("force")?.unwrap_or(false),
                ),
                None => (Vec::new(), false),
            };
            invoke(lua, &name, &[], args, force).map_err(into_lua)
        })?,
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

    kern.set("sleep", tasks::sleep_function(lua)?)?;
    kern.set("next_key", tasks::next_key_function(lua)?)?;

    kern.set(
        "quit",
        lua.create_function(|lua, ()| {
            state_mut(lua).editor.request_quit();
            Ok(())
        })?,
    )?;

    kern.set(
        "eval",
        lua.create_function(|lua, source: String| {
            Ok(match super::eval_repl(lua, &source) {
                Ok(values) => (true, values),
                Err(err) => (false, err.to_string()),
            })
        })?,
    )?;

    let o = owner.clone();
    kern.set(
        "statusline",
        lua.create_function(move |lua, build: Function| {
            state_mut(lua).statusline = Some((o.clone(), build));
            Ok(())
        })?,
    )?;

    workspace_functions(lua, &kern, owner)?;
    kern.set("keymap", keymap_module(lua, owner)?)?;
    kern.set("mode", mode_module(lua)?)?;
    kern.set("option", option_module(lua, owner)?)?;
    kern.set("history", history_module(lua)?)?;
    kern.set("clipboard", clipboard_module(lua)?)?;
    kern.set("lsp", super::lsp::module(lua)?)?;
    kern.set("fs", super::fs::module(lua)?)?;
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
        "find",
        lua.create_function(|lua, command: String| {
            let mut found = state(lua).editor.keymap().bindings_for(&command);
            found.sort_by_key(|(layer, keys)| (layer.to_string(), keys_text(keys)));
            let list = lua.create_table()?;
            for (layer, keys) in found {
                let entry = lua.create_table()?;
                entry.set("layer", layer.to_string())?;
                entry.set("keys", keys_text(&keys))?;
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
fn workspace_functions(lua: &Lua, kern: &Table, owner: &PluginId) -> LuaResult<()> {
    kern.set("create_buffer", create_buffer_function(lua, owner)?)?;

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
                if let Some(source) = &command.source {
                    entry.set("source", format!("{}:{}", source.file, source.line))?;
                    if let Some(path) = state.sources.get(&*source.file) {
                        entry.set("path", path.to_string_lossy().as_ref())?;
                        entry.set("line", source.line)?;
                    }
                }
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
        "language_of",
        lua.create_function(|_, path: String| Ok(crate::syntax::language_name(Path::new(&path))))?,
    )?;

    kern.set(
        "files",
        lua.create_function(|_, dir: Option<String>| {
            Ok(files(Path::new(dir.as_deref().unwrap_or("."))))
        })?,
    )?;
    Ok(())
}

/// `kern.create_buffer(kind, text, { readonly, language })`.
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
            focus: true,
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
        focus: spec.get::<Option<bool>>("focus")?.unwrap_or(true),
    })
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
    let (build, view, buffer, mode, author) = {
        let state = state(lua);
        let Some((owner, build)) = &state.statusline else {
            return Ok(None);
        };
        let view = state.editor.main();
        (
            build.clone(),
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
    let line: Table = build.call(ctx)?;
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
            let tag = match style.as_deref() {
                None | Some("status") => Tag::Status,
                Some("mode") => Tag::Mode,
                Some("message") => Tag::Message,
                Some(other) => {
                    return Err(mlua::Error::runtime(format!(
                        "status line style must be \"status\", \"mode\" or \"message\", not {other:?}"
                    )));
                }
            };
            Ok(Span {
                text,
                tags: std::iter::once(tag).collect(),
            })
        })
        .collect()
}
