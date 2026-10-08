//! What changed between two frames, so a client that already has the first
//! can be sent much less than the second: typing a character changes one or
//! two rows, not the whole screen. This matters most for clients far away,
//! like a terminal attached over SSH.

use std::collections::BTreeMap;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::CursorShape;
use crate::render::{Frame, ImagePlacement, Menu, Position, Row, Separator, Size, Surface};
use crate::theme::Theme;

/// The parts of a frame that changed. Anything left out is as it was.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FrameDelta {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<Size>,
    /// Every surface, when any of them came, went, moved or changed
    /// otherwise than in its rows.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub surfaces: Option<Vec<Surface>>,
    /// Rows that changed, by index, counting the surfaces' rows bottom
    /// surface first.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rows: Vec<(u16, Row)>,
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

/// `new` if it differs from `old`.
fn changed<T: PartialEq + Clone>(old: &T, new: &T) -> Option<T> {
    (old != new).then(|| new.clone())
}

/// Whether two surfaces differ in more than their rows' contents.
fn reshaped(old: &Surface, new: &Surface) -> bool {
    old.id != new.id
        || old.role != new.role
        || old.rect != new.rect
        || old.content != new.content
        || old.note != new.note
        || old.rows.len() != new.rows.len()
}

impl FrameDelta {
    /// What turns `old` into `new`, or `None` if they're the same.
    pub fn between(old: &Frame, new: &Frame) -> Option<FrameDelta> {
        let same_shape = old.surfaces.len() == new.surfaces.len()
            && old
                .surfaces
                .iter()
                .zip(&new.surfaces)
                .all(|(a, b)| !reshaped(a, b));
        let (surfaces, rows) = if same_shape {
            let rows = new
                .surfaces
                .iter()
                .flat_map(|s| &s.rows)
                .zip(old.surfaces.iter().flat_map(|s| &s.rows))
                .enumerate()
                .filter(|(_, (new, old))| new != old)
                .map(|(i, (row, _))| (u16::try_from(i).unwrap_or(u16::MAX), row.clone()))
                .collect();
            (None, rows)
        } else {
            (Some(new.surfaces.clone()), Vec::new())
        };
        // Frames from the same theme share it, so this is usually a pointer
        // comparison.
        let theme = (!Arc::ptr_eq(&old.theme, &new.theme) && old.theme != new.theme)
            .then(|| new.theme.clone());
        let delta = FrameDelta {
            size: changed(&old.size, &new.size),
            surfaces,
            rows,
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
            && self.surfaces.is_none()
            && self.rows.is_empty()
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
        if let Some(surfaces) = self.surfaces {
            frame.surfaces = surfaces;
        }
        if !self.rows.is_empty() {
            let mut slots: Vec<&mut Row> = frame
                .surfaces
                .iter_mut()
                .flat_map(|s| &mut s.rows)
                .collect();
            for (i, row) in self.rows {
                if let Some(slot) = slots.get_mut(usize::from(i)) {
                    **slot = row;
                }
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
