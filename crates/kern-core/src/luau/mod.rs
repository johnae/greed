//! The Luau host: loads plugins into sandboxed environments and runs their
//! commands and event handlers against the editor.
//!
//! The editor lives in the Lua state's app data. API functions borrow it
//! briefly and never hold the borrow while calling back into Luau, so
//! commands can run other commands and emit events freely.

mod api;
mod diff;
mod fs;
mod handles;
mod jobs;
mod json;
mod languages;
mod lsp;
mod modules;
mod requests;
mod tasks;
mod testing;
mod theme;

use std::cell::Cell;
use std::collections::HashMap;
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use mlua::{Function, Lua, Value, VmState};
use serde::Deserialize;

pub use jobs::Done as FinishedJob;
pub use testing::{TestResult, run_tests};

use crate::keymap::{Key, ParseError};
use crate::registry::{PluginId, Registry};
use crate::render::StatusLine;
use crate::{BufferId, Editor};
use modules::Modules;

/// How long one call into Luau may run before it is stopped.
const BUDGET: Duration = Duration::from_secs(2);

/// Plugin name used for code evaluated at the REPL.
const REPL: &str = "user/repl";

pub(crate) struct State {
    pub editor: Editor,
    pub registry: Registry<Function>,
    plugins: HashMap<PluginId, Plugin>,
    /// The REPL's environment, kept so its globals persist.
    repl: Option<Modules>,
    /// The function that builds the status line, and the plugin that set it.
    pub statusline: Option<(PluginId, Function)>,
    /// The file behind each chunk name, so definitions can point at their
    /// source.
    pub sources: HashMap<String, PathBuf>,
    /// What each plugin's entry file returned, for `require("@name")`.
    pub exports: HashMap<PluginId, Value>,
    /// Commands and handlers waiting on a timer or a reply.
    pub tasks: tasks::Tasks,
    /// The command waiting for the next key press, if any.
    pub key_waiter: Option<u64>,
    /// Language servers.
    pub lsp: crate::lsp::Lsp,
    /// The waiting command each pending request wakes, by server and
    /// request id.
    pub lsp_waiting: HashMap<(crate::lsp::ServerId, i64), u64>,
    /// The plugin that set each theme entry, so it goes with the plugin.
    pub theme_owners: HashMap<Arc<str>, PluginId>,
    /// Work running on other threads.
    pub jobs: jobs::Jobs,
    /// Requests from the session socket that plugins haven't answered yet.
    pub requests: HashMap<u64, crate::control::Request>,
    pub next_request: u64,
}

#[derive(Clone)]
enum Plugin {
    /// A plugin directory with a `plugin.toml`.
    Dir {
        dir: PathBuf,
        entry: String,
        /// Plugins it requires, which can't be unloaded while it's loaded.
        requires: Vec<String>,
    },
    /// Source passed in directly: config, tests, the REPL.
    Inline(Arc<str>),
}

