//! `greed test`: runs a plugin's `test/*.luau` files against a headless
//! editor.
//!
//! A test file gets `test` from `require("@greed/test")` and calls
//! `test(name, function(t) ... end)` for each test. Every
//! test runs in a fresh host with the plugins loaded, so tests can't affect
//! each other, and they run side by side. `t` sets up a buffer, presses keys
//! and checks the result:
//!
//! ```luau
//! local test = require("@greed/test")
//!
//! test("w selects a word", function(t)
//!     t:buffer("|hello world")
//!     t:keys("w")
//!     t:expect("^hello |world")
//! end)
//! ```
//!
//! Buffers are written with markers: `|` at each head and `^` at the anchor
//! of a non-empty range.

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Condvar, Mutex, PoisonError};
use std::time::{Duration, Instant};

use greed_text::ClientId;
use mlua::{Function, Lua, Table, UserData, UserDataMethods};

use super::arity::NoArgs;
use super::capabilities::Grant;
use super::modules::Modules;
use super::{
    Host, HostError, api, budgeted, extend_deadline, jobs, restart_deadline, state, state_mut,
    tasks, terminal, watch,
};
use crate::keymap::{Key, KeyCode};
use crate::{Editor, parse_marked};

/// The outcome of one test.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TestResult {
    pub file: PathBuf,
    pub name: String,
    /// Why the test failed, or `None` if it passed.
    pub failure: Option<String>,
}

/// Runs every test in `dir/test/*.luau`. Each test gets a fresh host with
/// `plugins` loaded, in order. They run side by side, on as many threads as
/// the machine has cores.
pub fn run_tests(plugins: &[PathBuf], dir: &Path) -> Result<Vec<TestResult>, HostError> {
    run_on(plugins, dir, None, cores())
}

/// `run_tests`, for checking the plugin in `dir`, the last of `plugins`,
/// before it's approved: with `approved`, it and what its tests do get no
/// capabilities but those, and what needs others fails as needing approval.
/// The tests run one at a time, since the editor, or the test checking a
/// plugin, carries on meanwhile.
pub(super) fn run_checked(
    plugins: &[PathBuf],
    dir: &Path,
    approved: Option<&BTreeSet<String>>,
) -> Result<Vec<TestResult>, HostError> {
    run_on(plugins, dir, approved, 1)
}

fn run_on(
    plugins: &[PathBuf],
    dir: &Path,
    approved: Option<&BTreeSet<String>>,
    threads: usize,
) -> Result<Vec<TestResult>, HostError> {
    let dir = &dir.canonicalize().map_err(|err| HostError::Manifest {
        path: dir.to_owned(),
        message: err.to_string(),
    })?;
    let mut files: Vec<PathBuf> = match std::fs::read_dir(dir.join("test")) {
        Ok(entries) => entries
            .filter_map(|entry| entry.ok().map(|e| e.path()))
            .filter(|path| path.extension().is_some_and(|ext| ext == "luau"))
            .collect(),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Vec::new(),
        Err(err) => {
            return Err(HostError::Manifest {
                path: dir.join("test"),
                message: err.to_string(),
            });
        }
    };
    files.sort();

    let names = side_by_side(&files, threads, |file| {
        fresh_host(plugins, approved)?.test_names(dir, file)
    });
    let mut tests = Vec::new();
    for (file, names) in files.iter().zip(names) {
        tests.extend(names?.into_iter().map(|name| (file, name)));
    }
    let failures = side_by_side(&tests, threads, |(file, name)| {
        let _watched = Watched::start(file, name);
        fresh_host(plugins, approved)?.run_test(dir, file, name)
    });
    tests
        .into_iter()
        .zip(failures)
        .map(|((file, name), failure)| {
            Ok(TestResult {
                file: file.clone(),
                name,
                failure: failure?,
            })
        })
        .collect()
}

/// `run_tests` for several plugins at once: each of `suites` is the plugins
/// to load and the plugin whose tests to run. They run side by side, and
/// their results come back in the same order.
pub fn run_suites(suites: &[(Vec<PathBuf>, PathBuf)]) -> Vec<Result<Vec<TestResult>, HostError>> {
    // A thread for each; their tests share the cores.
    std::thread::scope(|scope| {
        let running: Vec<_> = suites
            .iter()
            .map(|(plugins, dir)| scope.spawn(move || run_tests(plugins, dir)))
            .collect();
        running.into_iter().map(joined).collect()
    })
}

/// `f` of each of `items`, in order, worked out on up to `threads` threads.
/// However many calls run at once, the process works on no more items at a
/// time than the machine has cores.
fn side_by_side<T: Sync, R: Send>(
    items: &[T],
    threads: usize,
    f: impl Fn(&T) -> R + Sync,
) -> Vec<R> {
    if threads <= 1 {
        return items.iter().map(f).collect();
    }
    let workers = threads.min(items.len());
    let next = AtomicUsize::new(0);
    let mut done: Vec<(usize, R)> = std::thread::scope(|scope| {
        let workers: Vec<_> = (0..workers)
            .map(|_| {
                scope.spawn(|| {
                    let mut done = Vec::new();
                    loop {
                        let i = next.fetch_add(1, Ordering::Relaxed);
                        let Some(item) = items.get(i) else {
                            return done;
                        };
                        let _core = Core::take();
                        done.push((i, f(item)));
                    }
                })
            })
            .collect();
        workers.into_iter().flat_map(joined).collect()
    });
    done.sort_by_key(|(i, _)| *i);
    done.into_iter().map(|(_, result)| result).collect()
}

