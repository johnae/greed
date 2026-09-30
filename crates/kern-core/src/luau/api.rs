//! The `kern` module plugins get from `require("kern")`, and the buffer and
//! view handles passed to commands.
//!
//! Positions are 0-based byte offsets and lines are 0-based, matching LSP.
//! A range is `{ anchor = n, head = n }`; a selection is
//! `{ ranges = { range, ... }, primary = i }` with a 1-based `primary`.

use std::path::PathBuf;

use kern_text::{Author, ChangeSet, Range, Rope, Selection};
use mlua::{Function, Lua, MetaMethod, Table, UserData, UserDataMethods, Value, Variadic};

use super::{HostError, state, state_mut};
use crate::keymap::{Key, KeyCode, Layer, Mods};
use crate::registry::{Command, OptionDef, PluginId, Source, Value as OptionValue};
use crate::{Buffer, ViewId};

type LuaResult<T> = mlua::Result<T>;

/// The environment for `owner`'s code, created on first use.
pub(super) fn plugin_env(lua: &Lua, owner: &str, dir: Option<PathBuf>) -> LuaResult<Table> {
    if let Some(env) = state(lua).envs.get(owner) {
        return Ok(env.clone());
    }
    fresh_plugin_env(lua, owner, dir)
}

/// A new environment for `owner`: its own globals over the read-only
/// standard library, with `require` resolving `"kern"` and files in `dir`.
pub(super) fn fresh_plugin_env(lua: &Lua, owner: &str, dir: Option<PathBuf>) -> LuaResult<Table> {
    let owner: PluginId = owner.into();
    let env = lua.create_table()?;
    let meta = lua.create_table()?;
    meta.set("__index", lua.globals())?;
    env.set_metatable(Some(meta))?;

    let kern = kern_module(lua, &owner)?;
    let loaded = lua.create_table()?;
    let require_env = env.clone();
    let require_owner = owner.clone();
    env.set(
        "require",
        lua.create_function(move |lua, name: String| {
            if name == "kern" {
                return Ok(Value::Table(kern.clone()));
            }
            if let Some(module) = loaded.get::<Option<Value>>(name.as_str())? {
                return Ok(module);
            }
            let Some(dir) = &dir else {
                return Err(mlua::Error::runtime(format!("can't require {name:?} here")));
            };
            let file = format!("{}.luau", name.trim_start_matches("./"));
            let source = std::fs::read_to_string(dir.join(&file))
                .map_err(|err| mlua::Error::runtime(format!("can't require {name:?}: {err}")))?;
            let module: Value = lua
                .load(source)
                .set_name(format!("@{require_owner}/{file}"))
                .set_environment(require_env.clone())
                .eval()?;
            loaded.set(name.as_str(), module.clone())?;
            Ok(module)
        })?,
    )?;

    state_mut(lua).envs.insert(owner, env.clone());
    Ok(env)
}

