//! The Luau host: loads plugins into sandboxed environments and runs their
//! commands and event handlers against the editor.
//!
//! The editor lives in the Lua state's app data. API functions borrow it
//! briefly and never hold the borrow while calling back into Luau, so
//! commands can run other commands and emit events freely.

mod api;

use std::cell::Cell;
use std::collections::HashMap;
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use mlua::{Function, Lua, Table, VmState};
use serde::Deserialize;

use crate::keymap::{Key, ParseError};
use crate::registry::{PluginId, Registry};
use crate::{Editor, KeyOutcome};

/// How long one call into Luau may run before it is stopped.
const BUDGET: Duration = Duration::from_secs(2);

/// Plugin name used for code evaluated at the REPL.
const REPL: &str = "user/repl";

pub(crate) struct State {
    pub editor: Editor,
    pub registry: Registry<Function>,
    plugins: HashMap<PluginId, Plugin>,
    envs: HashMap<PluginId, Table>,
}

enum Plugin {
    /// A plugin directory with a `plugin.toml`.
    Dir { dir: PathBuf, entry: String },
    /// Source passed in directly: config, tests, the REPL.
    Inline(Arc<str>),
}

#[derive(Deserialize)]
struct Manifest {
    name: String,
    #[serde(default = "default_entry")]
    entry: String,
}

fn default_entry() -> String {
    "init.luau".to_owned()
}

/// When the current call into Luau must finish, and how long calls get.
struct Deadline {
    at: Cell<Option<Instant>>,
    budget: Cell<Duration>,
}

#[derive(Debug)]
pub enum HostError {
    Lua(mlua::Error),
    Manifest { path: PathBuf, message: String },
    UnknownCommand(Arc<str>),
    UnknownPlugin(Arc<str>),
    Keys(ParseError),
}

impl fmt::Display for HostError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            HostError::Lua(err) => err.fmt(f),
            HostError::Manifest { path, message } => {
                write!(f, "{}: {message}", path.display())
            }
            HostError::UnknownCommand(name) => write!(f, "there is no command called {name:?}"),
            HostError::UnknownPlugin(name) => write!(f, "there is no plugin called {name:?}"),
            HostError::Keys(err) => err.fmt(f),
        }
    }
}

impl std::error::Error for HostError {}

impl From<mlua::Error> for HostError {
    fn from(err: mlua::Error) -> Self {
        HostError::Lua(err)
    }
}

impl From<ParseError> for HostError {
    fn from(err: ParseError) -> Self {
        HostError::Keys(err)
    }
}

pub struct Host {
    lua: Lua,
}

impl Host {
    pub fn new(editor: Editor) -> Result<Self, HostError> {
        let lua = Lua::new();
        lua.sandbox(true)?;
        lua.set_app_data(State {
            editor,
            registry: Registry::default(),
            plugins: HashMap::new(),
            envs: HashMap::new(),
        });
        lua.set_app_data(Deadline {
            at: Cell::new(None),
            budget: Cell::new(BUDGET),
        });
        lua.set_interrupt(|lua| {
            let deadline = deadline(lua);
            match deadline.at.get() {
                Some(at) if Instant::now() > at => Err(mlua::Error::runtime(format!(
                    "stopped after running for more than {:?}",
                    deadline.budget.get()
                ))),
                _ => Ok(VmState::Continue),
            }
        });
        Ok(Self { lua })
    }

    /// Sets how long one call into Luau may run before it is stopped.
    pub fn set_budget(&self, budget: Duration) {
        deadline(&self.lua).budget.set(budget);
    }

    pub fn with_editor<R>(&self, f: impl FnOnce(&Editor) -> R) -> R {
        f(&state(&self.lua).editor)
    }

    pub fn with_editor_mut<R>(&self, f: impl FnOnce(&mut Editor) -> R) -> R {
        f(&mut state_mut(&self.lua).editor)
    }

    pub fn with_registry<R>(&self, f: impl FnOnce(&Registry<Function>) -> R) -> R {
        f(&state(&self.lua).registry)
    }

    /// Loads the plugin in `dir`, described by its `plugin.toml`.
    pub fn load_dir(&self, dir: &Path) -> Result<PluginId, HostError> {
        let path = dir.join("plugin.toml");
        let manifest: Manifest = std::fs::read_to_string(&path)
            .map_err(|err| err.to_string())
            .and_then(|text| toml::from_str(&text).map_err(|err| err.to_string()))
            .map_err(|message| HostError::Manifest {
                path: path.clone(),
                message,
            })?;
        let name: PluginId = manifest.name.into();
        let plugin = Plugin::Dir {
            dir: dir.to_owned(),
            entry: manifest.entry,
        };
        self.install(&name, plugin)?;
        Ok(name)
    }

