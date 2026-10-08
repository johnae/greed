//! Tabs and panes: each project has tabs in each layout, each tab a tree of
//! panes (see [`crate::layout`]), and the shown tab's active pane is the
//! main view. The clients that follow share the trees; which pane is
//! active, and whether only it shows, is each client's own.

use std::collections::HashMap;
use std::ops::Deref;
use std::sync::Arc;

use greed_text::Selection;

use super::clients::TabState;
use super::layouts::{Arrangement, LayoutId};
use super::{Editor, Extent, Side, ViewId};
use crate::layout::{Direction, Line, Node};
use crate::render::Rect;
use crate::{Buffer, BufferId};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct TabId(pub u32);

/// A tab: its panes, laid out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tab {
    id: TabId,
    name: Option<Arc<str>>,
    layout: Node,
}

impl Tab {
    pub(super) fn new(id: TabId, pane: ViewId) -> Self {
        Self {
            id,
            name: None,
            layout: Node::Pane(pane),
        }
    }

    pub fn id(&self) -> TabId {
        self.id
    }

    /// A copy of it as tab `id`, each pane `p` replaced with `copies[p]`.
    pub(super) fn copied(&self, id: TabId, copies: &HashMap<ViewId, ViewId>) -> Self {
        let mut layout = self.layout.clone();
        layout.rename(&|pane| copies.get(&pane).copied().unwrap_or(pane));
        Self {
            id,
            name: self.name.clone(),
            layout,
        }
    }

    /// The name it was given, if any.
    pub fn name(&self) -> Option<&str> {
        self.name.as_deref()
    }

    /// Its panes, left to right and top to bottom.
    pub fn panes(&self) -> Vec<ViewId> {
        self.layout.panes()
    }
}

/// A tab as the acting client has it.
#[derive(Debug, Clone, Copy)]
pub struct TabView<'a> {
    tab: &'a Tab,
    active: ViewId,
    zoomed: bool,
    area: Option<Rect>,
}

impl Deref for TabView<'_> {
    type Target = Tab;

    fn deref(&self) -> &Tab {
        self.tab
    }
}

impl TabView<'_> {
    /// The pane keys go to while the tab is shown.
    pub fn active(&self) -> ViewId {
        self.active
    }

    /// Where its panes went when it was last drawn.
    pub fn area(&self) -> Option<Rect> {
        self.area
    }

    /// Whether only the active pane is shown, filling the tab.
    pub fn zoomed(&self) -> bool {
        self.zoomed
    }

    /// Where its panes go in `rect`, and the lines between them: only the
    /// active pane when zoomed.
    pub fn place(&self, rect: Rect) -> (Vec<(ViewId, Rect)>, Vec<Line>) {
        if self.zoomed {
            return (vec![(self.active, rect)], Vec::new());
        }
        let (mut panes, mut lines) = (Vec::new(), Vec::new());
        self.tab.layout.place(rect, &mut panes, &mut lines);
        (panes, lines)
    }
}

/// Whether `b` touches `a` on its `dir` side, across the line between them.
fn beside(a: Rect, b: Rect, dir: Direction) -> bool {
    // In u32, so a rect at the screen's far edge doesn't overflow.
    let [ax, ay, aw, ah, bx, by, bw, bh] =
        [a.x, a.y, a.width, a.height, b.x, b.y, b.width, b.height].map(u32::from);
    let overlap = |a0: u32, a1: u32, b0: u32, b1: u32| a0.max(b0) < a1.min(b1);
    let across = overlap(ay, ay + ah, by, by + bh);
    let down = overlap(ax, ax + aw, bx, bx + bw);
    match dir {
        Direction::Right => across && bx == ax + aw + 1,
        Direction::Left => across && ax == bx + bw + 1,
        Direction::Down => down && by == ay + ah + 1,
        Direction::Up => down && ay == by + bh + 1,
    }
}

/// Where a tab is: its layout, its project's index, and its own index in
/// that project's arrangement.
pub(super) type TabPosition = (LayoutId, usize, usize);