/// Runs a command as the user, with `keys` as the sequence that triggered
/// it.
pub(super) fn run_command(lua: &Lua, name: &str, keys: &[Key]) -> Result<(), HostError> {
    let (handler, author, view) = {
        let state = state(lua);
        let command = state
            .registry
            .command(name)
            .ok_or_else(|| HostError::UnknownCommand(name.into()))?;
        let author = Author::User(state.editor.client());
        (command.handler.clone(), author, state.editor.focus())
    };
    let ctx = lua.create_table()?;
    ctx.set(
        "view",
        ViewRef {
            id: view,
            author: author.clone(),
        },
    )?;
    ctx.set("buffer", BufferRef { view, author })?;
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

/// Calls every handler for `event` with `payload`. All handlers run even if
/// one fails; the first error is returned.
fn emit(lua: &Lua, event: &str, payload: &Table) -> LuaResult<()> {
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

fn kern_module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
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

fn into_lua(err: HostError) -> mlua::Error {
    match err {
        HostError::Lua(err) => err,
        other => mlua::Error::external(other),
    }
}

/// A view, as seen by a command or plugin. Edits made through it are
/// attributed to `author`.
struct ViewRef {
    id: ViewId,
    author: Author,
}

impl UserData for ViewRef {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method("selection", |lua, this, ()| {
            selection_to_lua(lua, &state(lua).editor.view(this.id).selection)
        });
        methods.add_method("set_selection", |lua, this, t: Table| {
            let selection = selection_from_lua(&t)?;
            let mut state = state_mut(lua);
            let buffer = state.editor.view(this.id).buffer;
            check_selection(state.editor.buffer(buffer).text(), &selection)?;
            state.editor.view_mut(this.id).selection = selection;
            Ok(())
        });
        methods.add_method("buffer", |_, this, ()| {
            Ok(BufferRef {
                view: this.id,
                author: this.author.clone(),
            })
        });
        methods.add_method("undo", |lua, this, ()| {
            state_mut(lua)
                .editor
                .undo(this.id)
                .map_err(mlua::Error::external)
        });
        methods.add_method("redo", |lua, this, ()| {
            state_mut(lua)
                .editor
                .redo(this.id)
                .map_err(mlua::Error::external)
        });
    }
}

/// The buffer shown in a view. Edits map that view's selection.
struct BufferRef {
    view: ViewId,
    author: Author,
}

impl BufferRef {
    fn with_buffer<R>(&self, lua: &Lua, f: impl FnOnce(&Buffer) -> LuaResult<R>) -> LuaResult<R> {
        let state = state(lua);
        let id = state.editor.view(self.view).buffer;
        f(state.editor.buffer(id))
    }

    fn with_text<R>(&self, lua: &Lua, f: impl FnOnce(&Rope) -> LuaResult<R>) -> LuaResult<R> {
        self.with_buffer(lua, |buffer| f(buffer.text()))
    }

    /// Calls `f` with an edit collector, once per range of `selection` or
    /// once if there is none, then applies everything as one transaction.
    fn edit(&self, lua: &Lua, selection: Option<Table>, f: &Function) -> LuaResult<()> {
        let edits = lua.create_userdata(Edits::default())?;
        match selection {
            Some(t) => {
                for range in selection_from_lua(&t)?.ranges() {
                    f.call::<()>((&edits, range_to_lua(lua, *range)?))?;
                }
            }
            None => f.call::<()>(&edits)?,
        }
        let Edits {
            mut changes,
            selection,
        } = edits.take()?;
        changes.sort_by_key(|(from, to, _)| (*from, *to));
        let len = self.with_text(lua, |t| Ok(t.len_bytes()))?;
        let changes = ChangeSet::from_changes(len, changes).map_err(mlua::Error::external)?;
        state_mut(lua)
            .editor
            .apply(self.view, changes, self.author.clone(), None, selection)
            .map_err(mlua::Error::external)
    }
}

impl UserData for BufferRef {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method("len", |lua, this, ()| {
            this.with_text(lua, |t| Ok(t.len_bytes()))
        });
        methods.add_method("text", |lua, this, ()| {
            this.with_text(lua, |t| Ok(t.to_string()))
        });
        methods.add_method("slice", |lua, this, (from, to): (usize, usize)| {
            this.with_text(lua, |t| {
                let (from, to) = (char_index(t, from)?, char_index(t, to)?);
                if from > to {
                    return Err(mlua::Error::runtime("slice start is after its end"));
                }
                Ok(t.slice(from..to).to_string())
            })
        });
        methods.add_method("line_count", |lua, this, ()| {
            this.with_text(lua, |t| Ok(t.len_lines()))
        });
        methods.add_method("line_of", |lua, this, pos: usize| {
            this.with_text(lua, |t| {
                check_pos(t, pos)?;
                Ok(t.byte_to_line(pos))
            })
        });
        methods.add_method("line_start", |lua, this, line: usize| {
            this.with_text(lua, |t| {
                check_line(t, line)?;
                Ok(t.line_to_byte(line))
            })
        });
        methods.add_method("line_end", |lua, this, line: usize| {
            this.with_text(lua, |t| {
                check_line(t, line)?;
                let slice = t.line(line);
                let newline = match (slice.len_chars(), slice.chars().last()) {
                    (n, Some('\n')) if n >= 2 && slice.char(n - 2) == '\r' => 2,
                    (_, Some('\n')) => 1,
                    _ => 0,
                };
                Ok(t.line_to_byte(line) + slice.len_bytes() - newline)
            })
        });
        methods.add_method("char_at", |lua, this, pos: usize| {
            this.with_text(lua, |t| {
                let i = char_index(t, pos)?;
                Ok((i < t.len_chars()).then(|| t.char(i).to_string()))
            })
        });
        methods.add_method("next_char", |lua, this, pos: usize| {
            this.with_text(lua, |t| {
                let i = char_index(t, pos)?;
                Ok(t.char_to_byte((i + 1).min(t.len_chars())))
            })
        });
        methods.add_method("prev_char", |lua, this, pos: usize| {
            this.with_text(lua, |t| {
                let i = char_index(t, pos)?;
                Ok(t.char_to_byte(i.saturating_sub(1)))
            })
        });
        methods.add_method("kind", |lua, this, ()| {
            this.with_buffer(lua, |b| Ok(b.kind().to_owned()))
        });
        methods.add_method("path", |lua, this, ()| {
            this.with_buffer(lua, |b| {
                Ok(b.path().map(|p| p.to_string_lossy().into_owned()))
            })
        });
        methods.add_method("edit", |lua, this, (selection, f)| {
            this.edit(lua, selection, &f)
        });
    }
}

