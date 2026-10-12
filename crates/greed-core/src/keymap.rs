//! Keymaps: key sequences to command names, in layers.
//!
//! Keymaps are defined from Luau but resolved here, in a trie per layer, so
//! a keypress only runs Luau when the command it resolves to does.
//!
//! Layers are checked from most to least specific. Keys for the buffer's
//! kind come first, so a panel's keys work in every mode: the mode's, the
//! leader's and those of the modes it inherits for that kind, then those
//! for the kind in any mode. Then the layers the mode inherits ahead of
//! its own (an editing style's role layer), those it enters with keys
//! (the leader), the mode's own, the layers it inherits after (the role's
//! for every style, other modes), and global. The first layer a
//! key sequence leads anywhere in decides what it does.

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

    /// The name of the layer for an editing role, like "typing", in every
    /// style; each style's mode for the role inherits it.
    pub fn role_name(role: &str) -> String {
        format!("role:{role}")
    }

    /// The name of the layer for an editing role in one style, which the
    /// style's mode for the role uses ahead of its own keys.
    pub fn style_role_name(style: &str, role: &str) -> String {
        format!("{style}:{role}")
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

/// A key sequence, the command it runs and the plugin that bound it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bound {
    pub keys: Vec<Key>,
    pub command: Arc<str>,
    pub owner: PluginId,
}

/// A binding that hides another in the same layer, from
/// [`Keymap::shadowed`]. `under` may be for the same keys, a shorter start
/// of them or a longer sequence starting with them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Shadow {
    pub layer: Layer,
    pub over: Bound,
    pub under: Bound,
}

/// What happened to a layer, in order. The layer's trie is these replayed.
#[derive(Debug, Clone)]
enum Op {
    Bind(Vec<Key>, Arc<str>),
    Unbind(Vec<Key>),
    Clear,
}

#[derive(Debug, Clone)]
struct Entry {
    owner: PluginId,
    op: Op,
}

#[derive(Debug, Clone)]
struct Binding {
    command: Arc<str>,
    owner: PluginId,
}

impl Binding {
    fn at(&self, keys: &[Key]) -> Bound {
        Bound {
            keys: keys.to_vec(),
            command: self.command.clone(),
            owner: self.owner.clone(),
        }
    }
}

/// A mode falling back to another mode's or layer's bindings.
#[derive(Debug, PartialEq)]
struct Inherit {
    parent: Arc<str>,
    /// Only sequences starting with one of these; all of them if empty.
    prefixes: Vec<Vec<Key>>,
    /// For a layer entered with keys ([`Keymap::enter`]): those keys, after
    /// which the parent's bindings follow.
    entry: Option<Vec<Key>>,
    /// Whether the parent's bindings come ahead of the mode's own
    /// ([`Keymap::inherit_first`]).
    first: bool,
    owner: PluginId,
}

impl Inherit {
    /// Whether `keys`, typed in full or in part, fall under the prefixes.
    fn covers(&self, keys: &[Key]) -> bool {
        self.prefixes.is_empty()
            || self
                .prefixes
                .iter()
                .any(|p| keys.starts_with(p) || p.starts_with(keys))
    }
}

/// A layer to look in for a mode, and the inheritances that led there,
/// from the mode outwards.
struct Step<'a> {
    layer: Layer,
    via: Vec<&'a Inherit>,
}

impl<'a> Step<'a> {
    fn direct(layer: Layer) -> Self {
        Self {
            layer,
            via: Vec::new(),
        }
    }

