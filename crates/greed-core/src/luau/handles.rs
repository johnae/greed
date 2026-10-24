//! The handles Luau code holds: views, buffers, and the edit collector used
//! inside `buffer:edit`. Handles refer to things by id, so a handle to a
//! closed view or buffer fails cleanly instead of keeping it alive; only
//! `id`, `valid` and `==` still work on it.
//!
//! Positions are 0-based byte offsets and lines are 0-based, matching LSP.
//! A range is `{ anchor = n, head = n }`; a selection is
//! `{ ranges = { range, ... }, primary = i }` with a 1-based `primary`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use greed_text::{Author, ChangeSet, Range, Rope, Selection, line_content, line_end};
use mlua::{
    Function, IntoLuaMulti, Lua, LuaSerdeExt, MetaMethod, Table, UserData, UserDataMethods,
    UserDataRef, Value,
};
use unicode_segmentation::UnicodeSegmentation;

use super::api::{emit, float_options, single_keys};
use super::arity::NoArgs;
use super::{state, state_mut};
use crate::image::ImageId;
use crate::layout::Direction;
use crate::search::{self, Direction as SearchDirection};
use crate::{
    Buffer, BufferId, Mark, MarkImage, MarkScene, Reveal, ScreenSize, Scroll, View, ViewId,
    VirtualLine,
};

type LuaResult<T> = mlua::Result<T>;

const METHODS: &str = r"
local t = ...
for name, f in t do
    if type(f) == 'function' then
        t[name] = function(first, ...)
            if rawequal(first, t) then
                return f(...)
            end
            return f(first, ...)
        end
    end
end
return t
";

/// Makes the functions in a table-shaped handle, like a child process or
/// an HTTP stream, work as methods (`child:write(text)`) as well as plain
/// fields (`child.write(text)`).
pub(super) fn methods(lua: &Lua, handle: Table) -> LuaResult<Table> {
    const KEY: &str = "greed.methods";
    let cached = lua.named_registry_value::<Option<Function>>(KEY)?;
    let wrap = if let Some(wrap) = cached {
        wrap
    } else {
        let wrap: Function = lua.load(METHODS).set_name("=greed").into_function()?;
        lua.set_named_registry_value(KEY, &wrap)?;
        wrap
    };
    wrap.call(handle)
}

/// A view, as seen by a command or plugin. Edits made through it are
/// attributed to `author`.
pub(super) struct ViewRef {
    pub id: ViewId,
    pub author: Author,
}

impl ViewRef {
    fn with_view<R>(&self, lua: &Lua, f: impl FnOnce(&View) -> LuaResult<R>) -> LuaResult<R> {
        let state = state(lua);
        let view = state
            .editor
            .find_view(self.id)
            .ok_or_else(|| mlua::Error::runtime("this view was closed"))?;
        f(view)
    }

    fn with_view_mut<R>(
        &self,
        lua: &Lua,
        f: impl FnOnce(&mut View) -> LuaResult<R>,
    ) -> LuaResult<R> {
        let mut state = state_mut(lua);
        let view = state
            .editor
            .find_view_mut(self.id)
            .ok_or_else(|| mlua::Error::runtime("this view was closed"))?;
        f(view)
    }

    fn buffer(&self, lua: &Lua) -> LuaResult<BufferId> {
        self.with_view(lua, |v| Ok(v.buffer))
    }

    /// A handle to view `id` with the same author.
    fn other(&self, id: ViewId) -> ViewRef {
        ViewRef {
            id,
            author: self.author.clone(),
        }
    }

    /// Undoes or redoes in this view, then tells plugins the buffer changed.
    fn history_step(&self, lua: &Lua, undo: bool) -> LuaResult<bool> {
        let buffer = self.buffer(lua)?;
        let mut state = state_mut(lua);
        let changed = if undo {
            state.editor.undo(self.id)
        } else {
            state.editor.redo(self.id)
        }
        .map_err(mlua::Error::external)?;
        drop(state);
        if changed {
            buffer_changed(lua, buffer, &self.author)?;
        }
        Ok(changed)
    }
}

impl UserData for ViewRef {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method("id", |_, this, NoArgs| Ok(this.id.0));
        methods.add_meta_method(MetaMethod::Eq, |_, this, other: Value| {
            Ok(same_handle(&other, |o: &ViewRef| o.id == this.id))
        });
        methods.add_method("valid", |lua, this, NoArgs| {
            Ok(state(lua).editor.find_view(this.id).is_some())
        });
        methods.add_method(
            "decorate",
            |lua, this, (ns, list, within): (String, Vec<Table>, Option<Table>)| {
                let marks = marks_from_lua(lua, &list)?;
                let buffer = this.with_view(lua, |v| Ok(v.buffer))?;
                decorate(lua, buffer, Some(this.id), &ns, within, marks)
            },
        );
        add_selection_methods(methods);
        methods.add_method("size", |lua, this, NoArgs| {
            this.with_view(lua, |v| Ok(v.size.unzip()))
        });
        methods.add_method("visible", |lua, this, NoArgs| {
            let state = state(lua);
            let view = state
                .editor
                .find_view(this.id)
                .ok_or_else(|| mlua::Error::runtime("this view was closed"))?;
            let len = state.editor.buffer(view.buffer).text().len_bytes();
            let visible = view.visible.clone().unwrap_or(0..len);
            Ok((visible.start.min(len), visible.end.min(len)))
        });
        add_drawn_methods(methods);
        methods.add_method("hidden_lines", |lua, this, NoArgs| {
            let state = state(lua);
            let view = state
                .editor
                .find_view(this.id)
                .ok_or_else(|| mlua::Error::runtime("this view was closed"))?;
            let list = lua.create_table()?;
            for lines in crate::render::hidden_lines(&state.editor, view) {
                let range = lua.create_table()?;
                range.set("from", lines.start)?;
                range.set("to", lines.end - 1)?;
                list.push(range)?;
            }
            Ok(list)
        });
        add_part_methods(methods);
        methods.add_method("scroll", |lua, this, NoArgs| {
            this.with_view(lua, |v| Ok(v.scroll.line))
        });
        methods.add_method("set_scroll", |lua, this, line: usize| {
            let buffer = this.buffer(lua)?;
            let last = state(lua)
                .editor
                .buffer(buffer)
                .text()
                .len_lines()
                .saturating_sub(1);
            this.with_view_mut(lua, |v| {
                v.scroll = Scroll {
                    line: line.min(last),
                    row: 0,
                };
                Ok(())
            })
        });
        methods.add_method("buffer", |lua, this, NoArgs| {
            Ok(BufferRef {
                buffer: this.buffer(lua)?,
                view: Some(this.id),
                author: this.author.clone(),
            })
        });
        methods.add_method("show", |lua, this, buffer: UserDataRef<BufferRef>| {
            let shown = this.buffer(lua)?;
            buffer.with_buffer(lua, |_| Ok(()))?;
            if shown != buffer.buffer {
                super::capabilities::unless_sandboxed(lua, "show another buffer in a view")?;
            }
            state_mut(lua).editor.show(this.id, buffer.buffer);
            Ok(())
        });
        methods.add_method("focus", |lua, this, NoArgs| {
            this.with_view(lua, |_| Ok(()))?;
            super::capabilities::unless_sandboxed(lua, "focus a view")?;
            state_mut(lua).editor.set_focus(this.id);
            Ok(())
        });
        methods.add_method("close", |lua, this, NoArgs| {
            super::capabilities::unless_sandboxed(lua, "close a view")?;
            let closed = state_mut(lua).editor.close(this.id);
            if closed {
                view_closed(lua, this.id)?;
            }
            Ok(closed)
        });
        add_float_methods(methods);
        add_pane_methods(methods);
        add_history_methods(methods);
    }
}