#[derive(Deserialize)]
struct Manifest {
    name: String,
    #[serde(default = "default_entry")]
    entry: String,
    /// Plugins this one uses through `require("@name")`; they load first.
    #[serde(default)]
    requires: Vec<String>,
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
    Required { plugin: Arc<str>, by: Arc<str> },
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
            HostError::Required { plugin, by } => {
                write!(f, "can't unload {plugin:?}: {by:?} requires it")
            }
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
            repl: None,
            statusline: None,
            sources: HashMap::new(),
            exports: HashMap::new(),
            tasks: tasks::Tasks::default(),
            key_waiter: None,
            lsp: crate::lsp::Lsp::default(),
            lsp_waiting: HashMap::new(),
            theme_owners: HashMap::new(),
            jobs: jobs::Jobs::default(),
            requests: HashMap::new(),
            next_request: 0,
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
        let (dir, manifest) = read_manifest(dir)?;
        if let Some(missing) = manifest
            .requires
            .iter()
            .find(|r| !state(&self.lua).plugins.contains_key(r.as_str()))
        {
            return Err(HostError::Manifest {
                path: dir.join("plugin.toml"),
                message: format!("requires plugin {missing:?}, which isn't loaded"),
            });
        }
        let name: PluginId = manifest.name.into();
        let plugin = Plugin::Dir {
            dir,
            entry: manifest.entry,
            requires: manifest.requires,
        };
        self.install(&name, plugin)?;
        Ok(name)
    }

    /// Loads several plugin directories, each after the plugins it requires.
    pub fn load_dirs(&self, dirs: &[PathBuf]) -> Result<Vec<PluginId>, HostError> {
        let mut pending = dirs
            .iter()
            .map(|dir| read_manifest(dir))
            .collect::<Result<Vec<_>, _>>()?;
        let mut loaded = Vec::new();
        while !pending.is_empty() {
            let ready = pending.iter().position(|(_, manifest)| {
                let plugins = &state(&self.lua).plugins;
                manifest
                    .requires
                    .iter()
                    .all(|r| plugins.contains_key(r.as_str()))
            });
            let Some(ready) = ready else {
                let (dir, manifest) = &pending[0];
                return Err(HostError::Manifest {
                    path: dir.join("plugin.toml"),
                    message: format!(
                        "requires {}, which can't be loaded (missing, or requires each other)",
                        manifest.requires.join(", ")
                    ),
                });
            };
            let (dir, _) = pending.remove(ready);
            loaded.push(self.load_dir(&dir)?);
        }
        Ok(loaded)
    }

    /// Loads a single file as a plugin called `name`, e.g. the user's
    /// config. It requires files next to it as any plugin file does: "@self/x"
    /// from an init.luau, "./x" otherwise.
    pub fn load_file(&self, name: &str, path: &Path) -> Result<(), HostError> {
        let fail = |message: String| HostError::Manifest {
            path: path.to_owned(),
            message,
        };
        let path = path.canonicalize().map_err(|err| fail(err.to_string()))?;
        let (Some(dir), Some(entry)) = (path.parent(), path.file_name()) else {
            return Err(fail("not a file".to_owned()));
        };
        let plugin = Plugin::Dir {
            dir: dir.to_owned(),
            entry: entry.to_string_lossy().into_owned(),
            requires: Vec::new(),
        };
        self.install(name, plugin)
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
        unregister(&self.lua, name);
        self.run_plugin(name)
    }

    /// Removes a plugin and everything it registered. Fails while a loaded
    /// plugin requires it.
    pub fn unload(&self, name: &str) -> Result<(), HostError> {
        unload(&self.lua, name)
    }

    /// Adds or replaces a plugin and runs it.
    fn install(&self, name: &str, plugin: Plugin) -> Result<(), HostError> {
        unregister(&self.lua, name);
        state_mut(&self.lua).plugins.insert(name.into(), plugin);
        self.run_plugin(name)
    }

    /// Evaluates Luau typed at the REPL. Expressions return their value as
    /// text; globals persist between calls.
    pub fn eval(&self, source: &str) -> Result<String, HostError> {
        Ok(budgeted(&self.lua, || eval_repl(&self.lua, source))?)
    }

    /// The status line a plugin builds, or `None` if no plugin builds one.
    pub fn status_line(
        &self,
        message: Option<&str>,
        width: u16,
    ) -> Result<Option<StatusLine>, HostError> {
        budgeted(&self.lua, || {
            api::status_line(&self.lua, message, width).map_err(HostError::from)
        })
    }

    /// When the next timer a command is waiting on is due.
    pub fn next_timer(&self) -> Option<Instant> {
        tasks::next_timer(&self.lua)
    }

    /// Resumes commands waiting on timers that are due by `now`.
    pub fn fire_timers(&self, now: Instant) -> Result<(), HostError> {
        budgeted(&self.lua, || {
            tasks::fire_timers(&self.lua, now).map_err(HostError::from)
        })
    }

    /// Jobs that finished on other threads, to pass to [`Host::finish_job`].
    pub fn finished_jobs(&self) -> crossbeam_channel::Receiver<FinishedJob> {
        state(&self.lua).jobs.finished().clone()
    }

    /// Wakes the command waiting on a finished job.
    pub fn finish_job(&self, done: FinishedJob) -> Result<(), HostError> {
        budgeted(&self.lua, || {
            jobs::finish(&self.lua, done).map_err(HostError::from)
        })
    }

    /// Passes a request from the session socket to the plugins that answer
    /// them.
    pub fn handle_request(&self, request: crate::control::Request) -> Result<(), HostError> {
        budgeted(&self.lua, || {
            requests::handle(&self.lua, request).map_err(HostError::from)
        })
    }

    /// Messages from language servers, to pass to [`Host::handle_lsp`].
    pub fn lsp_events(&self) -> crossbeam_channel::Receiver<crate::lsp::Event> {
        state(&self.lua).lsp.events().clone()
    }

    /// Handles a message from a language server.
    pub fn handle_lsp(&self, event: crate::lsp::Event) -> Result<(), HostError> {
        budgeted(&self.lua, || {
            lsp::handle(&self.lua, event).map_err(HostError::from)
        })
    }

    /// Sends open buffers to their language servers, starting servers as
    /// needed. Returns what went wrong, each problem once.
    pub fn sync_lsp(&self) -> Vec<String> {
        let state = &mut *state_mut(&self.lua);
        state
            .lsp
            .sync(&state.editor)
            .iter()
            .map(ToString::to_string)
            .collect()
    }

    /// Each buffer's diagnostics, as byte ranges and severities.
    pub fn diagnostic_marks(&self) -> HashMap<BufferId, Vec<(std::ops::Range<usize>, u8)>> {
        state(&self.lua)
            .lsp
            .all_diagnostics()
            .map(|(buffer, list)| {
                (
                    buffer,
                    list.iter().map(|d| (d.from..d.to, d.severity)).collect(),
                )
            })
            .collect()
    }

    /// Talks to a language server over `input` and `output` instead of
    /// starting one; for tests.
    pub fn connect_lsp(
        &self,
        language: &str,
        input: Box<dyn std::io::Write + Send>,
        output: impl std::io::Read + Send + 'static,
    ) -> Result<(), HostError> {
        state_mut(&self.lua)
            .lsp
            .connect(language, input, output, Path::new("."))
            .map(drop)
            .map_err(|err| HostError::Lua(mlua::Error::external(err)))
    }

    /// Runs a command as the user.
    pub fn run(&self, name: &str) -> Result<(), HostError> {
        budgeted(&self.lua, || api::run_command(&self.lua, name))
    }

    /// Feeds one key press through the keymap, running whatever it resolves
    /// to.
    pub fn press(&self, key: Key) -> Result<(), HostError> {
        budgeted(&self.lua, || api::press(&self.lua, key))
    }

    /// Presses each key of a space-separated sequence, e.g. `"g g"`.
    pub fn press_keys(&self, keys: &str) -> Result<(), HostError> {
        Key::parse_sequence(keys)?
            .into_iter()
            .try_for_each(|key| self.press(key))
    }

    fn run_plugin(&self, name: &str) -> Result<(), HostError> {
        let plugin = state(&self.lua).plugins[name].clone();
        let export = match plugin {
            Plugin::Dir { dir, entry, .. } => {
                let file = dir.join(entry);
                let modules = Modules::new(&self.lua, name, Some(dir), None)?;
                budgeted(&self.lua, || modules.run_file(&self.lua, &file))?
            }
            Plugin::Inline(source) => {
                let modules = Modules::new(&self.lua, name, None, None)?;
                let chunk_name = format!("@{name}");
                let values = budgeted(&self.lua, || modules.eval(&self.lua, &source, &chunk_name))?;
                values.into_iter().next().unwrap_or(Value::Nil)
            }
        };
        state_mut(&self.lua).exports.insert(name.into(), export);
        Ok(())
    }
}

