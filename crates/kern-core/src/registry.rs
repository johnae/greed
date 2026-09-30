//! The registry of named things plugins define: commands, event handlers and
//! options.
//!
//! Everything is owned by the plugin that registered it, so a plugin can be
//! removed or reloaded cleanly. Commands keep every definition, so removing a
//! plugin restores whatever it overrode and `definitions` can answer "who
//! overrides this?".

use std::collections::HashMap;
use std::fmt;
use std::sync::Arc;

/// A plugin name, e.g. `"core"` or `"user/jump-to-crate"`.
pub type PluginId = Arc<str>;

/// Where something was defined.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Source {
    pub file: Arc<str>,
    pub line: u32,
}

#[derive(Debug, Clone)]
pub struct Command<H> {
    pub name: Arc<str>,
    pub doc: Arc<str>,
    pub owner: PluginId,
    pub source: Option<Source>,
    pub handler: H,
}

#[derive(Debug, Clone)]
pub struct EventHandler<H> {
    pub owner: PluginId,
    pub source: Option<Source>,
    pub handler: H,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Bool(bool),
    Int(i64),
    Float(f64),
    String(Arc<str>),
}

impl Value {
    pub fn type_name(&self) -> &'static str {
        match self {
            Value::Bool(_) => "bool",
            Value::Int(_) => "int",
            Value::Float(_) => "float",
            Value::String(_) => "string",
        }
    }
}

#[derive(Debug, Clone)]
pub struct OptionDef {
    pub name: Arc<str>,
    pub doc: Arc<str>,
    pub owner: PluginId,
    pub default: Value,
}

#[derive(Debug, Clone, PartialEq)]
pub enum OptionError {
    Unknown(Arc<str>),
    WrongType {
        name: Arc<str>,
        expected: &'static str,
        actual: &'static str,
    },
}

impl fmt::Display for OptionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            OptionError::Unknown(name) => write!(f, "there is no option called {name:?}"),
            OptionError::WrongType {
                name,
                expected,
                actual,
            } => write!(f, "option {name:?} takes a {expected}, not a {actual}"),
        }
    }
}

impl std::error::Error for OptionError {}

#[derive(Debug)]
struct OptionSlot {
    def: OptionDef,
    value: Value,
}

#[derive(Debug)]
pub struct Registry<H> {
    /// Every definition of each command, oldest first. The last one is active.
    commands: HashMap<Arc<str>, Vec<Command<H>>>,
    events: HashMap<Arc<str>, Vec<EventHandler<H>>>,
    options: HashMap<Arc<str>, OptionSlot>,
}

impl<H> Default for Registry<H> {
    fn default() -> Self {
        Self {
            commands: HashMap::new(),
            events: HashMap::new(),
            options: HashMap::new(),
        }
    }
}

impl<H> Registry<H> {
    /// Adds a command. An existing command with the same name stays defined
    /// underneath and comes back if this one's owner is removed.
    pub fn add_command(&mut self, command: Command<H>) {
        self.commands
            .entry(command.name.clone())
            .or_default()
            .push(command);
    }

    /// The active definition of a command.
    pub fn command(&self, name: &str) -> Option<&Command<H>> {
        self.commands.get(name).and_then(|defs| defs.last())
    }

    /// Every definition of a command, oldest first.
    pub fn definitions(&self, name: &str) -> &[Command<H>] {
        self.commands.get(name).map_or(&[], Vec::as_slice)
    }

    /// Active commands, sorted by name.
    pub fn commands(&self) -> impl Iterator<Item = &Command<H>> {
        let mut active: Vec<&Command<H>> = self
            .commands
            .values()
            .filter_map(|defs| defs.last())
            .collect();
        active.sort_unstable_by(|a, b| a.name.cmp(&b.name));
        active.into_iter()
    }

    pub fn on(
        &mut self,
        event: impl Into<Arc<str>>,
        owner: impl Into<PluginId>,
        source: Option<Source>,
        handler: H,
    ) {
        self.events
            .entry(event.into())
            .or_default()
            .push(EventHandler {
                owner: owner.into(),
                source,
                handler,
            });
    }

    /// Handlers for an event, in the order they were registered.
    pub fn handlers(&self, event: &str) -> &[EventHandler<H>] {
        self.events.get(event).map_or(&[], Vec::as_slice)
    }

    /// Defines an option, set to its default.
    pub fn define_option(&mut self, def: OptionDef) {
        let value = def.default.clone();
        self.options
            .insert(def.name.clone(), OptionSlot { def, value });
    }

    pub fn option(&self, name: &str) -> Option<&Value> {
        self.options.get(name).map(|slot| &slot.value)
    }

    pub fn option_def(&self, name: &str) -> Option<&OptionDef> {
        self.options.get(name).map(|slot| &slot.def)
    }

    pub fn set_option(&mut self, name: &str, value: Value) -> Result<(), OptionError> {
        let slot = self
            .options
            .get_mut(name)
            .ok_or_else(|| OptionError::Unknown(name.into()))?;
        if std::mem::discriminant(&slot.value) != std::mem::discriminant(&value) {
            return Err(OptionError::WrongType {
                name: name.into(),
                expected: slot.value.type_name(),
                actual: value.type_name(),
            });
        }
        slot.value = value;
        Ok(())
    }

    /// Removes everything `owner` registered.
    pub fn remove_owned_by(&mut self, owner: &str) {
        for defs in self.commands.values_mut() {
            defs.retain(|c| &*c.owner != owner);
        }
        self.commands.retain(|_, defs| !defs.is_empty());
        for handlers in self.events.values_mut() {
            handlers.retain(|h| &*h.owner != owner);
        }
        self.events.retain(|_, handlers| !handlers.is_empty());
        self.options.retain(|_, slot| &*slot.def.owner != owner);
    }
}
