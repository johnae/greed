//! Keymaps: key sequences to command names, in layers.
//!
//! Keymaps are defined from Luau but resolved here, in a trie per layer, so
//! a keypress only runs Luau when the command it resolves to does.
//!
//! Layers are checked from most to least specific: mode and buffer kind,
//! mode, buffer kind, then global.

use std::collections::HashMap;
use std::fmt;
use std::ops::BitOr;
use std::sync::Arc;

use crate::registry::PluginId;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Mods(u8);

impl Mods {
    pub const NONE: Self = Self(0);
    pub const CTRL: Self = Self(1);
    pub const ALT: Self = Self(2);
    pub const SHIFT: Self = Self(4);

    pub fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }
}

impl BitOr for Mods {
    type Output = Self;

    fn bitor(self, rhs: Self) -> Self {
        Self(self.0 | rhs.0)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum KeyCode {
    Char(char),
    Enter,
    Esc,
    Tab,
    Backspace,
    Delete,
    Insert,
    Up,
    Down,
    Left,
    Right,
    Home,
    End,
    PageUp,
    PageDown,
    F(u8),
}

const NAMED: &[(&str, KeyCode)] = &[
    ("space", KeyCode::Char(' ')),
    ("enter", KeyCode::Enter),
    ("esc", KeyCode::Esc),
    ("tab", KeyCode::Tab),
    ("backspace", KeyCode::Backspace),
    ("delete", KeyCode::Delete),
    ("insert", KeyCode::Insert),
    ("up", KeyCode::Up),
    ("down", KeyCode::Down),
    ("left", KeyCode::Left),
    ("right", KeyCode::Right),
    ("home", KeyCode::Home),
    ("end", KeyCode::End),
    ("pageup", KeyCode::PageUp),
    ("pagedown", KeyCode::PageDown),
];

const MODS: &[(&str, Mods)] = &[
    ("ctrl", Mods::CTRL),
    ("alt", Mods::ALT),
    ("shift", Mods::SHIFT),
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Key {
    pub code: KeyCode,
    pub mods: Mods,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParseError {
    Empty,
    UnknownModifier(String),
    UnknownKey(String),
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ParseError::Empty => write!(f, "no key given"),
            ParseError::UnknownModifier(m) => {
                write!(f, "unknown modifier {m:?} (use ctrl, alt or shift)")
            }
            ParseError::UnknownKey(k) => write!(f, "unknown key {k:?}"),
        }
    }
}

impl std::error::Error for ParseError {}

impl Key {
    pub fn char(c: char) -> Self {
        Self::named(KeyCode::Char(c))
    }

    pub fn named(code: KeyCode) -> Self {
        Self {
            code,
            mods: Mods::NONE,
        }
    }

    #[must_use]
    pub fn with(self, mods: Mods) -> Self {
        Self {
            mods: self.mods | mods,
            ..self
        }
    }

    /// Parses one key: `g`, `G`, `space`, `enter`, `f5`, `ctrl-x`,
    /// `ctrl-alt-x`, `ctrl--`.
    pub fn parse(s: &str) -> Result<Self, ParseError> {
        let (mods, name) = match s {
            "" => return Err(ParseError::Empty),
            "-" => ("", "-"),
            _ => match s.strip_suffix("--") {
                Some(mods) => (mods, "-"),
                None => s.rsplit_once('-').unwrap_or(("", s)),
            },
        };
        let mods = mods
            .split('-')
            .filter(|m| !m.is_empty())
            .try_fold(Mods::NONE, |acc, m| {
                MODS.iter()
                    .find(|(n, _)| *n == m)
                    .map(|(_, bit)| acc | *bit)
                    .ok_or_else(|| ParseError::UnknownModifier(m.to_owned()))
            })?;
        Ok(Self {
            code: parse_code(name)?,
            mods,
        })
    }

    /// Parses a space-separated key sequence, e.g. `space f` or `g g`.
    pub fn parse_sequence(s: &str) -> Result<Vec<Self>, ParseError> {
        let keys: Vec<Self> = s
            .split_whitespace()
            .map(Self::parse)
            .collect::<Result<_, _>>()?;
        if keys.is_empty() {
            return Err(ParseError::Empty);
        }
        Ok(keys)
    }
}

fn parse_code(name: &str) -> Result<KeyCode, ParseError> {
    let mut chars = name.chars();
    if let (Some(c), None) = (chars.next(), chars.next()) {
        return Ok(KeyCode::Char(c));
    }
    if let Some(&(_, code)) = NAMED.iter().find(|(n, _)| *n == name) {
        return Ok(code);
    }
    name.strip_prefix('f')
        .and_then(|n| n.parse::<u8>().ok())
        .filter(|n| (1..=24).contains(n))
        .map(KeyCode::F)
        .ok_or_else(|| ParseError::UnknownKey(name.to_owned()))
}

impl fmt::Display for Key {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for (name, bit) in MODS {
            if self.mods.contains(*bit) {
                write!(f, "{name}-")?;
            }
        }
        match self.code {
            KeyCode::F(n) => write!(f, "f{n}"),
            KeyCode::Char(c) if c != ' ' => write!(f, "{c}"),
            code => {
                let (name, _) = NAMED
                    .iter()
                    .find(|(_, k)| *k == code)
                    .expect("every named key is listed");
                f.write_str(name)
            }
        }
    }
}

/// Which keymap layer a binding lives in. `None` matches any mode or kind.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Layer {
    pub mode: Option<Arc<str>>,
    pub kind: Option<Arc<str>>,
}