/// Columns as the view draws its lines, hidden text taking no room.
fn add_drawn_methods<M: UserDataMethods<ViewRef>>(methods: &mut M) {
    use crate::render::{CellWidth, Renderer};
    fn with_drawn<R>(
        lua: &Lua,
        this: &ViewRef,
        f: impl FnOnce(&Renderer<CellWidth>, &crate::Editor, &View) -> LuaResult<R>,
    ) -> LuaResult<R> {
        let state = state(lua);
        let view = state
            .editor
            .find_view(this.id)
            .ok_or_else(|| mlua::Error::runtime("this view was closed"))?;
        f(&Renderer::new(CellWidth), &state.editor, view)
    }
    methods.add_method("drawn_column", |lua, this, pos: usize| {
        with_drawn(lua, this, |renderer, editor, view| {
            char_index(editor.buffer(view.buffer).text(), pos)?;
            Ok(renderer.drawn_column(editor, view, pos))
        })
    });
    methods.add_method(
        "at_drawn_column",
        |lua, this, (line, col): (usize, usize)| {
            with_drawn(lua, this, |renderer, editor, view| {
                check_line(editor.buffer(view.buffer).text(), line)?;
                Ok(renderer.at_drawn_column(editor, view, line, col))
            })
        },
    );
}

/// `view:selection()`, `set_selection(selection)`, `cursor()` and
/// `set_cursor(pos)`.
fn add_selection_methods<M: UserDataMethods<ViewRef>>(methods: &mut M) {
    methods.add_method("selection", |lua, this, NoArgs| {
        this.with_view(lua, |v| selection_to_lua(lua, &v.selection))
    });
    methods.add_method("set_selection", |lua, this, t: Table| {
        let selection = selection_from_lua(&t)?;
        let buffer = this.buffer(lua)?;
        check_selection(state(lua).editor.buffer(buffer).text(), &selection)?;
        this.with_view_mut(lua, |v| {
            v.selection = selection;
            Ok(())
        })
    });
    methods.add_method("cursor", |lua, this, NoArgs| {
        this.with_view(lua, |v| Ok(v.selection.primary().head))
    });
    methods.add_method("set_cursor", |lua, this, pos: usize| {
        let buffer = this.buffer(lua)?;
        char_index(state(lua).editor.buffer(buffer).text(), pos)?;
        this.with_view_mut(lua, |v| {
            v.selection = Selection::point(pos);
            Ok(())
        })
    });
}

/// `view:undo()`, `undo_to(node)` and `redo()`.
fn add_history_methods<M: UserDataMethods<ViewRef>>(methods: &mut M) {
    methods.add_method("undo", |lua, this, NoArgs| this.history_step(lua, true));
    methods.add_method("undo_to", |lua, this, node: usize| {
        let buffer = this.buffer(lua)?;
        let changed = state_mut(lua)
            .editor
            .undo_to(this.id, node)
            .map_err(mlua::Error::external)?;
        if changed {
            buffer_changed(lua, buffer, &this.author)?;
        }
        Ok(changed)
    });
    methods.add_method("redo", |lua, this, NoArgs| this.history_step(lua, false));
}

/// A buffer. When it came from a view, edits map that view's selection;
/// otherwise every view of the buffer is mapped.
pub(super) struct BufferRef {
    pub buffer: BufferId,
    pub view: Option<ViewId>,
    pub author: Author,
}

impl BufferRef {
    pub(super) fn with_buffer<R>(
        &self,
        lua: &Lua,
        f: impl FnOnce(&Buffer) -> LuaResult<R>,
    ) -> LuaResult<R> {
        let state = state(lua);
        let buffer = state
            .editor
            .find_buffer(self.buffer)
            .ok_or_else(|| mlua::Error::runtime("this buffer was closed"))?;
        f(buffer)
    }

    /// Closes the buffer, then tells plugins with "buffer.closed".
    fn close(&self, lua: &Lua) -> LuaResult<()> {
        self.with_buffer(lua, |_| Ok(()))?;
        super::capabilities::unless_sandboxed(lua, "close a buffer")?;
        state_mut(lua)
            .editor
            .close_buffer(self.buffer)
            .map_err(mlua::Error::external)?;
        let payload = lua.create_table()?;
        payload.set("id", self.buffer.0)?;
        emit(lua, "buffer.closed", &payload)
    }

    /// Writes the buffer to its file, or to `path`, then tells plugins with
    /// "buffer.saved".
    fn save(&self, lua: &Lua, path: Option<String>) -> LuaResult<()> {
        self.with_buffer(lua, |_| Ok(()))?;
        super::capabilities::unless_sandboxed(lua, "write a file")?;
        let path = path.map(|path| super::fs::expand_home(lua, path));
        super::capabilities::check(lua, "fs.write")?;
        // Greed's approvals and secrets are written only by Greed, or by
        // you at its own file; a buffer a plugin loaded could be either.
        let target = path.clone().map(PathBuf::from).or_else(|| {
            self.with_buffer(lua, |b| Ok(b.path().map(Path::to_owned)))
                .ok()?
        });
        if let Some(target) = target
            && (path.is_some() || !super::capabilities::by_you(lua))
        {
            super::approvals::guard(lua, &target)?;
            super::secrets::guard(lua, &target)?;
        }
        {
            let mut state = state_mut(lua);
            match path {
                Some(path) => state.editor.save_as(self.buffer, Path::new(&path)),
                None => state.editor.save(self.buffer),
            }
            .map_err(mlua::Error::external)?;
        }
        let payload = lua.create_table()?;
        payload.set(
            "buffer",
            BufferRef {
                buffer: self.buffer,
                view: None,
                author: self.author.clone(),
            },
        )?;
        emit(lua, "buffer.saved", &payload)
    }

    fn with_text<R>(&self, lua: &Lua, f: impl FnOnce(&Rope) -> LuaResult<R>) -> LuaResult<R> {
        self.with_buffer(lua, |buffer| f(buffer.text()))
    }

