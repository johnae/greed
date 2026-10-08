//! The Luau host: loads plugins into sandboxed environments and runs their
//! commands and event handlers against the editor.
//!
//! The editor lives in the Lua state's app data. API functions borrow it
//! briefly and never hold the borrow while calling back into Luau, so
//! commands can run other commands and emit events freely.

mod api;
mod approvals;
mod capabilities;
mod cli;
mod diff;
mod errors;
mod fs;
mod handles;
pub(crate) mod hash;
mod history;
mod http;
mod images;
mod jobs;
mod json;
mod languages;
mod lsp;
mod modules;
mod owned;
mod pdf;
mod plugin;
mod process;
mod projects;
mod requests;
mod secrets;
mod sessions;
mod stalls;
mod syntax;
mod tabs;
mod tasks;
mod terminal;
mod testing;
mod theme;
mod track;
mod watch;

use std::cell::Cell;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use greed_text::ClientId;
use mlua::{Function, Lua, Value, VmState};
use serde::Deserialize;

pub use api::EVENTS;
pub use jobs::Done as FinishedJob;
pub use testing::{TestResult, run_suites, run_tests};

use crate::Editor;
use crate::keymap::{Key, ParseError};
use crate::mouse::{Button, Mouse};
use crate::registry::{PluginId, Registry};
use crate::render::{Hit, StatusLine};
use modules::Modules;

/// How long one call into Luau may work before it is stopped.
const BUDGET: Duration = Duration::from_secs(2);

/// How long a command or handler runs before it yields to the editor, to
/// carry on once keys are handled and the screen is drawn.
const SLICE: Duration = Duration::from_millis(15);

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
    /// The command waiting for each client's next key press, and the limit
    /// it runs within.
    pub key_waiter: HashMap<ClientId, (u64, capabilities::Limit)>,
    /// What each `greed.keys.record` is keeping, by client and name.
    pub recording: HashMap<ClientId, HashMap<String, api::Recording>>,
    /// Language servers.
    pub lsp: crate::lsp::Lsp,
    /// The waiting command each pending request wakes, by server and
    /// request id.
    pub lsp_waiting: HashMap<(crate::lsp::ServerId, i64), u64>,
    /// What answers each kind of request from servers, and its plugin.
    pub lsp_handlers: HashMap<String, (PluginId, Function)>,
    /// What hears each kind of notification from servers, and its plugin.
    pub lsp_listeners: Vec<(String, PluginId, Function)>,
    /// The theme entries plugins set, each with the plugin that set it last,
    /// so it goes with the plugin. Each patches the base theme's entry.
    pub theme_set: HashMap<Arc<str>, (PluginId, crate::theme::Entry)>,
    /// The theme under the entries plugins set with `greed.theme.set`, from
    /// `greed.theme.base`, and the plugin that set it.
    pub theme_base: Option<(PluginId, HashMap<Arc<str>, crate::theme::Entry>)>,
    /// Work running on other threads.
    pub jobs: jobs::Jobs,
    /// Requests from the session socket that plugins haven't answered yet.
    pub requests: HashMap<u64, crate::control::Request>,
    pub next_request: u64,
    /// The session socket connections requests came on, by id, for
    /// `greed.control.send`; closed ones are dropped as new ones come.
    pub connections: HashMap<u64, crate::control::Notifier>,
    /// Where requests from other transports go, when there is a session.
    pub request_sender: Option<crossbeam_channel::Sender<crate::control::Request>>,
    /// Claude Code's IDE connection, once a plugin starts it.
    pub ide: Option<crate::ide::Ide>,
    /// The name of the session this editor is, when it is one.
    pub session_name: Option<String>,
    /// Whether the attached client, or the last one, came over `greed ssh`;
    /// `None` before any attached.
    pub remote: Option<bool>,
    /// Whether a client is attached. The terminal or window a session
    /// started in counts, until it goes.
    pub attached: bool,
    /// A folder standing in for the home, config and cache folders, for
    /// tests.
    pub dirs: Option<PathBuf>,
    /// Programs running in terminals.
    pub terminals: terminal::Terminals,
    /// Each view's size for each client, as last told to plugins with
    /// "view.resized".
    pub view_sizes: HashMap<(ClientId, crate::ViewId), (u16, u16)>,
    /// Each view's top line for each client, as last told to plugins with
    /// "view.scrolled".
    pub view_scrolls: HashMap<(ClientId, crate::ViewId), usize>,
    /// Each view's buffer and selection for each client, as last told to
    /// plugins with "selection.changed".
    pub view_selections:
        HashMap<(ClientId, crate::ViewId), (crate::BufferId, greed_text::Selection)>,
    /// Each client's focused view as last told to plugins with
    /// "view.focused".
    pub focus_told: HashMap<ClientId, crate::ViewId>,
    /// Syntax trees, for highlighting and for plugins.
    pub syntax: crate::syntax::Syntax,
    /// The queries each plugin set, by language and kind, oldest first; the
    /// newest is the one in use.
    pub query_owners: HashMap<(String, String), Vec<(PluginId, String)>>,
    /// Files plugins watch for changes.
    pub watches: watch::Watches,
    /// Marks, images, views, file types and servers, by the plugin that
    /// made them.
    pub owned: owned::Owned,
    /// What plugins' registries added for other plugins.
    pub ties: Vec<plugin::Tie>,
    /// What each plugin may use beyond the editor.
    pub grants: HashMap<PluginId, capabilities::Grant>,
    /// The plugin whose code is running, if any: a command or handler it
    /// registered, or its own file loading.
    pub running: Option<PluginId>,
    /// What started the code running now, which it may do no more than.
    pub limit: capabilities::Limit,
    /// The limit what you start runs within: none, except while checking a
    /// plugin, when it's that plugin with what you approved for it.
    pub floor: capabilities::Limit,
    /// Whose code made each coroutine plugins made, by the coroutine; weak,
    /// so they go with it.
    pub makers: mlua::Table,
    /// The plugins vouching for what runs in each coroutine (`greed.vouch`),
    /// innermost last, by the coroutine; weak, so they go with it.
    pub vouches: mlua::Table,
    /// Approved capabilities, when plugins need approving.
    pub approvals: Option<approvals::Approvals>,
    /// The folders of plugins waiting for approval, oldest first.
    pub pending: Vec<PathBuf>,
    /// HTTP streams being read.
    pub http: http::Streams,
    /// Programs started with `greed.process.spawn`.
    pub children: process::Children,
    /// Command line commands plugins added.
    pub cli: cli::Commands,
    /// Runs of plugin code that held the editor up.
    pub stalls: stalls::Stalls,
    /// Errors from plugin code that nothing caught.
    pub errors: errors::Errors,
}