impl Layer {
    pub fn global() -> Self {
        Self {
            mode: None,
            kind: None,
        }
    }

    pub fn mode(mode: &str) -> Self {
        Self {
            mode: Some(mode.into()),
            kind: None,
        }
    }

    pub fn kind(kind: &str) -> Self {
        Self {
            mode: None,
            kind: Some(kind.into()),
        }
    }

    pub fn mode_kind(mode: &str, kind: &str) -> Self {
        Self {
            mode: Some(mode.into()),
            kind: Some(kind.into()),
        }
    }

    /// The layers that apply in `mode` for a buffer of `kind`, most specific
    /// first.
    fn lookup_order(mode: &str, kind: &str) -> [Self; 4] {
        [
            Self::mode_kind(mode, kind),
            Self::mode(mode),
            Self::kind(kind),
            Self::global(),
        ]
    }
}

impl fmt::Display for Layer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match (&self.mode, &self.kind) {
            (None, None) => f.write_str("global"),
            (Some(mode), None) => f.write_str(mode),
            (None, Some(kind)) => write!(f, "kind:{kind}"),
            (Some(mode), Some(kind)) => write!(f, "{mode} kind:{kind}"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Resolution {
    /// The sequence is bound to this command.
    Command(Arc<str>),
    /// The sequence is the start of at least one longer binding.
    Pending,
    Unbound,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BindError {
    /// A shorter sequence is already bound to a command, or this sequence is
    /// already a prefix of longer bindings.
    Conflict {
        keys: String,
    },
    Empty,
}

impl fmt::Display for BindError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            BindError::Conflict { keys } => {
                write!(f, "{keys:?} conflicts with an existing binding")
            }
            BindError::Empty => write!(f, "no keys given"),
        }
    }
}

impl std::error::Error for BindError {}

/// What a key does after a prefix, from [`Keymap::continuations`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Next {
    Command(Arc<str>),
    /// The key starts a longer sequence.
    Prefix,
}

/// A binding found by [`Keymap::describe`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Found {
    pub layer: Layer,
    pub command: Arc<str>,
    pub owner: PluginId,
}

#[derive(Debug, Clone)]
struct Binding {
    command: Arc<str>,
    owner: PluginId,
}

#[derive(Debug)]
enum Node {
    /// Every binding of this exact sequence, oldest first. The last is active.
    Command(Vec<Binding>),
    Prefix(HashMap<Key, Node>),
}

#[derive(Debug, Default)]
pub struct Keymap {
    layers: HashMap<Layer, HashMap<Key, Node>>,
    /// Per mode, the command that handles a single unbound key (e.g. insert
    /// mode inserting the character). Oldest first; the last is active.
    fallbacks: HashMap<Arc<str>, Vec<Binding>>,
}

impl Keymap {
    /// Binds a key sequence to a command. Rebinding a sequence keeps the old
    /// binding underneath, restored if the new owner is removed.
    pub fn bind(
        &mut self,
        layer: Layer,
        keys: &[Key],
        command: impl Into<Arc<str>>,
        owner: impl Into<PluginId>,
    ) -> Result<(), BindError> {
        let Some((last, prefix)) = keys.split_last() else {
            return Err(BindError::Empty);
        };
        let conflict = || BindError::Conflict {
            keys: format_keys(keys),
        };
        let mut children = self.layers.entry(layer).or_default();
        for key in prefix {
            match children
                .entry(*key)
                .or_insert_with(|| Node::Prefix(HashMap::new()))
            {
                Node::Prefix(next) => children = next,
                Node::Command(_) => return Err(conflict()),
            }
        }
        let binding = Binding {
            command: command.into(),
            owner: owner.into(),
        };
        match children
            .entry(*last)
            .or_insert_with(|| Node::Command(Vec::new()))
        {
            Node::Command(bindings) => bindings.push(binding),
            Node::Prefix(_) => return Err(conflict()),
        }
        Ok(())
    }

    /// Resolves a key sequence in `mode` for a buffer of `kind`.
    pub fn resolve(&self, mode: &str, kind: &str, keys: &[Key]) -> Resolution {
        let mut pending = false;
        for layer in Layer::lookup_order(mode, kind) {
            match self.lookup(&layer, keys) {
                Some(Node::Command(bindings)) => {
                    let active = bindings.last().expect("empty bindings are pruned");
                    return Resolution::Command(active.command.clone());
                }
                Some(Node::Prefix(_)) => pending = true,
                None => {}
            }
        }
        if pending {
            Resolution::Pending
        } else {
            Resolution::Unbound
        }
    }

