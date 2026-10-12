//! What changed between two frames, so a client that already has the first
//! can be sent much less than the second: typing a character changes one or
//! two rows of one surface, focusing another pane changes two roles, and
//! moving a float changes its rect. This matters most for clients far away,
//! like a terminal attached over SSH.

use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::CursorShape;
use crate::render::{
    Frame, ImagePlacement, Menu, Position, Rect, Role, Row, ScenePlacement, Separator, Size,
    Surface, SurfaceId, uncounted,
};
use crate::theme::Theme;

/// The parts of a frame that changed. Anything left out is as it was.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FrameDelta {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<Size>,
    /// Every surface's id, bottom first, when that changed: one came, went
    /// or moved above another.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub order: Option<Vec<SurfaceId>>,
    /// The surfaces that went.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub removed: Vec<SurfaceId>,
    /// What changed in each surface that did, and all of each new one.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub surfaces: Vec<SurfaceDelta>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lines: Option<Vec<Separator>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub images: Option<Vec<ImagePlacement>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scenes: Option<Vec<ScenePlacement>>,
    /// The cursor, when it moved, appeared or went away.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "changed_to"
    )]
    pub cursor: Option<Option<Position>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor_shape: Option<CursorShape>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub theme: Option<Arc<Theme>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gui: Option<BTreeMap<String, String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub menus: Option<Vec<Menu>>,
    /// The `seq` of the frame it was made against, and of the one it makes;
    /// 0 from a session that doesn't count them.
    #[serde(default, skip_serializing_if = "uncounted")]
    pub base: u64,
    #[serde(default, skip_serializing_if = "uncounted")]
    pub seq: u64,
}

/// What changed in one surface. Anything left out is as it was; a new
/// surface comes with all of it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SurfaceDelta {
    pub id: SurfaceId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<Role>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rect: Option<Rect>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "changed_to"
    )]
    pub content: Option<Option<Size>>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "changed_to"
    )]
    pub note: Option<Option<String>>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "changed_to"
    )]
    pub keep: Option<Option<u16>>,
    /// Where its view's first row now is in its text, when the view
    /// scrolled.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "changed_to"
    )]
    pub top: Option<Option<[u64; 2]>>,
    /// How many rows its rows moved up, or down when negative, before the
    /// rest applies, as when its view scrolled: the rows that stay in sight
    /// aren't sent again, and a window can glide them to their new place.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub shift: i32,
    /// How many rows it has, when that changed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub row_count: Option<usize>,
    /// Rows that changed, by index.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rows: Vec<(u16, Row)>,
}

/// Reads a field saying what something optional changed to: `null` is that
/// it went away. Left out, the field is `None` by its default: unchanged.
/// Without this, `null` would read as unchanged too.
#[expect(
    clippy::option_option,
    reason = "the fields it reads are unchanged, gone or a new value"
)]
fn changed_to<'de, T, D>(deserializer: D) -> Result<Option<Option<T>>, D::Error>
where
    T: Deserialize<'de>,
    D: serde::Deserializer<'de>,
{
    Option::<T>::deserialize(deserializer).map(Some)
}

/// `new` if it differs from `old`.
fn changed<T: PartialEq + Clone>(old: &T, new: &T) -> Option<T> {
    (old != new).then(|| new.clone())
}

/// Rows are numbered in a `u16`; a frame never has more in a surface.
fn index(i: usize) -> u16 {
    u16::try_from(i).unwrap_or(u16::MAX)
}

#[expect(
    clippy::trivially_copy_pass_by_ref,
    reason = "serde passes a reference"
)]
fn is_zero(n: &i32) -> bool {
    *n == 0
}

/// The row of `old` that row `i` is once its rows moved up by `shift`.
fn shifted(old: &[Row], i: usize, shift: isize) -> Option<&Row> {
    if i >= old.len() {
        return None;
    }
    i.checked_add_signed(shift).and_then(|from| old.get(from))
}

/// How far `old`'s rows moved up (or down) to become `new`'s, as when a view
/// scrolls: the move that leaves the most rows as they are, if it leaves
/// more than staying put does.
fn shift_between(old: &[Row], new: &[Row]) -> isize {
    let kept = |shift: isize| {
        (0..new.len())
            .filter(|&i| shifted(old, i, shift) == Some(&new[i]))
            .count()
    };
    let still = kept(0);
    // Too few rows change to be worth looking for a move.
    if new.len().saturating_sub(still) < 3 {
        return 0;
    }
    let most = isize::try_from(old.len().min(new.len())).unwrap_or(0);
    let (mut best, mut best_kept) = (0, still);
    for shift in (1..most).flat_map(|n| [n, -n]) {
        // A move can keep no more rows than it leaves in sight.
        if most - shift.abs() <= isize::try_from(best_kept).unwrap_or(isize::MAX) {
            break;
        }
        let n = kept(shift);
        if n > best_kept {
            (best, best_kept) = (shift, n);
        }
    }
    // Moving costs a little to say, so it has to keep a few more rows.
    if best_kept > still + 2 { best } else { 0 }
}