    /// Calls `f` with an edit collector, then applies everything it collected
    /// as one transaction, kept to undo when `undo`, and tells plugins the
    /// buffer changed.
    fn edit(&self, lua: &Lua, f: &Function, undo: bool) -> LuaResult<()> {
        // Read-only buffers are pages plugins draw, some of them asking
        // you something: sandboxed code doesn't get to change what they say.
        if self.with_buffer(lua, |b| Ok(b.is_readonly()))? {
            super::capabilities::unless_sandboxed(lua, "change a read-only buffer")?;
        }
        let edits = lua.create_userdata(Edits::default())?;
        f.call::<()>(&edits)?;
        let Edits {
            mut changes,
            selection,
        } = edits.take()?;
        changes.sort_by_key(|(from, to, _)| (*from, *to));
        let len = self.with_text(lua, |t| Ok(t.len_bytes()))?;
        let changes = ChangeSet::from_changes(len, changes).map_err(mlua::Error::external)?;
        if self.with_buffer(lua, |b| Ok(b.touches_readonly_start(&changes)))? {
            super::capabilities::unless_sandboxed(lua, "change a read-only buffer")?;
        }
        let mut state = state_mut(lua);
        let view = self.view.filter(|v| {
            state
                .editor
                .find_view(*v)
                .is_some_and(|v| v.buffer == self.buffer)
        });
        let author = self.author.clone();
        match (view, undo) {
            (Some(view), true) => state.editor.apply(view, changes, author, None, selection),
            (Some(view), false) => state
                .editor
                .apply_unrecorded(view, changes, author, selection),
            (None, true) => {
                state
                    .editor
                    .apply_to_buffer(self.buffer, changes, author, None, selection)
            }
            (None, false) => {
                state
                    .editor
                    .apply_to_buffer_unrecorded(self.buffer, changes, author, selection)
            }
        }
        .map_err(mlua::Error::external)?;
        drop(state);
        buffer_changed(lua, self.buffer, &self.author)
    }
}

/// The methods for showing part of a buffer: some of its lines
/// (narrowing), and lines that don't wrap scrolled sideways.
fn add_part_methods<M: UserDataMethods<ViewRef>>(methods: &mut M) {
    methods.add_method(
        "narrow",
        |lua, this, (from, to): (Option<usize>, Option<usize>)| {
            this.with_view(lua, |_| Ok(()))?;
            let lines = match (from, to) {
                (Some(from), Some(to)) if to >= from => Some(from..to + 1),
                (None, None) => None,
                _ => return Err(mlua::Error::runtime("narrow takes a first and last line")),
            };
            state_mut(lua).editor.narrow(this.id, lines.as_ref());
            Ok(())
        },
    );
    methods.add_method(
        "set_filter",
        |lua, this, (text, opts): (Option<String>, Option<mlua::Table>)| {
            this.with_view(lua, |_| Ok(()))?;
            let filter = match text.filter(|t| !t.trim().is_empty()) {
                None => None,
                Some(text) => {
                    let skip = match &opts {
                        Some(o) => o.get::<Option<usize>>("skip")?.unwrap_or(0),
                        None => 0,
                    };
                    let keep = keep_of(lua, &text, opts.as_ref())?;
                    Some(
                        crate::line_filter::LineFilter::new(&text, keep, skip)
                            .map_err(mlua::Error::runtime)?,
                    )
                }
            };
            state_mut(lua).editor.filter(this.id, filter);
            Ok(())
        },
    );
    methods.add_method("filter", |lua, this, NoArgs| {
        this.with_view(lua, |v| Ok(v.filter.as_ref().map(|f| f.text.clone())))
    });
    methods.add_method("narrowed", |lua, this, NoArgs| {
        this.with_view(lua, |v| {
            Ok(v.lines.as_ref().map(|l| (l.start, l.end - 1)).unzip())
        })
    });
    methods.add_method("side_scroll", |lua, this, NoArgs| {
        this.with_view(lua, |v| Ok(v.columns))
    });
    methods.add_method("set_side_scroll", |lua, this, columns: usize| {
        this.with_view_mut(lua, |v| {
            v.columns = columns;
            Ok(())
        })
    });
}

/// The methods for floating views: changing how one is shown, bringing it
/// to the front, and reading how it's shown.
fn add_float_methods<M: UserDataMethods<ViewRef>>(methods: &mut M) {
    methods.add_method("configure", |lua, this, spec: Table| {
        // A closed view fails, as with every other method.
        this.with_view(lua, |_| Ok(()))?;
        let Some(current) = state(lua).editor.float_options(this.id).cloned() else {
            return Ok(false);
        };
        let options = float_options(current, Some(spec))?;
        state_mut(lua).editor.configure_float(this.id, options);
        Ok(true)
    });
    methods.add_method("raise", |lua, this, NoArgs| {
        Ok(state_mut(lua).editor.raise_float(this.id))
    });
    methods.add_method("float_spec", |lua, this, NoArgs| {
        let options = state(lua).editor.float_options(this.id).cloned();
        options
            .map(|options| super::api::float_spec(lua, &options))
            .transpose()
    });
}

/// Splitting panes, moving between them and resizing them.
fn add_pane_methods<M: UserDataMethods<ViewRef>>(methods: &mut M) {
    methods.add_method("is_pane", |lua, this, NoArgs| {
        Ok(state(lua).editor.is_pane(this.id))
    });
    methods.add_method("area", |lua, this, NoArgs| {
        let Some(area) = this.with_view(lua, |v| Ok(v.area))? else {
            return Ok(None);
        };
        let t = lua.create_table()?;
        t.set("x", area.x)?;
        t.set("y", area.y)?;
        t.set("width", area.width)?;
        t.set("height", area.height)?;
        Ok(Some(t))
    });
    methods.add_method(
        "split",
        |lua, this, (dir, buffer): (String, Option<UserDataRef<BufferRef>>)| {
            let dir = direction(&dir)?;
            let buffer = buffer
                .map(|b| b.with_buffer(lua, |_| Ok(b.buffer)))
                .transpose()?;
            let new = state_mut(lua)
                .editor
                .split_pane(this.id, dir, buffer)
                .ok_or_else(|| mlua::Error::runtime("only panes can be split"))?;
            // For layout managers, which arrange panes wherever they come from.
            let payload = lua.create_table()?;
            payload.set("view", this.other(new))?;
            payload.set("from", this.other(this.id))?;
            emit(lua, "pane.opened", &payload)?;
            Ok(this.other(new))
        },
    );
    methods.add_method("neighbor", |lua, this, dir: String| {
        let dir = direction(&dir)?;
        let neighbor = state(lua).editor.neighbor(this.id, dir);
        Ok(neighbor.map(|id| this.other(id)))
    });
    methods.add_method("resize", |lua, this, (dir, cells): (String, i32)| {
        let dir = direction(&dir)?;
        Ok(state_mut(lua).editor.resize_pane(this.id, dir, cells))
    });
}

/// "left", "right", "up" or "down".
fn direction(name: &str) -> LuaResult<Direction> {
    Direction::parse(name).ok_or_else(|| {
        mlua::Error::runtime(format!(
            "{name:?} isn't a direction: use \"left\", \"right\", \"up\" or \"down\""
        ))
    })
}

/// `{ rows, cols, note, cursor_row }`, as `buffer:set_screen_size` takes
/// it.
fn screen_size_from(t: &Table) -> LuaResult<ScreenSize> {
    let rows = screen_cells(t, "rows")?;
    let cursor_row = t
        .get::<Option<u32>>("cursor_row")?
        .map(|row| u16::try_from(row).unwrap_or(u16::MAX).min(rows - 1));
    Ok(ScreenSize {
        rows,
        cols: screen_cells(t, "cols")?,
        note: t.get::<Option<String>>("note")?.map(Into::into),
        cursor_row,
    })
}

