//! Tabs and panes: each project has tabs, each tab a tree of panes (see
//! [`crate::layout`]), and the shown tab's active pane is the main view.

use std::sync::Arc;

use kern_text::Selection;

use super::{Editor, Project, ViewId};
use crate::layout::{Direction, Line, Node};
use crate::render::Rect;
use crate::{Buffer, BufferId};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct TabId(pub u32);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tab {
    id: TabId,
    name: Option<Arc<str>>,
    layout: Node,
    /// The pane keys go to while the tab is shown.
    active: ViewId,
    /// Panes in the order they were last active, the latest last, so moving
    /// left and back right returns to the same pane.
    recent: Vec<ViewId>,
    /// Only the active pane is shown, filling the tab.
    zoomed: bool,
    /// Where the panes went when the tab was last drawn.
    area: Option<Rect>,
}

impl Tab {
    pub(super) fn new(id: TabId, pane: ViewId) -> Self {
        Self {
            id,
            name: None,
            layout: Node::Pane(pane),
            active: pane,
            recent: vec![pane],
            zoomed: false,
            area: None,
        }
    }

    pub fn id(&self) -> TabId {
        self.id
    }

    /// The name it was given, if any.
    pub fn name(&self) -> Option<&str> {
        self.name.as_deref()
    }

    pub fn active(&self) -> ViewId {
        self.active
    }

    /// Where its panes went when it was last drawn.
    pub fn area(&self) -> Option<Rect> {
        self.area
    }

    pub fn zoomed(&self) -> bool {
        self.zoomed
    }

    /// Its panes, left to right and top to bottom.
    pub fn panes(&self) -> Vec<ViewId> {
        self.layout.panes()
    }

    fn activate(&mut self, view: ViewId) {
        self.active = view;
        self.recent.retain(|v| *v != view);
        self.recent.push(view);
    }

    /// Where its panes go in `rect`, and the lines between them: only the
    /// active pane when zoomed.
    pub fn place(&self, rect: Rect) -> (Vec<(ViewId, Rect)>, Vec<Line>) {
        if self.zoomed {
            return (vec![(self.active, rect)], Vec::new());
        }
        let (mut panes, mut lines) = (Vec::new(), Vec::new());
        self.layout.place(rect, &mut panes, &mut lines);
        (panes, lines)
    }
}

/// Whether `b` touches `a` on its `dir` side, across the line between them.
fn beside(a: Rect, b: Rect, dir: Direction) -> bool {
    let overlap = |a0: u16, a1: u16, b0: u16, b1: u16| a0.max(b0) < a1.min(b1);
    let across = overlap(a.y, a.y + a.height, b.y, b.y + b.height);
    let down = overlap(a.x, a.x + a.width, b.x, b.x + b.width);
    match dir {
        Direction::Right => across && b.x == a.x + a.width + 1,
        Direction::Left => across && a.x == b.x + b.width + 1,
        Direction::Down => down && b.y == a.y + a.height + 1,
        Direction::Up => down && a.y == b.y + b.height + 1,
    }
}

impl Project {
    /// Takes out tab `t`, keeping the shown tab shown if it's another one.
    fn remove_tab(&mut self, t: usize) -> Tab {
        let tab = self.tabs.remove(t);
        if t < self.tab {
            self.tab -= 1;
        }
        self.tab = self.tab.min(self.tabs.len() - 1);
        tab
    }
}

impl Editor {
    /// The project and tab `view` is a pane of.
    fn pane_position(&self, view: ViewId) -> Option<(usize, usize)> {
        self.projects.iter().enumerate().find_map(|(p, project)| {
            let t = project.tabs.iter().position(|t| t.layout.contains(view))?;
            Some((p, t))
        })
    }

    /// Whether `view` is a pane, rather than a panel or a floating view.
    pub fn is_pane(&self, view: ViewId) -> bool {
        self.pane_position(view).is_some()
    }

    /// Makes `view` its tab's active pane, and its tab the shown one, if
    /// it's a pane of the current project.
    pub(super) fn activate(&mut self, view: ViewId) {
        let project = &mut self.projects[self.current];
        if let Some(t) = project.tabs.iter().position(|t| t.layout.contains(view)) {
            project.tab = t;
            project.tabs[t].activate(view);
        }
    }

    /// The shown project's tabs.
    pub fn tabs(&self) -> &[Tab] {
        &self.current_project().tabs
    }

    pub fn current_tab(&self) -> &Tab {
        let project = self.current_project();
        &project.tabs[project.tab]
    }

    fn current_tab_mut(&mut self) -> &mut Tab {
        let project = &mut self.projects[self.current];
        &mut project.tabs[project.tab]
    }

    /// Remembers where the shown tab's panes were drawn, for resizing.
    pub(crate) fn set_tab_area(&mut self, area: Rect) {
        self.current_tab_mut().area = Some(area);
    }