impl SurfaceDelta {
    /// All of `new`, for a client that hasn't seen it.
    fn whole(new: &Surface) -> Self {
        SurfaceDelta {
            id: new.id,
            role: Some(new.role.clone()),
            rect: Some(new.rect),
            content: new.content.map(Some),
            note: new.note.clone().map(Some),
            keep: new.keep.map(Some),
            top: new.top.map(Some),
            shift: 0,
            row_count: Some(new.rows.len()),
            rows: (new.rows.iter().enumerate())
                .map(|(i, row)| (index(i), row.clone()))
                .collect(),
        }
    }

    /// What turns `old` into `new`, or `None` if they're the same.
    fn between(old: &Surface, new: &Surface) -> Option<Self> {
        // Only a surface that stays where it is scrolls.
        let shift = if old.rect == new.rect {
            shift_between(&old.rows, &new.rows)
        } else {
            0
        };
        let rows: Vec<(u16, Row)> = (new.rows.iter().enumerate())
            .filter(|(i, row)| shifted(&old.rows, *i, shift) != Some(row))
            .map(|(i, row)| (index(i), row.clone()))
            .collect();
        let delta = SurfaceDelta {
            id: new.id,
            role: changed(&old.role, &new.role),
            rect: changed(&old.rect, &new.rect),
            content: changed(&old.content, &new.content),
            note: changed(&old.note, &new.note),
            keep: changed(&old.keep, &new.keep),
            top: changed(&old.top, &new.top),
            shift: i32::try_from(shift).unwrap_or(0),
            row_count: changed(&old.rows.len(), &new.rows.len()),
            rows,
        };
        (!delta.is_empty()).then_some(delta)
    }

    fn is_empty(&self) -> bool {
        self.role.is_none()
            && self.rect.is_none()
            && self.content.is_none()
            && self.note.is_none()
            && self.keep.is_none()
            && self.top.is_none()
            && self.shift == 0
            && self.row_count.is_none()
            && self.rows.is_empty()
    }

    fn apply(self, surface: &mut Surface) {
        if let Some(role) = self.role {
            surface.role = role;
        }
        if let Some(rect) = self.rect {
            surface.rect = rect;
        }
        if let Some(content) = self.content {
            surface.content = content;
        }
        if let Some(note) = self.note {
            surface.note = note;
        }
        if let Some(keep) = self.keep {
            surface.keep = keep;
        }
        if let Some(top) = self.top {
            surface.top = top;
        }
        // Rows moved out of sight go; those coming into it are empty until
        // `rows` fills them.
        let len = surface.rows.len();
        let by = usize::try_from(self.shift.unsigned_abs())
            .unwrap_or(usize::MAX)
            .min(len);
        if self.shift > 0 {
            surface.rows.drain(..by);
            surface.rows.resize_with(len, Row::default);
        } else if self.shift < 0 {
            surface.rows.truncate(len - by);
            surface
                .rows
                .splice(0..0, std::iter::repeat_with(Row::default).take(by));
        }
        if let Some(count) = self.row_count {
            // A delta saying more than a u16 numbers is broken.
            let count = count.min(usize::from(u16::MAX));
            surface.rows.resize_with(count, Row::default);
        }
        for (i, row) in self.rows {
            if let Some(slot) = surface.rows.get_mut(usize::from(i)) {
                *slot = row;
            }
        }
    }
}

impl FrameDelta {
    /// What turns `old` into `new`, or `None` if they're the same. Surfaces
    /// are told apart by their ids, which a frame never repeats.
    pub fn between(old: &Frame, new: &Frame) -> Option<FrameDelta> {
        let before: HashMap<SurfaceId, &Surface> = old.surfaces.iter().map(|s| (s.id, s)).collect();
        let ids = |frame: &Frame| frame.surfaces.iter().map(|s| s.id).collect::<Vec<_>>();
        let (old_ids, new_ids) = (ids(old), ids(new));
        let removed = old_ids
            .iter()
            .filter(|id| !new_ids.contains(id))
            .copied()
            .collect();
        let surfaces = new
            .surfaces
            .iter()
            .filter_map(|s| match before.get(&s.id) {
                Some(was) => SurfaceDelta::between(was, s),
                None => Some(SurfaceDelta::whole(s)),
            })
            .collect();
        // Frames from the same theme share it, so this is usually a pointer
        // comparison.
        let theme = (!Arc::ptr_eq(&old.theme, &new.theme) && old.theme != new.theme)
            .then(|| new.theme.clone());
        let delta = FrameDelta {
            size: changed(&old.size, &new.size),
            order: changed(&old_ids, &new_ids),
            removed,
            surfaces,
            lines: changed(&old.lines, &new.lines),
            images: changed(&old.images, &new.images),
            scenes: changed(&old.scenes, &new.scenes),
            cursor: changed(&old.cursor, &new.cursor),
            cursor_shape: changed(&old.cursor_shape, &new.cursor_shape),
            theme,
            gui: changed(&old.gui, &new.gui),
            menus: changed(&old.menus, &new.menus),
            base: old.seq,
            seq: new.seq,
        };
        (!delta.is_empty()).then_some(delta)
    }