/// A screen's `key`, its rows or columns: at least 1.
fn screen_cells(t: &Table, key: &str) -> LuaResult<u16> {
    let n: u32 = t.get(key)?;
    u16::try_from(n.max(1))
        .map_err(|_| mlua::Error::runtime(format!("a screen's {key} are at most {}", u16::MAX)))
}

/// Emits "view.closed" with the id of `view`, so plugins holding it can let
/// go.
pub(super) fn view_closed(lua: &Lua, view: ViewId) -> LuaResult<()> {
    let payload = lua.create_table()?;
    payload.set("view", view.0)?;
    emit(lua, "view.closed", &payload)
}

/// Emits "buffer.changed" for `buffer`, with the lines that changed since
/// plugins were last told. An edit that changed nothing isn't told.
pub(super) fn buffer_changed(lua: &Lua, buffer: BufferId, author: &Author) -> LuaResult<()> {
    let Some((from, to)) = state_mut(lua).editor.take_changed_lines(buffer) else {
        return Ok(());
    };
    let payload = lua.create_table()?;
    payload.set("from_line", from)?;
    payload.set("to_line", to)?;
    payload.set(
        "buffer",
        BufferRef {
            buffer,
            view: None,
            author: author.clone(),
        },
    )?;
    emit(lua, "buffer.changed", &payload)
}

/// `buffer:find(pattern, from, { backward, wrap })` and
/// `buffer:find_all(pattern, from, to)`. A bad pattern gives nil and the
/// error, since a search prompt sees half-typed patterns all the time.
fn add_search_methods<M: UserDataMethods<BufferRef>>(methods: &mut M) {
    methods.add_method(
        "find",
        |lua, this, (pattern, from, opts): (String, Option<usize>, Option<Table>)| {
            let flag = |key: &str| -> LuaResult<bool> {
                Ok(match &opts {
                    Some(opts) => opts.get::<Option<bool>>(key)?.unwrap_or(false),
                    None => false,
                })
            };
            let direction = if flag("backward")? {
                SearchDirection::Backward
            } else {
                SearchDirection::Forward
            };
            let wrap = flag("wrap")?;
            let found = this.with_text(lua, |text| {
                Ok(search::find(
                    text,
                    &pattern,
                    from.unwrap_or(0),
                    direction,
                    wrap,
                ))
            })?;
            match found {
                Ok(Some(m)) => (m.start, m.end).into_lua_multi(lua),
                Ok(None) => Value::Nil.into_lua_multi(lua),
                Err(err) => (Value::Nil, Value::Nil, err.to_string()).into_lua_multi(lua),
            }
        },
    );
    methods.add_method(
        "find_all",
        |lua, this, (pattern, from, to): (String, Option<usize>, Option<usize>)| {
            let found = this.with_text(lua, |text| {
                let to = to.unwrap_or(text.len_bytes());
                Ok(search::find_all(text, &pattern, from.unwrap_or(0)..to))
            })?;
            match found {
                Ok(matches) => {
                    let list = lua.create_table()?;
                    for m in matches {
                        list.push(span_table(lua, &m)?)?;
                    }
                    list.into_lua_multi(lua)
                }
                Err(err) => (Value::Nil, err.to_string()).into_lua_multi(lua),
            }
        },
    );
    methods.add_method(
        "find_groups",
        |lua, this, (pattern, from, to): (String, Option<usize>, Option<usize>)| {
            let found = this.with_text(lua, |text| {
                let to = to.unwrap_or(text.len_bytes());
                Ok(search::find_all_groups(
                    text,
                    &pattern,
                    from.unwrap_or(0)..to,
                ))
            })?;
            match found {
                Ok(matches) => {
                    let list = lua.create_table()?;
                    for groups in matches {
                        let spans = lua.create_table()?;
                        for group in &groups {
                            match group {
                                Some(span) => spans.push(span_table(lua, span)?)?,
                                None => spans.push(false)?,
                            }
                        }
                        list.push(spans)?;
                    }
                    list.into_lua_multi(lua)
                }
                Err(err) => (Value::Nil, err.to_string()).into_lua_multi(lua),
            }
        },
    );
}

/// `buffer:kept_lines(filter, opts)`: what a view's filter keeps.
fn add_filter_methods<M: UserDataMethods<BufferRef>>(methods: &mut M) {
    methods.add_method(
        "kept_lines",
        |lua, this, (filter, opts): (String, Option<mlua::Table>)| {
            let (from, to) = match &opts {
                Some(o) => (
                    o.get::<Option<usize>>("from")?,
                    o.get::<Option<usize>>("to")?,
                ),
                None => (None, None),
            };
            let keep = keep_of(lua, &filter, opts.as_ref())?;
            let filter = crate::line_filter::LineFilter::new(&filter, keep, 0)
                .map_err(mlua::Error::runtime)?;
            this.with_text(lua, |text| {
                let all = text.len_lines();
                let lines = from.unwrap_or(0).min(all)..to.map_or(all, |to| (to + 1).min(all));
                let hidden = filter.hidden(text, lines.clone(), &[]);
                let mut runs = hidden.iter().peekable();
                Ok(lines
                    .filter(|line| {
                        while runs.next_if(|run| run.end <= *line).is_some() {}
                        !runs.peek().is_some_and(|run| run.contains(line))
                    })
                    .collect::<Vec<_>>())
            })
        },
    );
}

/// `{ from, to }` for a byte range.
fn span_table(lua: &Lua, span: &std::ops::Range<usize>) -> LuaResult<Table> {
    let t = lua.create_table()?;
    t.set("from", span.start)?;
    t.set("to", span.end)?;
    Ok(t)
}

/// `buffer:decorate(ns, marks)` and `buffer:decorations(ns)`, where a mark is
/// `{ from, to, style, line, text, eol, sign, gutter, above, overlay, ... }`.
fn add_decoration_methods<M: UserDataMethods<BufferRef>>(methods: &mut M) {
    methods.add_method(
        "decorate",
        |lua, this, (ns, list, within): (String, Vec<Table>, Option<Table>)| {
            let marks = marks_from_lua(lua, &list)?;
            // Checked last: reading the marks can run Luau that closes it.
            this.with_buffer(lua, |_| Ok(()))?;
            decorate(lua, this.buffer, None, &ns, within, marks)
        },
    );
    methods.add_method("decorations", |lua, this, ns: String| {
        let marks = this.with_buffer(lua, |b| Ok(b.marks(&ns).to_vec()))?;
        let list = lua.create_table()?;
        for mark in &marks {
            list.push(mark_to_lua(lua, mark)?)?;
        }
        Ok(list)
    });
    methods.add_method("marks_at", |lua, this, pos: usize| {
        let marks = this.with_buffer(lua, |b| {
            Ok(b.marks_at(pos)
                .map(|(ns, m)| (ns.to_owned(), m.clone()))
                .collect::<Vec<_>>())
        })?;
        let list = lua.create_table()?;
        for (ns, mark) in &marks {
            let t = mark_to_lua(lua, mark)?;
            t.set("ns", ns.as_str())?;
            list.push(t)?;
        }
        Ok(list)
    });
}

