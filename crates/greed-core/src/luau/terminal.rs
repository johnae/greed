//! `greed.terminal`: programs running in terminals, for the terminal plugin
//! to show in buffers. Output arrives as "terminal.output" events, and the
//! end of the program as "terminal.exited". A terminal belongs to the
//! plugin that started it and ends with it.

use std::collections::HashMap;

use crossbeam_channel::{Receiver, Sender};
use mlua::{Lua, MetaMethod, Table, UserData, UserDataMethods, Value};

use super::api::emit;
use super::handles::same_handle;
use super::{state, state_mut};
use crate::image::ImageId;
use crate::keymap::Key;
use crate::mouse::{Mouse, MouseKind};
use crate::registry::PluginId;
use crate::terminal::{Event, Mark, MarkKind, Modes, Options, Row, Terminal, TerminalId};

type LuaResult<T> = mlua::Result<T>;

/// Lines kept above the screen when the plugin doesn't say.
const SCROLLBACK: usize = 10_000;

pub struct Terminals {
    open: HashMap<u64, (Terminal, PluginId)>,
    next: u64,
    sender: Sender<Event>,
    pub events: Receiver<Event>,
}

impl Default for Terminals {
    fn default() -> Self {
        let (sender, events) = crossbeam_channel::unbounded();
        Self {
            open: HashMap::new(),
            next: 1,
            sender,
            events,
        }
    }
}

impl Terminals {
    /// Ends the terminals plugin `name` started.
    pub fn remove_owned_by(&mut self, name: &str) {
        self.open.retain(|_, (_, owner)| &**owner != name);
    }
}

pub(super) fn module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let terminal = lua.create_table()?;
    let owner = owner.clone();
    terminal.set(
        "spawn",
        lua.create_function(move |lua, spec: Table| {
            let options = Options {
                command: spec.get("command")?,
                cwd: spec.get::<Option<String>>("cwd")?.map(Into::into),
                env: super::process::env_from_lua(spec.get("env")?)?,
                rows: spec.get("rows")?,
                cols: spec.get("cols")?,
                scrollback: spec
                    .get::<Option<usize>>("scrollback")?
                    .unwrap_or(SCROLLBACK),
                cell: state(lua).editor.cell_size(),
            };
            let mut state = state_mut(lua);
            let terminals = &mut state.terminals;
            let id = terminals.next;
            let terminal = Terminal::spawn(TerminalId(id), &options, terminals.sender.clone())
                .map_err(|err| mlua::Error::runtime(format!("can't start the terminal: {err}")))?;
            terminals.next += 1;
            terminals.open.insert(id, (terminal, owner.clone()));
            Ok(TerminalRef(id, Some(owner.clone())))
        })?,
    )?;
    Ok(terminal)
}

/// Tells plugins about output or a program ending.
pub(super) fn handle(lua: &Lua, event: Event) -> LuaResult<()> {
    let payload = lua.create_table()?;
    let (name, id) = match event {
        Event::Output(TerminalId(id)) => ("terminal.output", id),
        Event::Exited(TerminalId(id), code) => {
            payload.set("code", code)?;
            ("terminal.exited", id)
        }
    };
    // Events can arrive after the plugin closed it.
    let copied = {
        let state = state(lua);
        let Some((terminal, _)) = state.terminals.open.get(&id) else {
            return Ok(());
        };
        terminal.take_copied()
    };
    // What a program copies goes on the clipboard, as any copy does.
    if let Some(text) = copied {
        state_mut(lua).editor.copy(vec![text]);
    }
    payload.set("terminal", TerminalRef(id, None))?;
    emit(lua, name, &payload)
}

/// A terminal, for Luau, with the plugin that started it when the handle
/// came from starting it rather than from an event.
#[derive(Clone)]
struct TerminalRef(u64, Option<PluginId>);

impl TerminalRef {
    fn with<T>(&self, lua: &Lua, f: impl FnOnce(&mut Terminal) -> T) -> LuaResult<T> {
        let mut state = state_mut(lua);
        let (terminal, _) = state
            .terminals
            .open
            .get_mut(&self.0)
            .ok_or_else(|| mlua::Error::runtime("this terminal was closed"))?;
        Ok(f(terminal))
    }