impl Editor {
    /// Where the first tab that `matches` is, in whichever layout and
    /// project.
    fn find_tab(&self, matches: impl Fn(&Tab) -> bool) -> Option<TabPosition> {
        self.projects.iter().enumerate().find_map(|(p, project)| {
            project
                .arrangements
                .iter()
                .find_map(|(layout, arrangement)| {
                    let t = arrangement.tabs.iter().position(&matches)?;
                    Some((*layout, p, t))
                })
        })
    }

    /// Where the tab that `view` is a pane of is.
    pub(super) fn pane_position(&self, view: ViewId) -> Option<TabPosition> {
        self.find_tab(|t| t.layout.contains(view))
    }

    /// Whether `view` is a pane, rather than a panel or a floating view.
    pub fn is_pane(&self, view: ViewId) -> bool {
        self.pane_position(view).is_some()
    }

    /// Where tab `id` is.
    pub(super) fn tab_position(&self, id: TabId) -> Option<TabPosition> {
        self.find_tab(|t| t.id == id)
    }

    fn arrangement_at_mut(&mut self, (layout, p, _): TabPosition) -> &mut Arrangement {
        self.arrangement_mut(layout, p)
    }

    fn tab_at(&self, (layout, p, t): TabPosition) -> &Tab {
        &self.projects[p].arrangements[&layout].tabs[t]
    }

    fn tab_at_mut(&mut self, at: TabPosition) -> &mut Tab {
        &mut self.arrangement_at_mut(at).tabs[at.2]
    }

    fn tab_mut(&mut self, id: TabId) -> Option<&mut Tab> {
        let at = self.tab_position(id)?;
        Some(self.tab_at_mut(at))
    }

    /// `tab` as the acting client has it.
    pub(super) fn tab_view<'a>(&'a self, tab: &'a Tab) -> TabView<'a> {
        let (active, zoomed, area) = match self.acting_client().tabs.get(&tab.id) {
            Some(state) => (state.active, state.zoomed, state.area),
            None => (tab.layout.panes()[0], false, None),
        };
        TabView {
            tab,
            active,
            zoomed,
            area,
        }
    }

    /// The acting client's state of tab `id`, which starts out with the
    /// tab's first pane active.
    fn tab_state_mut(&mut self, id: TabId) -> &mut TabState {
        let first = self
            .tab_position(id)
            .map_or(ViewId(0), |at| self.tab_at(at).layout.panes()[0]);
        self.acting_client_mut()
            .tabs
            .entry(id)
            .or_insert_with(|| TabState::new(first))
    }

    /// Makes `view` its tab's active pane and shows its tab, and the project
    /// it's a pane or panel of, in the acting client's layout.
    pub(super) fn activate(&mut self, view: ViewId) {
        let layout = self.layout_id();
        let before = self.shown_place();
        if let Some(at @ (l, p, t)) = self.pane_position(view) {
            if l == layout {
                self.shown.insert(layout, p);
                self.arrangement_at_mut(at).tab = t;
            }
            let id = self.tab_at(at).id;
            self.tab_state_mut(id).activate(view);
        } else if let Some(p) = self.projects.iter().position(|project| {
            project.arrangements[&layout]
                .panels
                .iter()
                .any(|panel| panel.view == view)
        }) {
            self.shown.insert(layout, p);
        }
        if self.shown_place() != before {
            self.settle_others();
        }
    }