#[derive(Clone)]
enum Plugin {
    /// A plugin directory with a `plugin.toml`.
    Dir {
        dir: PathBuf,
        entry: String,
        /// Plugins it requires, which can't be unloaded while it's loaded.
        requires: Vec<String>,
        grant: capabilities::Grant,
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
    /// What it uses beyond the editor; see `capabilities`.
    #[serde(default)]
    capabilities: Vec<String>,
}

fn default_entry() -> String {
    "init.luau".to_owned()
}

/// When the current call into Luau must finish, and how long calls get.
struct Deadline {
    at: Cell<Option<Instant>>,
    budget: Cell<Duration>,
    /// How long the thread had run on a CPU when the call started, where
    /// the system says.
    worked: Cell<Option<Duration>>,
    /// The task coroutine running now: past `SLICE` it yields, so the editor
    /// gets a turn.
    slice: Cell<Option<Slice>>,
    /// Whether an event loop fires the timers, and so carries on what a
    /// slice cut short. Without one, it carries on before the call returns.
    looped: Cell<bool>,
}

impl Deadline {
    fn new(budget: Duration) -> Self {
        Self {
            at: Cell::new(None),
            budget: Cell::new(budget),
            worked: Cell::new(None),
            slice: Cell::new(None),
            looped: Cell::new(false),
        }
    }

    /// Gives the call a whole budget from now.
    fn start(&self) {
        self.at.set(Some(Instant::now() + self.budget.get()));
        self.worked.set(cpu_time());
    }

    /// Whether the call, past its deadline at `now`, has worked its whole
    /// budget. As with slices, time the thread waited for a CPU doesn't
    /// count; until it has, the deadline moves later by that time.
    fn spent(&self, now: Instant) -> bool {
        let (Some(start), Some(worked)) = (self.worked.get(), cpu_time()) else {
            return true;
        };
        let left = self
            .budget
            .get()
            .checked_sub(worked.saturating_sub(start))
            .filter(|left| !left.is_zero());
        if let Some(left) = left {
            self.at.set(Some(now + left));
        }
        left.is_none()
    }
}

/// A run of a task coroutine, which the interrupt may cut short.
#[derive(Clone, Copy)]
struct Slice {
    /// The coroutine, by its pointer.
    thread: usize,
    /// When it started, moved later by time the thread spent waiting for a
    /// CPU rather than working.
    from: Instant,
    /// How long the thread had run on a CPU when it started, where the
    /// system says.
    worked: Option<Duration>,
}

impl Slice {
    fn new(thread: usize) -> Self {
        Self {
            thread,
            from: Instant::now(),
            worked: cpu_time(),
        }
    }

    /// Whether it has worked for `SLICE` by `now`. Time the thread waited
    /// for a CPU on a busy machine doesn't count, since the editor, which
    /// runs on the same thread, would have waited too; otherwise how busy
    /// the machine is would decide where work is cut. Until it has, `from`
    /// moves later by the time it waited.
    fn ran_out(&mut self, now: Instant) -> bool {
        if now.duration_since(self.from) <= SLICE {
            return false;
        }
        let (Some(start), Some(worked)) = (self.worked, cpu_time()) else {
            return true;
        };
        let worked = worked.saturating_sub(start);
        if worked > SLICE {
            return true;
        }
        self.from = now.checked_sub(worked).unwrap_or(now);
        false
    }
}

/// How long this thread has run on a CPU, on systems that say.
fn cpu_time() -> Option<Duration> {
    let time = nix::time::clock_gettime(nix::time::ClockId::CLOCK_THREAD_CPUTIME_ID).ok()?;
    Some(Duration::from(time))
}

#[derive(Debug)]
pub enum HostError {
    Lua(mlua::Error),
    Manifest {
        path: PathBuf,
        message: String,
    },
    UnknownCommand(Arc<str>),
    UnknownPlugin(Arc<str>),
    UnknownClient(ClientId),
    Required {
        plugin: Arc<str>,
        by: Arc<str>,
    },
    Keys(ParseError),
    /// A plugin declares capabilities that haven't been approved.
    NotApproved {
        name: Arc<str>,
        missing: Vec<String>,
    },
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
            HostError::UnknownClient(id) => write!(f, "there is no client {}", id.0),
            HostError::Required { plugin, by } => {
                write!(f, "can't unload {plugin:?}: {by:?} requires it")
            }
            HostError::Keys(err) => err.fmt(f),
            HostError::NotApproved { name, missing } => write!(
                f,
                "{name} wants {}, which you haven't approved: :plugins-approve reviews it",
                missing.join(", ")
            ),
        }
    }
}

impl std::error::Error for HostError {}

