//! Themes: what named styles look like.
//!
//! Everything the core draws carries style names rather than colors:
//! `ui.selection`, `ui.statusline.mode`, `keyword`, or whatever a plugin
//! decorates text with. A theme maps names to styles, and each client
//! resolves them for its own medium, so a terminal and a GUI can share
//! frames and themes.
//!
//! Names are dotted and fall back to their parents: `markup.heading.1`
//! uses `markup.heading` if the theme has no entry for it, then `markup`.
//! A name starting with `=` is a style itself, e.g. `=fg:red bold`, and
//! skips the theme: a terminal's colors come from the program in it.
//!
//! The core's own names:
//!
//! - `ui.text`, `ui.gutter`, `ui.gutter.diagnostic.<severity>`,
//!   `ui.selection`, `ui.cursor` (cursors other than the primary one)
//! - `ui.statusline`, `ui.statusline.mode`, `ui.statusline.message`
//! - `ui.float`, `ui.float.border`, `ui.float.title`
//! - `ui.panel`, `ui.panel.border` (the line beside it), `ui.panel.title`
//! - `ui.pane.border` (the lines between panes), `ui.pane.inactive` (under
//!   every pane but the active one), `ui.tabline`, `ui.tabline.active`
//! - `ui.menu.selected`, `ui.menu.match`, `ui.menu.doc`: lists like the
//!   picker's, drawn by plugins
//! - `diagnostic.<severity>`: `error`, `warning`, `info` or `hint`
//! - tree-sitter captures for syntax, e.g. `keyword` or `function.macro`

use std::collections::HashMap;
use std::fmt;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Color {
    /// The terminal's or window's own foreground or background.
    Default,
    /// One of the 16 terminal colors: 0-7 normal, 8-15 bright.
    Ansi(u8),
    Rgb(u8, u8, u8),
}

/// The 16 terminal colors by name; "bright-" names are 8 higher.
pub(crate) const ANSI: [&str; 8] = [
    "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
];

impl Color {
    /// Parses "red", "bright-red", "grey", "default" or "#rrggbb".
    pub fn parse(s: &str) -> Option<Self> {
        if let Some(hex) = s.strip_prefix('#') {
            if hex.len() != 6 {
                return None;
            }
            let channel = |i: usize| u8::from_str_radix(hex.get(i..i + 2)?, 16).ok();
            return Some(Color::Rgb(channel(0)?, channel(2)?, channel(4)?));
        }
        match s {
            "default" => return Some(Color::Default),
            "grey" | "gray" => return Some(Color::Ansi(8)),
            _ => {}
        }
        let (base, offset) = match s.strip_prefix("bright-") {
            Some(base) => (base, 8),
            None => (s, 0),
        };
        let index = ANSI.iter().position(|name| *name == base)?;
        Some(Color::Ansi(u8::try_from(index).ok()? + offset))
    }
}

/// Which of the window's fonts text is drawn in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Font {
    /// The monospaced font that sets the grid (`gui-font`).
    Mono,
    /// A proportional font for prose (`gui-font-prose`).
    Prose,
}

/// A checkbox the window draws in place of the text's own symbol.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Checkbox {
    /// An outlined box.
    Empty,
    /// A filled box with a tick.
    Checked,
    /// An outlined circle, one choice of several.
    Choice,
    /// An outlined circle with a dot: the choice picked.
    Chosen,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Underline {
    Line,
    Curl,
    Dotted,
    Dashed,
    Double,
}

impl fmt::Display for Color {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match *self {
            Color::Default => f.write_str("default"),
            Color::Ansi(n) if n < 8 => f.write_str(ANSI[usize::from(n)]),
            Color::Ansi(n) => write!(f, "bright-{}", ANSI[usize::from(n % 8)]),
            Color::Rgb(r, g, b) => write!(f, "#{r:02x}{g:02x}{b:02x}"),
        }
    }
}

impl Underline {
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "line" => Underline::Line,
            "curl" => Underline::Curl,
            "dotted" => Underline::Dotted,
            "dashed" => Underline::Dashed,
            "double" => Underline::Double,
            _ => return None,
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            Underline::Line => "line",
            Underline::Curl => "curl",
            Underline::Dotted => "dotted",
            Underline::Dashed => "dashed",
            Underline::Double => "double",
        }
    }
}

/// How text looks. Fields left as `None` leave whatever is underneath, so
/// styles layer: a selection's background over a keyword's color.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Style {
    pub fg: Option<Color>,
    pub bg: Option<Color>,
    pub underline: Option<Underline>,
    pub underline_color: Option<Color>,
    pub bold: Option<bool>,
    pub italic: Option<bool>,
    pub dim: Option<bool>,
    pub reverse: Option<bool>,
    pub strikethrough: Option<bool>,
    /// For floats in the window: rounded corners and an outline instead of
    /// box lines, and a soft shadow. Terminals draw neither.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rounded: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shadow: Option<bool>,
    /// For text in the window: its background as a badge, a box with
    /// rounded corners a little inside its cells, as motion hints have.
    /// Terminals draw a block.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub badge: Option<bool>,
    /// For a todo's box in the window: drawn as a checkbox, empty or
    /// checked, over the cells of its text. Terminals show the text.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checkbox: Option<Checkbox>,
    /// The window's font for the text: the grid's, or a proportional one for
    /// prose, fitted into the same cells. Terminals have only the one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub font: Option<Font>,
}