    /// The shown project's tabs.
    pub fn tabs(&self) -> Vec<TabView<'_>> {
        let arrangement = self.shown_arrangement();
        arrangement.tabs.iter().map(|t| self.tab_view(t)).collect()
    }

    pub fn current_tab(&self) -> TabView<'_> {
        let arrangement = self.shown_arrangement();
        self.tab_view(&arrangement.tabs[arrangement.tab])
    }

    /// The acting client's state of the shown tab.
    fn current_tab_state_mut(&mut self) -> &mut TabState {
        let id = self.current_tab().id;
        self.tab_state_mut(id)
    }

    /// The active pane of project `p`'s shown tab, as the acting client has
    /// it.
    pub(super) fn main_of(&self, p: usize) -> ViewId {
        let arrangement = self.arrangement(p);
        self.tab_view(&arrangement.tabs[arrangement.tab]).active
    }

    /// Remembers where the shown tab's panes were drawn, for resizing.
    pub(crate) fn set_tab_area(&mut self, area: Rect) {
        self.current_tab_state_mut().area = Some(area);
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
        let at = self.pane_position(view)?;
        let new = match buffer {
            Some(buffer) => self.add_view(buffer, Selection::point(0)),
            None => self.split(view),
        };
        let tab = self.tab_at_mut(at);
        tab.layout.insert(view, new, dir);
        let id = tab.id;
        self.tab_state_mut(id).zoomed = false;
        self.set_focus(new);
        Some(new)
    }

    /// Takes pane `view` out of its tab, closing the tab if it was the last
    /// pane. False for the project's last pane. Not a pane: true, nothing
    /// to do.
    pub(super) fn remove_pane(&mut self, view: ViewId) -> bool {
        let Some(at) = self.pane_position(view) else {
            return true;
        };
        let arrangement = self.arrangement_at_mut(at);
        let tab = &mut arrangement.tabs[at.2];
        if tab.layout == Node::Pane(view) {
            if arrangement.tabs.len() == 1 {
                return false;
            }
            let gone = arrangement.remove_tab(at.2).id;
            self.forget_tab(gone);
            return true;
        }
        tab.layout.remove(view);
        let (id, first) = (tab.id, tab.layout.panes()[0]);
        for client in self.clients.values_mut() {
            let Some(state) = client.tabs.get_mut(&id) else {
                continue;
            };
            state.recent.retain(|v| *v != view);
            if state.active == view {
                state.active = state.recent.last().copied().unwrap_or(first);
            }
        }
        true
    }

    /// Drops every client's state of tab `id`, which closed.
    pub(super) fn forget_tab(&mut self, id: TabId) {
        for client in self.clients.values_mut() {
            client.tabs.remove(&id);
        }
    }

    /// The pane next to `view` on its `dir` side in its tab, as last drawn:
    /// of several, the one active most recently. In the shown tab, panels
    /// count too, and `view` may be one.
    pub fn neighbor(&self, view: ViewId, dir: Direction) -> Option<ViewId> {
        let panels: Vec<ViewId> = self.panels().iter().map(|p| p.view).collect();
        let tab = match self.pane_position(view) {
            Some(at) => self.tab_at(at),
            None if panels.contains(&view) => {
                let shown = self.shown_arrangement();
                &shown.tabs[shown.tab]
            }
            None => return None,
        };
        let mut candidates = tab.layout.panes();
        if tab.id == self.current_tab().id {
            candidates.extend(panels);
        }
        let recent = self
            .acting_client()
            .tabs
            .get(&tab.id)
            .map_or(&[][..], |state| &state.recent);
        let from = self.find_view(view)?.area?;
        candidates
            .into_iter()
            .filter(|v| *v != view)
            .filter(|v| {
                self.find_view(*v)
                    .and_then(|v| v.area)
                    .is_some_and(|area| beside(from, area, dir))
            })
            .max_by_key(|v| recent.iter().position(|r| r == v))
    }

    /// Moves pane `view`'s edge on its `dir` side by `cells`. False when
    /// there's no pane on that side, or the tab hasn't been drawn. A panel
    /// moves its edge toward the main view, its only side that moves.
    pub fn resize_pane(&mut self, view: ViewId, dir: Direction, cells: i32) -> bool {
        let Some(at) = self.pane_position(view) else {
            return self.resize_panel(view, dir, cells);
        };
        let Some(area) = self.tab_view(self.tab_at(at)).area else {
            return false;
        };
        self.tab_at_mut(at).layout.resize(view, dir, cells, area)
    }

    /// Moves panel `view`'s edge by the main view by `cells`, when `dir`
    /// points that way. False otherwise, or before it's drawn.
    fn resize_panel(&mut self, view: ViewId, dir: Direction, cells: i32) -> bool {
        let Some(width) = self.find_view(view).and_then(|v| v.area).map(|a| a.width) else {
            return false;
        };
        let arrangement = self.shown_arrangement_mut();
        let Some(panel) = arrangement.panels.iter_mut().find(|p| p.view == view) else {
            return false;
        };
        let inward = match panel.options.side {
            Side::Left => Direction::Right,
            Side::Right => Direction::Left,
        };
        if dir != inward {
            return false;
        }
        let width = i32::from(width)
            .saturating_add(cells)
            .clamp(1, i32::from(u16::MAX));
        panel.options.width = Extent::Cells(u16::try_from(width).unwrap_or(1));
        true
    }

    /// Shows only the active pane of the shown tab, or all of them again,
    /// for the acting client alone.
    pub fn set_zoomed(&mut self, zoomed: bool) {
        self.current_tab_state_mut().zoomed = zoomed;
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
        let arrangement = self.shown_arrangement_mut();
        arrangement.tab += 1;
        arrangement.tabs.insert(arrangement.tab, Tab::new(id, view));
        self.acting_client_mut()
            .tabs
            .insert(id, TabState::new(view));
        self.settle_others();
        id
    }

    /// Shows tab `id`, and the project it's in. False if there's no such
    /// tab in the acting client's layout.
    pub fn switch_tab(&mut self, id: TabId) -> bool {
        let Some(at @ (layout, p, t)) = self.tab_position(id) else {
            return false;
        };
        if layout != self.layout_id() {
            return false;
        }
        self.shown.insert(layout, p);
        self.arrangement_at_mut(at).tab = t;
        self.focus_main();
        self.settle_others();
        true
    }

    /// Closes tab `id` and its panes, returning the views that closed. `None`
    /// for its project's last tab, or no such tab.
    pub fn close_tab(&mut self, id: TabId) -> Option<Vec<ViewId>> {
        let at = self.tab_position(id)?;
        let arrangement = self.arrangement_at_mut(at);
        if arrangement.tabs.len() == 1 {
            return None;
        }
        let mut panes = arrangement.remove_tab(at.2).panes();
        self.forget_tab(id);
        // Its floats go with it.
        panes.extend(
            self.floats
                .extract_if(.., |f| f.tab == Some(id))
                .map(|f| f.view),
        );
        for view in &panes {
            if let Some(closed) = self.remove_view(*view) {
                self.drop_if_unused(closed.buffer);
            }
        }
        self.as_each_client(|ed| {
            if !ed.views().contains_key(&ed.focus()) {
                ed.focus_main();
            }
        });
        self.settle_others();
        Some(panes)
    }

    /// How tab `id` lays out its panes.
    pub fn tab_layout(&self, id: TabId) -> Option<&Node> {
        let at = self.tab_position(id)?;
        Some(&self.tab_at(at).layout)
    }

    /// Lays out tab `id`'s panes as `layout` instead, which has to hold
    /// exactly the panes it has: this arranges them, opening and closing
    /// panes is done elsewhere.
    pub fn set_tab_layout(&mut self, id: TabId, layout: Node) -> Result<(), String> {
        let tab = self.tab_mut(id).ok_or("there's no such tab")?;
        let (mut now, mut given) = (tab.layout.panes(), layout.panes());
        now.sort();
        given.sort();
        if now != given {
            return Err("a layout has to hold every pane of the tab, each once".to_owned());
        }
        if !layout.is_whole() {
            return Err("every split needs at least one child".to_owned());
        }
        tab.layout = layout;
        Ok(())
    }

    /// Names tab `id`, or with `None` lets it be named after what it shows.
    pub fn rename_tab(&mut self, id: TabId, name: Option<Arc<str>>) -> bool {
        let Some(tab) = self.tab_mut(id) else {
            return false;
        };
        tab.name = name;
        true
    }
}