/// Collects edits made inside `buffer:edit`.
#[derive(Default)]
struct Edits {
    changes: Vec<(usize, usize, Option<String>)>,
    selection: Option<Selection>,
}

impl UserData for Edits {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method_mut("insert", |_, this, (pos, text): (usize, String)| {
            this.changes.push((pos, pos, Some(text)));
            Ok(())
        });
        methods.add_method_mut("delete", |_, this, (from, to): (usize, usize)| {
            this.changes.push((from, to, None));
            Ok(())
        });
        methods.add_method_mut(
            "replace",
            |_, this, (from, to, text): (usize, usize, String)| {
                this.changes.push((from, to, Some(text)));
                Ok(())
            },
        );
        methods.add_method_mut("select", |_, this, t: Table| {
            this.selection = Some(selection_from_lua(&t)?);
            Ok(())
        });
        methods.add_meta_method(MetaMethod::ToString, |_, this, ()| {
            Ok(format!("edits({})", this.changes.len()))
        });
    }
}

fn range_to_lua(lua: &Lua, range: Range) -> LuaResult<Table> {
    let t = lua.create_table()?;
    t.set("anchor", range.anchor)?;
    t.set("head", range.head)?;
    Ok(t)
}

fn selection_to_lua(lua: &Lua, selection: &Selection) -> LuaResult<Table> {
    let ranges = lua.create_table()?;
    for range in selection.ranges() {
        ranges.push(range_to_lua(lua, *range)?)?;
    }
    let t = lua.create_table()?;
    t.set("ranges", ranges)?;
    t.set("primary", selection.primary_index() + 1)?;
    Ok(t)
}

fn selection_from_lua(t: &Table) -> LuaResult<Selection> {
    let ranges = t
        .get::<Table>("ranges")?
        .sequence_values::<Table>()
        .map(|r| {
            let r = r?;
            Ok(Range::new(r.get("anchor")?, r.get("head")?))
        })
        .collect::<LuaResult<Vec<Range>>>()?;
    let primary = t
        .get::<Option<usize>>("primary")?
        .unwrap_or(1)
        .saturating_sub(1);
    Selection::new(ranges, primary).map_err(mlua::Error::external)
}

fn check_selection(text: &Rope, selection: &Selection) -> LuaResult<()> {
    selection
        .ranges()
        .iter()
        .flat_map(|r| [r.anchor, r.head])
        .try_for_each(|pos| char_index(text, pos).map(drop))
}

fn check_pos(text: &Rope, pos: usize) -> LuaResult<()> {
    if pos > text.len_bytes() {
        return Err(mlua::Error::runtime(format!(
            "position {pos} is past the end of the buffer ({} bytes)",
            text.len_bytes()
        )));
    }
    Ok(())
}

fn check_line(text: &Rope, line: usize) -> LuaResult<()> {
    if line >= text.len_lines() {
        return Err(mlua::Error::runtime(format!(
            "line {line} is past the end of the buffer ({} lines)",
            text.len_lines()
        )));
    }
    Ok(())
}

/// The char index of byte `pos`, which must be in bounds and on a char
/// boundary.
fn char_index(text: &Rope, pos: usize) -> LuaResult<usize> {
    check_pos(text, pos)?;
    let i = text.byte_to_char(pos);
    if text.char_to_byte(i) != pos {
        return Err(mlua::Error::runtime(format!(
            "position {pos} is inside a character"
        )));
    }
    Ok(i)
}