/// What a thread returned, or its panic, passed on.
fn joined<R>(thread: std::thread::ScopedJoinHandle<'_, R>) -> R {
    thread
        .join()
        .unwrap_or_else(|panic| std::panic::resume_unwind(panic))
}

/// How long a test runs before the watchdog names it.
const STUCK: Duration = Duration::from_secs(30);

/// The tests running now, by a number of their own, with when each started.
static RUNNING: Mutex<Vec<(usize, String, Instant)>> = Mutex::new(Vec::new());

/// A test running, which the watchdog names on stderr once it has run
/// longer than `STUCK`, so a test that never ends says which it is.
struct Watched(usize);

impl Watched {
    fn start(file: &Path, name: &str) -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        static WATCHDOG: std::sync::Once = std::sync::Once::new();
        WATCHDOG.call_once(|| {
            let _ = std::thread::Builder::new()
                .name("greed-test-watchdog".into())
                .spawn(watchdog);
        });
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        let what = format!("{} {name:?}", file.display());
        running().push((id, what, Instant::now()));
        WATCHED.set(Some(id));
        Self(id)
    }
}

impl Drop for Watched {
    fn drop(&mut self) {
        WATCHED.set(None);
        running().retain(|(id, ..)| *id != self.0);
        busy().remove(&self.0);
    }
}

thread_local! {
    /// The test this thread runs, while the watchdog watches it.
    static WATCHED: Cell<Option<usize>> = const { Cell::new(None) };
}

/// What each test running has resumed lately: the task, how many times,
/// and where it was, so a test that never ends says what keeps it busy.
#[derive(Default)]
struct Busy {
    what: String,
    resumed: u64,
    traceback: String,
}

static BUSY: Mutex<BTreeMap<usize, Busy>> = Mutex::new(BTreeMap::new());

fn busy() -> std::sync::MutexGuard<'static, BTreeMap<usize, Busy>> {
    BUSY.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Notes that the test on this thread, if the watchdog watches one, just
/// resumed task `what`; `traceback` says where it is, asked now and then.
pub(super) fn resumed(what: &str, traceback: impl FnOnce() -> String) {
    let Some(id) = WATCHED.get() else {
        return;
    };
    let mut busy = busy();
    let entry = busy.entry(id).or_default();
    entry.resumed += 1;
    if entry.what != what || entry.resumed % 256 == 1 {
        what.clone_into(&mut entry.what);
        entry.traceback = traceback();
    }
}

fn running() -> std::sync::MutexGuard<'static, Vec<(usize, String, Instant)>> {
    RUNNING.lock().unwrap_or_else(PoisonError::into_inner)
}

fn watchdog() {
    let mut told = BTreeSet::new();
    loop {
        std::thread::sleep(Duration::from_secs(5));
        for (id, what, started) in running().iter() {
            if started.elapsed() > STUCK && told.insert(*id) {
                // Past `cargo test`'s capture, which shows nothing of a
                // test that never ends.
                let _ = writeln!(std::io::stderr(), "still running after {STUCK:?}: {what}");
                if let Some(busy) = busy().get(id) {
                    let _ = writeln!(
                        std::io::stderr(),
                        "  it resumed {} {} times, last at:\n{}",
                        busy.what,
                        busy.resumed,
                        busy.traceback
                    );
                }
            }
        }
    }
}

fn cores() -> usize {
    std::thread::available_parallelism().map_or(1, std::num::NonZero::get)
}

/// Two of the machine's cores, taken by a test while it runs, so that tests
/// started from many threads at once, as `cargo test` starts them, don't
/// crowd the machine until real-time waits in them give up. Two, as a test
/// keeps more than one busy: the programs it starts and its jobs' threads.
struct Core;

static CORES_TAKEN: (Mutex<usize>, Condvar) = (Mutex::new(0), Condvar::new());

impl Core {
    fn take() -> Self {
        let (taken, freed) = &CORES_TAKEN;
        let mut taken = freed
            .wait_while(
                taken.lock().unwrap_or_else(PoisonError::into_inner),
                |taken| *taken >= cores().div_ceil(2),
            )
            .unwrap_or_else(PoisonError::into_inner);
        *taken += 1;
        Self
    }
}

impl Drop for Core {
    fn drop(&mut self) {
        let (taken, freed) = &CORES_TAKEN;
        *taken.lock().unwrap_or_else(PoisonError::into_inner) -= 1;
        freed.notify_one();
    }
}

/// What looks wrong in what `plugins` register once they're all loaded, as
/// `run_checked` loads them.
pub(super) fn warnings(
    plugins: &[PathBuf],
    approved: Option<&BTreeSet<String>>,
) -> Result<Vec<String>, HostError> {
    Ok(api::registry_warnings(&fresh_host(plugins, approved)?.lua))
}