    /// `with`, for sending the program input. Typing into a shell runs
    /// programs, so it takes `proc`: the starting plugin's, through the
    /// handle it got, otherwise that of the plugin whose code runs.
    fn send<T>(&self, lua: &Lua, f: impl FnOnce(&mut Terminal) -> T) -> LuaResult<T> {
        match &self.1 {
            Some(owner) => super::capabilities::check_for(lua, owner, "proc")?,
            None => super::capabilities::check(lua, "proc")?,
        }
        self.with(lua, f)
    }
}

fn row_to_lua(lua: &Lua, row: Row) -> LuaResult<Table> {
    let t = lua.create_table()?;
    t.set("text", row.text)?;
    let spans = lua.create_table()?;
    for span in row.spans {
        let s = lua.create_table()?;
        s.set("from", span.from)?;
        s.set("to", span.to)?;
        s.set("style", &*span.style)?;
        spans.push(s)?;
    }
    t.set("spans", spans)?;
    let images = lua.create_table()?;
    for image in row.images {
        let i = lua.create_table()?;
        i.set("from", image.from)?;
        i.set("id", image.id.0)?;
        i.set("col", image.col)?;
        i.set("row", image.row)?;
        i.set("cols", image.cols)?;
        i.set("rows", image.rows)?;
        images.push(i)?;
    }
    t.set("images", images)?;
    let links = lua.create_table()?;
    for link in row.links {
        let l = lua.create_table()?;
        l.set("from", link.from)?;
        l.set("to", link.to)?;
        l.set("uri", &*link.uri)?;
        links.push(l)?;
    }
    t.set("links", links)?;
    t.set("wrapped", row.wrapped)?;
    Ok(t)
}

/// Gives the editor the images `rows` show that it doesn't have yet, so
/// marks can show them.
fn share_images(lua: &Lua, terminal: &TerminalRef, rows: &[Row]) -> LuaResult<()> {
    let missing: Vec<ImageId> = {
        let state = state(lua);
        rows.iter()
            .flat_map(|row| &row.images)
            .map(|image| image.id)
            .filter(|id| !state.editor.images().contains(*id))
            .collect()
    };
    if missing.is_empty() {
        return Ok(());
    }
    let found: Vec<_> = terminal.with(lua, |t| {
        missing.iter().filter_map(|id| t.image(*id)).collect()
    })?;
    let mut state = state_mut(lua);
    for image in found {
        state.editor.images_mut().insert(image);
    }
    Ok(())
}

fn rows_to_lua(lua: &Lua, rows: Vec<Row>) -> LuaResult<Table> {
    let t = lua.create_table_with_capacity(rows.len(), 0)?;
    for row in rows {
        t.push(row_to_lua(lua, row)?)?;
    }
    Ok(t)
}

fn marks_to_lua(lua: &Lua, marks: Vec<Mark>) -> LuaResult<Table> {
    let list = lua.create_table_with_capacity(marks.len(), 0)?;
    for mark in marks {
        let t = lua.create_table()?;
        t.set("line", mark.line)?;
        t.set("col", mark.col)?;
        let kind = match mark.kind {
            MarkKind::Prompt => "prompt",
            MarkKind::Command => "command",
            MarkKind::Output => "output",
            MarkKind::Done(code) => {
                t.set("code", code)?;
                "done"
            }
        };
        t.set("kind", kind)?;
        list.push(t)?;
    }
    Ok(list)
}

fn modes_to_lua(lua: &Lua, modes: Modes) -> LuaResult<Table> {
    let t = lua.create_table()?;
    t.set("alternate", modes.alternate)?;
    t.set("canonical", modes.canonical)?;
    t.set("echo", modes.echo)?;
    t.set("mouse", modes.mouse)?;
    t.set("app_cursor", modes.app_cursor)?;
    t.set("bracketed_paste", modes.bracketed_paste)?;
    Ok(t)
}