    /// Opens a pane beside `view` on its `dir` side, showing `buffer`, or
    /// `view`'s buffer as `view` shows it, and focuses it. `None` if
    /// `view` isn't a pane.
    pub fn split_pane(
        &mut self,
        view: ViewId,
        dir: Direction,
        buffer: Option<BufferId>,
    ) -> Option<ViewId> {
        let (p, t) = self.pane_position(view)?;
        let new = match buffer {
            Some(buffer) => self.add_view(buffer, Selection::point(0)),
            None => self.split(view),
        };
        let tab = &mut self.projects[p].tabs[t];
        tab.layout.insert(view, new, dir);
        tab.zoomed = false;
        self.set_focus(new);
        Some(new)
    }

    /// Takes pane `view` out of its tab, closing the tab if it was the last
    /// pane. False for the project's last pane. Not a pane: true, nothing
    /// to do.
    pub(super) fn remove_pane(&mut self, view: ViewId) -> bool {
        let Some((p, t)) = self.pane_position(view) else {
            return true;
        };
        let project = &mut self.projects[p];
        let tab = &mut project.tabs[t];
        if tab.layout == Node::Pane(view) {
            if project.tabs.len() == 1 {
                return false;
            }
            project.remove_tab(t);
            return true;
        }
        tab.layout.remove(view);
        tab.recent.retain(|v| *v != view);
        if tab.active == view {
            tab.active = match tab.recent.last() {
                Some(view) => *view,
                None => tab.layout.panes()[0],
            };
        }
        true
    }

    /// The pane next to `view` on its `dir` side in its tab, as last drawn:
    /// of several, the one active most recently.
    pub fn neighbor(&self, view: ViewId, dir: Direction) -> Option<ViewId> {
        let (p, t) = self.pane_position(view)?;
        let tab = &self.projects[p].tabs[t];
        let from = self.views.get(&view)?.area?;
        tab.layout
            .panes()
            .into_iter()
            .filter(|v| *v != view)
            .filter(|v| {
                self.views
                    .get(v)
                    .and_then(|v| v.area)
                    .is_some_and(|area| beside(from, area, dir))
            })
            .max_by_key(|v| tab.recent.iter().position(|r| r == v))
    }

    /// Moves pane `view`'s edge on its `dir` side by `cells`. False when
    /// there's no pane on that side, or the tab hasn't been drawn.
    pub fn resize_pane(&mut self, view: ViewId, dir: Direction, cells: i32) -> bool {
        let Some((p, t)) = self.pane_position(view) else {
            return false;
        };
        let tab = &mut self.projects[p].tabs[t];
        let Some(area) = tab.area else {
            return false;
        };
        tab.layout.resize(view, dir, cells, area)
    }

    /// Shows only the active pane of the shown tab, or all of them again.
    pub fn set_zoomed(&mut self, zoomed: bool) {
        self.current_tab_mut().zoomed = zoomed;
    }

    /// Opens a tab after the shown one with a pane showing `buffer` (or an
    /// empty one), and shows it.
    pub fn new_tab(&mut self, buffer: Option<BufferId>) -> TabId {
        let buffer = buffer.unwrap_or_else(|| {
            let id = BufferId(self.next_id());
            self.insert_buffer(Buffer::new(id, "file", ""));
            id
        });
        let view = self.add_view(buffer, Selection::point(0));
        let id = TabId(self.next_id());
        let project = &mut self.projects[self.current];
        project.tab += 1;
        project.tabs.insert(project.tab, Tab::new(id, view));
        id
    }

    /// Shows tab `id` of the shown project. False if there's no such tab.
    pub fn switch_tab(&mut self, id: TabId) -> bool {
        let project = &mut self.projects[self.current];
        let Some(t) = project.tabs.iter().position(|tab| tab.id == id) else {
            return false;
        };
        project.tab = t;
        self.focus = project.tabs[t].active;
        true
    }

    /// Closes tab `id` and its panes, returning the views that closed. `None`
    /// for the last tab, or no such tab.
    pub fn close_tab(&mut self, id: TabId) -> Option<Vec<ViewId>> {
        let project = &mut self.projects[self.current];
        let t = project.tabs.iter().position(|tab| tab.id == id)?;
        if project.tabs.len() == 1 {
            return None;
        }
        let panes = project.remove_tab(t).panes();
        let main = project.main();
        for view in &panes {
            if let Some(closed) = self.views.remove(view) {
                self.drop_if_unused(closed.buffer);
            }
        }
        if !self.views.contains_key(&self.focus) {
            self.focus = main;
        }
        Some(panes)
    }

    /// Names tab `id`, or with `None` lets it be named after what it shows.
    pub fn rename_tab(&mut self, id: TabId, name: Option<Arc<str>>) -> bool {
        let project = &mut self.projects[self.current];
        match project.tabs.iter_mut().find(|tab| tab.id == id) {
            Some(tab) => {
                tab.name = name;
                true
            }
            None => false,
        }
    }
}