fn fresh_host(plugins: &[PathBuf], approved: Option<&BTreeSet<String>>) -> Result<Host, HostError> {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", "", None);
    let host = Host::new(editor)?;
    // Folders of the test's own, so plugins writing to the config or cache
    // never touch the user's. They only exist once something writes there.
    let n = NEXT.fetch_add(1, Ordering::Relaxed);
    // Resolved, since on macOS the temporary folder is behind a link
    // (/var to /private/var) and plugins see the resolved paths of files.
    let temp = std::env::temp_dir();
    let temp = temp.canonicalize().unwrap_or(temp);
    let dirs = temp.join(format!("greed-home-{}-{n}", std::process::id()));
    host.use_test_home(dirs);
    host.quiet_stalls();
    let (Some(approved), Some((checked, others))) = (approved, plugins.split_last()) else {
        host.load_dirs(plugins)?;
        trust_projects(&host)?;
        return Ok(host);
    };
    host.load_dirs(others)?;
    // From here on, what runs can do no more than the checked plugin may.
    let floor = vec![(
        super::plugin_name(checked)?.into(),
        Grant::Only(approved.clone()),
    )];
    {
        let mut state = state_mut(&host.lua);
        state.limit.clone_from(&floor);
        state.floor = floor;
    }
    host.load_dir(checked)?;
    trust_projects(&host)?;
    Ok(host)
}

/// Trusts every project, so a file a test opens never stops to ask whether
/// its project may run its code, which would depend on the language servers
/// installed on the machine; a test of trust sets `project-trust` back to
/// "ask".
fn trust_projects(host: &Host) -> Result<(), HostError> {
    host.eval("pcall(require('@greed').option.set, 'project-trust', 'off')")?;
    Ok(())
}

impl Drop for Host {
    fn drop(&mut self) {
        if let Some(dirs) = &state(&self.lua).dirs {
            let _ = std::fs::remove_dir_all(dirs);
        }
    }
}

impl Host {
    /// The names of the tests in a test file, in order.
    fn test_names(&self, root: &Path, file: &Path) -> Result<Vec<String>, HostError> {
        let names = Rc::new(RefCell::new(Vec::new()));
        let collected = names.clone();
        let test = self
            .lua
            .create_function(move |_, (name, _): (String, Function)| {
                collected.borrow_mut().push(name);
                Ok(())
            })?;
        self.run_test_file(root, file, test)?;
        Ok(names.take())
    }

    /// Runs the test called `name`. Returns why it failed, or `None`.
    fn run_test(&self, root: &Path, file: &Path, name: &str) -> Result<Option<String>, HostError> {
        let target = name.to_owned();
        let test = self
            .lua
            .create_function(move |lua, (name, body): (String, Function)| {
                if name == target {
                    // What loading did is the start, with nothing to tell.
                    super::report_selections(lua)?;
                    // As a coroutine, so the test can wait like any command.
                    super::tasks::run_to_end(lua, body, TestContext)?;
                }
                Ok(())
            })?;
        Ok(self
            .run_test_file(root, file, test)
            .err()
            .map(|err| failure(&err)))
    }

    fn run_test_file(&self, root: &Path, file: &Path, test: Function) -> Result<(), HostError> {
        let mut modules = Modules::new(
            &self.lua,
            "test",
            Some(root.to_owned()),
            Some(test),
            &Grant::All,
        )?;
        if let Some(loaded) = super::loaded_at(&self.lua, root) {
            modules = modules.sharing(loaded);
        }
        budgeted(&self.lua, || modules.run_file(&self.lua, file))?;
        Ok(())
    }
}

/// Why a test failed: the error, then the Luau lines it was raised from that
/// the message doesn't name already, so an error from the API, which names
/// no line, still says where it came from.
fn failure(err: &HostError) -> String {
    let brief = err.brief();
    let mut out = brief.clone();
    let text = err.to_string();
    if let Some(trace) = text.split("\nstack traceback:").nth(1) {
        for frame in trace.lines().map(str::trim) {
            let place = frame.split(": ").next().unwrap_or(frame);
            if !frame.is_empty() && !frame.starts_with("[C]") && !brief.contains(place) {
                out.push_str("\nat ");
                out.push_str(frame);
            }
        }
    }
    out
}

/// Delivers terminal events and finishes jobs until `done` returns true, for
/// tests of things that happen in real time, like a program's output. Time
/// spent waiting doesn't count against the test's budget.
fn wait_until(lua: &Lua, done: &Function, limit: Duration) -> mlua::Result<()> {
    const STEP: Duration = Duration::from_millis(10);
    let start = Instant::now();
    let events = state(lua).terminals.events.clone();
    loop {
        for event in events.try_iter() {
            terminal::handle(lua, event)?;
        }
        // Timers due by now fire, as the editor fires them while it waits:
        // by the time as it passes, also when a timer woke the test itself.
        let now = state(lua).tasks.passing();
        tasks::advance(lua, now)?;
        jobs::settle(lua)?;
        watch::check(lua)?;
        end_frame(lua)?;
        if done.call::<bool>(())? {
            return Ok(());
        }
        if start.elapsed() > limit {
            return Err(mlua::Error::runtime(format!(
                "gave up waiting after {limit:?}"
            )));
        }
        std::thread::sleep(STEP);
        extend_deadline(lua, STEP);
    }
}