impl UserData for TerminalRef {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method("id", |_, this, ()| Ok(this.0));
        methods.add_meta_method(MetaMethod::Eq, |_, this, other: Value| {
            Ok(same_handle(&other, |o: &TerminalRef| o.0 == this.0))
        });
        methods.add_method("valid", |lua, this, ()| {
            Ok(state(lua).terminals.open.contains_key(&this.0))
        });
        methods.add_method("screen", |lua, this, ()| {
            let screen = this.with(lua, |t| t.screen())?;
            share_images(lua, this, &screen.rows)?;
            let t = lua.create_table()?;
            t.set("rows", rows_to_lua(lua, screen.rows)?)?;
            if let Some((row, col)) = screen.cursor {
                let cursor = lua.create_table()?;
                cursor.set("row", row)?;
                cursor.set("col", col)?;
                t.set("cursor", cursor)?;
            }
            t.set("alternate", screen.alternate)?;
            Ok(t)
        });
        methods.add_method("scrollback", |lua, this, from: Option<u64>| {
            let scrollback = this.with(lua, |t| t.scrollback(from.unwrap_or(0)))?;
            share_images(lua, this, &scrollback.rows)?;
            let t = lua.create_table()?;
            t.set("first", scrollback.first)?;
            t.set("rows", rows_to_lua(lua, scrollback.rows)?)?;
            Ok(t)
        });
        methods.add_method("cwd", |lua, this, ()| {
            this.with(lua, |t| t.cwd().map(|p| p.to_string_lossy().into_owned()))
        });
        methods.add_method("marks_made", |lua, this, ()| {
            this.with(lua, |t| t.marks_made())
        });
        methods.add_method("marks", |lua, this, from: Option<u64>| {
            let marks = this.with(lua, |t| t.marks(from.unwrap_or(0)))?;
            marks_to_lua(lua, marks)
        });
        methods.add_method("write", |lua, this, text: mlua::LuaString| {
            let bytes = text.as_bytes().to_vec();
            this.send(lua, |t| t.write(bytes))
        });
        methods.add_method("key", |lua, this, name: String| {
            let key = Key::parse(&name).map_err(mlua::Error::external)?;
            this.send(lua, |t| t.key(key))
        });
        methods.add_method("paste", |lua, this, text: String| {
            this.send(lua, |t| t.paste(&text))
        });
        methods.add_method("resize", |lua, this, (rows, cols): (u16, u16)| {
            let cell = state(lua).editor.cell_size();
            this.with(lua, |t| t.resize(rows, cols, cell))?
                .map_err(mlua::Error::external)
        });
        methods.add_method("modes", |lua, this, ()| {
            modes_to_lua(lua, this.with(lua, |t| t.modes())?)
        });
        methods.add_method("wants_mouse", |lua, this, ()| {
            this.with(lua, |t| t.wants_mouse())
        });
        methods.add_method(
            "mouse",
            |lua, this, (kind, col, row, which, mods): (String, u16, u16, Option<String>, Option<Table>)| {
                let kind = MouseKind::parse(&kind, which.as_deref()).ok_or_else(|| {
                    mlua::Error::runtime(format!("{kind:?} {which:?} isn't a mouse event"))
                })?;
                let held = |key: &str| -> LuaResult<bool> {
                    match &mods {
                        Some(m) => Ok(m.get::<Option<bool>>(key)?.unwrap_or(false)),
                        None => Ok(false),
                    }
                };
                let mouse = Mouse {
                    kind,
                    col,
                    row,
                    ctrl: held("ctrl")?,
                    alt: held("alt")?,
                    shift: held("shift")?,
                };
                this.send(lua, |t| t.mouse(mouse))
            },
        );
        methods.add_method("title", |lua, this, ()| this.with(lua, |t| t.title()));
        methods.add_method("exit_code", |lua, this, ()| {
            this.with(lua, |t| t.exit_code())
        });
        methods.add_method("busy", |lua, this, ()| this.with(lua, |t| t.busy()));
        methods.add_method("kill", |lua, this, ()| this.with(lua, Terminal::kill));
        methods.add_method("close", |lua, this, ()| {
            state_mut(lua).terminals.open.remove(&this.0);
            Ok(())
        });
    }
}