/// Removes everything plugin `name` registered.
fn unregister(lua: &Lua, name: &str) {
    let mut state = state_mut(lua);
    let state = &mut *state;
    state.registry.remove_owned_by(name);
    state.editor.keymap_mut().remove_owned_by(name);
    state.theme_owners.retain(|entry, owner| {
        let owned = &**owner == name;
        if owned {
            state.editor.theme_mut().remove(entry);
        }
        !owned
    });
    if state
        .statusline
        .as_ref()
        .is_some_and(|(owner, _)| &**owner == name)
    {
        state.statusline = None;
    }
}

/// Removes plugin `name` and everything it registered, unless a loaded
/// plugin requires it.
pub(crate) fn unload(lua: &Lua, name: &str) -> Result<(), HostError> {
    {
        let state = state(lua);
        if !state.plugins.contains_key(name) {
            return Err(HostError::UnknownPlugin(name.into()));
        }
        let requirer = state.plugins.iter().find(|(_, plugin)| {
            matches!(plugin, Plugin::Dir { requires, .. } if requires.iter().any(|r| r == name))
        });
        if let Some((by, _)) = requirer {
            return Err(HostError::Required {
                plugin: name.into(),
                by: by.clone(),
            });
        }
    }
    unregister(lua, name);
    let mut state = state_mut(lua);
    state.plugins.remove(name);
    state.exports.remove(name);
    Ok(())
}

/// The names of the loaded plugins, sorted.
pub(crate) fn plugin_names(lua: &Lua) -> Vec<String> {
    let mut names: Vec<String> = state(lua).plugins.keys().map(ToString::to_string).collect();
    names.sort();
    names
}

/// Evaluates Luau in the REPL's environment, where globals persist between
/// calls. Expressions return their values as text, separated by tabs.
pub(crate) fn eval_repl(lua: &Lua, source: &str) -> mlua::Result<String> {
    // Bound first so the state borrow ends before `state_mut`.
    let cached = state(lua).repl.clone();
    let modules = if let Some(modules) = cached {
        modules
    } else {
        let modules = Modules::new(lua, REPL, None, None)?;
        state_mut(lua).repl = Some(modules.clone());
        modules
    };
    let expression = format!("return {source}");
    let chunk = match lua.load(&expression).into_function() {
        Ok(_) => expression.as_str(),
        Err(_) => source,
    };
    let values = modules.eval(lua, chunk, "=repl")?;
    let parts: Vec<String> = values.iter().map(api::display).collect();
    Ok(parts.join("\t"))
}

/// A plugin's canonical directory and its `plugin.toml`.
fn read_manifest(dir: &Path) -> Result<(PathBuf, Manifest), HostError> {
    let path = dir.join("plugin.toml");
    let fail = |message: String| HostError::Manifest {
        path: path.clone(),
        message,
    };
    let dir = dir.canonicalize().map_err(|err| fail(err.to_string()))?;
    let text = std::fs::read_to_string(&path).map_err(|err| fail(err.to_string()))?;
    let manifest = toml::from_str(&text).map_err(|err| fail(err.to_string()))?;
    Ok((dir, manifest))
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