/// Replaces the marks in `ns` of `buffer` that `view` alone draws (every
/// view's with none), and with `within` only those that start there.
fn decorate(
    lua: &Lua,
    buffer: crate::BufferId,
    view: Option<ViewId>,
    ns: &str,
    within: Option<Table>,
    marks: Vec<Mark>,
) -> LuaResult<()> {
    let within = within
        .map(|t| -> LuaResult<_> {
            let to: Option<usize> = t.get("to")?;
            Ok(t.get::<usize>("from")?..to.unwrap_or(usize::MAX))
        })
        .transpose()?;
    let by = super::capabilities::caller(lua, None);
    let state = &mut *state_mut(lua);
    state.editor.decorate_in(buffer, ns, view, within, marks);
    let cleared = state.editor.buffer(buffer).marks(ns).is_empty();
    state.owned.marked(buffer, ns, by, cleared);
    Ok(())
}

/// The marks `decorate` takes, `{ from, to, style, ... }`.
fn marks_from_lua(lua: &Lua, list: &[Table]) -> LuaResult<Vec<Mark>> {
    // A button runs a command when clicked; sandboxed code could make one
    // look like something else on a page asking you.
    if list
        .iter()
        .any(|t| t.contains_key("action").unwrap_or(false))
    {
        super::capabilities::unless_sandboxed(lua, "add buttons that run commands")?;
    }
    list.iter()
        .map(|t| {
            let style = t.get::<Option<String>>("style")?.ok_or_else(|| {
                mlua::Error::runtime(
                    "a mark needs a style, e.g. { from = 0, to = 5, style = \"match\" }",
                )
            })?;
            let flag =
                |key: &str| -> LuaResult<bool> { Ok(t.get::<Option<bool>>(key)?.unwrap_or(false)) };
            Ok(Mark {
                range: t.get("from")?..t.get("to")?,
                style: style.into(),
                line: flag("line")?,
                text: t.get::<Option<String>>("text")?.map(Into::into),
                eol: flag("eol")?,
                eol_space: t.get::<Option<bool>>("eol_space")?.unwrap_or(true),
                sign: t.get::<Option<String>>("sign")?.map(Into::into),
                gutter: t.get::<Option<String>>("gutter")?.map(Into::into),
                above: flag("above")?,
                overlay: flag("overlay")?,
                conceal: flag("conceal")?,
                reveal: reveal_from_lua(t.get("reveal"))?,
                fold: flag("fold")?,
                peek: flag("peek")?,
                nowrap: flag("nowrap")?,
                plain: flag("plain")?,
                lines: t
                    .get::<Option<Vec<Value>>>("lines")?
                    .unwrap_or_default()
                    .into_iter()
                    .map(virtual_line_from_lua)
                    .collect::<LuaResult<_>>()?,
                image: t
                    .get::<Option<Table>>("image")?
                    .map(|i| mark_image_from_lua(&i))
                    .transpose()?,
                scene: t
                    .get::<Option<Table>>("scene")?
                    .map(|s| mark_scene_from_lua(&s))
                    .transpose()?,
                action: t.get::<Option<String>>("action")?.map(Into::into),
                scale: scale_from_lua(t.get("scale"))?,
                data: match t.get::<Value>("data")? {
                    Value::Nil => None,
                    data => Some(lua.from_value(data)?),
                },
                view: None,
            })
        })
        .collect()
}

/// A mark's `reveal`: "line" when not given, "cursor", "never", "auto" or
/// "typing".
fn reveal_from_lua(value: LuaResult<Option<String>>) -> LuaResult<Reveal> {
    match value?.as_deref() {
        None | Some("line") => Ok(Reveal::Line),
        Some("cursor") => Ok(Reveal::Cursor),
        Some("never") => Ok(Reveal::Never),
        Some("auto") => Ok(Reveal::Auto),
        Some("typing") => Ok(Reveal::Typing),
        Some(_) => Err(mlua::Error::runtime(
            "a mark's reveal is \"line\", \"cursor\", \"never\", \"auto\" or \"typing\"",
        )),
    }
}

/// A mark's `scale`: 1 when not given, else a whole number from 1 to 4.
fn scale_from_lua(value: LuaResult<Option<f64>>) -> LuaResult<u8> {
    let invalid = || mlua::Error::runtime("a mark's scale is a whole number from 1 to 4");
    match value.map_err(|_| invalid())? {
        None => Ok(1),
        Some(n) => (1..=4)
            .find(|&k| (f64::from(k) - n).abs() < f64::EPSILON)
            .ok_or_else(invalid),
    }
}

/// A mark as the table plugins give `decorate`.
fn mark_to_lua(lua: &Lua, mark: &Mark) -> LuaResult<Table> {
    let t = lua.create_table()?;
    t.set("from", mark.range.start)?;
    t.set("to", mark.range.end)?;
    t.set("style", &*mark.style)?;
    t.set("line", mark.line)?;
    t.set("text", mark.text.as_deref())?;
    t.set("eol", mark.eol)?;
    t.set("eol_space", mark.eol_space)?;
    t.set("sign", mark.sign.as_deref())?;
    t.set("gutter", mark.gutter.as_deref())?;
    t.set("above", mark.above)?;
    t.set("overlay", mark.overlay)?;
    t.set("conceal", mark.conceal)?;
    t.set(
        "reveal",
        match mark.reveal {
            Reveal::Line => "line",
            Reveal::Cursor => "cursor",
            Reveal::Never => "never",
            Reveal::Auto => "auto",
            Reveal::Typing => "typing",
        },
    )?;
    t.set("fold", mark.fold)?;
    t.set("peek", mark.peek)?;
    t.set("nowrap", mark.nowrap)?;
    t.set("plain", mark.plain)?;
    t.set("action", mark.action.as_deref())?;
    if mark.scale > 1 {
        t.set("scale", mark.scale)?;
    }
    if let Some(data) = &mark.data {
        t.set("data", super::lsp::to_lua(lua, data)?)?;
    }
    if !mark.lines.is_empty() {
        let lines = lua.create_table()?;
        for line in &mark.lines {
            lines.push(virtual_line_to_lua(lua, line)?)?;
        }
        t.set("lines", lines)?;
    }
    if let Some(image) = mark.image {
        let i = lua.create_table()?;
        i.set("id", image.id.0)?;
        i.set("cols", image.cols)?;
        i.set("rows", image.rows)?;
        i.set("col", image.col)?;
        i.set("row", image.row)?;
        t.set("image", i)?;
    }
    if let Some(scene) = mark.scene {
        let s = lua.create_table()?;
        s.set("id", scene.id.0)?;
        s.set("cols", scene.cols)?;
        s.set("rows", scene.rows)?;
        s.set("col", scene.col)?;
        s.set("row", scene.row)?;
        t.set("scene", s)?;
    }
    Ok(t)
}

