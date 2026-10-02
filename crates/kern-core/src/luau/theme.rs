//! `kern.theme`: what style names look like.
//!
//! ```luau
//! kern.theme.set({
//!     keyword = { fg = "magenta", bold = true },
//!     ["ui.selection"] = { bg = "#203040", tui = { bg = "blue" } },
//! })
//! ```

use std::collections::HashMap;
use std::sync::Arc;

use mlua::{Lua, Table, Value};

use super::{State, state, state_mut};
use crate::registry::PluginId;
use crate::theme::{Color, Entry, Style, Underline};

type LuaResult<T> = mlua::Result<T>;

pub(super) fn module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let theme = lua.create_table()?;

    let o = owner.clone();
    theme.set(
        "set",
        lua.create_function(move |lua, entries: Table| {
            let parsed = entries_from_lua(&entries)?;
            let mut state = state_mut(lua);
            for (name, entry) in parsed {
                state.theme_owners.insert(name.clone(), o.clone());
                state.editor.theme_mut().set(name, entry);
            }
            Ok(())
        })?,
    )?;

    let o = owner.clone();
    theme.set(
        "base",
        lua.create_function(move |lua, entries: Table| {
            let parsed: HashMap<_, _> = entries_from_lua(&entries)?.into_iter().collect();
            let mut state = state_mut(lua);
            let state = &mut *state;
            // Entries set with `set` stay on top.
            if let Some((_, old)) = state.theme_base.take() {
                remove_base(state, &old);
            }
            for (name, entry) in &parsed {
                if !state.theme_owners.contains_key(name) {
                    state.editor.theme_mut().set(name.clone(), entry.clone());
                }
            }
            state.theme_base = Some((o.clone(), parsed));
            Ok(())
        })?,
    )?;

    theme.set(
        "get",
        lua.create_function(|lua, name: String| {
            let entry = state(lua).editor.theme().entry(&name).cloned();
            entry
                .map(|entry| {
                    let table = style_to_lua(lua, &entry.style)?;
                    table.set("tui", style_to_lua(lua, &entry.tui)?)?;
                    table.set("gui", style_to_lua(lua, &entry.gui)?)?;
                    Ok(table)
                })
                .transpose()
        })?,
    )?;
    Ok(theme)
}

/// Removes the entries of a base theme that no `set` entry covers.
pub(super) fn remove_base(state: &mut State, base: &HashMap<Arc<str>, Entry>) {
    for name in base.keys() {
        if !state.theme_owners.contains_key(name) {
            state.editor.theme_mut().remove(name);
        }
    }
}

/// Reads `{ [name] = entry }`.
fn entries_from_lua(entries: &Table) -> LuaResult<Vec<(Arc<str>, Entry)>> {
    entries
        .pairs::<String, Table>()
        .map(|pair| {
            let (name, spec) = pair?;
            let entry = entry_from_lua(&spec)
                .map_err(|err| mlua::Error::runtime(format!("theme entry {name:?}: {err}")))?;
            Ok((name.into(), entry))
        })
        .collect()
}

/// Reads `{ fg, bg, ..., tui = {...}, gui = {...} }`.
fn entry_from_lua(spec: &Table) -> LuaResult<Entry> {
    let part = |key: &str| -> LuaResult<Style> {
        match spec.get::<Option<Table>>(key)? {
            Some(t) => style_from_lua(&t, false),
            None => Ok(Style::default()),
        }
    };
    Ok(Entry {
        style: style_from_lua(spec, true)?,
        tui: part("tui")?,
        gui: part("gui")?,
    })
}

const KEYS: [&str; 9] = [
    "fg",
    "bg",
    "underline",
    "underline_color",
    "bold",
    "italic",
    "dim",
    "reverse",
    "strikethrough",
];

fn style_from_lua(t: &Table, surfaces: bool) -> LuaResult<Style> {
    for pair in t.pairs::<String, Value>() {
        let (key, _) = pair?;
        let known = KEYS.contains(&key.as_str()) || (surfaces && (key == "tui" || key == "gui"));
        if !known {
            return Err(mlua::Error::runtime(format!(
                "unknown style key {key:?} (use {})",
                KEYS.join(", ")
            )));
        }
    }
    let color = |key: &str| -> LuaResult<Option<Color>> {
        t.get::<Option<String>>(key)?
            .map(|name| {
                Color::parse(&name).ok_or_else(|| {
                    mlua::Error::runtime(format!(
                        "{name:?} isn't a color: use a name like \"red\" or \"bright-blue\", \"default\" or \"#rrggbb\""
                    ))
                })
            })
            .transpose()
    };
    let underline = match t.get::<Value>("underline")? {
        Value::Nil | Value::Boolean(false) => None,
        Value::Boolean(true) => Some(Underline::Line),
        Value::String(kind) => Some(Underline::parse(&kind.to_str()?).ok_or_else(|| {
            mlua::Error::runtime(
                "underline is true, \"line\", \"curl\", \"dotted\", \"dashed\" or \"double\"",
            )
        })?),
        other => {
            return Err(mlua::Error::runtime(format!(
                "underline is a boolean or a string, not {}",
                other.type_name()
            )));
        }
    };
    Ok(Style {
        fg: color("fg")?,
        bg: color("bg")?,
        underline,
        underline_color: color("underline_color")?,
        bold: t.get("bold")?,
        italic: t.get("italic")?,
        dim: t.get("dim")?,
        reverse: t.get("reverse")?,
        strikethrough: t.get("strikethrough")?,
    })
}

fn style_to_lua(lua: &Lua, style: &Style) -> LuaResult<Table> {
    let t = lua.create_table()?;
    t.set("fg", style.fg.map(|c| c.to_string()))?;
    t.set("bg", style.bg.map(|c| c.to_string()))?;
    t.set(
        "underline_color",
        style.underline_color.map(|c| c.to_string()),
    )?;
    t.set("underline", style.underline.map(Underline::name))?;
    t.set("bold", style.bold)?;
    t.set("italic", style.italic)?;
    t.set("dim", style.dim)?;
    t.set("reverse", style.reverse)?;
    t.set("strikethrough", style.strikethrough)?;
    Ok(t)
}