    fn through(layer: Layer, via: &[&'a Inherit]) -> Self {
        Self {
            layer,
            via: via.to_vec(),
        }
    }
}

/// Keys typed in a mode, as a layer it inherits sees them.
enum Through<'k> {
    /// These keys, after the entry keys of the layers on the way.
    Keys(&'k [Key]),
    /// The keys typed so far are the start of an entry; this key comes next.
    Entering(Key),
}

/// Where keys lead in one layer.
enum At<'a> {
    Command(&'a Binding),
    /// The start of longer sequences, or the layer itself.
    Prefix(&'a HashMap<Key, Node>),
    /// Part of the keys that enter the layer, and the key that comes next.
    Entering(Key),
}

/// How `keys` typed in a mode reach a layer through `via`, if they do.
fn through<'k>(via: &[&Inherit], keys: &'k [Key]) -> Option<Through<'k>> {
    let mut keys = keys;
    for inherit in via {
        match &inherit.entry {
            Some(entry) => match keys.strip_prefix(entry.as_slice()) {
                Some(rest) => keys = rest,
                None if entry.starts_with(keys) => {
                    return Some(Through::Entering(entry[keys.len()]));
                }
                None => return None,
            },
            None if inherit.covers(keys) => {}
            None => return None,
        }
    }
    Some(Through::Keys(keys))
}

#[derive(Debug)]
enum Node {
    Command(Binding),
    Prefix(HashMap<Key, Node>),
}

#[derive(Debug, Default)]
pub struct Keymap {
    /// Every change to each layer, oldest first.
    log: HashMap<Layer, Vec<Entry>>,
    /// Each layer's bindings: its log replayed.
    layers: HashMap<Layer, HashMap<Key, Node>>,
    /// Per mode, the command that handles a single unbound key (e.g. insert
    /// mode inserting the character). Oldest first; the last is active.
    fallbacks: HashMap<Arc<str>, Vec<Binding>>,
    /// Modes where digits before a key sequence are a count, and which
    /// plugins turned that on.
    counts: HashMap<Arc<str>, Vec<PluginId>>,
    /// Modes that use only their own keys, and which plugins made them so.
    isolated: HashMap<Arc<str>, Vec<PluginId>>,
    /// Per mode, the modes and layers it falls back to, in the order they
    /// were added.
    inherits: HashMap<Arc<str>, Vec<Inherit>>,
}

impl Keymap {
    /// Binds a key sequence to a command. A newer binding wins over older
    /// ones it conflicts with, which come back if its owner is removed.
    /// Conflicting with the owner's own bindings is an error.
    pub fn bind(
        &mut self,
        layer: Layer,
        keys: &[Key],
        command: impl Into<Arc<str>>,
        owner: impl Into<PluginId>,
    ) -> Result<(), BindError> {
        if keys.is_empty() {
            return Err(BindError::Empty);
        }
        let owner = owner.into();
        if let Some(children) = self.layers.get(&layer)
            && conflicts(children, keys, &owner)
        {
            return Err(BindError::Conflict {
                keys: format_keys(keys),
            });
        }
        self.record(layer, owner, Op::Bind(keys.to_vec(), command.into()));
        Ok(())
    }

    /// Hides whatever `keys` runs in `layer`, until `owner` is removed.
    pub fn unbind(&mut self, layer: Layer, keys: &[Key], owner: impl Into<PluginId>) {
        self.record(layer, owner.into(), Op::Unbind(keys.to_vec()));
    }

    /// Hides every binding in `layer` so far, until `owner` is removed.
    /// Bindings made afterwards apply as usual.
    pub fn clear(&mut self, layer: Layer, owner: impl Into<PluginId>) {
        self.record(layer, owner.into(), Op::Clear);
    }

    /// Adds a change to `layer`'s log, and makes it to the trie, which is
    /// what replaying the log would build.
    fn record(&mut self, layer: Layer, owner: PluginId, op: Op) {
        let entry = Entry { owner, op };
        let mut children = self.layers.remove(&layer).unwrap_or_default();
        apply(&mut children, &entry);
        self.log.entry(layer.clone()).or_default().push(entry);
        self.keep(layer, children);
    }

    /// Rebuilds `layer`'s trie from its log.
    fn replay(&mut self, layer: Layer) {
        let mut children = HashMap::new();
        for entry in self.log.get(&layer).into_iter().flatten() {
            apply(&mut children, entry);
        }
        self.keep(layer, children);
    }

