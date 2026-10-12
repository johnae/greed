//! What belongs to each person using the editor rather than to the editor
//! itself: where their focus and cursors are, how far each view is
//! scrolled for them, their mode and half-typed keys, their undo group, and
//! what's waiting to be sent to their client. Buffers and floats are
//! shared, and so are tabs and panes between the clients that follow. The
//! editor acts for one client at a time, the acting one, and its methods
//! read and change that one's state.

use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;

use greed_text::ClientId;

use super::{LayoutId, Notice, SwitchTo, TabId, View, ViewId};
use crate::keymap::Key;
use crate::render::Rect;

/// The client every editor has from the start: the one in a headless
/// editor, in tests and for `greed ctl`, and the first to attach.
pub const FIRST_CLIENT: ClientId = ClientId(1);

/// One person's state in the editor.
#[derive(Debug, Clone)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "each says something of its own about the client"
)]
pub struct ClientState {
    pub(super) id: ClientId,
    /// What it's called, like "tui@laptop": its kind and machine. A client
    /// coming back with the same name gets its state back.
    pub(super) name: Arc<str>,
    /// What sort of client it is: "tui", "gui", "headless" or "test".
    pub(super) kind: Arc<str>,
    /// Whether it came over `greed ssh`.
    pub(super) remote: bool,
    /// Its screen's width and height in cells, once it has said.
    pub(super) size: Option<(u16, u16)>,
    /// Which of the peer colors, 1 to [`PEER_COLORS`], its cursors show in
    /// for the others.
    pub(super) color: u8,
    /// The tabs and panels it's shown: [`LayoutId::SHARED`] while it
    /// follows, its own while it's independent.
    pub(super) layout: LayoutId,
    /// When it last did something, as a count that only goes up.
    pub(super) active_at: u64,
    /// It went, and its state waits for it to come back by its name.
    pub(super) parked: bool,
    /// The view keys go to.
    pub(super) focus: ViewId,
    /// Its focus was moved under it, by another client's doing or by
    /// following again, since it was last told of a focus change.
    pub(super) moved: bool,
    /// Every open view as this client sees it: its selection and scroll.
    /// Each client has every view.
    pub(super) views: BTreeMap<ViewId, View>,
    /// Each tab's active pane and the like, for this client.
    pub(super) tabs: HashMap<TabId, TabState>,
    pub(super) mode: Arc<str>,
    pub(super) pending: Vec<Key>,
    /// A count typed before the pending keys.
    pub(super) count: Option<u32>,
    /// Single keys bound for the next key press only, over every layer;
    /// any other key drops them and goes through the keymap as usual.
    pub(super) overlay: Option<HashMap<Key, Arc<str>>>,
    /// Edits made while a group is open become one undo step.
    pub(super) undo_group: Option<u64>,
    /// The latest copy, until the client has been told.
    pub(super) copied: Option<String>,
    /// Notifications for the client, until it has been told.
    pub(super) notices: Vec<Notice>,
    /// Requests for the image on the client's system clipboard, until it
    /// has been asked.
    pub(super) image_asks: Vec<u64>,
    /// The client asked to leave, with the editor running on.
    pub(super) detach_requested: bool,
    /// Where the client was asked to go instead of this session.
    pub(super) switch_requested: Option<SwitchTo>,
    /// How many pixels wide and high a cell is on the client's screen, for
    /// sizing images.
    pub(super) cell_size: (u16, u16),
}

impl ClientState {
    pub(super) fn new(id: ClientId) -> Self {
        Self {
            id,
            name: "headless".into(),
            kind: "headless".into(),
            remote: false,
            size: None,
            color: 1,
            layout: LayoutId::SHARED,
            active_at: 0,
            parked: false,
            focus: ViewId(0),
            moved: false,
            views: BTreeMap::new(),
            tabs: HashMap::new(),
            mode: "helix".into(),
            pending: Vec::new(),
            count: None,
            overlay: None,
            undo_group: None,
            copied: None,
            notices: Vec::new(),
            image_asks: Vec::new(),
            detach_requested: false,
            switch_requested: None,
            cell_size: (8, 16),
        }
    }

    /// A new client `id` seeing what this one sees: the same focus,
    /// selections and mode, with nothing typed or waiting yet. It follows,
    /// whether or not this one does.
    pub(super) fn seeing_as(&self, id: ClientId) -> Self {
        Self {
            focus: self.focus,
            views: self.views.clone(),
            tabs: self.tabs.clone(),
            mode: self.mode.clone(),
            cell_size: self.cell_size,
            ..Self::new(id)
        }
    }

    /// Its focus was moved under it: keys it typed halfway are dropped, as
    /// they were meant for what it had focused.
    pub(super) fn moved_under(&mut self) {
        self.moved = true;
        self.pending.clear();
        self.count = None;
        self.overlay = None;
    }

    pub fn id(&self) -> ClientId {
        self.id
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    pub fn kind(&self) -> &str {
        &self.kind
    }

    pub fn remote(&self) -> bool {
        self.remote
    }

    /// When it last did something, as a count that only goes up.
    pub fn active_at(&self) -> u64 {
        self.active_at
    }

    pub fn size(&self) -> Option<(u16, u16)> {
        self.size
    }

    pub fn color(&self) -> u8 {
        self.color
    }

    pub fn layout(&self) -> ClientLayout {
        if self.layout == LayoutId::SHARED {
            ClientLayout::Follow
        } else {
            ClientLayout::Independent
        }
    }

    pub fn mode(&self) -> &str {
        &self.mode
    }

    /// The view its keys go to.
    pub fn focus(&self) -> ViewId {
        self.focus
    }

    /// View `id` as this client sees it.
    pub fn view(&self, id: ViewId) -> Option<&View> {
        self.views.get(&id)
    }
}

/// How many colors clients' cursors come in for each other.
pub const PEER_COLORS: u8 = 6;

/// How a client's layout relates to the others': following them, with the
/// same project, tab and panes shown (each client with its own focus and
/// zoom), or laid out on its own.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum ClientLayout {
    #[default]
    Follow,
    Independent,
}

impl ClientLayout {
    pub fn name(self) -> &'static str {
        match self {
            ClientLayout::Follow => "follow",
            ClientLayout::Independent => "independent",
        }
    }

    /// The layout called `name`: "follow" or "independent".
    pub fn parse(name: &str) -> Option<Self> {
        match name {
            "follow" => Some(ClientLayout::Follow),
            "independent" => Some(ClientLayout::Independent),
            _ => None,
        }
    }
}

/// What a client says about itself when it attaches.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClientInfo {
    /// Like "tui@laptop"; a client coming back with the same name gets its
    /// state back.
    pub name: String,
    /// "tui", "gui", "headless" or "test".
    pub kind: String,
    /// Whether it came over `greed ssh`.
    pub remote: bool,
}

/// A tab as one client has it: which pane is active, the panes in the
/// order they were last active, the latest last (so moving left and back
/// right returns to the same pane), whether only the active one shows, and
/// where the panes went when it was last drawn.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct TabState {
    pub(super) active: ViewId,
    pub(super) recent: Vec<ViewId>,
    pub(super) zoomed: bool,
    pub(super) area: Option<Rect>,
}

impl TabState {
    pub(super) fn new(pane: ViewId) -> Self {
        Self {
            active: pane,
            recent: vec![pane],
            zoomed: false,
            area: None,
        }
    }

    pub(super) fn activate(&mut self, view: ViewId) {
        self.active = view;
        self.recent.retain(|v| *v != view);
        self.recent.push(view);
    }
}
