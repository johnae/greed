//! What's under a screen cell, for the mouse: a view and the place in its
//! buffer, or a tab in the tab line. Worked out from where things were last
//! drawn.

use super::{Measure, Rect, Renderer, hidden_lines, is_hidden, tab_label};
use std::sync::Arc;

use crate::{Editor, Side, TabId, ViewId};

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
    /// On a floating view's border, which part: "top" (where the title
    /// is), "bottom", "left", "right", or a corner like "bottom-right".
    pub border: Option<&'static str>,
    /// On the line between a pane or panel (`view`) and its neighbor, the
    /// side of `view` it's on: "right" or "down" for panes, the side
    /// toward the main view for panels. Dragging it resizes `view`.
    pub edge: Option<&'static str>,
}

fn inside(rect: Rect, col: u16, row: u16) -> bool {
    (rect.x..rect.x + rect.width).contains(&col) && (rect.y..rect.y + rect.height).contains(&row)
}

/// Which part of the border around `area` (one cell outside it) is at
/// (`col`, `row`), if any.
fn border_at(area: Rect, col: u16, row: u16) -> Option<&'static str> {
    let (left, top) = (area.x.checked_sub(1)?, area.y.checked_sub(1)?);
    let (right, bottom) = (area.x + area.width, area.y + area.height);
    if !(left..=right).contains(&col) || !(top..=bottom).contains(&row) {
        return None;
    }
    let side = |low: bool, high: bool| match (low, high) {
        (true, _) => 0,
        (_, true) => 2,
        _ => 1,
    };
    let names = [
        ["top-left", "top", "top-right"],
        ["left", "", "right"],
        ["bottom-left", "bottom", "bottom-right"],
    ];
    let name = names[side(row == top, row == bottom)][side(col == left, col == right)];
    (!name.is_empty()).then_some(name)
}

/// The line between panes, or between a panel and the main view, at
/// (`col`, `row`), if one is there.
fn edge_at(editor: &Editor, col: u16, row: u16) -> Option<Hit> {
    let found = |view, edge| Hit {
        view: Some(view),
        edge: Some(edge),
        ..Hit::default()
    };
    let area = |view| editor.find_view(view).and_then(|v| v.area);
    for panel in editor.panels() {
        let Some(a) = area(panel.view) else {
            continue;
        };
        // A panel's title is on the row above its area.
        if !(a.y.saturating_sub(1)..a.y + a.height).contains(&row) {
            continue;
        }
        match panel.options.side {
            Side::Left if col == a.x + a.width => return Some(found(panel.view, "right")),
            Side::Right if col + 1 == a.x => return Some(found(panel.view, "left")),
            _ => {}
        }
    }
    let tab = editor.current_tab();
    if tab.zoomed() {
        return None;
    }
    for view in tab.panes() {
        let Some(a) = area(view) else {
            continue;
        };
        if col == a.x + a.width && (a.y..a.y + a.height).contains(&row) {
            return Some(found(view, "right"));
        }
        if row == a.y + a.height && (a.x..a.x + a.width).contains(&col) {
            return Some(found(view, "down"));
        }
    }
    None
}

impl<M: Measure> Renderer<M> {
    /// What's at (`col`, `row`) on screen: a status line segment with an
    /// action, floating views, then panels, then the shown tab's panes.
    pub fn hit(&self, editor: &Editor, col: u16, row: u16) -> Hit {
        if let Some(action) = self.status_action_at(col, row) {
            return Hit {
                action: Some(action),
                ..Hit::default()
            };
        }
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
            .into_iter()
            .rev()
            .map(|f| (f.view, true))
            .chain(editor.panels().iter().map(|p| (p.view, false)))
            .chain(panes.into_iter().map(|v| (v, false)));
        for (view_id, floating) in candidates {
            let Some(view) = editor.find_view(view_id) else {
                continue;
            };
            let (Some(area), Some((_, cols))) = (view.area, view.size) else {
                continue;
            };
            if !inside(area, col, row) {
                // A float's border is part of it, for moving and resizing it.
                if floating && let Some(border) = border_at(area, col, row) {
                    return Hit {
                        view: Some(view_id),
                        border: Some(border),
                        ..Hit::default()
                    };
                }
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
                ..Hit::default()
            };
        }
        edge_at(editor, col, row).unwrap_or_default()
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
                // A scaled row takes more than one screen row; any of them
                // finds it.
                let height = super::row_height(&cells);
                if (row..row + height).contains(&usize::from(y)) {
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
                row += height;
            }
            row += super::virtual_lines(editor, view, line).count();
            if row > usize::from(y) {
                return None;
            }
        }
        None
    }
}
