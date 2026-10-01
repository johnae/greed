//! What changed between two frames, so a client that already has the first
//! can be sent much less than the second: typing a character changes one or
//! two rows, not the whole screen. This matters most for clients far away,
//! like a terminal attached over SSH.

use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::CursorShape;
use crate::render::{FloatFrame, Frame, PanelFrame, Position, Rect, Row, Size};
use crate::theme::Theme;

/// The parts of a frame that changed. Anything left out is as it was.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FrameDelta {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<Size>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub main: Option<Rect>,
    /// How many rows the frame has, when that changed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub row_count: Option<usize>,
    /// Rows that changed, by index.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rows: Vec<(u16, Row)>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub panels: Option<Vec<PanelFrame>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub floats: Option<Vec<FloatFrame>>,
    /// The cursor, when it moved, appeared or went away.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<Option<Position>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor_shape: Option<CursorShape>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub theme: Option<Arc<Theme>>,
}

/// `new` if it differs from `old`.
fn changed<T: PartialEq + Clone>(old: &T, new: &T) -> Option<T> {
    (old != new).then(|| new.clone())
}

impl FrameDelta {
    /// What turns `old` into `new`, or `None` if they're the same.
    pub fn between(old: &Frame, new: &Frame) -> Option<FrameDelta> {
        let rows = new
            .rows
            .iter()
            .enumerate()
            .filter(|(i, row)| old.rows.get(*i) != Some(row))
            .map(|(i, row)| (u16::try_from(i).unwrap_or(u16::MAX), row.clone()))
            .collect();
        // Frames from the same theme share it, so this is usually a pointer
        // comparison.
        let theme = (!Arc::ptr_eq(&old.theme, &new.theme) && old.theme != new.theme)
            .then(|| new.theme.clone());
        let delta = FrameDelta {
            size: changed(&old.size, &new.size),
            main: changed(&old.main, &new.main),
            row_count: changed(&old.rows.len(), &new.rows.len()),
            rows,
            panels: changed(&old.panels, &new.panels),
            floats: changed(&old.floats, &new.floats),
            cursor: changed(&old.cursor, &new.cursor),
            cursor_shape: changed(&old.cursor_shape, &new.cursor_shape),
            theme,
        };
        (!delta.is_empty()).then_some(delta)
    }

    fn is_empty(&self) -> bool {
        self.size.is_none()
            && self.main.is_none()
            && self.row_count.is_none()
            && self.rows.is_empty()
            && self.panels.is_none()
            && self.floats.is_none()
            && self.cursor.is_none()
            && self.cursor_shape.is_none()
            && self.theme.is_none()
    }

    /// Turns `frame` (the old frame this delta was made against) into the
    /// new one.
    pub fn apply(self, frame: &mut Frame) {
        if let Some(size) = self.size {
            frame.size = size;
        }
        if let Some(main) = self.main {
            frame.main = main;
        }
        if let Some(count) = self.row_count {
            frame.rows.resize_with(count, Row::default);
        }
        for (i, row) in self.rows {
            if let Some(slot) = frame.rows.get_mut(usize::from(i)) {
                *slot = row;
            }
        }
        if let Some(panels) = self.panels {
            frame.panels = panels;
        }
        if let Some(floats) = self.floats {
            frame.floats = floats;
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
    }
}