/// Does what a client sends for the mouse at (`col`, `row`), against the
/// last frame drawn: `kind` is "press", "release", "drag", "move" or
/// "scroll", with a button (default "left") or a scroll direction, and
/// `mods` the keys held (`{ shift = true }`).
fn mouse(
    lua: &Lua,
    kind: &str,
    col: u16,
    row: u16,
    which: Option<&str>,
    mods: Option<&Table>,
) -> mlua::Result<()> {
    use crate::mouse::{Mouse, MouseKind};
    restart_deadline(lua);
    let kind = MouseKind::parse(kind, which)
        .ok_or_else(|| mlua::Error::runtime(format!("{kind:?} {which:?} isn't a mouse event")))?;
    let held = |name: &str| -> mlua::Result<bool> {
        Ok(match mods {
            Some(mods) => mods.get::<Option<bool>>(name)?.unwrap_or(false),
            None => false,
        })
    };
    let event = Mouse {
        kind,
        col,
        row,
        ctrl: held("ctrl")?,
        alt: held("alt")?,
        shift: held("shift")?,
    };
    let hit = with_renderer(lua, |r| r.hit(&state(lua).editor, col, row));
    super::mouse_event(lua, event, &hit)?;
    jobs::settle(lua)?;
    end_frame(lua)
}

/// Echoes already delivered to handlers, retained for `t:messages`.
#[derive(Default)]
struct ObservedMessages(Vec<String>);

/// One turn's detached echo batch. Handler echoes stay queued until the
/// next frame or explicit `t:messages`, just as in the session loop.
fn report_messages(lua: &Lua) -> mlua::Result<()> {
    let (client, messages) = {
        let editor = &mut state_mut(lua).editor;
        (editor.last_active(), editor.take_messages())
    };
    let reported = api::emit_messages(lua, Some(client), &messages);
    if lua.app_data_ref::<ObservedMessages>().is_none() {
        lua.set_app_data(ObservedMessages::default());
    }
    lua.app_data_mut::<ObservedMessages>()
        .expect("it was just set")
        .0
        .extend(messages);
    reported
}

/// Tells plugins what the server tells them before drawing the next frame:
/// selections and focus that changed. Each `t:keys`, `t:run`, `t:mouse`,
/// `t:wait` and `t:draw` ends one.
fn end_frame(lua: &Lua) -> mlua::Result<()> {
    report_messages(lua)?;
    super::report_selections(lua)?;
    jobs::settle(lua)
}

/// The renderer of each client in a test, which its draws and clicks share,
/// so a click finds what its last draw put where, as the server's do.
#[derive(Default)]
struct Renderers(HashMap<ClientId, crate::render::Renderer<crate::render::CellWidth>>);

/// Calls `f` with the acting client's renderer.
fn with_renderer<R>(
    lua: &Lua,
    f: impl FnOnce(&crate::render::Renderer<crate::render::CellWidth>) -> R,
) -> R {
    use crate::render::{CellWidth, Renderer};
    let client = state(lua).editor.client();
    if lua.app_data_ref::<Renderers>().is_none() {
        lua.set_app_data(Renderers::default());
    }
    lua.app_data_mut::<Renderers>()
        .expect("it was just set")
        .0
        .entry(client)
        .or_insert_with(|| Renderer::new(CellWidth));
    let renderers = lua.app_data_ref::<Renderers>().expect("it was just set");
    f(&renderers.0[&client])
}

/// Runs `f` as client `id` does something, then acts for the client acting
/// before again.
fn as_client<R>(lua: &Lua, id: ClientId, f: impl FnOnce() -> mlua::Result<R>) -> mlua::Result<R> {
    let outer = {
        let editor = &mut state_mut(lua).editor;
        let outer = editor.client();
        if !editor.set_acting(id) {
            return Err(mlua::Error::runtime(format!("there is no client {}", id.0)));
        }
        outer
    };
    let result = f();
    state_mut(lua).editor.act_as(outer);
    result
}

/// Runs `f` acting for client `id` without that counting as its doing
/// anything, as when looking at what it sees.
fn seen_by<R>(lua: &Lua, id: ClientId, f: impl FnOnce() -> mlua::Result<R>) -> mlua::Result<R> {
    let outer = {
        let editor = &mut state_mut(lua).editor;
        if editor.client_state(id).is_none() {
            return Err(mlua::Error::runtime(format!("there is no client {}", id.0)));
        }
        let outer = editor.client();
        editor.act_as(id);
        outer
    };
    let result = f();
    state_mut(lua).editor.act_as(outer);
    result
}

/// What `t` and the clients `t:client` adds have in common: each is a
/// client, which their methods act as.
trait TestClient {
    fn id(&self) -> ClientId;
}