/// A mark's virtual line: a string, or pieces `{ text, style? }` to style
/// parts of it on top of the mark's style.
pub(super) fn virtual_line_from_lua(value: Value) -> LuaResult<VirtualLine> {
    let pieces = match value {
        Value::Table(pieces) => pieces,
        Value::String(text) => return Ok(VirtualLine::from(&*text.to_str()?)),
        other => {
            return Err(mlua::Error::runtime(format!(
                "a mark's line is a string or a list of pieces, not {}",
                other.type_name()
            )));
        }
    };
    let mut text = String::new();
    let mut styles = Vec::new();
    let mut actions = Vec::new();
    for piece in pieces.sequence_values::<Table>() {
        let piece = piece?;
        let start = text.len();
        text.push_str(&piece.get::<String>("text")?);
        if let Some(style) = piece.get::<Option<String>>("style")? {
            styles.push((start..text.len(), style.into()));
        }
        if let Some(action) = piece.get::<Option<String>>("action")? {
            actions.push((start..text.len(), action.into()));
        }
    }
    Ok(VirtualLine {
        text: text.into(),
        styles,
        actions,
    })
}

/// A virtual line as Luau gets it back: a string, or pieces if parts of it
/// have styles.
pub(super) fn virtual_line_to_lua(lua: &Lua, line: &VirtualLine) -> LuaResult<Value> {
    if line.styles.is_empty() && line.actions.is_empty() {
        return Ok(Value::String(lua.create_string(&*line.text)?));
    }
    // A piece wherever a style or an action starts or ends.
    let mut cuts: Vec<usize> = line
        .styles
        .iter()
        .chain(&line.actions)
        .flat_map(|(range, _)| [range.start, range.end])
        .chain([0, line.text.len()])
        .collect();
    cuts.sort_unstable();
    cuts.dedup();
    let covering = |spans: &[(std::ops::Range<usize>, std::sync::Arc<str>)], at: usize| {
        spans
            .iter()
            .find(|(range, _)| range.contains(&at))
            .map(|(_, name)| name.clone())
    };
    let pieces = lua.create_table()?;
    for pair in cuts.windows(2) {
        let (from, to) = (pair[0], pair[1]);
        let piece = lua.create_table()?;
        piece.set("text", &line.text[from..to])?;
        piece.set("style", covering(&line.styles, from).as_deref())?;
        piece.set("action", covering(&line.actions, from).as_deref())?;
        pieces.push(piece)?;
    }
    Ok(Value::Table(pieces))
}

/// `{ id, cols, rows, col?, row? }`.
fn mark_image_from_lua(t: &Table) -> LuaResult<MarkImage> {
    Ok(MarkImage {
        id: ImageId(t.get("id")?),
        cols: t.get::<u16>("cols")?.max(1),
        rows: t.get::<u16>("rows")?.max(1),
        col: t.get::<Option<u16>>("col")?.unwrap_or(0),
        row: t.get::<Option<u16>>("row")?.unwrap_or(0),
    })
}

/// `{ id, cols, rows, col?, row? }`, as for an image; `row` can be negative.
fn mark_scene_from_lua(t: &Table) -> LuaResult<MarkScene> {
    Ok(MarkScene {
        id: crate::scene::SceneId(t.get("id")?),
        cols: t.get::<u16>("cols")?.max(1),
        rows: t.get::<u16>("rows")?.max(1),
        col: t.get::<Option<u16>>("col")?.unwrap_or(0),
        row: t.get::<Option<i32>>("row")?.unwrap_or(0),
    })
}

/// Whether the buffer, or its start, is read-only.
fn add_readonly_methods<M: UserDataMethods<BufferRef>>(methods: &mut M) {
    methods.add_method("readonly", |lua, this, NoArgs| {
        this.with_buffer(lua, |b| Ok(b.is_readonly()))
    });
    methods.add_method("set_readonly", |lua, this, readonly: bool| {
        super::capabilities::unless_sandboxed(lua, "make a buffer read-only or writable")?;
        this.with_buffer(lua, |_| Ok(()))?;
        state_mut(lua).editor.set_readonly(this.buffer, readonly);
        Ok(())
    });
    methods.add_method("readonly_before", |lua, this, NoArgs| {
        this.with_buffer(lua, |b| Ok(b.readonly_before()))
    });
    methods.add_method("set_readonly_before", |lua, this, pos: Option<usize>| {
        super::capabilities::unless_sandboxed(lua, "make a buffer read-only or writable")?;
        this.with_buffer(lua, |_| Ok(()))?;
        state_mut(lua).editor.set_readonly_before(this.buffer, pos);
        Ok(())
    });
}

/// The buffer's name, its settings, its history kept or not, and its language.
fn add_setting_methods<M: UserDataMethods<BufferRef>>(methods: &mut M) {
    methods.add_method("name", |lua, this, NoArgs| {
        this.with_buffer(lua, |b| Ok(b.name().map(str::to_owned)))
    });
    methods.add_method("set_name", |lua, this, name: Option<String>| {
        this.with_buffer(lua, |_| Ok(()))?;
        state_mut(lua)
            .editor
            .set_buffer_name(this.buffer, name.as_deref());
        Ok(())
    });
    methods.add_method("title", |lua, this, NoArgs| {
        this.with_buffer(lua, |b| Ok(b.title()))
    });
    methods.add_method("line_numbers", |lua, this, NoArgs| {
        this.with_buffer(lua, |b| Ok(b.line_numbers()))
    });
    methods.add_method("set_line_numbers", |lua, this, on: bool| {
        this.with_buffer(lua, |_| Ok(()))?;
        state_mut(lua).editor.set_line_numbers(this.buffer, on);
        Ok(())
    });
    methods.add_method("views", |lua, this, NoArgs| {
        this.with_buffer(lua, |_| Ok(()))?;
        let list = lua.create_table()?;
        for id in state(lua).editor.views_of(this.buffer) {
            list.push(ViewRef {
                id,
                author: this.author.clone(),
            })?;
        }
        Ok(list)
    });
    methods.add_method("kept", |lua, this, NoArgs| {
        this.with_buffer(lua, |b| Ok(b.is_kept()))
    });
    methods.add_method("forget_history", |lua, this, NoArgs| {
        this.with_buffer(lua, |_| Ok(()))?;
        state_mut(lua).editor.forget_history(this.buffer);
        Ok(())
    });
    methods.add_method("clear_history", |lua, this, NoArgs| {
        this.with_buffer(lua, |_| Ok(()))?;
        state_mut(lua).editor.clear_history(this.buffer);
        Ok(())
    });
    methods.add_method("set_kept", |lua, this, kept: bool| {
        this.with_buffer(lua, |_| Ok(()))?;
        state_mut(lua).editor.set_kept(this.buffer, kept);
        Ok(())
    });
    methods.add_method("set_screen_size", |lua, this, size: Option<Table>| {
        let size = size.map(|t| screen_size_from(&t)).transpose()?;
        this.with_buffer(lua, |_| Ok(()))?;
        state_mut(lua).editor.set_screen_size(this.buffer, size);
        Ok(())
    });
    methods.add_method("screen_size", |lua, this, NoArgs| {
        let size = this.with_buffer(lua, |b| Ok(b.screen_size().cloned()))?;
        size.map(|size| {
            let t = lua.create_table()?;
            t.set("rows", size.rows)?;
            t.set("cols", size.cols)?;
            t.set("note", size.note.as_deref())?;
            t.set("cursor_row", size.cursor_row)?;
            Ok(t)
        })
        .transpose()
    });
    methods.add_method(
        "set_keys",
        |lua, this, bindings: Option<HashMap<String, String>>| {
            super::capabilities::unless_sandboxed(lua, "change a buffer's keys")?;
            this.with_buffer(lua, |_| Ok(()))?;
            let keys = single_keys(bindings.unwrap_or_default())?;
            state_mut(lua).editor.set_buffer_keys(this.buffer, keys);
            Ok(())
        },
    );
    methods.add_method("language", |lua, this, NoArgs| {
        this.with_buffer(lua, |b| Ok(b.language().map(str::to_owned)))
    });
    methods.add_method("set_language", |lua, this, language: Option<String>| {
        this.with_buffer(lua, |_| Ok(()))?;
        state_mut(lua)
            .editor
            .set_language(this.buffer, language.map(Into::into));
        Ok(())
    });
}

