//! `kern test`: runs a plugin's `test/*.luau` files against a headless
//! editor.
//!
//! A test file calls `test(name, function(t) ... end)` for each test. Every
//! test runs in a fresh host with the plugins loaded, so tests can't affect
//! each other. `t` sets up a buffer, presses keys and checks the result:
//!
//! ```luau
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
use std::path::{Path, PathBuf};
use std::rc::Rc;

use kern_text::ClientId;
use mlua::{Function, Lua, UserData, UserDataMethods};

use super::{Host, HostError, api, budgeted, state, state_mut};
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
/// `plugins` loaded, in order.
pub fn run_tests(plugins: &[PathBuf], dir: &Path) -> Result<Vec<TestResult>, HostError> {
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

    let mut results = Vec::new();
    for file in files {
        let source = std::fs::read_to_string(&file).map_err(|err| HostError::Manifest {
            path: file.clone(),
            message: err.to_string(),
        })?;
        for name in fresh_host(plugins)?.test_names(&file, &source)? {
            let failure = fresh_host(plugins)?.run_test(&file, &source, &name)?;
            results.push(TestResult {
                file: file.clone(),
                name,
                failure,
            });
        }
    }
    Ok(results)
}

fn fresh_host(plugins: &[PathBuf]) -> Result<Host, HostError> {
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", "", None);
    let host = Host::new(editor)?;
    for plugin in plugins {
        host.load_dir(plugin)?;
    }
    Ok(host)
}

impl Host {
    /// The names of the tests in a test file, in order.
    fn test_names(&self, file: &Path, source: &str) -> Result<Vec<String>, HostError> {
        let names = Rc::new(RefCell::new(Vec::new()));
        let collected = names.clone();
        let test = self
            .lua
            .create_function(move |_, (name, _): (String, Function)| {
                collected.borrow_mut().push(name);
                Ok(())
            })?;
        self.run_test_file(file, source, test)?;
        Ok(names.take())
    }

    /// Runs the test called `name`. Returns why it failed, or `None`.
    fn run_test(&self, file: &Path, source: &str, name: &str) -> Result<Option<String>, HostError> {
        let target = name.to_owned();
        let test = self
            .lua
            .create_function(move |_, (name, body): (String, Function)| {
                if name == target {
                    body.call::<()>(TestContext)?;
                }
                Ok(())
            })?;
        Ok(self
            .run_test_file(file, source, test)
            .err()
            .map(|err| failure_message(&err)))
    }

    fn run_test_file(&self, file: &Path, source: &str, test: Function) -> Result<(), HostError> {
        let env = api::fresh_plugin_env(&self.lua, "test", file.parent().map(Path::to_owned))?;
        env.set("test", test)?;
        budgeted(&self.lua, || {
            self.lua
                .load(source)
                .set_name(format!("@{}", file.display()))
                .set_environment(env)
                .exec()
                .map_err(HostError::from)
        })
    }
}

/// The error without mlua's "runtime error:" prefix and its stack traceback,
/// which only shows Rust frames.
fn failure_message(err: &HostError) -> String {
    let text = err.to_string();
    let text = text.split("\nstack traceback:").next().unwrap_or(&text);
    let text = text.strip_prefix("runtime error: ").unwrap_or(text);
    text.trim().to_owned()
}

/// The `t` passed to each test.
struct TestContext;

impl UserData for TestContext {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method("buffer", |lua, _, marked: String| {
            let (text, selection) = parse_marked(&marked).map_err(mlua::Error::external)?;
            let mut state = state_mut(lua);
            let (_, view) = state.editor.open("file", &text, None);
            state.editor.view_mut(view).selection = selection;
            state.editor.set_mode("normal");
            state.editor.end_group();
            Ok(())
        });
        methods.add_method("keys", |lua, _, keys: String| {
            for key in Key::parse_sequence(&keys).map_err(mlua::Error::external)? {
                api::press(lua, key).map_err(api::into_lua)?;
            }
            Ok(())
        });
        methods.add_method("run", |lua, _, command: String| {
            api::run_command(lua, &command, &[]).map_err(api::into_lua)
        });
        methods.add_method("marked", |lua, _, ()| Ok(focused_marked_text(lua)));
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