/// What a client does and sees, for `t` and the clients `t:client` adds:
/// `keys`, `run`, `mouse`, `draw`, `screen`, `marked`, `expect` and
/// `expect_mode`, each as that client.
fn add_client_view_methods<T: TestClient + UserData, M: UserDataMethods<T>>(methods: &mut M) {
    // A program asking to sign through the agent this client relays.
    methods.add_method("ssh_agent_use", |lua, this, host: Option<String>| {
        static ASKED: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let id = ASKED.fetch_add(1, Ordering::Relaxed) + 1;
        let asked = seen_by(lua, this.id(), || {
            super::ssh_agent::ask(lua, id, host.as_deref())
        })?;
        jobs::settle(lua)?;
        Ok(asked.then_some(id))
    });
    methods.add_method("keys", |lua, this, keys: String| {
        as_client(lua, this.id(), || {
            for key in Key::parse_sequence(&keys).map_err(mlua::Error::external)? {
                restart_deadline(lua);
                api::press(lua, key).map_err(api::into_lua)?;
                jobs::settle(lua)?;
            }
            end_frame(lua)
        })
    });
    methods.add_method("type", |lua, this, text: String| {
        as_client(lua, this.id(), || {
            for c in text.chars() {
                let key = match c {
                    '\n' => Key::named(KeyCode::Enter),
                    '\t' => Key::named(KeyCode::Tab),
                    c => Key::char(c),
                };
                restart_deadline(lua);
                api::press(lua, key).map_err(api::into_lua)?;
                jobs::settle(lua)?;
            }
            end_frame(lua)
        })
    });
    methods.add_method(
        "run",
        |lua, this, (command, args): (String, Option<Vec<String>>)| {
            as_client(lua, this.id(), || {
                restart_deadline(lua);
                api::run_command_with(lua, &command, args.unwrap_or_default())
                    .map_err(api::into_lua)?;
                jobs::settle(lua)?;
                end_frame(lua)
            })
        },
    );
    methods.add_method(
        "mouse",
        |lua,
         this,
         (kind, col, row, which, mods): (String, u16, u16, Option<String>, Option<Table>)| {
            as_client(lua, this.id(), || {
                mouse(lua, &kind, col, row, which.as_deref(), mods.as_ref())
            })
        },
    );
    methods.add_method("draw", |lua, this, (width, height): (u16, u16)| {
        let frame = as_client(lua, this.id(), || draw(lua, width, height))?;
        Ok(crate::render::grid::text_rows(&frame))
    });
    methods.add_method("screen", |lua, this, (width, height): (u16, u16)| {
        use crate::render::grid::compose;
        let frame = as_client(lua, this.id(), || draw(lua, width, height))?;
        Ok(compose(&frame, crate::theme::Medium::Tui)
            .iter()
            .map(|row| row.iter().map(|c| c.text.as_str()).collect::<String>())
            .collect::<Vec<_>>())
    });
    methods.add_method(
        "frame",
        |lua, this, (width, height, medium): (u16, u16, Option<String>)| {
            let frame = as_client(lua, this.id(), || draw(lua, width, height))?;
            frame_table(lua, &frame, medium.as_deref())
        },
    );
    methods.add_method("status", |lua, this, NoArgs| {
        let join = |spans: &[crate::render::Span]| {
            spans.iter().map(|s| s.text.as_str()).collect::<String>()
        };
        let line = seen_by(lua, this.id(), || api::status_line(lua, None, 200))?;
        Ok(line.map_or((None, None), |l| {
            (Some(join(&l.left)), Some(join(&l.right)))
        }))
    });
    methods.add_method("marked", |lua, this, NoArgs| {
        seen_by(lua, this.id(), || Ok(focused_marked_text(lua)))
    });
    methods.add_method("expect", |lua, this, expected: String| {
        let actual = seen_by(lua, this.id(), || Ok(focused_marked_text(lua)))?;
        check(lua, "buffer", &expected, &actual)
    });
    methods.add_method("expect_mode", |lua, this, expected: String| {
        let actual = seen_by(lua, this.id(), || Ok(state(lua).editor.mode().to_owned()))?;
        check(lua, "mode", &expected, &actual)
    });
}

/// A client a test added with `t:client`, as if it had attached.
struct AddedClient(ClientId);

impl TestClient for AddedClient {
    fn id(&self) -> ClientId {
        self.0
    }
}

impl UserData for AddedClient {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method("id", |_, this, NoArgs| Ok(this.0.0));
        add_client_view_methods(methods);
    }
}

/// `t:client(name)`: a client seeing what the first one does, as one
/// attaching would.
fn add_client(lua: &Lua, name: Option<String>, kind: Option<String>) -> mlua::Result<AddedClient> {
    let id = {
        let editor = &mut state_mut(lua).editor;
        let id = editor.next_client_id();
        let outer = editor.act_as(crate::FIRST_CLIENT);
        editor.add_client(id);
        editor.act_as(outer);
        editor.set_client_info(
            id,
            crate::ClientInfo {
                name: name.unwrap_or_else(|| format!("test {}", id.0)),
                kind: kind.unwrap_or_else(|| "test".to_owned()),
                remote: false,
            },
        );
        id
    };
    // Where its selections and focus start, for what it does next to be
    // told as a change.
    end_frame(lua)?;
    Ok(AddedClient(id))
}