impl Style {
    /// This style with every field `over` sets replaced.
    #[must_use]
    pub fn patch(&self, over: &Style) -> Style {
        Style {
            fg: over.fg.or(self.fg),
            bg: over.bg.or(self.bg),
            underline: over.underline.or(self.underline),
            underline_color: over.underline_color.or(self.underline_color),
            bold: over.bold.or(self.bold),
            italic: over.italic.or(self.italic),
            dim: over.dim.or(self.dim),
            reverse: over.reverse.or(self.reverse),
            strikethrough: over.strikethrough.or(self.strikethrough),
            rounded: over.rounded.or(self.rounded),
            shadow: over.shadow.or(self.shadow),
            badge: over.badge.or(self.badge),
            checkbox: over.checkbox.or(self.checkbox),
            font: over.font.or(self.font),
        }
    }

    /// A name that spells out this style, e.g. `=fg:red bg:#202020 bold`,
    /// for text whose look comes from elsewhere than the theme, like a
    /// program's output in a terminal.
    pub fn inline_name(&self) -> String {
        let mut words = Vec::new();
        for (key, color) in [
            ("fg", self.fg),
            ("bg", self.bg),
            ("underline_color", self.underline_color),
        ] {
            if let Some(color) = color {
                words.push(format!("{key}:{color}"));
            }
        }
        if let Some(underline) = self.underline {
            words.push(format!("underline:{}", underline.name()));
        }
        for (key, on) in [
            ("bold", self.bold),
            ("italic", self.italic),
            ("dim", self.dim),
            ("reverse", self.reverse),
            ("strikethrough", self.strikethrough),
        ] {
            if on == Some(true) {
                words.push(key.to_owned());
            }
        }
        format!("={}", words.join(" "))
    }

    /// The style an inline name spells out, given without its `=`. Words it
    /// doesn't know are skipped.
    pub fn from_inline(spec: &str) -> Style {
        let mut style = Style::default();
        for word in spec.split_whitespace() {
            match word.split_once(':') {
                Some(("fg", color)) => style.fg = Color::parse(color),
                Some(("bg", color)) => style.bg = Color::parse(color),
                Some(("underline_color", color)) => style.underline_color = Color::parse(color),
                Some(("underline", kind)) => style.underline = Underline::parse(kind),
                Some(_) => {}
                None => match word {
                    "bold" => style.bold = Some(true),
                    "italic" => style.italic = Some(true),
                    "dim" => style.dim = Some(true),
                    "reverse" => style.reverse = Some(true),
                    "strikethrough" => style.strikethrough = Some(true),
                    _ => {}
                },
            }
        }
        style
    }
}

/// What draws a frame: a terminal or the window. Theme entries can style
/// each one differently.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Medium {
    Tui,
    Gui,
}

/// One theme entry: a style every medium uses, and changes for each.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    pub style: Style,
    pub tui: Style,
    pub gui: Style,
}

impl Entry {
    pub fn new(style: Style) -> Self {
        Self {
            style,
            ..Self::default()
        }
    }

    /// This entry with the fields `over` gives changed, medium by medium.
    #[must_use]
    pub fn patch(&self, over: &Entry) -> Entry {
        Entry {
            style: self.style.patch(&over.style),
            tui: self.tui.patch(&over.tui),
            gui: self.gui.patch(&over.gui),
        }
    }

    fn on(&self, medium: Medium) -> Style {
        self.style.patch(match medium {
            Medium::Tui => &self.tui,
            Medium::Gui => &self.gui,
        })
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Theme {
    entries: HashMap<Arc<str>, Entry>,
}

impl Theme {
    pub fn set(&mut self, name: impl Into<Arc<str>>, entry: Entry) {
        self.entries.insert(name.into(), entry);
    }

    pub fn remove(&mut self, name: &str) {
        self.entries.remove(name);
    }

    pub fn entry(&self, name: &str) -> Option<&Entry> {
        self.entries.get(name)
    }

    /// The style for `name` on `medium`: its entry, or its nearest
    /// parent's. Without either, a few core names keep a plain look so the
    /// editor stays usable with no theme at all.
    pub fn style(&self, name: &str, medium: Medium) -> Style {
        if let Some(spec) = name.strip_prefix('=') {
            return Style::from_inline(spec);
        }
        if let Some(entry) = lineage(name).find_map(|n| self.entries.get(n)) {
            return entry.on(medium);
        }
        if lineage(name).any(|n| PLAIN_REVERSED.contains(&n)) {
            return Style {
                reverse: Some(true),
                ..Style::default()
            };
        }
        Style::default()
    }
}

/// Core names drawn reversed when the theme has nothing for them.
const PLAIN_REVERSED: [&str; 3] = ["ui.selection", "ui.cursor", "ui.statusline"];

/// `name`, then each parent: "a.b.c", "a.b", "a".
fn lineage(name: &str) -> impl Iterator<Item = &str> {
    std::iter::successors(Some(name), |n| n.rsplit_once('.').map(|(parent, _)| parent))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inline_names_spell_out_their_style_and_skip_the_theme() {
        let style = Style {
            fg: Some(Color::Ansi(9)),
            bg: Some(Color::Rgb(0x20, 0x20, 0x20)),
            underline: Some(Underline::Curl),
            bold: Some(true),
            reverse: Some(true),
            ..Style::default()
        };
        let name = style.inline_name();
        assert_eq!(
            name,
            "=fg:bright-red bg:#202020 underline:curl bold reverse"
        );
        let mut theme = Theme::default();
        theme.set(name.clone(), Entry::new(Style::default()));
        assert_eq!(theme.style(&name, Medium::Tui), style);
        assert_eq!(Style::default().inline_name(), "=");
        assert_eq!(
            Style::from_inline("fg:nope wobbly italic").italic,
            Some(true)
        );
    }
}
