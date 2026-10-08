//! Layouts: the projects, tabs, panes and panels a client is shown. The
//! clients that follow share one layout, each with its own focus and zoom.
//! A client can be independent instead, with a layout of its own: a copy
//! of the one it had, with views of its own, laid out apart from then on.

use std::collections::HashMap;

use greed_text::ClientId;

use super::clients::TabState;
use super::{ClientLayout, Editor, Float, Panel, Tab, TabId, ViewId};

/// Which layout: the shared one, or an independent client's own.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(super) struct LayoutId(u64);

impl LayoutId {
    /// The layout the clients that follow share.
    pub(super) const SHARED: LayoutId = LayoutId(0);

    /// Client `id`'s own layout, while it's independent.
    fn own(id: ClientId) -> Self {
        LayoutId(u64::from(id.0) + 1)
    }
}

/// A project's tabs and panels in one layout.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Arrangement {
    /// Never empty.
    pub(super) tabs: Vec<Tab>,
    /// Which of `tabs` is shown.
    pub(super) tab: usize,
    /// Views beside the panes, outermost first on each side.
    pub(super) panels: Vec<Panel>,
}

impl Arrangement {
    pub(super) fn new(tab: Tab) -> Self {
        Self {
            tabs: vec![tab],
            tab: 0,
            panels: Vec::new(),
        }
    }

    /// Every pane of every tab, then the panels.
    pub(super) fn views(&self) -> impl Iterator<Item = ViewId> + '_ {
        self.tabs
            .iter()
            .flat_map(Tab::panes)
            .chain(self.panels.iter().map(|p| p.view))
    }

    /// Takes out tab `t`, keeping the shown tab shown if it's another one.
    pub(super) fn remove_tab(&mut self, t: usize) -> Tab {
        let tab = self.tabs.remove(t);
        if t < self.tab {
            self.tab -= 1;
        }
        self.tab = self.tab.min(self.tabs.len() - 1);
        tab
    }
}

/// What changing a client's layout did to views.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LayoutChange {
    /// The views opened for its own layout, each after the one it copies:
    /// its panes and panels, and the floats of its tabs.
    pub opened: Vec<(ViewId, ViewId)>,
    /// The views of its own layout, closed as it went back to following.
    /// Their buffers stay open.
    pub closed: Vec<ViewId>,
}

impl Editor {
    /// The acting client's layout.
    pub(super) fn layout_id(&self) -> LayoutId {
        self.acting_client().layout
    }

    /// Which project the acting client is shown, as an index.
    pub(super) fn shown_index(&self) -> usize {
        self.shown.get(&self.layout_id()).copied().unwrap_or(0)
    }

    /// Project `p`'s tabs and panels in the acting client's layout.
    pub(super) fn arrangement(&self, p: usize) -> &Arrangement {
        &self.projects[p].arrangements[&self.layout_id()]
    }

    /// The shown project's tabs and panels, as the acting client has them.
    pub(super) fn shown_arrangement(&self) -> &Arrangement {
        self.arrangement(self.shown_index())
    }

    pub(super) fn shown_arrangement_mut(&mut self) -> &mut Arrangement {
        let (layout, p) = (self.layout_id(), self.shown_index());
        self.arrangement_mut(layout, p)
    }

    /// Project `p`'s tabs and panels in `layout`.
    pub(super) fn arrangement_mut(&mut self, layout: LayoutId, p: usize) -> &mut Arrangement {
        self.projects[p]
            .arrangements
            .get_mut(&layout)
            .expect("every project is arranged in every layout")
    }

    /// The project and tab the acting client is shown, as indices; `None`
    /// before the first view opens.
    pub(super) fn shown_place(&self) -> Option<(usize, usize)> {
        let p = self.shown_index();
        let project = self.projects.get(p)?;
        Some((p, project.arrangements[&self.layout_id()].tab))
    }

    /// The layout `view` is in: the one it's a pane or panel of, or that
    /// its tab is in for a float that belongs to one. `None` for other
    /// floats, which float over every layout.
    pub(super) fn layout_of(&self, view: ViewId) -> Option<LayoutId> {
        if let Some((layout, ..)) = self.pane_position(view) {
            return Some(layout);
        }
        if let Some(float) = self.floats.iter().find(|f| f.view == view) {
            return self.tab_position(float.tab?).map(|(layout, ..)| layout);
        }
        self.projects
            .iter()
            .flat_map(|p| &p.arrangements)
            .find(|(_, a)| a.panels.iter().any(|p| p.view == view))
            .map(|(layout, _)| *layout)
    }

    /// Whether the acting client is shown `view`: a pane of its shown tab,
    /// one of its panels, or a float over them, hidden or not.
    fn is_shown(&self, view: ViewId) -> bool {
        self.views().contains_key(&view)
            && (self.current_tab().panes().contains(&view)
                || self.panels().iter().any(|p| p.view == view)
                || self.floats_hidden_too().iter().any(|f| f.view == view))
    }

    /// Moves the focus of client `id` to its main view when it isn't shown
    /// what it has focused, as when another tab is shown.
    pub(super) fn settle_focus_of(&mut self, id: ClientId) {
        let acting = std::mem::replace(&mut self.acting, id);
        if !self.projects.is_empty() && !self.is_shown(self.focus()) {
            self.focus_main();
        }
        self.acting = acting;
    }

