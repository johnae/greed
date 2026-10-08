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
    Frame, ImagePlacement, Menu, Position, Rect, Role, Row, Separator, Size, Surface, SurfaceId,
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
    /// The cursor, when it moved, appeared or went away.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<Option<Position>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor_shape: Option<CursorShape>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub theme: Option<Arc<Theme>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gui: Option<BTreeMap<String, String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub menus: Option<Vec<Menu>>,
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content: Option<Option<Size>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<Option<String>>,
    /// How many rows it has, when that changed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub row_count: Option<usize>,
    /// Rows that changed, by index.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rows: Vec<(u16, Row)>,
}

/// `new` if it differs from `old`.
fn changed<T: PartialEq + Clone>(old: &T, new: &T) -> Option<T> {
    (old != new).then(|| new.clone())
}

/// Rows are numbered in a `u16`; a frame never has more in a surface.
fn index(i: usize) -> u16 {
    u16::try_from(i).unwrap_or(u16::MAX)
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
            row_count: Some(new.rows.len()),
            rows: (new.rows.iter().enumerate())
                .map(|(i, row)| (index(i), row.clone()))
                .collect(),
        }
    }

    /// What turns `old` into `new`, or `None` if they're the same.
    fn between(old: &Surface, new: &Surface) -> Option<Self> {
        let rows: Vec<(u16, Row)> = (new.rows.iter().enumerate())
            .filter(|(i, row)| old.rows.get(*i) != Some(row))
            .map(|(i, row)| (index(i), row.clone()))
            .collect();
        let delta = SurfaceDelta {
            id: new.id,
            role: changed(&old.role, &new.role),
            rect: changed(&old.rect, &new.rect),
            content: changed(&old.content, &new.content),
            note: changed(&old.note, &new.note),
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
            cursor: changed(&old.cursor, &new.cursor),
            cursor_shape: changed(&old.cursor_shape, &new.cursor_shape),
            theme,
            gui: changed(&old.gui, &new.gui),
            menus: changed(&old.menus, &new.menus),
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
            && self.cursor.is_none()
            && self.cursor_shape.is_none()
            && self.theme.is_none()
            && self.gui.is_none()
            && self.menus.is_none()
    }

    /// Turns `frame` (the old frame this delta was made against) into the
    /// new one.
    pub fn apply(self, frame: &mut Frame) {
        if let Some(size) = self.size {
            frame.size = size;
        }
        frame.surfaces.retain(|s| !self.removed.contains(&s.id));
        if let Some(order) = self.order {
            let mut kept: HashMap<SurfaceId, Surface> =
                frame.surfaces.drain(..).map(|s| (s.id, s)).collect();
            frame.surfaces = order
                .into_iter()
                .map(|id| {
                    // A new one; its delta below says what it is.
                    kept.remove(&id).unwrap_or_else(|| {
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
            if let Some(surface) = frame.surfaces.iter_mut().find(|s| s.id == delta.id) {
                delta.apply(surface);
            }
        }
        if let Some(lines) = self.lines {
            frame.lines = lines;
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
    }
}
