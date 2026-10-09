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

use greed_text::ClientId;

/// A plugin name, e.g. `"core"` or `"user/jump-to-crate"`.
pub type PluginId = Arc<str>;

/// Where something was defined.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Source {
    pub file: Arc<str>,
    pub line: u32,
}

/// An argument a command takes, for completion and help.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Arg {
    pub name: Arc<str>,
    pub doc: Arc<str>,
    /// What completes it, e.g. "file"; the command line decides what each
    /// name means.
    pub complete: Option<Arc<str>>,
}

#[derive(Debug, Clone)]
pub struct Command<H> {
    pub name: Arc<str>,
    pub doc: Arc<str>,
    pub args: Vec<Arg>,
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

impl fmt::Display for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Value::Bool(b) => write!(f, "{b}"),
            Value::Int(i) => write!(f, "{i}"),
            Value::Float(x) => write!(f, "{x}"),
            Value::String(s) => f.write_str(s),
        }
    }
}

#[derive(Debug, Clone)]
pub struct OptionDef {
    pub name: Arc<str>,
    pub doc: Arc<str>,
    pub owner: PluginId,
    pub source: Option<Source>,
    pub default: Value,
    /// The values it can take; empty when any value of its type will do.
    pub choices: Vec<Value>,
    /// The capability code needs to set it, for an option whose value runs
    /// something (a program, Luau) or trusts agents more.
    pub needs: Option<Arc<str>>,
}

impl OptionDef {
    /// Whether `value` is one of its choices, or any value when it has none.
    fn allows(&self, value: &Value) -> bool {
        self.choices.is_empty() || self.choices.contains(value)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum OptionError {
    /// No option is called `name`; `like` are names that look like it.
    Unknown { name: Arc<str>, like: Vec<Arc<str>> },
    WrongType {
        name: Arc<str>,
        expected: &'static str,
        actual: &'static str,
    },
    NotAChoice {
        name: Arc<str>,
        value: Value,
        choices: Vec<Value>,
    },
}

impl fmt::Display for OptionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            OptionError::Unknown { name, like } => {
                write!(f, "there is no option called {name:?}")?;
                if !like.is_empty() {
                    let like: Vec<String> = like.iter().map(|n| format!("{n:?}")).collect();
                    write!(f, "; did you mean {}?", like.join(" or "))?;
                }
                Ok(())
            }
            OptionError::WrongType {
                name,
                expected,
                actual,
            } => write!(f, "option {name:?} takes a {expected}, not a {actual}"),
            OptionError::NotAChoice {
                name,
                value,
                choices,
            } => {
                let choices: Vec<String> = choices.iter().map(ToString::to_string).collect();
                write!(
                    f,
                    "option {name:?} can't be \"{value}\"; it takes one of: {}",
                    choices.join(", ")
                )
            }
        }
    }
}

impl std::error::Error for OptionError {}

#[derive(Debug)]
struct OptionSlot {
    def: OptionDef,
    value: Value,
    /// The plugin that last set it, if anything has since it was defined.
    set_by: Option<PluginId>,
    /// Whether anything set it since it was defined.
    set: bool,
}

/// An option as it stands: how it was defined, its value, and who set it.
pub struct OptionState<'a> {
    pub def: &'a OptionDef,
    pub value: &'a Value,
    pub set_by: Option<&'a PluginId>,
}

#[derive(Debug)]
pub struct Registry<H> {
    /// Every definition of each command, oldest first. The last one is active.
    commands: HashMap<Arc<str>, Vec<Command<H>>>,
    events: HashMap<Arc<str>, Vec<EventHandler<H>>>,
    options: HashMap<Arc<str>, OptionSlot>,
    /// The values set on options whose plugin was removed, and who set
    /// them, for when it defines them again.
    kept: HashMap<Arc<str>, (Value, Option<PluginId>)>,
    /// Values of options that one client has for itself, like a window's
    /// own font size, over the value every other client has.
    own: HashMap<ClientId, HashMap<Arc<str>, Value>>,
}