    /// Loads a plugin from source, e.g. a config file or a test.
    pub fn load_str(&self, name: &str, source: &str) -> Result<(), HostError> {
        self.install(name, Plugin::Inline(source.into()))
    }

    /// Removes everything a plugin registered and runs it again.
    pub fn reload(&self, name: &str) -> Result<(), HostError> {
        if !state(&self.lua).plugins.contains_key(name) {
            return Err(HostError::UnknownPlugin(name.into()));
        }
        self.unregister(name);
        self.run_plugin(name)
    }

    /// Adds or replaces a plugin and runs it.
    fn install(&self, name: &str, plugin: Plugin) -> Result<(), HostError> {
        self.unregister(name);
        state_mut(&self.lua).plugins.insert(name.into(), plugin);
        self.run_plugin(name)
    }

    fn unregister(&self, name: &str) {
        let mut state = state_mut(&self.lua);
        state.registry.remove_owned_by(name);
        state.editor.keymap_mut().remove_owned_by(name);
    }

    /// Evaluates Luau typed at the REPL. Expressions return their value as
    /// text; globals persist between calls.
    pub fn eval(&self, source: &str) -> Result<String, HostError> {
        let env = api::plugin_env(&self.lua, REPL, None)?;
        let expression = format!("return {source}");
        let chunk = match self.lua.load(&expression).into_function() {
            Ok(_) => expression.as_str(),
            Err(_) => source,
        };
        let values: mlua::MultiValue = budgeted(&self.lua, || {
            self.lua
                .load(chunk)
                .set_name("=repl")
                .set_environment(env)
                .eval()
        })?;
        let parts: Vec<String> = values.iter().map(api::display).collect();
        Ok(parts.join("\t"))
    }

    /// Runs a command as the user.
    pub fn run(&self, name: &str) -> Result<(), HostError> {
        budgeted(&self.lua, || api::run_command(&self.lua, name, &[]))
    }

    /// Feeds one key press through the keymap, running whatever it resolves
    /// to.
    pub fn press(&self, key: Key) -> Result<(), HostError> {
        let outcome = state_mut(&self.lua).editor.press(key);
        match outcome {
            KeyOutcome::Command { name, keys } => {
                budgeted(&self.lua, || api::run_command(&self.lua, &name, &keys))
            }
            KeyOutcome::Pending | KeyOutcome::Unbound(_) => Ok(()),
        }
    }

    /// Presses each key of a space-separated sequence, e.g. `"g g"`.
    pub fn press_keys(&self, keys: &str) -> Result<(), HostError> {
        Key::parse_sequence(keys)?
            .into_iter()
            .try_for_each(|key| self.press(key))
    }

    fn run_plugin(&self, name: &str) -> Result<(), HostError> {
        let (source, chunk_name, dir) = match &state(&self.lua).plugins[name] {
            Plugin::Dir { dir, entry } => {
                let path = dir.join(entry);
                let source = std::fs::read_to_string(&path).map_err(|err| HostError::Manifest {
                    path: path.clone(),
                    message: err.to_string(),
                })?;
                (source, format!("@{name}/{entry}"), Some(dir.clone()))
            }
            Plugin::Inline(source) => (source.to_string(), format!("@{name}"), None),
        };
        let env = api::fresh_plugin_env(&self.lua, name, dir)?;
        budgeted(&self.lua, || {
            self.lua
                .load(source)
                .set_name(chunk_name)
                .set_environment(env)
                .exec()
                .map_err(HostError::from)
        })
    }
}

pub(crate) fn state(lua: &Lua) -> mlua::AppDataRef<'_, State> {
    lua.app_data_ref().expect("host state is set")
}

pub(crate) fn state_mut(lua: &Lua) -> mlua::AppDataRefMut<'_, State> {
    lua.app_data_mut().expect("host state is set")
}

/// Runs `f` under the time budget, unless an outer call already set one.
fn budgeted<R>(lua: &Lua, f: impl FnOnce() -> R) -> R {
    let outer = {
        let deadline = deadline(lua);
        let outer = deadline.at.get().is_some();
        if !outer {
            deadline
                .at
                .set(Some(Instant::now() + deadline.budget.get()));
        }
        outer
    };
    let result = f();
    if !outer {
        deadline(lua).at.set(None);
    }
    result
}

fn deadline(lua: &Lua) -> mlua::AppDataRef<'_, Deadline> {
    lua.app_data_ref().expect("deadline is set")
}
