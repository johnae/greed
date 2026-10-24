//! `greed.theme`: what style names look like.
//!
//! ```luau
//! greed.theme.set({
//!     keyword = { fg = "magenta", bold = true },
//!     ["ui.selection"] = { bg = "#203040", tui = { bg = "blue" } },
//! })
//! ```

use std::collections::HashMap;
use std::sync::Arc;

use mlua::{Lua, Table, Value};

use super::{State, state, state_mut};
use crate::registry::PluginId;
use crate::theme::{Checkbox, Color, Entry, Font, Style, Underline};

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
                state.theme_set.insert(name.clone(), (o.clone(), entry));
                refresh(&mut state, &name);
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
            let mut names: Vec<Arc<str>> = parsed.keys().cloned().collect();
            if let Some((_, old)) = state.theme_base.replace((o.clone(), parsed)) {
                names.extend(old.into_keys());
            }
            for name in &names {
                refresh(&mut state, name);
            }
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

/// Gives the editor's theme what `name` looks like now: the base theme's
/// entry with what plugins set patched over it.
pub(super) fn refresh(state: &mut State, name: &Arc<str>) {
    let base = state.theme_base.as_ref().and_then(|(_, b)| b.get(name));
    let set = state.theme_set.get(name).map(|(_, entry)| entry);
    let entry = match (base, set) {
        (Some(base), Some(set)) => Some(base.patch(set)),
        (base, set) => base.or(set).cloned(),
    };
    match entry {
        Some(entry) => state.editor.theme_mut().set(name.clone(), entry),
        None => state.editor.theme_mut().remove(name),
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

const KEYS: [&str; 15] = [
    "fg",
    "bg",
    "underline",
    "underline_color",
    "bold",
    "italic",
    "dim",
    "reverse",
    "strikethrough",
    "rounded",
    "shadow",
    "badge",
    "hover",
    "checkbox",
    "font",
];

fn style_from_lua(t: &Table, media: bool) -> LuaResult<Style> {
    for pair in t.pairs::<String, Value>() {
        let (key, _) = pair?;
        let known = KEYS.contains(&key.as_str()) || (media && (key == "tui" || key == "gui"));
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
        rounded: t.get("rounded")?,
        shadow: t.get("shadow")?,
        badge: t.get("badge")?,
        hover: t.get("hover")?,
        checkbox: match t.get::<Option<String>>("checkbox")?.as_deref() {
            None => None,
            Some("empty") => Some(Checkbox::Empty),
            Some("checked") => Some(Checkbox::Checked),
            Some("choice") => Some(Checkbox::Choice),
            Some("chosen") => Some(Checkbox::Chosen),
            Some(other) => {
                return Err(mlua::Error::runtime(format!(
                    "checkbox is \"empty\", \"checked\", \"choice\" or \"chosen\", not {other:?}"
                )));
            }
        },
        font: match t.get::<Option<String>>("font")?.as_deref() {
            None => None,
            Some("mono") => Some(Font::Mono),
            Some("prose") => Some(Font::Prose),
            Some("") => {
                return Err(mlua::Error::runtime(
                    "font is \"mono\", \"prose\" or a family's name, like \"Monaspace Radon\"",
                ));
            }
            Some(family) => Some(Font::named(family)),
        },
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
    t.set("rounded", style.rounded)?;
    t.set("shadow", style.shadow)?;
    t.set("badge", style.badge)?;
    t.set("hover", style.hover)?;
    t.set(
        "checkbox",
        style.checkbox.map(|c| match c {
            Checkbox::Empty => "empty",
            Checkbox::Checked => "checked",
            Checkbox::Choice => "choice",
            Checkbox::Chosen => "chosen",
        }),
    )?;
    t.set(
        "font",
        style.font.map(|f| match f {
            Font::Mono => "mono".into(),
            Font::Prose => "prose".into(),
            Font::Named(_) => f.name().unwrap_or_default().to_string(),
        }),
    )?;
    Ok(t)
}
