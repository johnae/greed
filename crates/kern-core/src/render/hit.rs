//! What's under a screen cell, for the mouse: a view and the place in its
//! buffer, or a tab in the tab line. Worked out from where things were last
//! drawn.

use super::{Measure, Rect, Renderer, hidden_lines, is_hidden, tab_label};
use std::sync::Arc;

use crate::{Editor, TabId, ViewId};

/// What a screen cell shows.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Hit {
    pub view: Option<ViewId>,
    /// The byte under the cell, or the end of its line past the end. On a
    /// mark's text, where the mark starts.
    pub pos: Option<usize>,
    /// The action of the mark whose text is under the cell, if it has one.
    pub action: Option<Arc<str>>,
    /// The cell, counted from the top left of the view's text, right of
    /// its gutter.
    pub x: u16,
    pub y: u16,
    pub tab: Option<TabId>,
}

fn inside(rect: Rect, col: u16, row: u16) -> bool {
    (rect.x..rect.x + rect.width).contains(&col) && (rect.y..rect.y + rect.height).contains(&row)
}

impl<M: Measure> Renderer<M> {
    /// What's at (`col`, `row`) on screen: floating views first, then
    /// panels, then the shown tab's panes.
    pub fn hit(&self, editor: &Editor, col: u16, row: u16) -> Hit {
        if let Some(tab) = self.tab_at(editor, col, row) {
            return Hit {
                tab: Some(tab),
                ..Hit::default()
            };
        }
        let tab = editor.current_tab();
        let panes = if tab.zoomed() {
            vec![tab.active()]
        } else {
            tab.panes()
        };
        let candidates = editor
            .floats()
            .iter()
            .rev()
            .map(|f| f.view)
            .chain(editor.panels().iter().map(|p| p.view))
            .chain(panes);
        for view_id in candidates {
            let Some(view) = editor.find_view(view_id) else {
                continue;
            };
            let (Some(area), Some((_, cols))) = (view.area, view.size) else {
                continue;
            };
            if !inside(area, col, row) {
                continue;
            }
            let gutter = area.width.saturating_sub(cols);
            let x = (col - area.x).saturating_sub(gutter);
            let y = row - area.y;
            let button = self
                .actions
                .borrow()
                .iter()
                .find(|a| a.view == view_id && a.row == row && a.cols.contains(&col))
                .map(|a| (a.action.clone(), a.at));
            let (action, pos) = match button {
                Some((action, at)) => (Some(action), Some(at)),
                None => (None, self.byte_at(editor, view_id, x, y)),
            };
            return Hit {
                view: Some(view_id),
                pos,
                action,
                x,
                y,
                tab: None,
            };
        }
        Hit::default()
    }

    /// The tab whose label is at (`col`, `row`) in the tab line, if one is.
    fn tab_at(&self, editor: &Editor, col: u16, row: u16) -> Option<TabId> {
        let tabs = editor.tabs();
        let area = editor.current_tab().area()?;
        if tabs.len() < 2 || row + 1 != area.y {
            return None;
        }
        let mut x = usize::from(area.x);
        for (i, tab) in tabs.iter().enumerate() {
            let width = self.text_width(&tab_label(editor, i, tab));
            if (x..x + width).contains(&usize::from(col)) {
                return Some(tab.id());
            }
            x += width;
        }
        None
    }

    /// The byte at text cell (`x`, `y`) of `view` as last drawn: the
    /// character there, or the end of the line when past it. `None` below
    /// the text, or on a line that isn't in the buffer.
    pub fn byte_at(&self, editor: &Editor, view_id: ViewId, x: u16, y: u16) -> Option<usize> {
        let view = editor.find_view(view_id)?;
        let width = usize::from(view.size?.1);
        let text = editor.buffer(view.buffer).text();
        let hidden = hidden_lines(editor, view);
        let mut row = 0;
        for line in view.scroll.line..text.len_lines() {
            if is_hidden(&hidden, line) {
                continue;
            }
            let skip = if line == view.scroll.line {
                view.scroll.row
            } else {
                0
            };
            for cells in self
                .layout(editor, view, line, width)
                .into_iter()
                .skip(skip)
            {
                if row == usize::from(y) {
                    let mut left = 0;
                    let mut last = None;
                    for cell in cells.iter().filter(|c| c.inserted.is_none()) {
                        if usize::from(x) < left + cell.width {
                            return Some(cell.byte);
                        }
                        left += cell.width;
                        last = Some(cell.byte);
                    }
                    return last;
                }
                row += 1;
            }
            row += super::virtual_lines(editor, view, line).count();
            if row > usize::from(y) {
                return None;
            }
        }
        None
    }
}