/// `t:quitting`, `t:detached`, `t:switched` and `t:notices`: what the
/// editor asked of the client.
fn add_client_methods<M: UserDataMethods<TestContext>>(methods: &mut M) {
    methods.add_method("quitting", |lua, _, NoArgs| {
        Ok(state(lua).editor.quit_requested())
    });
    methods.add_method("detached", |lua, _, NoArgs| {
        Ok(state_mut(lua).editor.take_detach_request())
    });
    methods.add_method("switched", |lua, _, NoArgs| {
        let to = state_mut(lua).editor.take_switch_request();
        to.map(|to| {
            let table = lua.create_table()?;
            table.set("session", to.session)?;
            table.set("path", to.path)?;
            table.set("host", to.host)?;
            table.set("window", to.window)?;
            table.set("back", to.back)?;
            table.set("home", to.home)?;
            Ok::<_, mlua::Error>(table)
        })
        .transpose()
    });
    methods.add_method("clipboard_image", |lua, _, png: Option<mlua::LuaString>| {
        let png = png.map_or_else(Vec::new, |png| png.as_bytes().to_vec());
        state_mut(lua).editor.fake_clipboard_image(Some(png));
        Ok(())
    });
    methods.add_method("ssh_agent_answer", |lua, _, id: u64| {
        let answers = &state(lua).ssh_agent.answers;
        Ok(answers
            .iter()
            .find(|(asked, _)| *asked == id)
            .map(|(_, allowed)| *allowed))
    });
    methods.add_method("notices", |lua, _, NoArgs| {
        let notices = state_mut(lua).editor.take_notices();
        notices
            .into_iter()
            .map(|notice| {
                let table = lua.create_table()?;
                table.set("title", notice.title)?;
                table.set("body", notice.body)?;
                Ok(table)
            })
            .collect::<mlua::Result<Vec<_>>>()
    });
}

/// `frame` as `t:frame` gives it: the screen as `medium` ("window", the
/// default, or "terminal") draws it, a row of text each, the images and
/// scenes placed on it, and `cell(col, row)` for one cell's text, size and
/// look.
fn frame_table(
    lua: &Lua,
    frame: &crate::render::Frame,
    medium: Option<&str>,
) -> mlua::Result<Table> {
    use crate::render::grid::compose;
    use crate::theme::Medium;
    let medium = match medium {
        None | Some("window") => Medium::Gui,
        Some("terminal") => Medium::Tui,
        Some(other) => {
            return Err(mlua::Error::external(format!(
                "a frame is drawn for a window or a terminal, not {other}"
            )));
        }
    };
    let grid = compose(frame, medium);
    let out = lua.create_table()?;
    let rows: Vec<String> = grid
        .iter()
        .map(|row| row.iter().map(|c| c.text.as_str()).collect())
        .collect();
    out.set("rows", rows)?;
    let placed = |rect: crate::render::Rect, id: u64| -> mlua::Result<Table> {
        let t = lua.create_table()?;
        t.set("id", id)?;
        t.set("col", rect.x)?;
        t.set("row", rect.y)?;
        t.set("width", rect.width)?;
        t.set("height", rect.height)?;
        Ok(t)
    };
    let scenes = frame
        .scenes
        .iter()
        .map(|s| placed(s.rect, s.id.0))
        .collect::<mlua::Result<Vec<_>>>()?;
    out.set("scenes", scenes)?;
    let images = frame
        .images
        .iter()
        .map(|i| placed(i.rect, i.id.0))
        .collect::<mlua::Result<Vec<_>>>()?;
    out.set("images", images)?;
    let cell = lua.create_function(move |lua, (col, row): (usize, usize)| {
        let Some(cell) = grid.get(row).and_then(|r| r.get(col)) else {
            return Ok(None);
        };
        let t = lua.create_table()?;
        t.set("text", cell.text.as_str())?;
        t.set("scale", cell.scale)?;
        let color = |c: Option<crate::theme::Color>| c.map(|c| c.to_string());
        t.set("fg", color(cell.style.fg))?;
        t.set("bg", color(cell.style.bg))?;
        t.set("bold", cell.style.bold.unwrap_or(false))?;
        t.set("italic", cell.style.italic.unwrap_or(false))?;
        Ok(Some(t))
    })?;
    out.set("cell", cell)?;
    Ok(out)
}

/// A frame drawn at this size, for the acting client, with its renderer.
fn draw(lua: &Lua, width: u16, height: u16) -> mlua::Result<crate::render::Frame> {
    use crate::render::{Plain, Size, Status};
    let frame = || -> mlua::Result<_> {
        let status = match api::status_line(lua, None, width)? {
            Some(line) => Status::Line(line),
            None => Status::Default { message: None },
        };
        Ok(with_renderer(lua, |r| {
            r.frame(
                &mut state_mut(lua).editor,
                Size { width, height },
                &status,
                &Plain,
            )
        }))
    };
    restart_deadline(lua);
    {
        let editor = &mut state_mut(lua).editor;
        let client = editor.client();
        editor.set_client_size(client, Some((width, height)));
    }
    end_frame(lua)?;
    let mut drawn = frame()?;
    // As the server does: what plugins do about views changing shows at once.
    if super::report_views(lua)? {
        drawn = frame()?;
        super::report_views(lua)?;
    }
    Ok(drawn)
}

/// The `t` passed to each test, which acts as the first client.
struct TestContext;

impl TestClient for TestContext {
    fn id(&self) -> ClientId {
        crate::FIRST_CLIENT
    }
}