    fn is_empty(&self) -> bool {
        self.size.is_none()
            && self.order.is_none()
            && self.removed.is_empty()
            && self.surfaces.is_empty()
            && self.lines.is_none()
            && self.images.is_none()
            && self.scenes.is_none()
            && self.cursor.is_none()
            && self.cursor_shape.is_none()
            && self.theme.is_none()
            && self.gui.is_none()
            && self.menus.is_none()
    }

    /// Turns `frame` (the old frame this delta was made against) into the
    /// new one. False when it doesn't fit `frame`: it was made against
    /// another frame, or changes or removes a surface `frame` doesn't have,
    /// as when a message on the way was lost. It's applied as far as it
    /// makes sense then, and the client should ask for a whole frame
    /// (`Input::Refresh`).
    #[must_use]
    pub fn apply(self, frame: &mut Frame) -> bool {
        let mut fits = self.base == 0 || self.base == frame.seq;
        if let Some(size) = self.size {
            frame.size = size;
        }
        fits &= self
            .removed
            .iter()
            .all(|id| frame.surfaces.iter().any(|s| s.id == *id));
        frame.surfaces.retain(|s| !self.removed.contains(&s.id));
        // Surfaces new to `frame`, which their deltas have to say all of.
        let mut new = Vec::new();
        if let Some(order) = self.order {
            let mut kept: HashMap<SurfaceId, Surface> =
                frame.surfaces.drain(..).map(|s| (s.id, s)).collect();
            frame.surfaces = order
                .into_iter()
                .map(|id| {
                    // A new one; its delta below says what it is.
                    kept.remove(&id).unwrap_or_else(|| {
                        new.push(id);
                        Surface::new(
                            id,
                            Role::Pane { active: false },
                            Rect::default(),
                            Vec::new(),
                        )
                    })
                })
                .collect();
        }
        for delta in self.surfaces {
            if delta.role.is_some() && delta.rect.is_some() {
                new.retain(|id| *id != delta.id);
            }
            match frame.surfaces.iter_mut().find(|s| s.id == delta.id) {
                Some(surface) => delta.apply(surface),
                None => fits = false,
            }
        }
        fits &= new.is_empty();
        if self.seq != 0 {
            frame.seq = self.seq;
        }
        if let Some(lines) = self.lines {
            frame.lines = lines;
        }
        if let Some(scenes) = self.scenes {
            frame.scenes = scenes;
        }
        if let Some(images) = self.images {
            frame.images = images;
        }
        if let Some(cursor) = self.cursor {
            frame.cursor = cursor;
        }
        if let Some(shape) = self.cursor_shape {
            frame.cursor_shape = shape;
        }
        if let Some(theme) = self.theme {
            frame.theme = theme;
        }
        if let Some(gui) = self.gui {
            frame.gui = gui;
        }
        if let Some(menus) = self.menus {
            frame.menus = menus;
        }
        fits
    }
}

/// The frame a client shows: the last whole one its session sent, with the
/// deltas since applied.
#[derive(Debug, Default)]
pub struct Latest {
    frame: Option<Frame>,
    /// Whether it asked for a whole frame since the last one came.
    asked: bool,
}

impl Latest {
    pub fn frame(&self) -> Option<&Frame> {
        self.frame.as_ref()
    }

    pub fn whole(&mut self, frame: Frame) {
        self.frame = Some(frame);
        self.asked = false;
    }

    /// Applies `delta`, as far as it makes sense. True when the client
    /// should ask for a whole frame (`Input::Refresh`), since the delta
    /// doesn't fit what it has (see [`FrameDelta::apply`]) or it has no
    /// frame yet; once, until the whole frame comes.
    pub fn delta(&mut self, delta: FrameDelta) -> bool {
        let fits = self.frame.as_mut().is_some_and(|frame| delta.apply(frame));
        let ask = !fits && !self.asked;
        self.asked |= ask;
        ask
    }
}