    /// Every layer where `keys` is bound, most specific first, with the
    /// active binding in each.
    pub fn describe(&self, mode: &str, kind: &str, keys: &[Key]) -> Vec<Found> {
        Layer::lookup_order(mode, kind)
            .into_iter()
            .filter_map(|layer| match self.lookup(&layer, keys) {
                Some(Node::Command(bindings)) => {
                    let active = bindings.last().expect("empty bindings are pruned");
                    Some(Found {
                        layer,
                        command: active.command.clone(),
                        owner: active.owner.clone(),
                    })
                }
                Some(Node::Prefix(_)) | None => None,
            })
            .collect()
    }

    /// Sets the command that handles an unbound key in `mode`.
    pub fn set_fallback(
        &mut self,
        mode: &str,
        command: impl Into<Arc<str>>,
        owner: impl Into<PluginId>,
    ) {
        self.fallbacks
            .entry(mode.into())
            .or_default()
            .push(Binding {
                command: command.into(),
                owner: owner.into(),
            });
    }

    pub fn fallback(&self, mode: &str) -> Option<&Arc<str>> {
        self.fallbacks.get(mode)?.last().map(|b| &b.command)
    }

    /// The keys that can follow `prefix` in `mode` for a buffer of `kind`, and
    /// what each does, sorted by key. A more specific layer hides the same
    /// key in a less specific one.
    pub fn continuations(&self, mode: &str, kind: &str, prefix: &[Key]) -> Vec<(Key, Next)> {
        let mut found = Vec::new();
        for layer in Layer::lookup_order(mode, kind) {
            let children = if prefix.is_empty() {
                self.layers.get(&layer)
            } else {
                match self.lookup(&layer, prefix) {
                    Some(Node::Prefix(children)) => Some(children),
                    Some(Node::Command(_)) | None => None,
                }
            };
            for (key, node) in children.into_iter().flatten() {
                if found.iter().any(|(k, _)| k == key) {
                    continue;
                }
                let next = match node {
                    Node::Command(bindings) => {
                        let active = bindings.last().expect("empty bindings are pruned");
                        Next::Command(active.command.clone())
                    }
                    Node::Prefix(_) => Next::Prefix,
                };
                found.push((*key, next));
            }
        }
        found.sort_by_key(|(key, _)| key.to_string());
        found
    }

    /// Every key sequence, in every layer, whose active binding runs
    /// `command`.
    pub fn bindings_for(&self, command: &str) -> Vec<(Layer, Vec<Key>)> {
        let mut found = Vec::new();
        for (layer, children) in &self.layers {
            collect_bindings(children, command, &mut Vec::new(), &mut |keys| {
                found.push((layer.clone(), keys));
            });
        }
        found
    }

    /// Removes every binding `owner` made.
    pub fn remove_owned_by(&mut self, owner: &str) {
        for children in self.layers.values_mut() {
            prune(children, owner);
        }
        self.layers.retain(|_, children| !children.is_empty());
        for bindings in self.fallbacks.values_mut() {
            bindings.retain(|b| &*b.owner != owner);
        }
        self.fallbacks.retain(|_, bindings| !bindings.is_empty());
    }

    fn lookup(&self, layer: &Layer, keys: &[Key]) -> Option<&Node> {
        let (first, rest) = keys.split_first()?;
        let mut node = self.layers.get(layer)?.get(first)?;
        for key in rest {
            match node {
                Node::Prefix(children) => node = children.get(key)?,
                Node::Command(_) => return None,
            }
        }
        Some(node)
    }
}

fn prune(children: &mut HashMap<Key, Node>, owner: &str) {
    children.retain(|_, node| match node {
        Node::Command(bindings) => {
            bindings.retain(|b| &*b.owner != owner);
            !bindings.is_empty()
        }
        Node::Prefix(next) => {
            prune(next, owner);
            !next.is_empty()
        }
    });
}

fn format_keys(keys: &[Key]) -> String {
    keys.iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(" ")
}

/// Calls `found` with every sequence under `children` (after `prefix`) whose
/// active binding runs `command`.
fn collect_bindings(
    children: &HashMap<Key, Node>,
    command: &str,
    prefix: &mut Vec<Key>,
    found: &mut impl FnMut(Vec<Key>),
) {
    for (key, node) in children {
        prefix.push(*key);
        match node {
            Node::Command(bindings) => {
                if bindings.last().is_some_and(|b| &*b.command == command) {
                    found(prefix.clone());
                }
            }
            Node::Prefix(next) => collect_bindings(next, command, prefix, found),
        }
        prefix.pop();
    }
}