impl UserData for BufferRef {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method("id", |_, this, NoArgs| Ok(this.buffer.0));
        methods.add_meta_method(MetaMethod::Eq, |_, this, other: Value| {
            Ok(same_handle(&other, |o: &BufferRef| o.buffer == this.buffer))
        });
        methods.add_method("valid", |lua, this, NoArgs| {
            Ok(state(lua).editor.find_buffer(this.buffer).is_some())
        });
        methods.add_method("len", |lua, this, NoArgs| {
            this.with_text(lua, |t| Ok(t.len_bytes()))
        });
        methods.add_method("text", |lua, this, NoArgs| {
            this.with_text(lua, |t| Ok(t.to_string()))
        });
        methods.add_method("slice", |lua, this, (from, to): (usize, usize)| {
            this.with_text(lua, |t| {
                let (from, to) = (char_index(t, from)?, char_index(t, to)?);
                if from > to {
                    return Err(mlua::Error::runtime("slice start is after its end"));
                }
                Ok(t.slice(from..to).to_string())
            })
        });
        add_line_methods(methods);
        methods.add_method("char_at", |lua, this, pos: usize| {
            this.with_text(lua, |t| {
                let i = char_index(t, pos)?;
                Ok((i < t.len_chars()).then(|| t.char(i).to_string()))
            })
        });
        methods.add_method("next_char", |lua, this, pos: usize| {
            this.with_text(lua, |t| {
                let i = char_index(t, pos)?;
                Ok(t.char_to_byte((i + 1).min(t.len_chars())))
            })
        });
        methods.add_method("prev_char", |lua, this, pos: usize| {
            this.with_text(lua, |t| {
                let i = char_index(t, pos)?;
                Ok(t.char_to_byte(i.saturating_sub(1)))
            })
        });
        methods.add_method("sentence", |lua, this, pos: usize| {
            this.with_text(lua, |t| {
                check_pos(t, pos)?;
                Ok(sentence_at(t, pos))
            })
        });
        methods.add_method("kind", |lua, this, NoArgs| {
            this.with_buffer(lua, |b| Ok(b.kind().to_owned()))
        });
        methods.add_method("project", |lua, this, NoArgs| {
            this.with_buffer(lua, |_| Ok(()))?;
            Ok(state(lua).editor.buffer_project(this.buffer).map(|id| id.0))
        });
        methods.add_method("path", |lua, this, NoArgs| {
            this.with_buffer(lua, |b| {
                Ok(b.path().map(|p| p.to_string_lossy().into_owned()))
            })
        });
        add_readonly_methods(methods);
        add_setting_methods(methods);
        add_decoration_methods(methods);
        add_search_methods(methods);
        add_filter_methods(methods);
        super::syntax::add_methods(methods);
        super::history::add_methods(methods);
        super::track::add_methods(methods);
        methods.add_method("edit", |lua, this, (f, opts): (Function, Option<Table>)| {
            this.edit(lua, &f, kept_to_undo(opts.as_ref())?)
        });
        methods.add_method("save", |lua, this, path: Option<String>| {
            this.save(lua, path)
        });
        methods.add_method("reload", |lua, this, NoArgs| {
            this.with_buffer(lua, |_| Ok(()))?;
            let changed = state_mut(lua)
                .editor
                .reload(this.buffer)
                .map_err(|err| mlua::Error::runtime(format!("can't reload: {err}")))?;
            if changed {
                buffer_changed(lua, this.buffer, &Author::External)?;
            }
            Ok(changed)
        });
        methods.add_method("modified", |lua, this, NoArgs| {
            this.with_buffer(lua, |b| Ok(b.is_modified()))
        });
        methods.add_method("version", |lua, this, NoArgs| {
            this.with_buffer(lua, |b| Ok(b.history().applied()))
        });
        methods.add_method("close", |lua, this, NoArgs| this.close(lua));
    }
}

/// For `__eq`: whether `other` is a `T` handle that `same` accepts. Luau
/// calls it for any two userdata, so a buffer compared with a view is false.
pub(super) fn same_handle<T: UserData + 'static>(other: &Value, same: impl Fn(&T) -> bool) -> bool {
    match other {
        Value::UserData(ud) => ud.borrow::<T>().is_ok_and(|o| same(&o)),
        _ => false,
    }
}

/// Whether `buffer:edit`'s options keep the edit to undo: unless they say
/// `undo = false`.
fn kept_to_undo(opts: Option<&Table>) -> LuaResult<bool> {
    Ok(match opts {
        Some(opts) => opts.get::<Option<bool>>("undo")?.unwrap_or(true),
        None => true,
    })
}

/// The tab width given, or the buffer's, `own`.
fn tab_width(given: Option<usize>, own: usize) -> LuaResult<usize> {
    match given {
        Some(0) => Err(mlua::Error::runtime("a tab width is at least 1")),
        Some(n) => Ok(n),
        None => Ok(own),
    }
}

/// `buffer:line_count()`, `line_of(pos)`, `line_start(line)`,
/// `line_end(line)`, `line_text(line)`, `display_column(pos)`,
/// `at_display_column(line, col)`, `tab_width()` and `set_tab_width(n)`.
fn add_line_methods<M: UserDataMethods<BufferRef>>(methods: &mut M) {
    methods.add_method("tab_width", |lua, this, NoArgs| {
        this.with_buffer(lua, |b| Ok(b.tab_width()))
    });
    methods.add_method("set_tab_width", |lua, this, width: usize| {
        this.with_buffer(lua, |_| Ok(()))?;
        let width = tab_width(Some(width), width)?;
        state_mut(lua).editor.set_tab_width(this.buffer, width);
        Ok(())
    });
    methods.add_method("line_count", |lua, this, NoArgs| {
        this.with_text(lua, |t| Ok(t.len_lines()))
    });
    methods.add_method("line_of", |lua, this, pos: usize| {
        this.with_text(lua, |t| {
            check_pos(t, pos)?;
            Ok(t.byte_to_line(pos))
        })
    });
    methods.add_method("line_start", |lua, this, line: usize| {
        this.with_text(lua, |t| {
            check_line(t, line)?;
            Ok(t.line_to_byte(line))
        })
    });
    methods.add_method("line_end", |lua, this, line: usize| {
        this.with_text(lua, |t| {
            check_line(t, line)?;
            Ok(line_end(t, line))
        })
    });
    methods.add_method("line_text", |lua, this, line: usize| {
        this.with_text(lua, |t| {
            check_line(t, line)?;
            Ok(line_content(t, line).to_string())
        })
    });
    methods.add_method(
        "display_column",
        |lua, this, (pos, tabs): (usize, Option<usize>)| {
            this.with_buffer(lua, |b| {
                let tabs = tab_width(tabs, b.tab_width())?;
                char_index(b.text(), pos)?;
                Ok(crate::render::display_column(b.text(), pos, tabs))
            })
        },
    );
    methods.add_method(
        "at_display_column",
        |lua, this, (line, col, tabs): (usize, usize, Option<usize>)| {
            this.with_buffer(lua, |b| {
                let tabs = tab_width(tabs, b.tab_width())?;
                check_line(b.text(), line)?;
                Ok(crate::render::at_display_column(b.text(), line, col, tabs))
            })
        },
    );
}

