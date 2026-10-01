//! Themes: what named styles look like.
//!
//! Everything the core draws carries style names rather than colors:
//! `ui.selection`, `ui.statusline.mode`, `keyword`, or whatever a plugin
//! decorates text with. A theme maps names to styles, and each client
//! resolves them for its own surface, so a terminal and a GUI can share
//! frames and themes.
//!
//! Names are dotted and fall back to their parents: `markup.heading.1`
//! uses `markup.heading` if the theme has no entry for it, then `markup`.
//!
//! The core's own names:
//!
//! - `ui.text`, `ui.gutter`, `ui.gutter.diagnostic.<severity>`,
//!   `ui.selection`, `ui.cursor` (cursors other than the primary one)
//! - `ui.statusline`, `ui.statusline.mode`, `ui.statusline.message`
//! - `ui.float`, `ui.float.border`, `ui.float.title`
//! - `ui.menu.selected`, `ui.menu.match`, `ui.menu.doc`: lists like the
//!   picker's, drawn by plugins
//! - `diagnostic.<severity>`: `error`, `warning`, `info` or `hint`
//! - tree-sitter captures for syntax, e.g. `keyword` or `function.macro`

use std::collections::HashMap;
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Underline {
    Line,
    Curl,
    Dotted,
    Dashed,
    Double,
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
}

/// How text looks. Fields left as `None` leave whatever is underneath, so
/// styles layer: a selection's background over a keyword's color.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
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
        }
    }
}

/// What draws a frame. Theme entries can style each one differently.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Surface {
    Tui,
    Gui,
}

/// One theme entry: a style every surface uses, and changes for each.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
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

    fn on(&self, surface: Surface) -> Style {
        self.style.patch(match surface {
            Surface::Tui => &self.tui,
            Surface::Gui => &self.gui,
        })
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
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

    /// The style for `name` on `surface`: its entry, or its nearest
    /// parent's. Without either, a few core names keep a plain look so the
    /// editor stays usable with no theme at all.
    pub fn style(&self, name: &str, surface: Surface) -> Style {
        if let Some(entry) = lineage(name).find_map(|n| self.entries.get(n)) {
            return entry.on(surface);
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