impl UserData for TestContext {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method("buffer", |lua, _, marked: String| {
            let (text, selection) = parse_marked(&marked).map_err(mlua::Error::external)?;
            let mut state = state_mut(lua);
            let buffer = state.editor.create_buffer("file", &text);
            let main = state.editor.main();
            state.editor.show(main, buffer);
            state.editor.view_mut(main).selection = selection;
            state.editor.set_focus(main);
            state.editor.set_mode("helix");
            state.editor.end_group();
            Ok(())
        });
        methods.add_method(
            "client",
            |lua, _, (name, kind): (Option<String>, Option<String>)| add_client(lua, name, kind),
        );
        add_client_view_methods(methods);
        methods.add_method(
            "tempdir",
            |lua, _, files: Option<HashMap<String, mlua::LuaString>>| {
                // Inside the test's own folder, so it goes when the test ends.
                let root = state(lua).dirs.clone().unwrap_or_else(std::env::temp_dir);
                tempdir(&root, files.unwrap_or_default()).map_err(mlua::Error::external)
            },
        );
        // A program standing in for the system keyring's (`secret-tool`,
        // `security`), or nil for none. One that isn't there acts as a
        // keyring that can't be reached.
        methods.add_method("keyring", |lua, _, program: Option<String>| {
            state_mut(lua).keyring = program;
            Ok(())
        });
        // Opens a file the test made, as greed.open does, without the
        // plugin needing fs.read just for its tests. Only inside the test's
        // own folder: a test's failures go back to whoever wrote it.
        methods.add_method("open", |lua, _, path: String| {
            let inside = state(lua).dirs.as_ref().is_some_and(|dirs| {
                std::fs::canonicalize(&path).is_ok_and(|path| {
                    std::fs::canonicalize(dirs).is_ok_and(|d| path.starts_with(d))
                })
            });
            if !inside {
                return Err(mlua::Error::runtime(format!(
                    "t:open opens files a test made with t:tempdir; {path} isn't one"
                )));
            }
            super::api::open_file(lua, &path)
        });
        add_repo_methods(methods);
        methods.add_method("wait", |lua, _, ms: f64| {
            restart_deadline(lua);
            let later = state(lua).tasks.now() + Duration::from_secs_f64(ms.max(0.0) / 1000.0);
            // What terminals said meanwhile, as the editor hears it.
            let events = state(lua).terminals.events.clone();
            for event in events.try_iter() {
                terminal::handle(lua, event)?;
            }
            jobs::settle(lua)?;
            end_frame(lua)?;
            tasks::advance(lua, later)?;
            jobs::settle(lua)?;
            // As much time as the session takes to look has gone by.
            watch::check(lua)?;
            end_frame(lua)
        });
        methods.add_method("wait_for", |lua, _, (done, ms): (Function, Option<f64>)| {
            wait_until(
                lua,
                &done,
                Duration::from_secs_f64(ms.unwrap_or(15000.0).max(0.0) / 1000.0),
            )
        });
        methods.add_method("floats", |lua, _, NoArgs| {
            let state = state(lua);
            let editor = &state.editor;
            Ok(editor
                .floats()
                .iter()
                .map(|f| editor.buffer(editor.view(f.view).buffer).text().to_string())
                .collect::<Vec<_>>())
        });
        add_client_methods(methods);
        methods.add_method("messages", |lua, _, NoArgs| {
            report_messages(lua)?;
            Ok(std::mem::take(
                &mut lua
                    .app_data_mut::<ObservedMessages>()
                    .expect("report_messages set it")
                    .0,
            ))
        });
    }
}

fn focused_marked_text(lua: &Lua) -> String {
    let state = state(lua);
    state.editor.marked_text(state.editor.focus())
}

/// Fails if `actual` isn't `expected`, naming the line in the test body.
fn check(lua: &Lua, what: &str, expected: &str, actual: &str) -> mlua::Result<()> {
    if expected == actual {
        return Ok(());
    }
    let line = test_body_line(lua).map_or_else(String::new, |line| format!("line {line}: "));
    Err(mlua::Error::runtime(format!(
        "{line}expected {what} {expected:?}, got {actual:?}"
    )))
}

/// The current line in the test body. Luau frames on the stack run from
/// helpers the test called, through the test body, out to the file's main
/// chunk; the test body is the one just inside the main chunk.
fn test_body_line(lua: &Lua) -> Option<usize> {
    let lines: Vec<Option<usize>> = (1..)
        .map_while(|level| {
            lua.inspect_stack(level, |debug| (debug.source().what, debug.current_line()))
        })
        .filter(|(what, _)| *what == "Lua")
        .map(|(_, line)| line)
        .collect();
    let body = lines
        .len()
        .checked_sub(2)
        .map_or(lines.first(), |i| lines.get(i));
    body.copied().flatten()
}

/// Making a test's repository, with the made-up user in its own config, so
/// what plugins commit there works on a machine with no user set, like CI's.
const JJ_INIT: &[&[&str]] = &[
    &["git", "init"],
    &["config", "set", "--repo", "user.name", "t"],
    &["config", "set", "--repo", "user.email", "t@t"],
];
const GIT_INIT: &[&[&str]] = &[
    &["init", "-q"],
    &["config", "user.name", "t"],
    &["config", "user.email", "t@t"],
];

