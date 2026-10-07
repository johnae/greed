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

use std::cell::RefCell;
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Condvar, Mutex, PoisonError};
use std::time::{Duration, Instant};

use greed_text::ClientId;
use mlua::{Function, Lua, Table, UserData, UserDataMethods};

use super::capabilities::Grant;
use super::modules::Modules;
use super::{
    Host, HostError, api, budgeted, extend_deadline, jobs, restart_deadline, state, state_mut,
    tasks, terminal, watch,
};
use crate::keymap::Key;
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

fn cores() -> usize {
    std::thread::available_parallelism().map_or(1, std::num::NonZero::get)
}

/// One of the machine's cores, taken by a test while it runs, so that tests
/// started from many threads at once, as `cargo test` starts them, don't
/// crowd the machine until real-time waits in them give up.
struct Core;

static CORES_TAKEN: (Mutex<usize>, Condvar) = (Mutex::new(0), Condvar::new());

impl Core {
    fn take() -> Self {
        let (taken, freed) = &CORES_TAKEN;
        let mut taken = freed
            .wait_while(
                taken.lock().unwrap_or_else(PoisonError::into_inner),
                |taken| *taken >= cores(),
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
    let dirs = std::env::temp_dir().join(format!("greed-home-{}-{n}", std::process::id()));
    {
        let mut state = state_mut(&host.lua);
        state.dirs = Some(dirs);
        state.stalls.quiet = true;
    }
    let (Some(approved), Some((checked, others))) = (approved, plugins.split_last()) else {
        host.load_dirs(plugins)?;
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
    Ok(host)
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
        let modules = Modules::new(
            &self.lua,
            "test",
            Some(root.to_owned()),
            Some(test),
            &Grant::All,
        )?;
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
    let hit = renderer(lua).hit(&state(lua).editor, col, row);
    super::mouse_event(lua, event, &hit)?;
    jobs::settle(lua)?;
    end_frame(lua)
}

/// Tells plugins what the server tells them before drawing the next frame:
/// selections and focus that changed. Each `t:keys`, `t:run`, `t:mouse`,
/// `t:wait` and `t:draw` ends one.
fn end_frame(lua: &Lua) -> mlua::Result<()> {
    super::report_selections(lua)?;
    jobs::settle(lua)
}

/// The renderer `t:draw` and `t:mouse` share, so a click finds what the
/// last draw put where, as the server's does.
fn renderer(lua: &Lua) -> mlua::AppDataRef<'_, crate::render::Renderer<crate::render::CellWidth>> {
    use crate::render::{CellWidth, Renderer};
    if lua.app_data_ref::<Renderer<CellWidth>>().is_none() {
        lua.set_app_data(Renderer::new(CellWidth));
    }
    lua.app_data_ref().expect("it was just set")
}

/// `t:draw`, `t:screen` and `t:mouse`: what a client would see and send.
fn add_screen_methods<M: UserDataMethods<TestContext>>(methods: &mut M) {
    methods.add_method(
        "mouse",
        |lua,
         _,
         (kind, col, row, which, mods): (String, u16, u16, Option<String>, Option<Table>)| {
            mouse(lua, &kind, col, row, which.as_deref(), mods.as_ref())
        },
    );
    methods.add_method("draw", |lua, _, (width, height): (u16, u16)| {
        let frame = draw(lua, width, height)?;
        Ok(frame
            .rows
            .iter()
            .map(crate::render::Row::text)
            .collect::<Vec<_>>())
    });
    methods.add_method("screen", |lua, _, (width, height): (u16, u16)| {
        use crate::render::grid::compose;
        let frame = draw(lua, width, height)?;
        Ok(compose(&frame, crate::theme::Surface::Tui)
            .iter()
            .map(|row| row.iter().map(|c| c.text.as_str()).collect::<String>())
            .collect::<Vec<_>>())
    });
}

/// `t:quitting`, `t:detached`, `t:switched` and `t:notices`: what the
/// editor asked of the client.
fn add_client_methods<M: UserDataMethods<TestContext>>(methods: &mut M) {
    methods.add_method("quitting", |lua, _, ()| {
        Ok(state(lua).editor.quit_requested())
    });
    methods.add_method("detached", |lua, _, ()| {
        Ok(state_mut(lua).editor.take_detach_request())
    });
    methods.add_method("switched", |lua, _, ()| {
        let to = state_mut(lua).editor.take_switch_request();
        to.map(|to| {
            let table = lua.create_table()?;
            table.set("session", to.session)?;
            table.set("path", to.path)?;
            Ok::<_, mlua::Error>(table)
        })
        .transpose()
    });
    methods.add_method("notices", |lua, _, ()| {
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

/// A frame drawn at this size.
fn draw(lua: &Lua, width: u16, height: u16) -> mlua::Result<crate::render::Frame> {
    use crate::render::{Plain, Size, Status};
    let frame = || -> mlua::Result<_> {
        let status = match api::status_line(lua, None, width)? {
            Some(line) => Status::Line(line),
            None => Status::Default { message: None },
        };
        Ok(renderer(lua).frame(
            &mut state_mut(lua).editor,
            Size { width, height },
            &status,
            &Plain,
        ))
    };
    restart_deadline(lua);
    end_frame(lua)?;
    let mut drawn = frame()?;
    // As the server does: what plugins do about views changing shows at once.
    if super::report_views(lua)? {
        drawn = frame()?;
        super::report_views(lua)?;
    }
    Ok(drawn)
}

/// The `t` passed to each test.
struct TestContext;

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
            state.editor.set_mode("normal");
            state.editor.end_group();
            Ok(())
        });
        methods.add_method("keys", |lua, _, keys: String| {
            for key in Key::parse_sequence(&keys).map_err(mlua::Error::external)? {
                restart_deadline(lua);
                api::press(lua, key).map_err(api::into_lua)?;
                jobs::settle(lua)?;
            }
            end_frame(lua)
        });
        methods.add_method(
            "run",
            |lua, _, (command, args): (String, Option<Vec<String>>)| {
                restart_deadline(lua);
                api::run_command_with(lua, &command, args.unwrap_or_default())
                    .map_err(api::into_lua)?;
                jobs::settle(lua)?;
                end_frame(lua)
            },
        );
        methods.add_method(
            "tempdir",
            |lua, _, files: Option<HashMap<String, mlua::LuaString>>| {
                // Inside the test's own folder, so it goes when the test ends.
                let root = state(lua).dirs.clone().unwrap_or_else(std::env::temp_dir);
                tempdir(&root, files.unwrap_or_default()).map_err(mlua::Error::external)
            },
        );
        methods.add_method("wait", |lua, _, ms: f64| {
            restart_deadline(lua);
            let later = state(lua).tasks.now() + Duration::from_secs_f64(ms.max(0.0) / 1000.0);
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
                Duration::from_secs_f64(ms.unwrap_or(5000.0).max(0.0) / 1000.0),
            )
        });
        methods.add_method("marked", |lua, _, ()| Ok(focused_marked_text(lua)));
        methods.add_method("floats", |lua, _, ()| {
            let state = state(lua);
            let editor = &state.editor;
            Ok(editor
                .floats()
                .iter()
                .map(|f| editor.buffer(editor.view(f.view).buffer).text().to_string())
                .collect::<Vec<_>>())
        });
        methods.add_method("status", |lua, _, ()| {
            let join = |spans: &[crate::render::Span]| {
                spans.iter().map(|s| s.text.as_str()).collect::<String>()
            };
            let line = api::status_line(lua, None, 200)?;
            Ok(line.map_or((None, None), |l| {
                (Some(join(&l.left)), Some(join(&l.right)))
            }))
        });
        add_screen_methods(methods);
        add_client_methods(methods);
        methods.add_method("messages", |lua, _, ()| {
            Ok(state_mut(lua).editor.take_messages())
        });
        methods.add_method("expect", |lua, _, expected: String| {
            check(lua, "buffer", &expected, &focused_marked_text(lua))
        });
        methods.add_method("expect_mode", |lua, _, expected: String| {
            let actual = state(lua).editor.mode().to_owned();
            check(lua, "mode", &expected, &actual)
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