    fn keep(&mut self, layer: Layer, children: HashMap<Key, Node>) {
        if children.is_empty() {
            self.layers.remove(&layer);
        } else {
            self.layers.insert(layer, children);
        }
    }

    /// Makes `mode` fall back to `parent`'s bindings for key sequences
    /// starting with one of `prefixes` (any sequence if there are none),
    /// until `owner` is removed. Bindings of `mode` itself come first, and
    /// `parent`'s own inheritances apply in turn. Asking again for the same
    /// owner changes nothing.
    pub fn inherit(
        &mut self,
        mode: &str,
        parent: &str,
        prefixes: Vec<Vec<Key>>,
        owner: impl Into<PluginId>,
    ) {
        self.add_inherit(
            mode,
            Inherit {
                parent: parent.into(),
                prefixes,
                entry: None,
                first: false,
                owner: owner.into(),
            },
        );
    }

    /// Makes `mode` use `parent`'s bindings ahead of its own, until `owner`
    /// is removed, e.g. for keys bound for one editing style's role over
    /// those the style binds itself. Asking again for the same owner
    /// changes nothing.
    pub fn inherit_first(&mut self, mode: &str, parent: &str, owner: impl Into<PluginId>) {
        self.add_inherit(
            mode,
            Inherit {
                parent: parent.into(),
                prefixes: Vec::new(),
                entry: None,
                first: true,
                owner: owner.into(),
            },
        );
    }

    /// Makes `keys` typed in `mode` lead into `layer`: what's bound there
    /// works after them, as if bound in `mode` behind `keys`, until `owner`
    /// is removed. Each editing style enters the shared leader layer this
    /// way, e.g. Helix's mode with `space`. It comes ahead of `mode`'s own
    /// keys, so the keys that enter it start nothing else. Asking again for
    /// the same owner changes nothing.
    pub fn enter(&mut self, mode: &str, keys: Vec<Key>, layer: &str, owner: impl Into<PluginId>) {
        self.add_inherit(
            mode,
            Inherit {
                parent: layer.into(),
                prefixes: Vec::new(),
                entry: Some(keys),
                first: false,
                owner: owner.into(),
            },
        );
    }

    fn add_inherit(&mut self, mode: &str, inherit: Inherit) {
        let inherits = self.inherits.entry(mode.into()).or_default();
        if !inherits.contains(&inherit) {
            inherits.push(inherit);
        }
    }