impl<H> Default for Registry<H> {
    fn default() -> Self {
        Self {
            commands: HashMap::new(),
            events: HashMap::new(),
            options: HashMap::new(),
            kept: HashMap::new(),
            own: HashMap::new(),
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

    /// Removes `owner`'s handlers for `event` that `matches` picks. False if
    /// there were none.
    pub fn off(&mut self, event: &str, owner: &str, matches: impl Fn(&H) -> bool) -> bool {
        let Some(handlers) = self.events.get_mut(event) else {
            return false;
        };
        let before = handlers.len();
        handlers.retain(|h| &*h.owner != owner || !matches(&h.handler));
        let removed = handlers.len() != before;
        if handlers.is_empty() {
            self.events.remove(event);
        }
        removed
    }

    /// Handlers for an event, in the order they were registered.
    pub fn handlers(&self, event: &str) -> &[EventHandler<H>] {
        self.events.get(event).map_or(&[], Vec::as_slice)
    }

    /// Every event something listens for, with its handlers, in no
    /// particular order.
    pub fn events(&self) -> impl Iterator<Item = (&str, &[EventHandler<H>])> {
        self.events
            .iter()
            .map(|(event, handlers)| (&**event, handlers.as_slice()))
    }

    /// Defines an option, set to its default. An option of the same name and
    /// type that was set, even one whose plugin was removed since, as when
    /// it reloads, keeps its value and who set it, if that value is still
    /// one of its choices.
    pub fn define_option(&mut self, def: OptionDef) {
        let earlier = self
            .options
            .remove(&def.name)
            .filter(|slot| slot.set)
            .map(|slot| (slot.value, slot.set_by))
            .or_else(|| self.kept.remove(&def.name))
            .filter(|(value, _)| {
                std::mem::discriminant(value) == std::mem::discriminant(&def.default)
                    && def.allows(value)
            });
        let set = earlier.is_some();
        let (value, set_by) = earlier.unwrap_or_else(|| (def.default.clone(), None));
        self.options.insert(
            def.name.clone(),
            OptionSlot {
                def,
                value,
                set_by,
                set,
            },
        );
    }

    pub fn option(&self, name: &str) -> Option<&Value> {
        self.options.get(name).map(|slot| &slot.value)
    }

    pub fn option_def(&self, name: &str) -> Option<&OptionDef> {
        self.options.get(name).map(|slot| &slot.def)
    }

    /// Every option with its definition, value and who last set it, in no
    /// particular order.
    pub fn option_states(&self) -> impl Iterator<Item = OptionState<'_>> {
        self.options.values().map(|slot| OptionState {
            def: &slot.def,
            value: &slot.value,
            set_by: slot.set_by.as_ref(),
        })
    }

    pub fn set_option(&mut self, name: &str, value: Value) -> Result<(), OptionError> {
        self.set_option_by(name, value, None)
    }

    /// Sets an option, noting `by` as the plugin that set it. It's set for
    /// every client: one that had a value of its own takes this one too.
    pub fn set_option_by(
        &mut self,
        name: &str,
        value: Value,
        by: Option<PluginId>,
    ) -> Result<(), OptionError> {
        let slot = self.checked(name, &value)?;
        slot.value = value;
        slot.set_by = by;
        slot.set = true;
        for own in self.own.values_mut() {
            own.remove(name);
        }
        Ok(())
    }

    /// Up to three option names like `name`, best first: the same with
    /// dashes for underscores, or sharing a word of four letters or more
    /// (`relativenumber` and `line-numbers` share "number").
    fn options_like(&self, name: &str) -> Vec<Arc<str>> {
        let wanted = name.to_lowercase().replace(['_', ' '], "-");
        let stem = |word: &str| word.strip_suffix('s').unwrap_or(word).to_owned();
        let words: Vec<String> = wanted
            .split('-')
            .filter(|w| w.len() >= 4)
            .map(stem)
            .collect();
        let mut like: Vec<(usize, &Arc<str>)> = self
            .options
            .keys()
            .filter_map(|option| {
                if **option == *wanted {
                    return Some((usize::MAX, option));
                }
                let shared = option
                    .split('-')
                    .map(stem)
                    .filter(|word| word.len() >= 4)
                    .filter(|word| {
                        wanted.contains(word.as_str())
                            || words.iter().any(|w| word.contains(w.as_str()))
                    })
                    .map(|word| word.len())
                    .sum::<usize>();
                (shared > 0).then_some((shared, option))
            })
            .collect();
        like.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(b.1)));
        like.into_iter()
            .take(3)
            .map(|(_, option)| option.clone())
            .collect()
    }

    /// Option `name`'s slot, if `value` is of its type and one of its
    /// choices.
    fn checked(&mut self, name: &str, value: &Value) -> Result<&mut OptionSlot, OptionError> {
        if !self.options.contains_key(name) {
            return Err(OptionError::Unknown {
                name: name.into(),
                like: self.options_like(name),
            });
        }
        let slot = self.options.get_mut(name).expect("just looked");
        if std::mem::discriminant(&slot.value) != std::mem::discriminant(value) {
            return Err(OptionError::WrongType {
                name: name.into(),
                expected: slot.value.type_name(),
                actual: value.type_name(),
            });
        }
        if !slot.def.allows(value) {
            return Err(OptionError::NotAChoice {
                name: name.into(),
                value: value.clone(),
                choices: slot.def.choices.clone(),
            });
        }
        Ok(slot)
    }

    /// Option `name` as `client` has it: its own value, or everyone's.
    pub fn option_for(&self, client: ClientId, name: &str) -> Option<&Value> {
        self.own
            .get(&client)
            .and_then(|own| own.get(name))
            .or_else(|| self.option(name))
    }

    /// Gives `client` a value of option `name` of its own, which only it
    /// sees, or with `None` has it see everyone's again.
    pub fn set_option_for(
        &mut self,
        client: ClientId,
        name: &str,
        value: Option<Value>,
    ) -> Result<(), OptionError> {
        let Some(value) = value else {
            if let Some(own) = self.own.get_mut(&client) {
                own.remove(name);
            }
            return Ok(());
        };
        let name = self.checked(name, &value)?.def.name.clone();
        self.own.entry(client).or_default().insert(name, value);
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
        let removed = self.options.extract_if(|_, slot| &*slot.def.owner == owner);
        for (name, slot) in removed {
            for own in self.own.values_mut() {
                own.remove(&name);
            }
            if slot.set {
                self.kept.insert(name, (slot.value, slot.set_by));
            }
        }
    }
}
