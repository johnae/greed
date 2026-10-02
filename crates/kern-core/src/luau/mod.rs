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
mod images;
mod jobs;
mod json;
mod languages;
mod lsp;
mod modules;
mod plugin;
mod process;
mod projects;
mod requests;
mod sessions;
mod syntax;
mod tabs;
mod tasks;
mod terminal;
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
use crate::mouse::{Button, Mouse};
use crate::registry::{PluginId, Registry};
use crate::render::{Hit, StatusLine};
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
    /// The keys typed since `kern.keys.record()`, while recording.
    pub recording: Option<Vec<Key>>,
    /// Language servers.
    pub lsp: crate::lsp::Lsp,
    /// The waiting command each pending request wakes, by server and
    /// request id.
    pub lsp_waiting: HashMap<(crate::lsp::ServerId, i64), u64>,
    /// What answers each kind of request from servers, and its plugin.
    pub lsp_handlers: HashMap<String, (PluginId, Function)>,
    /// The plugin that set each theme entry, so it goes with the plugin.
    pub theme_owners: HashMap<Arc<str>, PluginId>,
    /// Work running on other threads.
    pub jobs: jobs::Jobs,
    /// Requests from the session socket that plugins haven't answered yet.
    pub requests: HashMap<u64, crate::control::Request>,
    pub next_request: u64,
    /// Where requests from other transports go, when there is a session.
    pub request_sender: Option<crossbeam_channel::Sender<crate::control::Request>>,
    /// Claude Code's IDE connection, once a plugin starts it.
    pub ide: Option<crate::ide::Ide>,
    /// The name of the session this editor is, when it is one.
    pub session_name: Option<String>,
    /// A folder standing in for the home, config and cache folders, for
    /// tests.
    pub dirs: Option<PathBuf>,
    /// Programs running in terminals.
    pub terminals: terminal::Terminals,
    /// Each view's size as last told to plugins with "view.resized".
    pub view_sizes: HashMap<crate::ViewId, (u16, u16)>,
    /// Each view's top line as last told to plugins with "view.scrolled".
    pub view_scrolls: HashMap<crate::ViewId, usize>,
    /// Syntax trees, for highlighting and for plugins.
    pub syntax: crate::syntax::Syntax,
    /// The queries each plugin set, by language and kind, oldest first; the
    /// newest is the one in use.
    pub query_owners: HashMap<(String, String), Vec<(PluginId, String)>>,
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
            recording: None,
            lsp: crate::lsp::Lsp::default(),
            lsp_waiting: HashMap::new(),
            lsp_handlers: HashMap::new(),
            theme_owners: HashMap::new(),
            jobs: jobs::Jobs::default(),
            requests: HashMap::new(),
            next_request: 0,
            request_sender: None,
            ide: None,
            session_name: None,
            dirs: None,
            terminals: terminal::Terminals::default(),
            view_sizes: HashMap::new(),
            view_scrolls: HashMap::new(),
            syntax: crate::syntax::Syntax::new(),
            query_owners: HashMap::new(),
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

    /// Calls `f` with the editor and the syntax trees, for drawing.
    pub fn with_editor_and_syntax<R>(
        &self,
        f: impl FnOnce(&mut Editor, &crate::syntax::Syntax) -> R,
    ) -> R {
        let state = &mut *state_mut(&self.lua);
        f(&mut state.editor, &state.syntax)
    }

    /// Sends buffers that changed to the syntax worker.
    pub fn update_syntax(&self) {
        let state = &mut *state_mut(&self.lua);
        state.syntax.update(&state.editor);
    }

    /// Finished parses, to pass to [`Host::receive_parse`].
    pub fn parses(&self) -> crossbeam_channel::Receiver<crate::syntax::Parsed> {
        state(&self.lua).syntax.results().clone()
    }

    /// Keeps a finished parse.
    pub fn receive_parse(&self, parsed: crate::syntax::Parsed) {
        state_mut(&self.lua).syntax.receive(parsed);
    }

    pub fn with_registry<R>(&self, f: impl FnOnce(&Registry<Function>) -> R) -> R {
        f(&state(&self.lua).registry)
    }

    /// Loads the plugin in `dir`, described by its `plugin.toml`.
    pub fn load_dir(&self, dir: &Path) -> Result<PluginId, HostError> {
        load_dir(&self.lua, dir)
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
        install(&self.lua, name, plugin)
    }

    /// Loads a plugin from source, e.g. a config file or a test.
    pub fn load_str(&self, name: &str, source: &str) -> Result<(), HostError> {
        install(&self.lua, name, Plugin::Inline(source.into()))
    }

    /// Removes everything a plugin registered and runs it again.
    pub fn reload(&self, name: &str) -> Result<(), HostError> {
        if !state(&self.lua).plugins.contains_key(name) {
            return Err(HostError::UnknownPlugin(name.into()));
        }
        unregister(&self.lua, name);
        run_plugin(&self.lua, name)
    }

    /// Removes a plugin and everything it registered. Fails while a loaded
    /// plugin requires it.
    pub fn unload(&self, name: &str) -> Result<(), HostError> {
        unload(&self.lua, name)
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

    /// Lets plugins start transports, like the IDE connection, whose
    /// requests arrive with the session socket's.
    pub fn set_request_sender(&self, sender: crossbeam_channel::Sender<crate::control::Request>) {
        state_mut(&self.lua).request_sender = Some(sender);
    }

    /// Tells plugins about the files opened before they loaded, as
    /// "buffer.opened" events, once they and the config have.
    pub fn announce_open_files(&self) -> Result<(), HostError> {
        let buffers: Vec<_> = state(&self.lua)
            .editor
            .buffers()
            .filter(|b| b.path().is_some())
            .map(crate::Buffer::id)
            .collect();
        budgeted(&self.lua, || {
            let author = kern_text::Author::User(state(&self.lua).editor.client());
            for buffer in buffers {
                let payload = self.lua.create_table()?;
                payload.set(
                    "buffer",
                    handles::BufferRef {
                        buffer,
                        view: None,
                        author: author.clone(),
                    },
                )?;
                api::emit(&self.lua, "buffer.opened", &payload)?;
            }
            Ok(())
        })
    }

    /// Tells plugins a client attached, with the file or folder it asked to
    /// open, if any, and whether it asked for a terminal.
    pub fn client_attached(&self, open: Option<&str>, terminal: bool) -> Result<(), HostError> {
        budgeted(&self.lua, || {
            let payload = self.lua.create_table()?;
            payload.set("path", open)?;
            payload.set("terminal", terminal)?;
            api::emit(&self.lua, "client.attached", &payload).map_err(HostError::from)
        })
    }

    /// Tells plugins the editor is up and about to show itself, with
    /// "editor.started": once per run, so reloading a plugin doesn't repeat
    /// what it does then.
    pub fn started(&self) -> Result<(), HostError> {
        budgeted(&self.lua, || {
            let payload = self.lua.create_table()?;
            api::emit(&self.lua, "editor.started", &payload).map_err(HostError::from)
        })
    }

    /// Tells plugins what the mouse did, with "mouse", and what was under it.
    pub fn mouse(&self, mouse: Mouse, hit: &Hit) -> Result<(), HostError> {
        budgeted(&self.lua, || {
            mouse_event(&self.lua, mouse, hit).map_err(HostError::from)
        })
    }

    /// Tells plugins which session this editor is.
    pub fn set_session_name(&self, name: &str) {
        state_mut(&self.lua).session_name = Some(name.to_owned());
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

    /// Tells plugins about views drawn at a new size since the last call,
    /// with "view.resized", and scrolled to a new line, with
    /// "view.scrolled". Call it after drawing a frame. Returns whether a
    /// handler heard about it, since what it does may change the next
    /// frame (one view scrolling another along, say).
    pub fn report_views(&self) -> Result<bool, HostError> {
        budgeted(&self.lua, || {
            report_views(&self.lua).map_err(HostError::from)
        })
    }

    /// Output and endings from terminals, to pass to
    /// [`Host::handle_terminal`].
    pub fn terminal_events(&self) -> crossbeam_channel::Receiver<crate::terminal::Event> {
        state(&self.lua).terminals.events.clone()
    }

    /// Tells plugins about a terminal's output or its program ending.
    pub fn handle_terminal(&self, event: crate::terminal::Event) -> Result<(), HostError> {
        budgeted(&self.lua, || {
            terminal::handle(&self.lua, event).map_err(HostError::from)
        })
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
}

/// Loads the plugin in `dir`, described by its `plugin.toml`, replacing a
/// loaded plugin of the same name.
pub(crate) fn load_dir(lua: &Lua, dir: &Path) -> Result<PluginId, HostError> {
    let (dir, manifest) = read_manifest(dir)?;
    load_manifest(lua, dir, manifest)
}

/// Loads the folder `dir` as a plugin called `name`, with `init.luau` as its
/// entry, unless it has a `plugin.toml` saying otherwise. For config that
/// isn't a packaged plugin, like a project's `.kern` folder.
pub(crate) fn load_dir_as(lua: &Lua, dir: &Path, name: &str) -> Result<PluginId, HostError> {
    if dir.join("plugin.toml").is_file() {
        return load_dir(lua, dir);
    }
    let dir = dir.canonicalize().map_err(|err| HostError::Manifest {
        path: dir.to_owned(),
        message: err.to_string(),
    })?;
    let manifest = Manifest {
        name: name.to_owned(),
        entry: default_entry(),
        requires: Vec::new(),
    };
    load_manifest(lua, dir, manifest)
}

fn load_manifest(lua: &Lua, dir: PathBuf, manifest: Manifest) -> Result<PluginId, HostError> {
    if let Some(missing) = manifest
        .requires
        .iter()
        .find(|r| !state(lua).plugins.contains_key(r.as_str()))
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
    install(lua, &name, plugin)?;
    Ok(name)
}

/// Adds or replaces a plugin and runs it.
fn install(lua: &Lua, name: &str, plugin: Plugin) -> Result<(), HostError> {
    unregister(lua, name);
    let dir = match &plugin {
        Plugin::Dir { dir, .. } => Some(dir.to_string_lossy().into_owned()),
        Plugin::Inline(_) => None,
    };
    state_mut(lua).plugins.insert(name.into(), plugin);
    run_plugin(lua, name)?;
    let payload = lua.create_table()?;
    payload.set("name", name)?;
    payload.set("dir", dir)?;
    api::emit(lua, "plugin.loaded", &payload)?;
    Ok(())
}

fn run_plugin(lua: &Lua, name: &str) -> Result<(), HostError> {
    let plugin = state(lua).plugins[name].clone();
    let export = match plugin {
        Plugin::Dir { dir, entry, .. } => {
            let file = dir.join(entry);
            let modules = Modules::new(lua, name, Some(dir), None)?;
            budgeted(lua, || modules.run_file(lua, &file))?
        }
        Plugin::Inline(source) => {
            let modules = Modules::new(lua, name, None, None)?;
            let chunk_name = format!("@{name}");
            let values = budgeted(lua, || modules.eval(lua, &source, &chunk_name))?;
            values.into_iter().next().unwrap_or(Value::Nil)
        }
    };
    state_mut(lua).exports.insert(name.into(), export);
    Ok(())
}

/// Emits "mouse": `kind`, `button` or `dir`, the screen cell, and what's
/// there: a `view`, the `pos` in its buffer and the cell in its text (`x`,
/// `y`), or a `tab`.
fn mouse_event(lua: &Lua, mouse: Mouse, hit: &Hit) -> mlua::Result<()> {
    let payload = lua.create_table()?;
    payload.set("kind", mouse.kind.name())?;
    payload.set("button", mouse.kind.button().map(Button::name))?;
    payload.set("dir", mouse.kind.direction())?;
    payload.set("col", mouse.col)?;
    payload.set("row", mouse.row)?;
    payload.set("ctrl", mouse.ctrl)?;
    payload.set("alt", mouse.alt)?;
    payload.set("shift", mouse.shift)?;
    if let Some(view) = hit.view {
        let author = kern_text::Author::User(state(lua).editor.client());
        payload.set("view", handles::ViewRef { id: view, author })?;
        payload.set("pos", hit.pos)?;
        payload.set("x", hit.x)?;
        payload.set("y", hit.y)?;
        payload.set("action", hit.action.as_deref())?;
    }
    payload.set("tab", hit.tab.map(|t| t.0))?;
    api::emit(lua, "mouse", &payload)
}

/// Emits "view.resized" for each view drawn at a new size and
/// "view.scrolled" for each scrolled to a new line. Returns whether a
/// handler heard either.
fn report_views(lua: &Lua) -> mlua::Result<bool> {
    let (resized, scrolled): (Vec<_>, Vec<_>) = {
        let state = &mut *state_mut(lua);
        let sizes: HashMap<_, _> = state.editor.view_sizes().collect();
        let resized = sizes
            .iter()
            .filter(|(id, size)| state.view_sizes.get(id) != Some(size))
            .map(|(id, size)| (*id, *size))
            .collect();
        state.view_sizes = sizes;
        let scrolls: HashMap<_, _> = state.editor.view_scrolls().collect();
        // A view that's new hasn't scrolled anywhere yet.
        let scrolled = scrolls
            .iter()
            .filter(|(id, line)| state.view_scrolls.get(id).is_some_and(|old| old != *line))
            .map(|(id, line)| (*id, *line))
            .collect();
        state.view_scrolls = scrolls;
        (resized, scrolled)
    };
    let author = kern_text::Author::User(state(lua).editor.client());
    let payload = |id| -> mlua::Result<mlua::Table> {
        let payload = lua.create_table()?;
        payload.set(
            "view",
            handles::ViewRef {
                id,
                author: author.clone(),
            },
        )?;
        Ok(payload)
    };
    let heard = |event: &str| !state(lua).registry.handlers(event).is_empty();
    let reported = (!resized.is_empty() && heard("view.resized"))
        || (!scrolled.is_empty() && heard("view.scrolled"));
    for (id, (rows, cols)) in resized {
        let payload = payload(id)?;
        payload.set("rows", rows)?;
        payload.set("cols", cols)?;
        api::emit(lua, "view.resized", &payload)?;
    }
    for (id, line) in scrolled {
        let payload = payload(id)?;
        payload.set("line", line)?;
        api::emit(lua, "view.scrolled", &payload)?;
    }
    Ok(reported)
}

/// Removes everything plugin `name` registered.
fn unregister(lua: &Lua, name: &str) {
    let mut state = state_mut(lua);
    let state = &mut *state;
    state.registry.remove_owned_by(name);
    state.terminals.remove_owned_by(name);
    state.lsp_handlers.retain(|_, (owner, _)| &**owner != name);
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
    for ((language, kind), owners) in &mut state.query_owners {
        let before = owners.len();
        owners.retain(|(owner, _)| &**owner != name);
        if owners.len() != before {
            // What was in use before still compiled, so this can't fail.
            let source = owners.last().map(|(_, source)| source.clone());
            let _ = state.syntax.set_query(language, kind, source);
        }
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
    {
        let mut state = state_mut(lua);
        state.plugins.remove(name);
        state.exports.remove(name);
    }
    let payload = lua.create_table()?;
    payload.set("name", name)?;
    api::emit(lua, "plugin.unloaded", &payload)?;
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

/// The directory of every plugin loaded from one, by name.
pub(crate) fn plugin_dirs(lua: &Lua) -> Vec<(PluginId, PathBuf)> {
    state(lua)
        .plugins
        .iter()
        .filter_map(|(name, plugin)| match plugin {
            Plugin::Dir { dir, .. } => Some((name.clone(), dir.clone())),
            Plugin::Inline(_) => None,
        })
        .collect()
}

/// The name in `dir`'s `plugin.toml`.
pub(crate) fn plugin_name(dir: &Path) -> Result<String, HostError> {
    Ok(read_manifest(dir)?.1.name)
}
