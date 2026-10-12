//! Places that move with edits: `buffer:track(pos, opts)` and
//! `buffer:track_range(from, to, opts)`. Like marks, but never drawn, and
//! each has a handle of its own, so plugins needn't share namespaces.

use greed_text::Assoc;
use mlua::{Lua, Table, UserData, UserDataMethods};

use super::arity::NoArgs;
use super::handles::BufferRef;
use super::{state, state_mut};
use crate::{BufferId, TrackId};

type LuaResult<T> = mlua::Result<T>;

/// A tracked position or range. It goes when forgotten, when its buffer
/// closes, or when the plugin that made it is unloaded.
pub(super) struct TrackedRef {
    buffer: BufferId,
    id: TrackId,
}

impl TrackedRef {
    /// Where it is now, unless its text was deleted or it's gone.
    fn range(&self, lua: &Lua) -> Option<(usize, usize)> {
        let state = state(lua);
        let tracked = state.editor.find_buffer(self.buffer)?.tracked(self.id)?;
        (!tracked.deleted).then_some((tracked.range.start, tracked.range.end))
    }
}

impl UserData for TrackedRef {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method("pos", |lua, this, NoArgs| {
            Ok(this.range(lua).map(|(from, _)| from))
        });
        methods.add_method("range", |lua, this, NoArgs| {
            Ok(this
                .range(lua)
                .map_or((None, None), |(from, to)| (Some(from), Some(to))))
        });
        methods.add_method("deleted", |lua, this, NoArgs| Ok(this.range(lua).is_none()));
        methods.add_method("forget", |lua, this, NoArgs| {
            let state = &mut *state_mut(lua);
            state.editor.forget_tracked(this.buffer, this.id);
            state.owned.forget_tracked(this.buffer, this.id);
            Ok(())
        });
    }
}

/// `"left"` stays before text inserted exactly there, `"right"` goes after
/// it.
fn gravity(opts: Option<&Table>, key: &str, default: Assoc) -> LuaResult<Assoc> {
    let Some(opts) = opts else {
        return Ok(default);
    };
    match opts.get::<Option<String>>(key)?.as_deref() {
        None => Ok(default),
        Some("left") => Ok(Assoc::Before),
        Some("right") => Ok(Assoc::After),
        Some(other) => Err(mlua::Error::runtime(format!(
            "{key} should be \"left\" or \"right\", not {other:?}"
        ))),
    }
}

fn track(
    lua: &Lua,
    buffer: &BufferRef,
    (from, to): (usize, usize),
    gravity: (Assoc, Assoc),
) -> LuaResult<TrackedRef> {
    buffer.with_buffer(lua, |b| {
        let len = b.text().len_bytes();
        if from > to || to > len {
            return Err(mlua::Error::runtime(format!(
                "can't track {from}..{to} in a buffer of {len} bytes"
            )));
        }
        Ok(())
    })?;
    let by = super::capabilities::caller(lua, None);
    let state = &mut *state_mut(lua);
    let id = state
        .editor
        .track(buffer.buffer, from..to, gravity)
        .ok_or_else(|| mlua::Error::runtime("this buffer was closed"))?;
    if let Some(by) = by {
        state.owned.tracked(buffer.buffer, id, by);
    }
    Ok(TrackedRef {
        buffer: buffer.buffer,
        id,
    })
}

pub(super) fn add_methods<M: UserDataMethods<BufferRef>>(methods: &mut M) {
    methods.add_method("track", |lua, this, (pos, opts): (usize, Option<Table>)| {
        let g = gravity(opts.as_ref(), "gravity", Assoc::After)?;
        track(lua, this, (pos, pos), (g, g))
    });
    methods.add_method(
        "track_range",
        |lua, this, (from, to, opts): (usize, usize, Option<Table>)| {
            let start = gravity(opts.as_ref(), "from", Assoc::After)?;
            let end = gravity(opts.as_ref(), "to", Assoc::Before)?;
            track(lua, this, (from, to), (start, end))
        },
    );
}