    /// The layers that apply in `mode` for a buffer of `kind`, most specific
    /// first, each with the inheritances that brought it in.
    fn lookup_order(&self, mode: &str, kind: &str) -> Vec<Step<'_>> {
        // An isolated mode keeps the layers it enters with keys of its own,
        // like the leader: it said so itself.
        if self.isolated.contains_key(mode) {
            let entered = self
                .inherits
                .get(mode)
                .map_or(&[][..], Vec::as_slice)
                .iter()
                .filter(|i| i.entry.is_some());
            let mut steps = vec![Step::direct(Layer::mode_kind(mode, kind))];
            for inherit in entered.clone() {
                steps.push(Step::through(
                    Layer::mode_kind(&inherit.parent, kind),
                    &[inherit],
                ));
            }
            for inherit in entered {
                steps.push(Step::through(Layer::mode(&inherit.parent), &[inherit]));
            }
            steps.push(Step::direct(Layer::mode(mode)));
            return steps;
        }
        let (mut kinds, mut modes) = (Vec::new(), Vec::new());
        self.expand(mode, kind, &mut Vec::new(), &mut kinds, &mut modes);
        kinds.push(Step::direct(Layer::kind(kind)));
        kinds.append(&mut modes);
        kinds.push(Step::direct(Layer::global()));
        kinds
    }

    /// Adds the layers of `mode`, reached through `via`, to `kinds` (those
    /// for the buffer kind) and `modes` (the others): first those of the
    /// modes it inherits ahead of its own, then its own and the layers it
    /// enters with keys (the latter ahead of its own in `modes`), then
    /// those of the modes it inherits after, each with theirs in turn.
    fn expand<'a>(
        &'a self,
        mode: &str,
        kind: &str,
        via: &mut Vec<&'a Inherit>,
        kinds: &mut Vec<Step<'a>>,
        modes: &mut Vec<Step<'a>>,
    ) {
        let inherits = self.inherits.get(mode).map_or(&[][..], Vec::as_slice);
        for inherit in inherits.iter().filter(|i| i.first) {
            self.expand_parent(inherit, kind, via, kinds, modes);
        }
        kinds.push(Step::through(Layer::mode_kind(mode, kind), via));
        for inherit in inherits.iter().filter(|i| i.entry.is_some()) {
            via.push(inherit);
            kinds.push(Step::through(Layer::mode_kind(&inherit.parent, kind), via));
            modes.push(Step::through(Layer::mode(&inherit.parent), via));
            via.pop();
        }
        modes.push(Step::through(Layer::mode(mode), via));
        for inherit in inherits.iter().filter(|i| !i.first && i.entry.is_none()) {
            self.expand_parent(inherit, kind, via, kinds, modes);
        }
    }

    fn expand_parent<'a>(
        &'a self,
        inherit: &'a Inherit,
        kind: &str,
        via: &mut Vec<&'a Inherit>,
        kinds: &mut Vec<Step<'a>>,
        modes: &mut Vec<Step<'a>>,
    ) {
        // Modes can inherit from each other in a loop.
        if via.len() > 8 || via.iter().any(|i| i.parent == inherit.parent) {
            return;
        }
        via.push(inherit);
        self.expand(&inherit.parent, kind, via, kinds, modes);
        via.pop();
    }

    /// Where `keys`, typed in a mode, lead in the layer `step` looks in.
    fn locate<'a>(&'a self, step: &Step<'a>, keys: &[Key]) -> Option<At<'a>> {
        match through(&step.via, keys)? {
            Through::Keys([]) => self.layers.get(&step.layer).map(At::Prefix),
            Through::Keys(keys) => Some(match self.lookup(&step.layer, keys)? {
                Node::Command(binding) => At::Command(binding),
                Node::Prefix(children) => At::Prefix(children),
            }),
            Through::Entering(next) => self
                .layers
                .contains_key(&step.layer)
                .then_some(At::Entering(next)),
        }
    }

    /// Resolves a key sequence in `mode` for a buffer of `kind`. The most
    /// specific layer the keys lead anywhere in decides, whether to a
    /// command or to the start of longer sequences.
    pub fn resolve(&self, mode: &str, kind: &str, keys: &[Key]) -> Resolution {
        if keys.is_empty() {
            return Resolution::Unbound;
        }
        for step in self.lookup_order(mode, kind) {
            match self.locate(&step, keys) {
                Some(At::Command(active)) => return Resolution::Command(active.command.clone()),
                Some(At::Prefix(_) | At::Entering(_)) => return Resolution::Pending,
                None => {}
            }
        }
        Resolution::Unbound
    }

    /// Every layer where `keys` is bound, most specific first, with the
    /// active binding in each.
    pub fn describe(&self, mode: &str, kind: &str, keys: &[Key]) -> Vec<Found> {
        self.lookup_order(mode, kind)
            .into_iter()
            .filter_map(|step| match self.locate(&step, keys)? {
                At::Command(active) => Some(Found {
                    layer: step.layer,
                    command: active.command.clone(),
                    owner: active.owner.clone(),
                }),
                At::Prefix(_) | At::Entering(_) => None,
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

    /// The command that handles an unbound key in `mode`: its own, or else
    /// that of a mode it inherits every key from.
    pub fn fallback(&self, mode: &str) -> Option<&Arc<str>> {
        self.fallback_within(mode, 0)
    }

    fn fallback_within(&self, mode: &str, depth: usize) -> Option<&Arc<str>> {
        if let Some(binding) = self.fallbacks.get(mode).and_then(|b| b.last()) {
            return Some(&binding.command);
        }
        // Modes can inherit from each other in a loop.
        if depth > 8 {
            return None;
        }
        self.inherits
            .get(mode)?
            .iter()
            .filter(|inherit| inherit.prefixes.is_empty() && inherit.entry.is_none())
            .find_map(|inherit| self.fallback_within(&inherit.parent, depth + 1))
    }

    /// Makes digits typed before a key sequence in `mode` a count for the
    /// command it runs.
    pub fn enable_counts(&mut self, mode: &str, owner: impl Into<PluginId>) {
        self.counts
            .entry(mode.into())
            .or_default()
            .push(owner.into());
    }

    pub fn counts(&self, mode: &str) -> bool {
        self.counts.contains_key(mode)
    }

    /// Makes `mode` use only the keys bound in it, ignoring inherited modes
    /// and the layers for every mode or a buffer kind, e.g. for a terminal
    /// that takes every key.
    pub fn isolate(&mut self, mode: &str, owner: impl Into<PluginId>) {
        self.isolated
            .entry(mode.into())
            .or_default()
            .push(owner.into());
    }

    /// The keys that can follow `prefix` in `mode` for a buffer of `kind`, and
    /// what each does, sorted by key. A more specific layer hides the same
    /// key in a less specific one.
    pub fn continuations(&self, mode: &str, kind: &str, prefix: &[Key]) -> Vec<(Key, Next)> {
        let mut found: Vec<(Key, Next)> = Vec::new();
        let mut keys = prefix.to_vec();
        for step in self.lookup_order(mode, kind) {
            let children = match self.locate(&step, prefix) {
                Some(At::Prefix(children)) => children,
                Some(At::Entering(next)) => {
                    if !found.iter().any(|(k, _)| *k == next) {
                        found.push((next, Next::Prefix));
                    }
                    continue;
                }
                Some(At::Command(_)) | None => continue,
            };
            for (key, node) in children {
                if found.iter().any(|(k, _)| k == key) {
                    continue;
                }
                keys.push(*key);
                let covered = matches!(through(&step.via, &keys), Some(Through::Keys(_)));
                keys.pop();
                if !covered {
                    continue;
                }
                let next = match node {
                    Node::Command(active) => Next::Command(active.command.clone()),
                    Node::Prefix(_) => Next::Prefix,
                };
                found.push((*key, next));
            }
        }
        found.sort_by_key(|(key, _)| key.to_string());
        found
    }

    /// Every key sequence that runs a command in `mode` for a buffer of
    /// `kind`, with the command, sorted by keys: what the layers that apply
    /// bind, after the keys that enter them, less what a more specific
    /// layer hides.
    pub fn reachable(&self, mode: &str, kind: &str) -> Vec<(Vec<Key>, Arc<str>)> {
        let mut found: Vec<(Vec<Key>, Arc<str>)> = Vec::new();
        for step in self.lookup_order(mode, kind) {
            let Some(children) = self.layers.get(&step.layer) else {
                continue;
            };
            let entry: Vec<Key> = step
                .via
                .iter()
                .filter_map(|i| i.entry.as_deref())
                .flatten()
                .copied()
                .collect();
            collect_bindings(children, None, &mut Vec::new(), &mut |keys, command| {
                let mut typed = entry.clone();
                typed.extend(keys);
                if !found.iter().any(|(k, _)| *k == typed)
                    && self.resolve(mode, kind, &typed) == Resolution::Command(command.clone())
                {
                    found.push((typed, command.clone()));
                }
            });
        }
        found.sort_by_cached_key(|(keys, _)| format_keys(keys));
        found
    }

    /// Every key sequence, in every layer, whose active binding runs
    /// `command`.
    pub fn bindings_for(&self, command: &str) -> Vec<(Layer, Vec<Key>)> {
        let mut found = Vec::new();
        for (layer, children) in &self.layers {
            collect_bindings(children, Some(command), &mut Vec::new(), &mut |keys, _| {
                found.push((layer.clone(), keys));
            });
        }
        found
    }

    /// Every active binding, in every layer: its layer, keys and command.
    pub fn bindings(&self) -> Vec<(Layer, Vec<Key>, Arc<str>)> {
        let mut found = Vec::new();
        for (layer, children) in &self.layers {
            collect_bindings(children, None, &mut Vec::new(), &mut |keys, command| {
                found.push((layer.clone(), keys, command.clone()));
            });
        }
        found
    }

    /// The active bindings in `layer` that binding `keys` to `command` would
    /// hide. Binding the same keys to the same command again hides nothing.
    pub fn hides(&self, layer: &Layer, keys: &[Key], command: &str) -> Vec<Bound> {
        self.layers
            .get(layer)
            .map(|children| hidden(children, keys, command))
            .unwrap_or_default()
    }

    /// Every binding that hid another in its layer when it was made, and
    /// still does, in the order they were made.
    pub fn shadowed(&self) -> Vec<Shadow> {
        let mut found = Vec::new();
        for (layer, entries) in &self.log {
            let mut children = HashMap::new();
            for entry in entries {
                if let Op::Bind(keys, command) = &entry.op {
                    for under in hidden(&children, keys, command) {
                        let over = Bound {
                            keys: keys.clone(),
                            command: command.clone(),
                            owner: entry.owner.clone(),
                        };
                        found.push(Shadow {
                            layer: layer.clone(),
                            over,
                            under,
                        });
                    }
                }
                apply(&mut children, entry);
            }
        }
        found.retain(|shadow| {
            matches!(
                self.lookup(&shadow.layer, &shadow.over.keys),
                Some(Node::Command(active)) if active.command == shadow.over.command
                    && active.owner == shadow.over.owner
            )
        });
        found
    }

    /// Removes everything `owner` did.
    pub fn remove_owned_by(&mut self, owner: &str) {
        let changed: Vec<Layer> = self
            .log
            .iter_mut()
            .filter_map(|(layer, entries)| {
                let before = entries.len();
                entries.retain(|e| &*e.owner != owner);
                (entries.len() != before).then(|| layer.clone())
            })
            .collect();
        self.log.retain(|_, entries| !entries.is_empty());
        for layer in changed {
            self.replay(layer);
        }
        for bindings in self.fallbacks.values_mut() {
            bindings.retain(|b| &*b.owner != owner);
        }
        self.fallbacks.retain(|_, bindings| !bindings.is_empty());
        for owners in self.counts.values_mut() {
            owners.retain(|o| &**o != owner);
        }
        self.counts.retain(|_, owners| !owners.is_empty());
        for owners in self.isolated.values_mut() {
            owners.retain(|o| &**o != owner);
        }
        self.isolated.retain(|_, owners| !owners.is_empty());
        for inherits in self.inherits.values_mut() {
            inherits.retain(|i| &*i.owner != owner);
        }
        self.inherits.retain(|_, inherits| !inherits.is_empty());
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

/// Whether binding `keys` would replace one of `owner`'s own bindings: a
/// shorter sequence it bound, or longer ones starting with `keys`.
fn conflicts(children: &HashMap<Key, Node>, keys: &[Key], owner: &str) -> bool {
    let (last, prefix) = keys.split_last().expect("keys aren't empty");
    let mut children = children;
    for key in prefix {
        match children.get(key) {
            Some(Node::Prefix(next)) => children = next,
            Some(Node::Command(b)) => return &*b.owner == owner,
            None => return false,
        }
    }
    match children.get(last) {
        Some(Node::Prefix(next)) => owns_any(next, owner),
        Some(Node::Command(_)) | None => false,
    }
}

/// The bindings in `children` that binding `keys` to `command` would hide:
/// one for `keys` or a shorter start of them, or those for longer
/// sequences starting with `keys`.
fn hidden(children: &HashMap<Key, Node>, keys: &[Key], command: &str) -> Vec<Bound> {
    let mut children = children;
    for (i, key) in keys.iter().enumerate() {
        match children.get(key) {
            None => return Vec::new(),
            Some(Node::Command(b)) => {
                let same = i + 1 == keys.len() && *b.command == *command;
                return if same {
                    Vec::new()
                } else {
                    vec![b.at(&keys[..=i])]
                };
            }
            Some(Node::Prefix(next)) => children = next,
        }
    }
    let mut found = Vec::new();
    bound_under(children, &mut keys.to_vec(), &mut found);
    found
}

/// Every binding under `children`, whose sequences start with `prefix`.
fn bound_under(children: &HashMap<Key, Node>, prefix: &mut Vec<Key>, found: &mut Vec<Bound>) {
    for (key, node) in children {
        prefix.push(*key);
        match node {
            Node::Command(b) => found.push(b.at(prefix)),
            Node::Prefix(next) => bound_under(next, prefix, found),
        }
        prefix.pop();
    }
}

fn owns_any(children: &HashMap<Key, Node>, owner: &str) -> bool {
    children.values().any(|node| match node {
        Node::Command(b) => &*b.owner == owner,
        Node::Prefix(next) => owns_any(next, owner),
    })
}

/// Makes the change `entry` logs to a layer's trie.
fn apply(children: &mut HashMap<Key, Node>, entry: &Entry) {
    match &entry.op {
        Op::Bind(keys, command) => insert(
            children,
            keys,
            Binding {
                command: command.clone(),
                owner: entry.owner.clone(),
            },
        ),
        Op::Unbind(keys) => remove(children, keys),
        Op::Clear => children.clear(),
    }
}

/// Binds `keys`, replacing whatever it conflicts with.
fn insert(children: &mut HashMap<Key, Node>, keys: &[Key], binding: Binding) {
    let (last, prefix) = keys.split_last().expect("keys aren't empty");
    let mut children = children;
    for key in prefix {
        let node = children
            .entry(*key)
            .or_insert_with(|| Node::Prefix(HashMap::new()));
        if matches!(node, Node::Command(_)) {
            *node = Node::Prefix(HashMap::new());
        }
        let Node::Prefix(next) = node else {
            unreachable!("made a prefix above")
        };
        children = next;
    }
    children.insert(*last, Node::Command(binding));
}

/// Removes `keys` and everything after it, and prefixes left empty.
fn remove(children: &mut HashMap<Key, Node>, keys: &[Key]) {
    let Some((first, rest)) = keys.split_first() else {
        return;
    };
    if rest.is_empty() {
        children.remove(first);
        return;
    }
    if let Some(Node::Prefix(next)) = children.get_mut(first) {
        remove(next, rest);
        if next.is_empty() {
            children.remove(first);
        }
    }
}

fn format_keys(keys: &[Key]) -> String {
    keys.iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(" ")
}

/// Calls `found` with each key sequence under `children` and the command it
/// runs, for `command` only if given.
fn collect_bindings(
    children: &HashMap<Key, Node>,
    command: Option<&str>,
    prefix: &mut Vec<Key>,
    found: &mut impl FnMut(Vec<Key>, &Arc<str>),
) {
    for (key, node) in children {
        prefix.push(*key);
        match node {
            Node::Command(binding) => {
                if command.is_none_or(|c| *binding.command == *c) {
                    found(prefix.clone(), &binding.command);
                }
            }
            Node::Prefix(next) => collect_bindings(next, command, prefix, found),
        }
        prefix.pop();
    }
}

// Keys travel between clients and the server as their names, e.g. "ctrl-s".
impl serde::Serialize for Key {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(self)
    }
}

impl<'de> serde::Deserialize<'de> for Key {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let name = String::deserialize(deserializer)?;
        Key::parse(&name).map_err(serde::de::Error::custom)
    }
}