/// Collects edits made inside `buffer:edit`.
#[derive(Default)]
struct Edits {
    changes: Vec<(usize, usize, Option<String>)>,
    selection: Option<Selection>,
}

impl UserData for Edits {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method_mut("insert", |_, this, (pos, text): (usize, String)| {
            this.changes.push((pos, pos, Some(text)));
            Ok(())
        });
        methods.add_method_mut("delete", |_, this, (from, to): (usize, usize)| {
            this.changes.push((from, to, None));
            Ok(())
        });
        methods.add_method_mut(
            "replace",
            |_, this, (from, to, text): (usize, usize, String)| {
                this.changes.push((from, to, Some(text)));
                Ok(())
            },
        );
        methods.add_method_mut("select", |_, this, t: Table| {
            this.selection = Some(selection_from_lua(&t)?);
            Ok(())
        });
        methods.add_meta_method(MetaMethod::ToString, |_, this, NoArgs| {
            Ok(format!("edits({})", this.changes.len()))
        });
    }
}

fn range_to_lua(lua: &Lua, range: Range) -> LuaResult<Table> {
    let t = lua.create_table()?;
    t.set("anchor", range.anchor)?;
    t.set("head", range.head)?;
    Ok(t)
}

fn selection_to_lua(lua: &Lua, selection: &Selection) -> LuaResult<Table> {
    let ranges = lua.create_table()?;
    for range in selection.ranges() {
        ranges.push(range_to_lua(lua, *range)?)?;
    }
    let t = lua.create_table()?;
    t.set("ranges", ranges)?;
    t.set("primary", selection.primary_index() + 1)?;
    Ok(t)
}

fn selection_from_lua(t: &Table) -> LuaResult<Selection> {
    let ranges = t
        .get::<Table>("ranges")?
        .sequence_values::<Table>()
        .map(|r| {
            let r = r?;
            Ok(Range::new(r.get("anchor")?, r.get("head")?))
        })
        .collect::<LuaResult<Vec<Range>>>()?;
    let primary = t
        .get::<Option<usize>>("primary")?
        .unwrap_or(1)
        .saturating_sub(1);
    Selection::new(ranges, primary).map_err(mlua::Error::external)
}

fn check_selection(text: &Rope, selection: &Selection) -> LuaResult<()> {
    selection
        .ranges()
        .iter()
        .flat_map(|r| [r.anchor, r.head])
        .try_for_each(|pos| char_index(text, pos).map(drop))
}

fn check_pos(text: &Rope, pos: usize) -> LuaResult<()> {
    if pos > text.len_bytes() {
        return Err(mlua::Error::runtime(format!(
            "position {pos} is past the end of the buffer ({} bytes)",
            text.len_bytes()
        )));
    }
    Ok(())
}

fn check_line(text: &Rope, line: usize) -> LuaResult<()> {
    if line >= text.len_lines() {
        return Err(mlua::Error::runtime(format!(
            "line {line} is past the end of the buffer ({} lines)",
            text.len_lines()
        )));
    }
    Ok(())
}

/// The char index of byte `pos`, which must be in bounds and on a char
/// boundary.
fn char_index(text: &Rope, pos: usize) -> LuaResult<usize> {
    check_pos(text, pos)?;
    let i = text.byte_to_char(pos);
    if text.char_to_byte(i) != pos {
        return Err(mlua::Error::runtime(format!(
            "position {pos} is inside a character"
        )));
    }
    Ok(i)
}

/// The sentence around byte `pos`, without the spaces after it. Sentences
/// don't cross blank lines, so only the paragraph around `pos` is examined.
fn sentence_at(text: &Rope, pos: usize) -> (usize, usize) {
    let blank = |line: usize| text.line(line).chars().all(char::is_whitespace);
    let line = text.byte_to_line(pos);
    let mut first = line;
    while first > 0 && !blank(first - 1) {
        first -= 1;
    }
    let mut last = line;
    while last + 1 < text.len_lines() && !blank(last + 1) {
        last += 1;
    }
    let start = text.line_to_byte(first);
    let end = text.line_to_byte(last + 1);
    let paragraph = text.byte_slice(start..end).to_string();

    let mut found = (pos, pos);
    for (offset, sentence) in paragraph.split_sentence_bound_indices() {
        let from = start + offset;
        let to = from + sentence.trim_end().len();
        found = (from, to);
        if pos < from + sentence.len() {
            break;
        }
    }
    found
}

/// What a line filter keeps, from `set_filter`'s and `kept_lines`' options:
/// `text` as a regex with `regex`, else the `query` `core.query` parsed of
/// it and the `section` (keys between dots) it keeps.
fn keep_of(
    lua: &Lua,
    text: &str,
    opts: Option<&mlua::Table>,
) -> LuaResult<crate::line_filter::Keep> {
    let get = |key: &str| -> LuaResult<Value> { opts.map_or(Ok(Value::Nil), |o| o.get(key)) };
    if get("regex")?.as_boolean().unwrap_or(false) {
        return Ok(crate::line_filter::Keep::Regex(text.to_owned()));
    }
    let section = match get("section")? {
        Value::String(s) => s.to_str()?.to_string(),
        _ => String::new(),
    };
    // Given no query and no section, every word of the text, as a plain
    // filter is.
    let query = super::query::node(lua, get("query")?)?;
    let query = if query.is_none() && section.is_empty() {
        words(text)
    } else {
        query
    };
    Ok(crate::line_filter::Keep::Query(
        query.map(Box::new),
        section,
        get("case")?.as_boolean().unwrap_or(false),
    ))
}

// A query of each word of `text`, all of them needed; none for no words.
fn words(text: &str) -> Option<greed_index::query::Node> {
    use greed_index::query::Node;
    let mut items: Vec<Node> = text
        .split_whitespace()
        .map(|word| Node {
            kind: "word".into(),
            text: Some(word.into()),
            ..Node::default()
        })
        .collect();
    match items.len() {
        0 => None,
        1 => items.pop(),
        _ => Some(Node {
            kind: "and".into(),
            items,
            ..Node::default()
        }),
    }
}