    /// [`Editor::settle_focus_of`] for each other client sharing the acting
    /// one's layout, which has just changed what it shows.
    pub(super) fn settle_others(&mut self) {
        let (acting, layout) = (self.acting, self.layout_id());
        let others: Vec<ClientId> = self
            .clients
            .values()
            .filter(|c| c.id != acting && c.layout == layout)
            .map(|c| c.id)
            .collect();
        for id in others {
            self.settle_focus_of(id);
        }
    }

    /// Has client `id` follow the others, sharing their layout, or lays it
    /// out on its own, starting from a copy of the layout it had. Returns
    /// what that did to views; `None` without such a client, or when it's
    /// laid out that way already.
    pub fn set_layout(&mut self, id: ClientId, layout: ClientLayout) -> Option<LayoutChange> {
        if self.clients.get(&id)?.layout() == layout {
            return None;
        }
        let acting = std::mem::replace(&mut self.acting, id);
        let change = match layout {
            ClientLayout::Independent => self.copy_layout(),
            ClientLayout::Follow => self.drop_own_layout(),
        };
        self.acting = acting;
        Some(change)
    }

    /// Gives the acting client a layout of its own, copying the one it has
    /// with new views: each seen as it sees the one it copies.
    fn copy_layout(&mut self) -> LayoutChange {
        let (from, to) = (self.layout_id(), LayoutId::own(self.acting));
        let mut copies = HashMap::new();
        let mut tabs = HashMap::new();
        for p in 0..self.projects.len() {
            let original = self.projects[p].arrangements[&from].clone();
            for view in original.views() {
                let copy = self.copy_view(view);
                copies.insert(view, copy);
            }
            let mut arrangement = Arrangement {
                tabs: Vec::new(),
                tab: original.tab,
                panels: original.panels,
            };
            for tab in &original.tabs {
                let id = TabId(self.next_id());
                tabs.insert(tab.id(), id);
                arrangement.tabs.push(tab.copied(id, &copies));
            }
            for panel in &mut arrangement.panels {
                panel.view = copies[&panel.view];
            }
            self.projects[p].arrangements.insert(to, arrangement);
        }
        // The floats that belong to a tab go with its copy.
        let floats: Vec<Float> = self
            .floats
            .iter()
            .filter(|f| f.tab.is_some_and(|t| tabs.contains_key(&t)))
            .cloned()
            .collect();
        for float in floats {
            let copy = self.copy_view(float.view);
            copies.insert(float.view, copy);
            self.floats.push(Float {
                view: copy,
                tab: float.tab.map(|t| tabs[&t]),
                return_to: copies
                    .get(&float.return_to)
                    .copied()
                    .unwrap_or(float.return_to),
                ..float
            });
        }
        let renamed = |view: ViewId| copies.get(&view).copied().unwrap_or(view);
        let client = self.acting_client_mut();
        for (old, new) in &tabs {
            if let Some(state) = client.tabs.get(old) {
                let state = TabState {
                    active: renamed(state.active),
                    recent: state.recent.iter().map(|v| renamed(*v)).collect(),
                    zoomed: state.zoomed,
                    area: state.area,
                };
                client.tabs.insert(*new, state);
            }
        }
        client.focus = renamed(client.focus);
        client.layout = to;
        let shown = self.shown.get(&from).copied().unwrap_or(0);
        self.shown.insert(to, shown);
        let mut opened: Vec<(ViewId, ViewId)> = copies.into_iter().collect();
        opened.sort_unstable();
        LayoutChange {
            opened,
            closed: Vec::new(),
        }
    }

    /// A new view, for every client, seen as the acting client sees `view`
    /// but not drawn yet.
    fn copy_view(&mut self, view: ViewId) -> ViewId {
        let mut seen = self.view(view).clone();
        seen.visible = None;
        seen.size = None;
        seen.area = None;
        self.open_view(&seen)
    }

    /// Has the acting client follow again, closing the views of its own
    /// layout but keeping their buffers.
    fn drop_own_layout(&mut self) -> LayoutChange {
        let own = self.layout_id();
        let mut closed = Vec::new();
        let mut tabs = Vec::new();
        for project in &mut self.projects {
            if let Some(arrangement) = project.arrangements.remove(&own) {
                closed.extend(arrangement.views());
                tabs.extend(arrangement.tabs.iter().map(Tab::id));
            }
        }
        closed.extend(
            self.floats
                .extract_if(.., |f| f.tab.is_some_and(|t| tabs.contains(&t)))
                .map(|f| f.view),
        );
        for tab in tabs {
            self.forget_tab(tab);
        }
        for view in &closed {
            self.remove_view(*view);
        }
        self.shown.remove(&own);
        self.acting_client_mut().layout = LayoutId::SHARED;
        self.as_each_client(|ed| {
            if !ed.views().contains_key(&ed.focus()) {
                ed.focus_main();
            }
        });
        self.settle_focus_of(self.acting);
        LayoutChange {
            opened: Vec::new(),
            closed,
        }
    }
}
