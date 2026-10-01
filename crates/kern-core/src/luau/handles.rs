//! The handles Luau code holds: views, buffers, and the edit collector used
//! inside `buffer:edit`. Handles refer to things by id, so a handle to a
//! closed view or buffer fails cleanly instead of keeping it alive.
//!
//! Positions are 0-based byte offsets and lines are 0-based, matching LSP.
//! A range is `{ anchor = n, head = n }`; a selection is
//! `{ ranges = { range, ... }, primary = i }` with a 1-based `primary`.

use kern_text::{Author, ChangeSet, Range, Rope, Selection};
use mlua::{Function, Lua, MetaMethod, Table, UserData, UserDataMethods, UserDataRef};

use super::api::emit;
use super::{state, state_mut};
use crate::{Buffer, BufferId, View, ViewId};

type LuaResult<T> = mlua::Result<T>;

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

    fn buffer(&self, lua: &Lua) -> LuaResult<BufferId> {
        self.with_view(lua, |v| Ok(v.buffer))
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
        methods.add_method("id", |_, this, ()| Ok(this.id.0));
        methods.add_method("selection", |lua, this, ()| {
            this.with_view(lua, |v| selection_to_lua(lua, &v.selection))
        });
        methods.add_method("set_selection", |lua, this, t: Table| {
            let selection = selection_from_lua(&t)?;
            let buffer = this.buffer(lua)?;
            let mut state = state_mut(lua);
            check_selection(state.editor.buffer(buffer).text(), &selection)?;
            state.editor.view_mut(this.id).selection = selection;
            Ok(())
        });
        methods.add_method("buffer", |lua, this, ()| {
            Ok(BufferRef {
                buffer: this.buffer(lua)?,
                view: Some(this.id),
                author: this.author.clone(),
            })
        });
        methods.add_method("show", |lua, this, buffer: UserDataRef<BufferRef>| {
            this.with_view(lua, |_| Ok(()))?;
            buffer.with_buffer(lua, |_| Ok(()))?;
            state_mut(lua).editor.show(this.id, buffer.buffer);
            Ok(())
        });
        methods.add_method("focus", |lua, this, ()| {
            this.with_view(lua, |_| Ok(()))?;
            state_mut(lua).editor.set_focus(this.id);
            Ok(())
        });
        methods.add_method("close", |lua, this, ()| {
            Ok(state_mut(lua).editor.close(this.id))
        });
        methods.add_method("undo", |lua, this, ()| this.history_step(lua, true));
        methods.add_method("redo", |lua, this, ()| this.history_step(lua, false));
    }
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

    fn with_text<R>(&self, lua: &Lua, f: impl FnOnce(&Rope) -> LuaResult<R>) -> LuaResult<R> {
        self.with_buffer(lua, |buffer| f(buffer.text()))
    }

    /// Calls `f` with an edit collector, then applies everything it collected
    /// as one transaction and tells plugins the buffer changed.
    fn edit(&self, lua: &Lua, f: &Function) -> LuaResult<()> {
        let edits = lua.create_userdata(Edits::default())?;
        f.call::<()>(&edits)?;
        let Edits {
            mut changes,
            selection,
        } = edits.take()?;
        changes.sort_by_key(|(from, to, _)| (*from, *to));
        let len = self.with_text(lua, |t| Ok(t.len_bytes()))?;
        let changes = ChangeSet::from_changes(len, changes).map_err(mlua::Error::external)?;
        let mut state = state_mut(lua);
        let view = self.view.filter(|v| {
            state
                .editor
                .find_view(*v)
                .is_some_and(|v| v.buffer == self.buffer)
        });
        match view {
            Some(view) => state
                .editor
                .apply(view, changes, self.author.clone(), None, selection),
            None => state
                .editor
                .apply_to_buffer(self.buffer, changes, self.author.clone(), None),
        }
        .map_err(mlua::Error::external)?;
        drop(state);
        buffer_changed(lua, self.buffer, &self.author)
    }
}

/// Emits "buffer.changed" for `buffer`.
fn buffer_changed(lua: &Lua, buffer: BufferId, author: &Author) -> LuaResult<()> {
    let payload = lua.create_table()?;
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

impl UserData for BufferRef {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method("id", |_, this, ()| Ok(this.buffer.0));
        methods.add_method("len", |lua, this, ()| {
            this.with_text(lua, |t| Ok(t.len_bytes()))
        });
        methods.add_method("text", |lua, this, ()| {
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
        methods.add_method("line_count", |lua, this, ()| {
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
                let slice = t.line(line);
                let newline = match (slice.len_chars(), slice.chars().last()) {
                    (n, Some('\n')) if n >= 2 && slice.char(n - 2) == '\r' => 2,
                    (_, Some('\n')) => 1,
                    _ => 0,
                };
                Ok(t.line_to_byte(line) + slice.len_bytes() - newline)
            })
        });
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
        methods.add_method("kind", |lua, this, ()| {
            this.with_buffer(lua, |b| Ok(b.kind().to_owned()))
        });
        methods.add_method("path", |lua, this, ()| {
            this.with_buffer(lua, |b| {
                Ok(b.path().map(|p| p.to_string_lossy().into_owned()))
            })
        });
        methods.add_method("edit", |lua, this, f: Function| this.edit(lua, &f));
        methods.add_method("save", |lua, this, ()| {
            this.with_buffer(lua, |b| b.save().map_err(mlua::Error::external))
        });
    }
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
        methods.add_meta_method(MetaMethod::ToString, |_, this, ()| {
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
