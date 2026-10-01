//! `kern.theme`: what style names look like.
//!
//! ```luau
//! kern.theme.set({
//!     keyword = { fg = "magenta", bold = true },
//!     ["ui.selection"] = { bg = "#203040", tui = { bg = "blue" } },
//! })
//! ```

use mlua::{Lua, Table, Value};

use super::{state, state_mut};
use crate::registry::PluginId;
use crate::theme::{ANSI, Color, Entry, Style, Underline};

type LuaResult<T> = mlua::Result<T>;

pub(super) fn module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let theme = lua.create_table()?;

    let o = owner.clone();
    theme.set(
        "set",
        lua.create_function(move |lua, entries: Table| {
            let mut parsed = Vec::new();
            for pair in entries.pairs::<String, Table>() {
                let (name, spec) = pair?;
                let entry = entry_from_lua(&spec)
                    .map_err(|err| mlua::Error::runtime(format!("theme entry {name:?}: {err}")))?;
                parsed.push((name, entry));
            }
            let mut state = state_mut(lua);
            for (name, entry) in parsed {
                state.theme_owners.insert(name.as_str().into(), o.clone());
                state.editor.theme_mut().set(name, entry);
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

fn color_name(color: Color) -> String {
    match color {
        Color::Default => "default".to_owned(),
        Color::Ansi(n) if n < 8 => ANSI[usize::from(n)].to_owned(),
        Color::Ansi(n) => format!("bright-{}", ANSI[usize::from(n % 8)]),
        Color::Rgb(r, g, b) => format!("#{r:02x}{g:02x}{b:02x}"),
    }
}

fn style_to_lua(lua: &Lua, style: &Style) -> LuaResult<Table> {
    let t = lua.create_table()?;
    t.set("fg", style.fg.map(color_name))?;
    t.set("bg", style.bg.map(color_name))?;
    t.set("underline_color", style.underline_color.map(color_name))?;
    t.set(
        "underline",
        style.underline.map(|u| match u {
            Underline::Line => "line",
            Underline::Curl => "curl",
            Underline::Dotted => "dotted",
            Underline::Dashed => "dashed",
            Underline::Double => "double",
        }),
    )?;
    t.set("bold", style.bold)?;
    t.set("italic", style.italic)?;
    t.set("dim", style.dim)?;
    t.set("reverse", style.reverse)?;
    t.set("strikethrough", style.strikethrough)?;
    Ok(t)
}