/// `t:repo` and `t:vcs`: jj and git repositories to test against.
fn add_repo_methods<M: UserDataMethods<TestContext>>(methods: &mut M) {
    methods.add_method(
        "repo",
        |lua, _, (kind, files): (String, Option<HashMap<String, mlua::LuaString>>)| {
            let root = state(lua).dirs.clone().unwrap_or_else(std::env::temp_dir);
            let commit = files.is_some();
            let dir = tempdir(&root, files.unwrap_or_default()).map_err(mlua::Error::external)?;
            let vcs = Vcs::new(&kind, &dir)?;
            let first: &[&[&str]] = match (kind.as_str(), commit) {
                ("jj", true) => &[&["commit", "-m", "first"]],
                (_, true) => &[&["add", "."], &["commit", "-q", "-m", "first"]],
                (_, false) => &[],
            };
            let init = if kind == "jj" { JJ_INIT } else { GIT_INIT };
            let steps = init.iter().chain(first);
            for step in steps {
                vcs.run(lua, step)?;
            }
            Ok((dir, vcs.runner(lua)?))
        },
    );
    methods.add_method("vcs", |lua, _, (kind, dir): (String, String)| {
        Vcs::new(&kind, &dir)?.runner(lua)
    });
}

/// What programs a test starts get besides the editor's variables: a git
/// config of the test's own, a made-up user who signs nothing, so the
/// user's (a signing key, say) never changes what git does in a test.
/// Nothing outside tests.
pub(super) fn child_env(lua: &Lua) -> Vec<(String, Option<String>)> {
    let Some(dirs) = state(lua).dirs.clone() else {
        return Vec::new();
    };
    let config = dirs.join("gitconfig");
    if !config.exists() {
        let _ = std::fs::create_dir_all(&dirs);
        let _ = std::fs::write(
            &config,
            "[user]\n\tname = t\n\temail = t@t\n[commit]\n\tgpgsign = false\n[tag]\n\tgpgsign = false\n",
        );
    }
    vec![
        (
            "GIT_CONFIG_GLOBAL".into(),
            Some(config.to_string_lossy().into_owned()),
        ),
        ("GIT_CONFIG_NOSYSTEM".into(), Some("1".into())),
    ]
}

/// jj or git, run in a test's repository as a made-up user.
struct Vcs {
    program: &'static str,
    /// The made-up user, and plain output.
    options: &'static [&'static str],
    dir: String,
}

impl Vcs {
    fn new(kind: &str, dir: &str) -> mlua::Result<Self> {
        let (program, options): (_, &[_]) = match kind {
            "jj" => (
                "jj",
                &[
                    "--config",
                    "user.name=t",
                    "--config",
                    "user.email=t@t",
                    "--color",
                    "never",
                ],
            ),
            "git" => ("git", &["-c", "user.name=t", "-c", "user.email=t@t"]),
            other => {
                return Err(mlua::Error::runtime(format!(
                    "a repository is \"jj\" or \"git\", not {other:?}"
                )));
            }
        };
        Ok(Self {
            program,
            options,
            dir: dir.to_owned(),
        })
    }

    /// `run` as a Luau function taking the arguments.
    fn runner(self, lua: &Lua) -> mlua::Result<Function> {
        lua.create_function(move |lua, args: mlua::Variadic<String>| {
            let args: Vec<&str> = args.iter().map(String::as_str).collect();
            lua.create_string(self.run(lua, &args)?)
        })
    }

    /// What `args` printed, or an error with what it said if it failed. The
    /// time spent waiting for it doesn't count against the test's budget.
    fn run(&self, lua: &Lua, args: &[&str]) -> mlua::Result<Vec<u8>> {
        let started = Instant::now();
        let command: Vec<&str> = std::iter::once(self.program)
            .chain(self.options.iter().copied())
            .chain(args.iter().copied())
            .collect();
        let out =
            crate::child::command(&command, Some(Path::new(&self.dir)), &child_env(lua), false)
                .map_err(mlua::Error::external)?
                .stdin(std::process::Stdio::null())
                .output()
                .map_err(|err| {
                    mlua::Error::runtime(format!("can't run {}: {err}", self.program))
                })?;
        extend_deadline(lua, started.elapsed());
        if !out.status.success() {
            return Err(mlua::Error::runtime(format!(
                "{} {}: {}",
                self.program,
                args.join(" "),
                String::from_utf8_lossy(&out.stderr).trim()
            )));
        }
        Ok(out.stdout)
    }
}

/// A new directory under `root`, holding `files`.
fn tempdir(root: &Path, files: HashMap<String, mlua::LuaString>) -> std::io::Result<String> {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let n = NEXT.fetch_add(1, Ordering::Relaxed);
    let dir = root.join(format!("tmp-{n}"));
    if dir.exists() {
        std::fs::remove_dir_all(&dir)?;
    }
    std::fs::create_dir_all(&dir)?;
    for (path, text) in files {
        let path = dir.join(path);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(path, text.as_bytes())?;
    }
    Ok(dir.to_string_lossy().into_owned())
}