impl HostError {
    /// The error without mlua's "runtime error:" prefix and its stack
    /// traceback.
    pub fn brief(&self) -> String {
        let text = self.to_string();
        let text = text.split("\nstack traceback:").next().unwrap_or(&text);
        let text = text.strip_prefix("runtime error: ").unwrap_or(text);
        text.trim().to_owned()
    }
}

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
        let makers = lua.create_table()?;
        let weak = lua.create_table()?;
        weak.set("__mode", "k")?;
        makers.set_metatable(Some(weak.clone()))?;
        let vouches = lua.create_table()?;
        vouches.set_metatable(Some(weak))?;
        lua.set_app_data(State {
            editor,
            registry: Registry::default(),
            plugins: HashMap::new(),
            repl: None,
            statusline: None,
            sources: HashMap::new(),
            exports: HashMap::new(),
            tasks: tasks::Tasks::default(),
            key_waiter: HashMap::new(),
            recording: HashMap::new(),
            lsp: crate::lsp::Lsp::default(),
            lsp_waiting: HashMap::new(),
            lsp_handlers: HashMap::new(),
            lsp_listeners: Vec::new(),
            theme_set: HashMap::new(),
            theme_base: None,
            jobs: jobs::Jobs::default(),
            requests: HashMap::new(),
            next_request: 0,
            connections: HashMap::new(),
            request_sender: None,
            ide: None,
            session_name: None,
            remote: None,
            attached: true,
            dirs: None,
            terminals: terminal::Terminals::default(),
            view_sizes: HashMap::new(),
            view_scrolls: HashMap::new(),
            view_selections: HashMap::new(),
            focus_told: HashMap::new(),
            syntax: crate::syntax::Syntax::new(),
            query_owners: HashMap::new(),
            watches: watch::Watches::default(),
            owned: owned::Owned::default(),
            ties: Vec::new(),
            grants: HashMap::new(),
            running: None,
            limit: Vec::new(),
            floor: Vec::new(),
            makers,
            vouches,
            approvals: None,
            pending: Vec::new(),
            http: http::Streams::default(),
            children: process::Children::default(),
            cli: cli::Commands::default(),
            stalls: stalls::Stalls::default(),
            errors: errors::Errors::default(),
        });
        lua.set_app_data(Deadline::new(BUDGET));
        lua.set_interrupt(|lua| {
            let deadline = deadline(lua);
            let now = Instant::now();
            if let Some(at) = deadline.at.get()
                && now > at
                && deadline.spent(now)
            {
                return Err(mlua::Error::runtime(format!(
                    "stopped after running for more than {:?}",
                    deadline.budget.get()
                )));
            }
            // A command or handler that has run its slice yields to the
            // editor, but only its own coroutine: one a plugin made, like a
            // generator, must never see a yield it didn't ask for.
            if let Some(mut slice) = deadline.slice.get()
                && now.duration_since(slice.from) > SLICE
            {
                let ran_out = slice.ran_out(now);
                if ran_out {
                    // Asked again only a slice later, if it carries on: in
                    // a coroutine a plugin made, or where it can't yield,
                    // like a status line it draws. Asking which coroutine
                    // runs takes a slot of its stack, which a function
                    // working in a loop never gives back.
                    slice.from = now;
                }
                deadline.slice.set(Some(slice));
                if ran_out && lua.current_thread().to_pointer() as usize == slice.thread {
                    return Ok(VmState::Yield);
                }
            }
            Ok(VmState::Continue)
        });
        Ok(Self { lua })
    }

    /// Sets how long one call into Luau may work before it is stopped.
    pub fn set_budget(&self, budget: Duration) {
        deadline(&self.lua).budget.set(budget);
    }

    /// Says an event loop fires this host's timers, as the server's does. A
    /// command or handler whose time slice runs out then carries on from a
    /// timer, after the loop has handled keys and drawn. Without a loop, it
    /// carries on before the call that ran it returns, so code driving the
    /// host directly, like a test, sees its work done however busy the
    /// machine is.
    pub fn use_event_loop(&self) {
        deadline(&self.lua).looped.set(true);
    }

    /// Keeps code that held the editor up in `:stalls` without saying so,
    /// for tests that check what was said on a busy machine.
    pub fn quiet_stalls(&self) {
        state_mut(&self.lua).stalls.quiet = true;
    }

    pub fn with_editor<R>(&self, f: impl FnOnce(&Editor) -> R) -> R {
        f(&state(&self.lua).editor)
    }

    pub fn with_editor_mut<R>(&self, f: impl FnOnce(&mut Editor) -> R) -> R {
        f(&mut state_mut(&self.lua).editor)
    }

    /// Calls `f` with the editor and the syntax trees, for drawing. The
    /// trees are brought up to the text first, so highlights follow edits
    /// made since.
    pub fn with_editor_and_syntax<R>(
        &self,
        f: impl FnOnce(&mut Editor, &crate::syntax::Syntax) -> R,
    ) -> R {
        let state = &mut *state_mut(&self.lua);
        state.syntax.update(&state.editor);
        f(&mut state.editor, &state.syntax)
    }

    /// Sends buffers that changed to the syntax worker. Returns queries that
    /// failed to compile, one line each.
    pub fn update_syntax(&self) -> Vec<String> {
        let state = &mut *state_mut(&self.lua);
        state.syntax.update(&state.editor);
        state.syntax.take_problems()
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

    /// The options named `gui-...` as `client` has them, as text, for its
    /// window to read: a window can have its own, like its font size.
    pub fn gui_options(&self, client: ClientId) -> BTreeMap<String, String> {
        self.with_registry(|registry| {
            registry
                .option_states()
                .filter(|o| o.def.name.starts_with("gui-"))
                .map(|o| {
                    let value = registry.option_for(client, &o.def.name).unwrap_or(o.value);
                    (o.def.name.to_string(), value.to_string())
                })
                .collect()
        })
    }

    /// Loads the plugin in `dir`, described by its `plugin.toml`.
    pub fn load_dir(&self, dir: &Path) -> Result<PluginId, HostError> {
        load_dir(&self.lua, dir)
    }

    /// Makes plugins from outside `shipped` wait until the capabilities
    /// they declare are approved, keeping approvals in the file `store`.
    pub fn require_approval(&self, store: PathBuf, shipped: Vec<PathBuf>) {
        state_mut(&self.lua).approvals = Some(approvals::Approvals::load(store, shipped));
    }

    /// Loads several plugin directories, each after the plugins it requires.
    pub fn load_dirs(&self, dirs: &[PathBuf]) -> Result<Vec<PluginId>, HostError> {
        let mut pending = dirs
            .iter()
            .map(|dir| read_manifest(dir))
            .collect::<Result<Vec<_>, _>>()?;
        let mut loaded = Vec::new();
        // Plugins skipped until their capabilities are approved.
        let mut waiting: Vec<String> = Vec::new();
        while !pending.is_empty() {
            let ready = pending.iter().position(|(_, manifest)| {
                let plugins = &state(&self.lua).plugins;
                manifest
                    .requires
                    .iter()
                    .all(|r| plugins.contains_key(r.as_str()))
            });
            let Some(ready) = ready else {
                if waiting.is_empty() {
                    let (dir, manifest) = &pending[0];
                    return Err(HostError::Manifest {
                        path: dir.join("plugin.toml"),
                        message: format!(
                            "requires {}, which can't be loaded (missing, or requires each other)",
                            manifest.requires.join(", ")
                        ),
                    });
                }
                // The rest need a plugin that waits for approval; they load
                // once it's approved.
                let state = &mut *state_mut(&self.lua);
                for (dir, manifest) in pending {
                    state.editor.echo(format!(
                        "{} waits until {} is approved",
                        manifest.name,
                        waiting.join(", ")
                    ));
                    state.pending.push(dir);
                }
                break;
            };
            let (dir, _) = pending.remove(ready);
            match self.load_dir(&dir) {
                Ok(name) => loaded.push(name),
                Err(err) => {
                    let HostError::NotApproved { name, .. } = &err else {
                        return Err(err);
                    };
                    waiting.push(name.to_string());
                    state_mut(&self.lua).editor.echo(err.to_string());
                }
            }
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
            grant: capabilities::Grant::All,
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
        unregister(&self.lua, name)?;
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

    /// Waits for every running job and finishes it, and carries on commands
    /// whose time slice ran out, until nothing is left to do. For code with
    /// no event loop around the host, like tests. Fails, naming the jobs
    /// still running, when none has finished for a minute.
    pub fn settle(&self) -> Result<(), HostError> {
        budgeted(&self.lua, || {
            jobs::settle(&self.lua).map_err(HostError::from)
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
            let author = greed_text::Author::User(state(&self.lua).editor.client());
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

    /// Tells plugins `client` attached, with the file or folder it asked to
    /// open, if any, whether it asked for a terminal and whether it came
    /// over `greed ssh`. Its handlers run as that client.
    pub fn client_attached(
        &self,
        client: ClientId,
        open: Option<&str>,
        terminal: bool,
        remote: bool,
    ) -> Result<(), HostError> {
        {
            let mut state = state_mut(&self.lua);
            state.remote = Some(remote);
            state.attached = true;
        }
        self.act_for(client)?;
        budgeted(&self.lua, || {
            let payload = self.lua.create_table()?;
            payload.set("path", open)?;
            payload.set("terminal", terminal)?;
            payload.set("remote", remote)?;
            api::emit_for_client(&self.lua, "client.attached", &payload).map_err(HostError::from)
        })
    }

    /// Has `client` follow the others or lays it out on its own, as
    /// `greed.client.set_layout` does.
    pub fn set_client_layout(
        &self,
        client: ClientId,
        layout: crate::ClientLayout,
    ) -> Result<(), HostError> {
        budgeted(&self.lua, || {
            api::set_client_layout(&self.lua, client, layout)
                .map(|_| ())
                .map_err(HostError::from)
        })
    }

    /// Tells plugins `client` went, with "client.detached", its handlers
    /// running as that client; the session goes on without it. With
    /// `others` false, no other client is attached. Then the floats it alone
    /// was shown close, like a picker it left open.
    pub fn client_detached(&self, client: ClientId, others: bool) -> Result<(), HostError> {
        state_mut(&self.lua).attached = others;
        let outer = self.with_editor_mut(|ed| {
            let outer = ed.client();
            ed.act_as(client);
            outer
        });
        let told = budgeted(&self.lua, || {
            let payload = self.lua.create_table()?;
            api::emit_for_client(&self.lua, "client.detached", &payload)?;
            let closed = self.with_editor_mut(|ed| ed.close_floats_of(client));
            for view in closed {
                handles::view_closed(&self.lua, view)?;
            }
            Ok::<_, mlua::Error>(())
        })
        .map_err(HostError::from);
        self.with_editor_mut(|ed| ed.act_as(outer));
        told
    }

    /// Tells plugins text was pasted into `client`, with "client.paste";
    /// the core plugin puts it at the cursors.
    pub fn paste(&self, client: ClientId, text: &str) -> Result<(), HostError> {
        self.act_for(client)?;
        budgeted(&self.lua, || {
            let payload = self.lua.create_table()?;
            payload.set("text", text)?;
            api::emit_for_client(&self.lua, "client.paste", &payload).map_err(HostError::from)
        })
    }

    /// Acts for `client` from now on, as it does something.
    fn act_for(&self, client: ClientId) -> Result<(), HostError> {
        if self.with_editor_mut(|ed| ed.set_acting(client)) {
            Ok(())
        } else {
            Err(HostError::UnknownClient(client))
        }
    }

    /// Forgets what plugins were told about client `id` and what waits for
    /// its keys, once it's gone.
    pub fn forget_client(&self, id: ClientId) {
        let state = &mut *state_mut(&self.lua);
        state.key_waiter.remove(&id);
        state.recording.remove(&id);
        state.focus_told.remove(&id);
        state.view_sizes.retain(|(client, _), _| *client != id);
        state.view_scrolls.retain(|(client, _), _| *client != id);
        state.view_selections.retain(|(client, _), _| *client != id);
        state.tasks.forget_client(id);
    }

    /// Tells plugins the editor is up and about to show itself, with
    /// "editor.started": once per run, so reloading a plugin doesn't repeat
    /// what it does then. Says which keys are bound to commands that don't
    /// exist, if any are.
    pub fn started(&self) -> Result<(), HostError> {
        let emitted = budgeted(&self.lua, || {
            let payload = self.lua.create_table()?;
            api::emit(&self.lua, "editor.started", &payload).map_err(HostError::from)
        });
        let unknown = api::unknown_bindings(&self.lua);
        if !unknown.is_empty() {
            state_mut(&self.lua).editor.echo(unknown.join("; "));
        }
        emitted
    }

    /// Tells plugins what the mouse did in `client`, with "mouse", and what
    /// was under it.
    pub fn mouse(&self, client: ClientId, mouse: Mouse, hit: &Hit) -> Result<(), HostError> {
        self.act_for(client)?;
        budgeted(&self.lua, || {
            mouse_event(&self.lua, mouse, hit).map_err(HostError::from)
        })
    }

    /// The plugin and what it was running that `message`, an error, came
    /// from, as "notes (on buffer.opened)", when it's the error kept last.
    pub fn error_source(&self, message: &str) -> Option<String> {
        errors::source_of(&self.lua, message)
    }

    /// Tells plugins which session this editor is.
    pub fn set_session_name(&self, name: &str) {
        state_mut(&self.lua).session_name = Some(name.to_owned());
    }

    /// Tells plugins the session socket connection `id` closed, with
    /// "control.closed", e.g. so what its requests wait on can stop.
    pub fn connection_closed(&self, id: u64) -> Result<(), HostError> {
        state_mut(&self.lua).connections.remove(&id);
        budgeted(&self.lua, || {
            let payload = self.lua.create_table()?;
            payload.set("connection", id)?;
            api::emit(&self.lua, "control.closed", &payload).map_err(HostError::from)
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

    /// Tells plugins about another view taking focus, with "view.focused",
    /// and views whose selection changed since the last call, with
    /// "selection.changed": once each however many changes there were.
    /// Call it before drawing a frame.
    pub fn report_selections(&self) -> Result<(), HostError> {
        budgeted(&self.lua, || {
            report_selections(&self.lua).map_err(HostError::from)
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

    /// Whether plugins watch any files, so the session should look at them
    /// now and then with [`Host::check_watches`].
    pub fn watching(&self) -> bool {
        watch::watching(&self.lua)
    }

    /// Tells plugins about watched files that changed ("file.changed").
    pub fn check_watches(&self) -> Result<(), HostError> {
        budgeted(&self.lua, || {
            watch::check(&self.lua).map_err(HostError::from)
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

    /// Starts language servers with `launcher` instead of running their
    /// commands; for tests.
    pub fn set_lsp_launcher(&self, launcher: crate::lsp::Launcher) {
        state_mut(&self.lua).lsp.set_launcher(launcher);
    }

    /// Runs a command as the user, from `client`.
    pub fn run(&self, client: ClientId, name: &str) -> Result<(), HostError> {
        self.act_for(client)?;
        budgeted(&self.lua, || api::run_command(&self.lua, name))
    }

    /// The command line commands plugins added: name, what follows it on
    /// the command line and what it does, sorted by name.
    pub fn cli_commands(&self) -> Vec<(String, String, String)> {
        cli::list(&self.lua)
    }

    /// Runs the command line command `name` with `args` to its end, waiting
    /// on the jobs and timers it waits on, and handing each message it
    /// echoes to `say`. Returns what it returned, as text.
    pub fn run_cli(
        &self,
        name: &str,
        args: Vec<String>,
        say: &mut dyn FnMut(&str),
    ) -> Result<Option<String>, HostError> {
        Ok(cli::run(&self.lua, name, args, say)?)
    }

    /// Runs `f`, the editor's own work doing `what` (handling a key, drawing),
    /// timed like plugin code: a stall if it holds the editor up, and in the
    /// profile while one is taken.
    pub fn timed<R>(&self, what: &str, f: impl FnOnce() -> R) -> R {
        stalls::timed(&self.lua, None, what, f).0
    }

    /// Feeds one key press from `client` through its keymap, running
    /// whatever it resolves to.
    pub fn press(&self, client: ClientId, key: Key) -> Result<(), HostError> {
        self.act_for(client)?;
        budgeted(&self.lua, || api::press(&self.lua, key))
    }

    /// Whether the command the last key `client` typed ran is still at work:
    /// cut into time slices, or waiting on a timer, a job, or a command that
    /// is. Keys it types meanwhile should wait their turn. One waiting for
    /// the user, for a key or a prompt's answer, isn't at work.
    pub fn key_command_at_work(&self, client: ClientId) -> bool {
        tasks::key_command_at_work(&self.lua, client)
    }

    /// Stops `client`'s keys waiting for the command its last key ran,
    /// though it's still at work, once they've waited long enough.
    pub fn let_keys_through(&self, client: ClientId) {
        tasks::let_keys_through(&self.lua, client);
    }

    /// Presses each key of a space-separated sequence, e.g. `"g g"`, as the
    /// first client.
    pub fn press_keys(&self, keys: &str) -> Result<(), HostError> {
        Key::parse_sequence(keys)?
            .into_iter()
            .try_for_each(|key| self.press(crate::FIRST_CLIENT, key))
    }
}

/// Loads the plugin in `dir`, described by its `plugin.toml`, replacing a
/// loaded plugin of the same name.
pub(crate) fn load_dir(lua: &Lua, dir: &Path) -> Result<PluginId, HostError> {
    let (dir, manifest) = read_manifest(dir)?;
    let grant = capabilities::Grant::listed(&manifest.capabilities).map_err(|message| {
        HostError::Manifest {
            path: dir.join("plugin.toml"),
            message,
        }
    })?;
    load_manifest(lua, dir, manifest, grant)
}

/// Loads the folder `dir` as a plugin called `name`, with `init.luau` as its
/// entry, unless it has a `plugin.toml` saying otherwise. For config that
/// isn't a packaged plugin, like a project's `.greed` folder, which gets
/// every capability as config does.
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
        capabilities: Vec::new(),
    };
    load_manifest(lua, dir, manifest, capabilities::Grant::All)
}

fn load_manifest(
    lua: &Lua,
    dir: PathBuf,
    manifest: Manifest,
    grant: capabilities::Grant,
) -> Result<PluginId, HostError> {
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
    let missing = unapproved(lua, &dir, &grant);
    // A plugin being checked gets only what you approved for it.
    let grant = match (grant, state(lua).floor.iter().find(|(by, _)| *by == name)) {
        (capabilities::Grant::Only(asked), Some((_, capabilities::Grant::Only(approved)))) => {
            capabilities::Grant::Only(asked.intersection(approved).cloned().collect())
        }
        (grant, _) => grant,
    };
    {
        let pending = &mut state_mut(lua).pending;
        pending.retain(|p| *p != dir);
        if !missing.is_empty() {
            pending.push(dir);
            return Err(HostError::NotApproved { name, missing });
        }
    }
    let plugin = Plugin::Dir {
        dir,
        entry: manifest.entry,
        requires: manifest.requires,
        grant,
    };
    install(lua, &name, plugin)?;
    Ok(name)
}

/// The capabilities `grant` holds that the plugin in `dir` needs approved
/// first; empty when plugins need no approving.
fn unapproved(lua: &Lua, dir: &Path, grant: &capabilities::Grant) -> Vec<String> {
    state(lua)
        .approvals
        .as_ref()
        .map(|a| a.missing(dir, grant))
        .unwrap_or_default()
}

/// What you approved for the plugin in `dir`, for checking it before it
/// loads; `None` when it needs no approving.
pub(crate) fn approved_for(lua: &Lua, dir: &Path) -> Option<BTreeSet<String>> {
    let dir = dir.canonicalize().unwrap_or_else(|_| dir.to_owned());
    state(lua).approvals.as_ref()?.approved(&dir)
}

/// What the plugin in `dir` is and asks for, for a review: `{ name, dir,
/// requires, capabilities = { { name, what } }, missing }`, where `missing`
/// lists the capabilities not approved yet.
pub(crate) fn describe(lua: &Lua, dir: &Path) -> mlua::Result<mlua::Table> {
    let (dir, manifest) = read_manifest(dir).map_err(api::into_lua)?;
    let grant =
        capabilities::Grant::listed(&manifest.capabilities).map_err(mlua::Error::runtime)?;
    let missing = unapproved(lua, &dir, &grant);
    let t = lua.create_table()?;
    t.set("name", manifest.name)?;
    t.set("dir", dir.to_string_lossy().into_owned())?;
    t.set("requires", manifest.requires)?;
    let list = lua.create_table()?;
    for name in &manifest.capabilities {
        let what = capabilities::what(name).unwrap_or_default();
        let entry = lua.create_table()?;
        entry.set("name", name.as_str())?;
        entry.set("what", what)?;
        list.push(entry)?;
    }
    t.set("capabilities", list)?;
    t.set("missing", missing)?;
    Ok(t)
}

/// Approves what the plugin in `dir` declares and loads it, then loads the
/// waiting plugins that can load now.
pub(crate) fn approve(lua: &Lua, dir: &Path) -> Result<PluginId, HostError> {
    let (dir, manifest) = read_manifest(dir)?;
    let grant = capabilities::Grant::listed(&manifest.capabilities).map_err(|message| {
        HostError::Manifest {
            path: dir.join("plugin.toml"),
            message,
        }
    })?;
    if let (Some(approvals), capabilities::Grant::Only(asked)) =
        (state_mut(lua).approvals.as_mut(), &grant)
    {
        approvals
            .approve(&dir, asked)
            .map_err(|err| HostError::Manifest {
                path: approvals.path().to_owned(),
                message: err.to_string(),
            })?;
    }
    let name = load_manifest(lua, dir, manifest, grant)?;
    // Those that waited for this one, or were approved some other way.
    let waiting = state(lua).pending.clone();
    for waiting in waiting {
        let _ = load_dir(lua, &waiting);
    }
    Ok(name)
}

/// Adds or replaces a plugin and runs it.
fn install(lua: &Lua, name: &str, plugin: Plugin) -> Result<(), HostError> {
    unregister(lua, name)?;
    let (dir, grant) = match &plugin {
        Plugin::Dir { dir, grant, .. } => (Some(dir.to_string_lossy().into_owned()), grant.clone()),
        Plugin::Inline(_) => (None, capabilities::Grant::All),
    };
    {
        let mut state = state_mut(lua);
        state.plugins.insert(name.into(), plugin);
        state.grants.insert(name.into(), grant);
    }
    run_plugin(lua, name)?;
    let payload = lua.create_table()?;
    payload.set("name", name)?;
    payload.set("dir", dir)?;
    api::emit(lua, "plugin.loaded", &payload)?;
    Ok(())
}

fn run_plugin(lua: &Lua, name: &str) -> Result<(), HostError> {
    let plugin = state(lua).plugins[name].clone();
    let owner = Some(PluginId::from(name));
    let export = match plugin {
        Plugin::Dir {
            dir, entry, grant, ..
        } => {
            let file = dir.join(entry);
            let modules = Modules::new(lua, name, Some(dir), None, &grant)?;
            capabilities::running_as(lua, owner.as_ref(), "loading", || {
                budgeted(lua, || modules.run_file(lua, &file))
            })?
        }
        Plugin::Inline(source) => {
            let modules = Modules::new(lua, name, None, None, &capabilities::Grant::All)?;
            let chunk_name = format!("@{name}");
            let values = capabilities::running_as(lua, owner.as_ref(), "loading", || {
                budgeted(lua, || modules.eval(lua, &source, &chunk_name))
            })?;
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
        let author = greed_text::Author::User(state(lua).editor.client());
        payload.set("view", handles::ViewRef { id: view, author })?;
        payload.set("pos", hit.pos)?;
        payload.set("x", hit.x)?;
        payload.set("y", hit.y)?;
        payload.set("border", hit.border)?;
        payload.set("edge", hit.edge)?;
    }
    payload.set("action", hit.action.as_deref())?;
    payload.set("tab", hit.tab.map(|t| t.0))?;
    api::emit_for_client(lua, "mouse", &payload)
}

/// Runs `report` acting for each client in turn, then for the one acting
/// before, so what it tells plugins is each client's and their handlers run
/// as it. Returns whether any call returned true; the first error stops it.
fn as_each_client(
    lua: &Lua,
    mut report: impl FnMut(ClientId) -> mlua::Result<bool>,
) -> mlua::Result<bool> {
    let (outer, clients): (ClientId, Vec<ClientId>) = {
        let editor = &state(lua).editor;
        (
            editor.client(),
            editor.clients().map(crate::ClientState::id).collect(),
        )
    };
    let mut heard = false;
    let mut result = Ok(());
    for client in clients {
        state_mut(lua).editor.act_as(client);
        match report(client) {
            Ok(now) => heard |= now,
            Err(err) => {
                result = Err(err);
                break;
            }
        }
    }
    state_mut(lua).editor.act_as(outer);
    result.map(|()| heard)
}

/// Replaces what `told` holds for `client`'s views with `now`.
fn replace_client_views<V>(
    told: &mut HashMap<(ClientId, crate::ViewId), V>,
    client: ClientId,
    now: HashMap<(ClientId, crate::ViewId), V>,
) {
    told.retain(|(c, _), _| *c != client);
    told.extend(now);
}

/// Emits "view.resized" for each view drawn at a new size and
/// "view.scrolled" for each scrolled to a new line, for each client. Returns
/// whether a handler heard either.
fn report_views(lua: &Lua) -> mlua::Result<bool> {
    as_each_client(lua, |client| report_views_of(lua, client))
}

/// [`report_views`] for `client`, the acting one.
fn report_views_of(lua: &Lua, client: ClientId) -> mlua::Result<bool> {
    let (resized, scrolled): (Vec<_>, Vec<_>) = {
        let state = &mut *state_mut(lua);
        let sizes: HashMap<_, _> = state
            .editor
            .view_sizes()
            .map(|(id, size)| ((client, id), size))
            .collect();
        let resized = sizes
            .iter()
            .filter(|(id, size)| state.view_sizes.get(id) != Some(size))
            .map(|((_, id), size)| (*id, *size))
            .collect();
        replace_client_views(&mut state.view_sizes, client, sizes);
        let scrolls: HashMap<_, _> = state
            .editor
            .view_scrolls()
            .map(|(id, line)| ((client, id), line))
            .collect();
        // A view that's new hasn't scrolled anywhere yet.
        let scrolled = scrolls
            .iter()
            .filter(|(id, line)| state.view_scrolls.get(id).is_some_and(|old| old != *line))
            .map(|((_, id), line)| (*id, *line))
            .collect();
        replace_client_views(&mut state.view_scrolls, client, scrolls);
        (resized, scrolled)
    };
    let author = greed_text::Author::User(client);
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
        api::emit_for_client(lua, "view.resized", &payload)?;
    }
    for (id, line) in scrolled {
        let payload = payload(id)?;
        payload.set("line", line)?;
        api::emit_for_client(lua, "view.scrolled", &payload)?;
    }
    Ok(reported)
}

/// Emits "view.focused" when another view has focus and
/// "selection.changed" for each view whose selection changed, or which shows
/// another buffer, for each client. Views that are new have nothing to
/// compare with. What handlers change in answer is told once more.
fn report_selections(lua: &Lua) -> mlua::Result<()> {
    if as_each_client(lua, |client| report_selections_of(lua, client))? {
        as_each_client(lua, |client| report_selections_of(lua, client))?;
    }
    Ok(())
}

/// One round of [`report_selections`] for `client`, the acting one; whether
/// a handler heard it.
fn report_selections_of(lua: &Lua, client: ClientId) -> mlua::Result<bool> {
    let (focused, changed) = {
        let state = &mut *state_mut(lua);
        // Taken every round, so a move it isn't told of (a client that
        // just attached) isn't told with a later focus change of its own.
        let moved = state.editor.take_moved();
        let editor = &state.editor;
        let focus = editor.focus();
        let focused = match state.focus_told.insert(client, focus) {
            Some(old) if old != focus => Some((focus, editor.find_view(old).map(|_| old), moved)),
            _ => None,
        };
        let now: HashMap<_, _> = editor
            .view_selections()
            .map(|(id, buffer, selection)| ((client, id), (buffer, selection.clone())))
            .collect();
        let changed: Vec<_> = now
            .iter()
            .filter(|(id, seen)| {
                state
                    .view_selections
                    .get(id)
                    .is_some_and(|old| old != *seen)
            })
            .map(|((_, id), _)| *id)
            .collect();
        replace_client_views(&mut state.view_selections, client, now);
        (focused, changed)
    };
    let author = greed_text::Author::User(client);
    let view = |id| handles::ViewRef {
        id,
        author: author.clone(),
    };
    let heard = |event: &str| !state(lua).registry.handlers(event).is_empty();
    let reported = (focused.is_some() && heard("view.focused"))
        || (!changed.is_empty() && heard("selection.changed"));
    if let Some((id, from, moved)) = focused {
        let payload = lua.create_table()?;
        payload.set("view", view(id))?;
        payload.set("from", from.map(&view))?;
        payload.set("moved", moved)?;
        api::emit_for_client(lua, "view.focused", &payload)?;
    }
    for id in changed {
        let payload = lua.create_table()?;
        payload.set("view", view(id))?;
        api::emit_for_client(lua, "selection.changed", &payload)?;
    }
    Ok(reported)
}

/// Removes everything plugin `name` registered and stops what it runs.
fn unregister(lua: &Lua, name: &str) -> mlua::Result<()> {
    let (closed, removes) = {
        let state = &mut *state_mut(lua);
        (
            remove_owned_by(state, name),
            plugin::untie(&mut state.ties, name),
        )
    };
    tasks::stop_owned_by(lua, name)?;
    for view in closed {
        handles::view_closed(lua, view)?;
    }
    // Every one runs even if one fails; the first error is returned.
    let label: Arc<str> = format!("removing what {name} added").into();
    let mut first_error = None;
    for (owner, remove) in removes {
        if let Err(err) = tasks::spawn_labelled(lua, remove, (), owner, label.clone()) {
            first_error.get_or_insert(err);
        }
    }
    first_error.map_or(Ok(()), Err)
}

/// Removes what `name` registered and made, returning the views it closed.
fn remove_owned_by(state: &mut State, name: &str) -> Vec<crate::ViewId> {
    state.registry.remove_owned_by(name);
    state.terminals.remove_owned_by(name);
    state.children.remove_owned_by(name);
    state.watches.remove_owned_by(name);
    let closed = state
        .owned
        .remove_owned_by(name, &mut state.editor, &mut state.lsp);
    state.lsp_handlers.retain(|_, (owner, _)| &**owner != name);
    state.lsp_listeners.retain(|(_, owner, _)| &**owner != name);
    state.cli.retain(|_, command| &*command.owner != name);
    state.editor.keymap_mut().remove_owned_by(name);
    let mut restyled: Vec<Arc<str>> = state
        .theme_base
        .take_if(|(owner, _)| &**owner == name)
        .map(|(_, base)| base.into_keys().collect())
        .unwrap_or_default();
    state.theme_set.retain(|entry, (owner, _)| {
        let owned = &**owner == name;
        if owned {
            restyled.push(entry.clone());
        }
        !owned
    });
    for entry in &restyled {
        theme::refresh(state, entry);
    }
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
    closed
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
    unregister(lua, name)?;
    {
        let mut state = state_mut(lua);
        state.plugins.remove(name);
        state.exports.remove(name);
        state.grants.remove(name);
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
        let modules = Modules::new(lua, REPL, None, None, &capabilities::Grant::All)?;
        state_mut(lua).repl = Some(modules.clone());
        modules
    };
    eval_as_text(lua, source, |chunk| modules.eval(lua, chunk, "=repl"))
}

/// Evaluates Luau sandboxed, in a fresh environment each time: it runs as
/// [`capabilities::SANDBOX`], which may read the editor and edit buffers and
/// nothing more. What it would do beyond that fails with an error starting
/// "needs approval:". Expressions return their values as text, separated by
/// tabs.
pub(crate) fn eval_sandboxed(lua: &Lua, source: &str) -> mlua::Result<String> {
    let owner: PluginId = capabilities::SANDBOX.into();
    state_mut(lua)
        .grants
        .entry(owner.clone())
        .or_insert_with(capabilities::sandbox_grant);
    let modules = Modules::sandbox(lua)?;
    eval_as_text(lua, source, |chunk| {
        capabilities::running_as(lua, Some(&owner), "sandboxed eval", || {
            modules.eval(lua, chunk, "=sandbox")
        })
    })
}

/// Runs `source` with `eval`, as an expression if it is one, and returns its
/// values as text, separated by tabs.
fn eval_as_text(
    lua: &Lua,
    source: &str,
    eval: impl FnOnce(&str) -> mlua::Result<mlua::MultiValue>,
) -> mlua::Result<String> {
    let expression = format!("return {source}");
    let chunk = match lua.load(&expression).into_function() {
        Ok(_) => expression.as_str(),
        Err(_) => source,
    };
    let values = eval(chunk)?;
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
/// With no event loop around the host, what `f` started that its time slice
/// cut short then carries on, each turn of it with a budget of its own.
fn budgeted<T, E: From<mlua::Error>>(lua: &Lua, f: impl FnOnce() -> Result<T, E>) -> Result<T, E> {
    if deadline(lua).at.get().is_some() {
        return f();
    }
    let result = within_budget(lua, f);
    if deadline(lua).looped.get() {
        return result;
    }
    let mut first_error = None;
    loop {
        match within_budget(lua, || tasks::resume_sliced(lua)) {
            Ok(true) => {}
            Ok(false) => break,
            Err(err) => {
                first_error.get_or_insert(err);
            }
        }
    }
    let value = result?;
    match first_error {
        Some(err) => Err(err.into()),
        None => Ok(value),
    }
}

/// Runs `f` with the whole budget. A bug it runs into is an error, after
/// which the editor carries on.
fn within_budget<T, E: From<mlua::Error>>(
    lua: &Lua,
    f: impl FnOnce() -> Result<T, E>,
) -> Result<T, E> {
    deadline(lua).start();
    let result =
        crate::panics::catching(f).unwrap_or_else(|panic| Err(mlua::Error::runtime(panic).into()));
    deadline(lua).at.set(None);
    result
}

/// Moves the current call's deadline `by` later, for time spent waiting on
/// something other than Luau, which shouldn't count against its budget.
fn extend_deadline(lua: &Lua, by: Duration) {
    let deadline = deadline(lua);
    if let Some(at) = deadline.at.get() {
        deadline.at.set(Some(at + by));
    }
}

/// Gives the current call its whole budget again, from now: for a test,
/// whose every key and command is a call of its own, as in the editor.
fn restart_deadline(lua: &Lua) {
    let deadline = deadline(lua);
    if deadline.at.get().is_some() {
        deadline.start();
    }
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

/// `ms` milliseconds from Luau as a duration: none for a negative number
/// or NaN, and at most a year for a huge one or infinity.
pub(crate) fn millis(ms: f64) -> Duration {
    const YEAR: Duration = Duration::from_secs(365 * 24 * 3600);
    if ms.is_nan() || ms <= 0.0 {
        return Duration::ZERO;
    }
    Duration::try_from_secs_f64(ms / 1000.0).map_or(YEAR, |d| d.min(YEAR))
}

/// Runs `f`, a run of the task coroutine `thread`, as a slice the
/// interrupt may cut short.
fn sliced<R>(lua: &Lua, thread: usize, f: impl FnOnce() -> R) -> R {
    let outer = deadline(lua).slice.replace(Some(Slice::new(thread)));
    let result = f();
    deadline(lua).slice.set(outer);
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Works on a CPU for `time`, however busy the machine is.
    fn busy(time: Duration) {
        let (start, from) = (cpu_time(), Instant::now());
        loop {
            let worked = match (start, cpu_time()) {
                (Some(start), Some(now)) => now.saturating_sub(start),
                _ => from.elapsed(),
            };
            if worked > time {
                return;
            }
        }
    }

    #[test]
    fn a_slice_runs_out_after_working_its_time() {
        let mut slice = Slice::new(1);
        assert!(!slice.ran_out(Instant::now()), "just started");
        busy(SLICE * 2);
        assert!(slice.ran_out(Instant::now()));
    }

    #[test]
    fn a_bug_the_editor_runs_into_is_an_error_kept_with_its_plugin() {
        let mut editor = Editor::new(greed_text::ClientId(1));
        editor.open("file", "", None);
        let host = Host::new(editor).unwrap();
        let lua = &host.lua;
        let broken = lua
            .create_function(|_, ()| -> mlua::Result<()> { panic!("broken on purpose") })
            .unwrap();

        // Called from the editor.
        let called: Result<(), HostError> = budgeted(lua, || Ok(broken.call::<()>(())?));
        let err = called.unwrap_err().to_string();
        assert!(err.contains("broken on purpose"), "{err}");
        assert!(err.contains("a bug in Greed"), "{err}");

        // Called from a plugin's handler, which fails as with any error.
        let handler: Function = lua
            .load("local broken = ... return function() broken() end")
            .call(broken)
            .unwrap();
        let ran = budgeted(lua, || {
            tasks::spawn(lua, handler, (), "careless".into(), None)
        });
        assert!(ran.is_err());
        let kept = errors::list(lua).unwrap();
        let first: mlua::Table = kept.get(1).unwrap();
        assert_eq!(first.get::<String>("plugin").unwrap(), "careless");
        let message: String = first.get("message").unwrap();
        assert!(message.contains("broken on purpose"), "{message}");

        // And it carries on.
        assert_eq!(host.eval("1 + 1").unwrap(), "2");
    }

    #[test]
    fn time_a_slice_spends_off_the_cpu_doesnt_count() {
        let mut slice = Slice::new(1);
        if slice.worked.is_none() {
            // This system doesn't say how long a thread has worked.
            return;
        }
        let started = slice.from;
        std::thread::sleep(SLICE * 2);
        assert!(!slice.ran_out(Instant::now()));
        assert!(slice.from > started, "it starts again from the wait");
        busy(SLICE * 2);
        assert!(slice.ran_out(Instant::now()));
    }

    #[test]
    fn milliseconds_from_luau_are_none_to_a_year() {
        let year = Duration::from_secs(365 * 24 * 3600);
        assert_eq!(millis(1500.0), Duration::from_millis(1500));
        for ms in [-1.0, 0.0, f64::NAN, f64::NEG_INFINITY] {
            assert_eq!(millis(ms), Duration::ZERO, "{ms}");
        }
        for ms in [1e20, 1e300, f64::INFINITY, f64::MAX] {
            assert_eq!(millis(ms), year, "{ms}");
        }
    }

    #[test]
    fn a_call_is_stopped_once_it_has_worked_its_budget() {
        let deadline = Deadline::new(Duration::from_millis(30));
        deadline.start();
        let at = deadline.at.get().unwrap();
        if deadline.worked.get().is_some() {
            // Waiting isn't working.
            std::thread::sleep(Duration::from_millis(60));
            assert!(!deadline.spent(Instant::now()));
            assert!(deadline.at.get().unwrap() > at, "the deadline moved");
        }
        busy(Duration::from_millis(40));
        assert!(deadline.spent(Instant::now()));
    }
}
