//! The editor's authoritative state: buffers, views, the current mode and
//! the keymap. Everything here is plain Rust; the Luau host drives it.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

use greed_text::{
    Assoc, Author, ChangeSet, ClientId, Range, Replica, Selection, Transaction, TxId, TxMeta,
};

use crate::filetypes::FileTypes;
use crate::keymap::{Key, KeyCode, Keymap, Mods, Resolution};
use crate::theme::Theme;
use crate::{
    Buffer, BufferId, Error, GroupState, Mark, Reveal, SavedHistory, TrackId, VirtualLine,
};

mod clients;
mod layouts;
mod panes;
use clients::TabState;
pub use clients::{ClientInfo, ClientLayout, ClientState, FIRST_CLIENT, PEER_COLORS};
pub use layouts::LayoutChange;
use layouts::{Arrangement, LayoutId};
pub use panes::{Tab, TabId, TabView};

/// How many messages are kept to read again.
const RECENT_MESSAGES: usize = 200;

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, serde::Serialize, serde::Deserialize,
)]
pub struct ViewId(pub u32);

/// `Buffer::undo` or `Buffer::redo`.
type HistoryStep = fn(&mut Buffer, TxId, Author, &Selection) -> Result<Option<Selection>, Error>;

/// What the editor asks a client, which it finds out on its own machine
/// (`Editor::ask_client`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ask {
    /// The image on its system clipboard.
    ClipboardImage,
    /// The status of the hub of its machine, with the sessions and machines
    /// that hub knows of, for a session on another machine to show them.
    HomeStatus,
}

/// A client's answer to an [`Ask`].
#[derive(Debug, Clone, PartialEq)]
pub enum Answer {
    Png(Vec<u8>),
    Json(serde_json::Value),
}

/// A buffer shown on screen, as one client sees it: with its selection and
/// scroll position. Each client has its own of every view.
#[derive(Debug, Clone)]
pub struct View {
    pub id: ViewId,
    pub buffer: BufferId,
    pub selection: Selection,
    pub scroll: Scroll,
    /// The bytes on screen when the view was last drawn; None before that.
    pub visible: Option<std::ops::Range<usize>>,
    /// The rows and columns of text it had room for when last drawn.
    pub size: Option<(u16, u16)>,
    /// Where it was last drawn, gutter included.
    pub area: Option<crate::render::Rect>,
    /// The only lines it shows, when narrowed to part of its buffer, as a
    /// float showing one block of a shell.
    pub lines: Option<std::ops::Range<usize>>,
    /// How many columns the lines that don't wrap are scrolled to the left.
    pub columns: usize,
    /// The lines it shows of what it would, as a float filtering a log: those
    /// hidden stay in the buffer.
    pub filter: Option<std::sync::Arc<crate::line_filter::LineFilter>>,
}

impl View {
    /// Notes what drawing it showed: the bytes on screen, and where it went,
    /// with its text right of a gutter `gutter` cells wide.
    pub(crate) fn drawn(
        &mut self,
        shown: std::ops::Range<usize>,
        area: crate::render::Rect,
        gutter: usize,
    ) {
        let text_width = usize::from(area.width).saturating_sub(gutter).max(1);
        self.visible = Some(shown);
        self.size = Some((area.height, u16::try_from(text_width).unwrap_or(u16::MAX)));
        self.area = Some(area);
    }
}

/// The first thing a view shows: a buffer line, and how many of its wrapped
/// rows are scrolled past.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Scroll {
    pub line: usize,
    pub row: usize,
}

/// A size or a place given in cells, or as a share of the screen, which
/// keeps it in proportion on screens of other sizes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Extent {
    Cells(u16),
    /// In hundredths of a percent: 3750 is 37.5%.
    Share(u16),
}

impl Extent {
    /// All of the screen, as a share.
    pub const WHOLE: u16 = 10_000;

    /// `p` percent of the screen.
    pub const fn percent(p: u16) -> Self {
        Extent::Share(p.saturating_mul(100))
    }

    /// The size in cells, out of `total`.
    pub fn resolve(self, total: u16) -> u16 {
        match self {
            Extent::Cells(n) => n.min(total),
            Extent::Share(share) => {
                let share = u32::from(share.min(Self::WHOLE));
                u16::try_from(u32::from(total) * share / u32::from(Self::WHOLE)).unwrap_or(total)
            }
        }
    }
}

/// Where on the screen a floating view goes, across and down. A position
/// given in its options wins over its anchor on that axis.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Anchor {
    Center,
    Top,
    Bottom,
    /// At the left edge, halfway down.
    Left,
    /// At the right edge, halfway down.
    Right,
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
    /// Just below the focused view's cursor, or above it when there's no
    /// room below, like a completion menu.
    Cursor,
    /// Just above the focused view's cursor, or below it when there's no
    /// room above, like signature help, so a completion menu fits below.
    AboveCursor,
}

impl Anchor {
    const NAMES: [(Anchor, &str); 11] = [
        (Anchor::Center, "center"),
        (Anchor::Top, "top"),
        (Anchor::Bottom, "bottom"),
        (Anchor::Left, "left"),
        (Anchor::Right, "right"),
        (Anchor::TopLeft, "top-left"),
        (Anchor::TopRight, "top-right"),
        (Anchor::BottomLeft, "bottom-left"),
        (Anchor::BottomRight, "bottom-right"),
        (Anchor::Cursor, "cursor"),
        (Anchor::AboveCursor, "above-cursor"),
    ];

    /// The anchor called `name`, like "top-left".
    pub fn parse(name: &str) -> Option<Self> {
        Self::NAMES
            .iter()
            .find(|(_, n)| *n == name)
            .map(|(anchor, _)| *anchor)
    }

    pub fn name(self) -> &'static str {
        Self::NAMES
            .iter()
            .find(|(anchor, _)| *anchor == self)
            .map_or("center", |(_, name)| name)
    }

    /// Every anchor's name, in order, for saying what's allowed.
    pub fn names() -> impl Iterator<Item = &'static str> {
        Self::NAMES.iter().map(|(_, name)| *name)
    }
}

/// How a floating view is shown.
#[expect(
    clippy::struct_excessive_bools,
    reason = "independent flags set from Luau"
)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FloatOptions {
    pub title: Option<Arc<str>>,
    pub width: Extent,
    pub height: Extent,
    pub anchor: Anchor,
    /// Whether the view takes focus when it's shown.
    pub focus: bool,
    /// Where the outside of the border goes, from the left and top of the
    /// screen. Either one left out follows `anchor` (or centers, across).
    pub x: Option<Extent>,
    /// See `x`.
    pub y: Option<Extent>,
    /// Whether it belongs to the tab it opened in, shown only with that tab
    /// and closed with it, like a floating terminal. Otherwise it floats
    /// over every tab, like a picker.
    pub tab: bool,
    /// Text on the top border, at its right end.
    pub label: Option<VirtualLine>,
    /// Text in the middle of the bottom border.
    pub footer: Option<VirtualLine>,
    /// Whether it has a border. Without one, its text fills its whole box.
    pub border: bool,
    /// Whether it's hidden: its view and buffer stay, but it isn't drawn
    /// and the mouse goes through it. Focusing it shows it again.
    pub hidden: bool,
    /// Whether every client is shown it, like a review meant for everyone.
    /// Otherwise, unless it belongs to a tab, only the client it opened for
    /// is, as with a picker or a prompt.
    pub shared: bool,
}

/// A view floating over the main one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Float {
    pub view: ViewId,
    pub options: FloatOptions,
    /// The view that had focus when this one opened, which gets it back
    /// when this one closes.
    pub(crate) return_to: ViewId,
    /// The tab it belongs to, if it belongs to one.
    pub(crate) tab: Option<TabId>,
    /// The client it's shown to alone: the one it opened for, unless it's
    /// shared or belongs to a tab.
    pub(crate) owner: Option<ClientId>,
}

impl Float {
    /// The client it's shown to alone, if it isn't shown to all.
    pub fn owner(&self) -> Option<ClientId> {
        self.owner
    }
}

/// Which edge of the screen a panel is on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Side {
    Left,
    Right,
}

/// How a panel is shown.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PanelOptions {
    pub side: Side,
    pub width: Extent,
    /// Shown on the panel's first row.
    pub title: Option<Arc<str>>,
    /// Whether the view takes focus when it's shown.
    pub focus: bool,
}

/// A view beside the main one, which gives up the room.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Panel {
    pub view: ViewId,
    pub options: PanelOptions,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ProjectId(pub u32);

/// A folder being worked on: its tabs of panes, and panels, in each layout.
/// Buffers opened while it's current belong to it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Project {
    id: ProjectId,
    root: PathBuf,
    /// Its tabs and panels in the shared layout and in each independent
    /// client's.
    arrangements: BTreeMap<LayoutId, Arrangement>,
}

impl Project {
    pub fn id(&self) -> ProjectId {
        self.id
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Every pane of every tab, then the panels, in every layout.
    pub fn views(&self) -> impl Iterator<Item = ViewId> + '_ {
        self.arrangements.values().flat_map(Arrangement::views)
    }
}

/// The project the acting client is shown.
#[derive(Debug, Clone, Copy)]
pub struct CurrentProject<'a> {
    project: &'a Project,
    main: ViewId,
}

impl std::ops::Deref for CurrentProject<'_> {
    type Target = Project;

    fn deref(&self) -> &Project {
        self.project
    }
}

impl<'a> CurrentProject<'a> {
    /// The active pane of the shown tab: where files open, and what the
    /// status line describes.
    pub fn main(&self) -> ViewId {
        self.main
    }

    /// The project, borrowed from the editor rather than from this.
    pub fn project(&self) -> &'a Project {
        self.project
    }

    pub fn root(&self) -> &'a Path {
        &self.project.root
    }
}

/// Another session for a client to go to: a session by name, or the session
/// of the project a path is in (opening the path), started if it isn't
/// running; on another machine, over `greed ssh`, with `host`. With
/// `window`, a window client opens it in another window and stays; a
/// terminal goes to it as it would anyway. With `back`, the client goes to
/// where it was before, on whichever machine; with `home`, to the session on
/// its own machine it was on last. Only the client knows those places.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct SwitchTo {
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub window: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub back: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub home: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
}

/// A notification for the user's desktop, which the attached client shows
/// its own way: a terminal's notification escape, or nothing.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Notice {
    pub title: String,
    pub body: String,
}

/// How the cursor looks.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum CursorShape {
    #[default]
    Block,
    Bar,
    Underline,
}

/// How line numbers count.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum LineNumbers {
    /// Each line's own number.
    #[default]
    Absolute,
    /// How far each line is from the cursor's, 0 on the cursor's own.
    Relative,
    /// As `Relative`, with the cursor's line showing its own number.
    Hybrid,
}

impl LineNumbers {
    /// The number shown by line `line` (0-based) with the cursor on line
    /// `cursor`.
    pub fn number(self, line: usize, cursor: usize) -> usize {
        match self {
            LineNumbers::Absolute => line + 1,
            LineNumbers::Hybrid if line == cursor => line + 1,
            LineNumbers::Relative | LineNumbers::Hybrid => line.abs_diff(cursor),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyOutcome {
    /// Run this command. `keys` is the sequence that triggered it, and
    /// `count` the number typed before it, in modes with counts.
    Command {
        name: Arc<str>,
        keys: Vec<Key>,
        count: Option<u32>,
    },
    /// Waiting for more keys.
    Pending,
    /// Nothing is bound to this sequence.
    Unbound(Vec<Key>),
}

#[derive(Debug)]
pub struct Editor {
    /// Numbers this editor's transactions; its id is the replica's, which
    /// isn't any client's.
    replica: Replica,
    buffers: BTreeMap<BufferId, Buffer>,
    /// Each client's own state, the first one's always there.
    clients: BTreeMap<ClientId, ClientState>,
    /// The client the editor acts for now: whose focus, selections and mode
    /// its methods use.
    acting: ClientId,
    /// Whose doing what the editor does now is: the client it was asked to
    /// act for, while it acts for each of the others in turn to keep them
    /// up with it.
    doer: ClientId,
    /// The client that last did something, for work nobody in particular
    /// asked for, like timers.
    last_active: ClientId,
    /// Counts what clients do, for telling who did something last.
    activity: u64,
    /// What clients were asked (`ask_client`), by number, each with the
    /// client asked and where its answer goes, and the last number given;
    /// and an image every ask for the clipboard's gets at once instead, for
    /// tests.
    asks: HashMap<u64, (ClientId, crossbeam_channel::Sender<Option<Answer>>)>,
    asked: u64,
    fake_clipboard_image: Option<Vec<u8>>,
    /// Open projects, each with its own main view and panels. Empty until the
    /// first view opens.
    projects: Vec<Project>,
    /// Every layout, the shared one and each independent client's, with the
    /// project it shows: an index into `projects`.
    shown: BTreeMap<LayoutId, usize>,
    /// The project each buffer was opened in.
    buffer_projects: HashMap<BufferId, ProjectId>,
    /// Floating views, bottom first.
    floats: Vec<Float>,
    next_id: u32,
    keymap: Keymap,
    messages: Vec<String>,
    /// The last messages shown, oldest first, to read again in full.
    recent: VecDeque<String>,
    next_group: u64,
    /// Why edits are being made, e.g. the command running, when the edit
    /// itself doesn't say.
    cause: Option<Arc<str>>,
    quit_requested: bool,
    /// Copied text, oldest first. Each entry holds one piece per selection.
    clipboard: Vec<Vec<String>>,
    /// The cursor shape of each mode; modes not listed get a block.
    cursor_shapes: HashMap<Arc<str>, CursorShape>,
    /// How line numbers count, where buffers show them.
    line_numbers: LineNumbers,
    /// When marks whose `reveal` is `Auto` show the text they hide.
    reveal: Reveal,
    /// When marks whose `reveal` is `Typing` show the text they hide.
    typing_reveal: Reveal,
    file_types: FileTypes,
    theme: Arc<Theme>,
    /// The menus for a window's menu bar, as plugins set them.
    menus: Vec<crate::render::Menu>,
    /// Images marks can show.
    images: crate::image::Images,
    /// Scenes marks can show.
    scenes: crate::scene::Scenes,
}

impl Editor {
    /// An editor whose transactions are numbered as replica `replica_id`,
    /// with one client, [`FIRST_CLIENT`], acting.
    pub fn new(replica_id: ClientId) -> Self {
        Self {
            replica: Replica::new(replica_id.0),
            buffers: BTreeMap::new(),
            clients: BTreeMap::from([(FIRST_CLIENT, ClientState::new(FIRST_CLIENT))]),
            acting: FIRST_CLIENT,
            doer: FIRST_CLIENT,
            last_active: FIRST_CLIENT,
            activity: 0,
            asks: HashMap::new(),
            asked: 0,
            fake_clipboard_image: None,
            projects: Vec::new(),
            shown: BTreeMap::from([(LayoutId::SHARED, 0)]),
            buffer_projects: HashMap::new(),
            floats: Vec::new(),
            next_id: 1,
            keymap: Keymap::default(),
            messages: Vec::new(),
            recent: VecDeque::new(),
            next_group: 0,
            cause: None,
            quit_requested: false,
            clipboard: Vec::new(),
            cursor_shapes: HashMap::new(),
            line_numbers: LineNumbers::default(),
            reveal: Reveal::Line,
            typing_reveal: Reveal::Line,
            file_types: FileTypes::bundled(),
            theme: Arc::default(),
            menus: Vec::new(),
            images: crate::image::Images::default(),
            scenes: crate::scene::Scenes::default(),
        }
    }

    /// The acting client: the one edits are made by and keys go to now.
    pub fn client(&self) -> ClientId {
        self.acting
    }

    /// The client that last did something.
    pub fn last_active(&self) -> ClientId {
        self.last_active
    }

    /// The clients attached, in order of their ids: those not parked.
    pub fn clients(&self) -> impl Iterator<Item = &ClientState> {
        self.clients.values().filter(|c| !c.parked)
    }

    /// Adds client `id`, following and seeing what the acting client sees.
    /// False if there is one with that id already.
    pub fn add_client(&mut self, id: ClientId) -> bool {
        if self.clients.contains_key(&id) {
            return false;
        }
        self.add_client_like(id, self.acting);
        true
    }

    /// Adds client `id`, seeing what client `like` sees, but following.
    fn add_client_like(&mut self, id: ClientId, like: ClientId) {
        let mut state = self.clients[&like].seeing_as(id);
        state.color = self.free_color(id);
        self.clients.insert(id, state);
        // What `like` had focused may be in a layout of its own.
        self.settle_focus_of(id);
    }

    /// A client attaching, which says `info` about itself: the one parked
    /// under its name, back with its cursors, focus, mode and layout, or a
    /// new one following and seeing what the last active client sees. Two
    /// of the same kind on one machine are told apart by a number: one
    /// gets the first name no attached client has, like "tui@laptop#2",
    /// and the one parked under that name, if any, comes back.
    pub fn attach_client(&mut self, mut info: ClientInfo) -> ClientId {
        let base = info.name.clone();
        let mut n = 1;
        let returning = loop {
            match self.clients.values().find(|c| *c.name == *info.name) {
                Some(c) if !c.parked => {
                    n += 1;
                    info.name = format!("{base}#{n}");
                }
                found => break found.map(ClientState::id),
            }
        };
        let id = returning.unwrap_or_else(|| {
            let id = self.next_client_id();
            self.add_client_like(id, self.last_active);
            id
        });
        self.set_client_info(id, info);
        if let Some(client) = self.clients.get_mut(&id) {
            client.parked = false;
        }
        id
    }

    /// Parks client `id`, which went: its state stays, kept up with edits,
    /// for when it comes back by the same name, but it no longer counts as
    /// attached. The last active client becomes the attached one active
    /// most recently, if there is one. False without such a client.
    pub fn park_client(&mut self, id: ClientId) -> bool {
        let Some(client) = self.clients.get_mut(&id) else {
            return false;
        };
        client.parked = true;
        client.size = None;
        // It won't answer what it was asked; dropping where the answers go
        // tells those waiting it has nothing to say.
        client.asks.clear();
        self.asks.retain(|_, (asked, _)| *asked != id);
        if self.last_active == id
            && let Some(latest) = self.clients().max_by_key(|c| c.active_at)
        {
            self.last_active = latest.id;
        }
        true
    }

    /// The first peer color no attached client has, or one by `id` when
    /// all are taken.
    fn free_color(&self, id: ClientId) -> u8 {
        (1..=PEER_COLORS)
            .find(|c| self.clients().all(|s| s.color != *c))
            .unwrap_or_else(|| {
                u8::try_from(id.0.saturating_sub(1) % u32::from(PEER_COLORS)).unwrap_or(0) + 1
            })
    }

    /// An id no client has had.
    pub fn next_client_id(&self) -> ClientId {
        let last = self.clients.keys().next_back().map_or(0, |id| id.0);
        ClientId(last + 1)
    }

    /// Client `id`'s state, if there is such a client.
    pub fn client_state(&self, id: ClientId) -> Option<&ClientState> {
        self.clients.get(&id)
    }

    /// Sets what client `id` says about itself. False without such a client.
    pub fn set_client_info(&mut self, id: ClientId, info: ClientInfo) -> bool {
        let Some(client) = self.clients.get_mut(&id) else {
            return false;
        };
        client.name = info.name.into();
        client.kind = info.kind.into();
        client.remote = info.remote;
        true
    }

    /// Sets how big client `id`'s screen is, in cells.
    pub fn set_client_size(&mut self, id: ClientId, size: Option<(u16, u16)>) {
        if let Some(client) = self.clients.get_mut(&id) {
            client.size = size;
        }
    }

    /// Acts for client `id` from now on, which counts as its doing
    /// something. False, changing nothing, without such a client.
    pub fn set_acting(&mut self, id: ClientId) -> bool {
        if !self.clients.contains_key(&id) {
            return false;
        }
        self.acting = id;
        self.doer = id;
        self.last_active = id;
        self.activity += 1;
        let activity = self.activity;
        self.acting_client_mut().active_at = activity;
        true
    }

    /// Acts for client `id` without that counting as its doing anything, as
    /// when carrying on what it started, or drawing its screen. For a client
    /// that's gone, acts for the last active one. Returns who it acted for
    /// before, to act for again after.
    pub fn act_as(&mut self, id: ClientId) -> ClientId {
        let before = self.acting;
        self.acting = if self.clients.contains_key(&id) {
            id
        } else {
            self.last_active
        };
        self.doer = self.acting;
        before
    }

    fn acting_client(&self) -> &ClientState {
        &self.clients[&self.acting]
    }

    fn acting_client_mut(&mut self) -> &mut ClientState {
        self.clients
            .get_mut(&self.acting)
            .expect("the acting client exists")
    }

    /// Runs `f` acting for each client in turn, then for the one acting
    /// before.
    fn as_each_client(&mut self, mut f: impl FnMut(&mut Self)) {
        let acting = self.acting;
        let ids: Vec<ClientId> = self.clients.keys().copied().collect();
        for id in ids {
            self.acting = id;
            f(self);
        }
        self.acting = acting;
    }

    /// The open views, as the acting client sees them.
    fn views(&self) -> &BTreeMap<ViewId, View> {
        &self.acting_client().views
    }

    /// Takes view `id` away from every client; returns the acting one's.
    fn remove_view(&mut self, id: ViewId) -> Option<View> {
        let acting = self.acting;
        let mut removed = None;
        for (client, state) in &mut self.clients {
            let view = state.views.remove(&id);
            if *client == acting {
                removed = view;
            }
        }
        for buffer in self.buffers.values_mut() {
            buffer.forget_view(id);
        }
        removed
    }

    /// Whether any view shows `buffer`. Every client has the same views of
    /// the same buffers, so the acting one's tell.
    fn shown(&self, buffer: BufferId) -> bool {
        self.views().values().any(|v| v.buffer == buffer)
    }

    /// Opens a buffer in a new view and focuses it. The first view opened
    /// becomes the main view of the first project, rooted in the current
    /// directory.
    pub fn open(&mut self, kind: &str, text: &str, path: Option<PathBuf>) -> (BufferId, ViewId) {
        let id = BufferId(self.next_id());
        let mut buffer = Buffer::new(id, kind, text);
        if let Some(path) = path {
            let path = file_path(&path).unwrap_or(path);
            buffer.set_detected(self.file_types.detect(&path));
            buffer = buffer.with_path(path);
        }
        let view = self.add_view(id, Selection::point(0));
        if self.projects.is_empty() {
            let root = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
            self.add_project(root, view);
        }
        self.insert_buffer(buffer);
        (id, view)
    }

    /// Creates a buffer without showing it.
    pub fn create_buffer(&mut self, kind: &str, text: &str) -> BufferId {
        let id = BufferId(self.next_id());
        self.insert_buffer(Buffer::new(id, kind, text));
        id
    }

    /// Adds `buffer`, belonging to the current project.
    fn insert_buffer(&mut self, buffer: Buffer) {
        if let Some(project) = self.projects.get(self.shown_index()) {
            self.buffer_projects.insert(buffer.id(), project.id);
        }
        self.buffers.insert(buffer.id(), buffer);
    }

    /// Adds a project at `root` with `main` as the main view of its one tab
    /// in the acting client's layout, and shows it there. Every other
    /// layout gets a tab of its own showing the same buffer.
    fn add_project(&mut self, root: PathBuf, main: ViewId) -> ProjectId {
        let id = ProjectId(self.next_id());
        let buffer = self.view(main).buffer;
        let acting = self.layout_id();
        let layouts: Vec<LayoutId> = self.shown.keys().copied().collect();
        let mut arrangements = BTreeMap::new();
        for layout in layouts {
            let pane = if layout == acting {
                main
            } else {
                self.new_view(buffer, Selection::point(0))
            };
            let tab = Tab::new(TabId(self.next_id()), pane);
            if layout == acting {
                self.acting_client_mut()
                    .tabs
                    .insert(tab.id(), TabState::new(main));
            }
            arrangements.insert(layout, Arrangement::new(tab));
        }
        self.projects.push(Project {
            id,
            root,
            arrangements,
        });
        let index = self.projects.len() - 1;
        self.shown.insert(acting, index);
        self.settle_others();
        id
    }

    /// Opens a project at `root` with an empty main view, and shows it.
    pub fn open_project(&mut self, root: PathBuf) -> ProjectId {
        let id = BufferId(self.next_id());
        self.buffers.insert(id, Buffer::new(id, "file", ""));
        let view = self.add_view(id, Selection::point(0));
        let project = self.add_project(root, view);
        self.buffer_projects.insert(id, project);
        project
    }

    /// Shows the project `id`. Returns false if there is no such project.
    pub fn switch_project(&mut self, id: ProjectId) -> bool {
        let Some(index) = self.projects.iter().position(|p| p.id == id) else {
            return false;
        };
        let layout = self.layout_id();
        self.shown.insert(layout, index);
        self.focus_main();
        self.settle_others();
        true
    }

    /// Closes project `id`: its views, and the buffers opened in it. The
    /// last project can't be closed; returns false for it.
    pub fn close_project(&mut self, id: ProjectId) -> bool {
        let Some(index) = self.projects.iter().position(|p| p.id == id) else {
            return false;
        };
        if self.projects.len() == 1 {
            return false;
        }
        let project = self.projects.remove(index);
        for view in project.views() {
            self.remove_view(view);
        }
        for arrangement in project.arrangements.values() {
            for tab in &arrangement.tabs {
                self.forget_tab(tab.id());
            }
        }
        let owned: Vec<BufferId> = self
            .buffer_projects
            .iter()
            .filter(|(_, owner)| **owner == id)
            .map(|(buffer, _)| *buffer)
            .collect();
        for buffer in owned {
            if !self.shown(buffer) {
                self.buffers.remove(&buffer);
                self.buffer_projects.remove(&buffer);
            }
        }
        // The same project stays current unless it was the one closed; then
        // the one after it takes over, or the one before at the end.
        let last = self.projects.len() - 1;
        for shown in self.shown.values_mut() {
            if index < *shown {
                *shown -= 1;
            }
            *shown = (*shown).min(last);
        }
        self.as_each_client(Self::focus_main);
        true
    }

    /// Open projects, in the order they were opened.
    pub fn projects(&self) -> &[Project] {
        &self.projects
    }

    /// The root of the project shown, if there's one yet.
    pub fn shown_root(&self) -> Option<&Path> {
        self.projects.get(self.shown_index()).map(Project::root)
    }

    /// The project shown. Panics before the first view opens.
    pub fn current_project(&self) -> CurrentProject<'_> {
        let current = self.shown_index();
        CurrentProject {
            project: &self.projects[current],
            main: self.main_of(current),
        }
    }

    /// The tabs of project `id` as the acting client has them, in its
    /// layout; `None` without such a project.
    pub fn project_tabs(&self, id: ProjectId) -> Option<Vec<TabView<'_>>> {
        let p = self.projects.iter().position(|p| p.id == id)?;
        let tabs = &self.arrangement(p).tabs;
        Some(tabs.iter().map(|t| self.tab_view(t)).collect())
    }

    /// The project `buffer` was opened in.
    pub fn buffer_project(&self, buffer: BufferId) -> Option<ProjectId> {
        self.buffer_projects.get(&buffer).copied()
    }

    /// Makes `buffer` read-only, so only plugins can change it, or editable.
    pub fn set_readonly(&mut self, buffer: BufferId, readonly: bool) {
        if let Some(b) = self.buffers.get_mut(&buffer) {
            b.set_readonly(readonly);
        }
    }

    /// Makes the text of `buffer` before `pos` read-only, so only plugins
    /// can change it, and the rest editable; `None` makes all of it editable.
    pub fn set_readonly_before(&mut self, buffer: BufferId, pos: Option<usize>) {
        if let Some(b) = self.buffers.get_mut(&buffer) {
            b.set_readonly_before(pos);
        }
    }

    /// Shows or hides line numbers beside `buffer` in the main view.
    pub fn set_line_numbers(&mut self, buffer: BufferId, on: bool) {
        if let Some(b) = self.buffers.get_mut(&buffer) {
            b.set_line_numbers(on);
        }
    }

    pub fn set_tab_width(&mut self, buffer: BufferId, width: usize) {
        if let Some(b) = self.buffers.get_mut(&buffer) {
            b.set_tab_width(width);
        }
    }

    /// Stops keeping `buffer`'s undo history (see [`Buffer::forget_history`]).
    pub fn forget_history(&mut self, buffer: BufferId) {
        if let Some(b) = self.buffers.get_mut(&buffer) {
            b.forget_history();
        }
    }

    /// Lets go of `buffer`'s undo history so far (see
    /// [`Buffer::clear_history`]).
    pub fn clear_history(&mut self, buffer: BufferId) {
        if let Some(b) = self.buffers.get_mut(&buffer) {
            b.clear_history();
        }
    }

    /// Takes back an undo tree kept from before for `buffer` (see
    /// [`Buffer::restore_history`]).
    pub fn restore_history(
        &mut self,
        buffer: BufferId,
        saved: &SavedHistory,
    ) -> Result<(), String> {
        self.buffers
            .get_mut(&buffer)
            .ok_or_else(|| "this buffer was closed".to_string())?
            .restore_history(saved)
    }

    /// Keeps `buffer` open while nothing shows it, like a terminal you'll
    /// come back to, or lets it go then again (right away if nothing shows
    /// it now).
    pub fn set_kept(&mut self, buffer: BufferId, kept: bool) {
        if let Some(b) = self.buffers.get_mut(&buffer) {
            b.set_kept(kept);
            self.drop_if_unused(buffer);
        }
    }

    /// Lays `buffer`'s text out at `size` in every view, whatever room each
    /// has, like a terminal's screen sized for one client; or with `None`,
    /// at each view's own size again.
    pub fn set_screen_size(&mut self, buffer: BufferId, size: Option<crate::ScreenSize>) {
        if let Some(b) = self.buffers.get_mut(&buffer) {
            b.set_screen_size(size);
        }
    }

    /// Names `buffer` where it shows, or leaves it unnamed with `None`.
    pub fn set_buffer_name(&mut self, buffer: BufferId, name: Option<&str>) {
        if let Some(b) = self.buffers.get_mut(&buffer) {
            b.set_name(name);
        }
    }

    /// Binds single keys for `buffer` alone, in every mode and ahead of
    /// every keymap layer, while a view of it has focus. Replaces what was
    /// bound for it before; an empty map drops them.
    pub fn set_buffer_keys(&mut self, buffer: BufferId, keys: HashMap<Key, Arc<str>>) {
        if let Some(b) = self.buffers.get_mut(&buffer) {
            b.set_keys(keys);
        }
    }

    /// Sets the language `buffer` is in, or with `None` goes back to the one
    /// its file name says.
    pub fn set_language(&mut self, buffer: BufferId, language: Option<Arc<str>>) {
        if let Some(b) = self.buffers.get_mut(&buffer) {
            b.set_language(language);
        }
    }

    /// Replaces all of `buffer`'s marks in namespace `ns`, every view's,
    /// clamping them to its text.
    pub fn decorate(&mut self, buffer: BufferId, ns: &str, mut marks: Vec<Mark>) {
        let Some(b) = self.buffers.get_mut(&buffer) else {
            return;
        };
        clamp_marks(b, &mut marks);
        b.set_marks(ns, marks);
    }

    /// Like [`Editor::decorate`], but replaces only the marks in `ns` that
    /// only `view` draws (with none, those every view draws), and with
    /// `within` only those that start there. The marks get `view`.
    pub fn decorate_in(
        &mut self,
        buffer: BufferId,
        ns: &str,
        view: Option<ViewId>,
        within: Option<std::ops::Range<usize>>,
        mut marks: Vec<Mark>,
    ) {
        let Some(b) = self.buffers.get_mut(&buffer) else {
            return;
        };
        clamp_marks(b, &mut marks);
        for mark in &mut marks {
            mark.view = view;
        }
        b.set_marks_in(ns, view, within, marks);
    }

    /// Starts following `range` of `buffer` through edits; see [`crate::Tracked`].
    pub fn track(
        &mut self,
        buffer: BufferId,
        range: std::ops::Range<usize>,
        gravity: (Assoc, Assoc),
    ) -> Option<TrackId> {
        Some(self.buffers.get_mut(&buffer)?.track(range, gravity))
    }

    pub fn forget_tracked(&mut self, buffer: BufferId, id: TrackId) {
        if let Some(b) = self.buffers.get_mut(&buffer) {
            b.forget(id);
        }
    }

    /// The buffer for the file at `path`: the open one, or a new buffer
    /// with the file's text (empty if the file doesn't exist yet). A file
    /// that isn't UTF-8 opens read-only, with what can't be read replaced,
    /// and can't be saved over.
    pub fn open_file(&mut self, path: &Path) -> std::io::Result<BufferId> {
        let path = &file_path(path)?;
        if let Some(buffer) = self.buffer_for(path) {
            return Ok(buffer);
        }
        let buffer = self.file_buffer(path)?;
        let id = buffer.id();
        self.insert_buffer(buffer);
        Ok(id)
    }

    /// The file at `path` in a new view, focused, as [`Editor::open`] opens
    /// text: for the file a session starts with. Read as
    /// [`Editor::open_file`] reads it, so one that isn't text opens too.
    pub fn open_path(&mut self, path: &Path) -> std::io::Result<(BufferId, ViewId)> {
        let path = &file_path(path)?;
        let buffer = self.file_buffer(path)?;
        let id = buffer.id();
        let view = self.add_view(id, Selection::point(0));
        if self.projects.is_empty() {
            let root = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
            self.add_project(root, view);
        }
        self.insert_buffer(buffer);
        Ok((id, view))
    }

    /// A new buffer for the file at `path` (made absolute already): its text,
    /// empty if it isn't there yet; read-only with what can't be read
    /// replaced when it isn't UTF-8.
    fn file_buffer(&mut self, path: &Path) -> std::io::Result<Buffer> {
        let (text, binary) = match std::fs::read(path) {
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => (String::new(), false),
            Err(err) => return Err(err),
            Ok(bytes) => match String::from_utf8(bytes) {
                Ok(text) => (text, false),
                Err(err) => (String::from_utf8_lossy(err.as_bytes()).into_owned(), true),
            },
        };
        let id = BufferId(self.next_id());
        let mut buffer = Buffer::new(id, "file", &text).with_path(path);
        buffer.set_detected(self.file_types.detect(path));
        buffer.set_readonly(binary);
        buffer.set_lossy(binary);
        Ok(buffer)
    }

    /// The open buffer for the file at `path`, however it's spelled (see
    /// [`file_path`]), without opening it.
    pub fn buffer_for(&self, path: &Path) -> Option<BufferId> {
        let path = file_path(path).ok()?;
        self.buffers
            .values()
            .find(|b| b.path() == Some(&path))
            .map(Buffer::id)
    }

    /// Makes `extensions` and whole file `names` mean `language`, replacing
    /// whatever it had, and redetects every open file.
    pub fn set_file_type(&mut self, language: &str, extensions: &[String], names: &[String]) {
        self.file_types.set(language, extensions, names);
        self.redetect();
    }

    /// Goes back to the bundled file types, then sets each of `types` as
    /// `(language, extensions, names)`, in order, and redetects every open
    /// file.
    pub fn reset_file_types<'a>(
        &mut self,
        types: impl IntoIterator<Item = (&'a str, &'a [String], &'a [String])>,
    ) {
        self.file_types = FileTypes::bundled();
        for (language, extensions, names) in types {
            self.file_types.set(language, extensions, names);
        }
        self.redetect();
    }

    fn redetect(&mut self) {
        for buffer in self.buffers.values_mut() {
            let detected = buffer.path().and_then(|p| self.file_types.detect(p));
            buffer.set_detected(detected);
        }
    }

    /// The language of the file at `path`, by its name or extension.
    pub fn file_type(&self, path: &Path) -> Option<Arc<str>> {
        self.file_types.detect(path)
    }

    /// Shows `buffer` in `view`, starting at the top.
    pub fn show(&mut self, view: ViewId, buffer: BufferId) {
        let old = self.view(view).buffer;
        for client in self.clients.values_mut() {
            let Some(view) = client.views.get_mut(&view) else {
                continue;
            };
            view.buffer = buffer;
            view.selection = Selection::point(0);
            view.scroll = Scroll::default();
            view.visible = None;
            view.lines = None;
            view.columns = 0;
            view.filter = None;
        }
        self.drop_if_unused(old);
    }

    /// Narrows `view` to `lines` of its buffer, for every client, or shows
    /// all of it again with `None`.
    pub fn narrow(&mut self, view: ViewId, lines: Option<&std::ops::Range<usize>>) {
        for client in self.clients.values_mut() {
            if let Some(view) = client.views.get_mut(&view) {
                view.lines = lines.cloned();
            }
        }
    }

    /// Shows only the lines of `view` that `filter` keeps, for every client, or
    /// every line again with `None`.
    pub fn filter(&mut self, view: ViewId, filter: Option<crate::line_filter::LineFilter>) {
        let filter = filter.map(std::sync::Arc::new);
        for client in self.clients.values_mut() {
            if let Some(view) = client.views.get_mut(&view) {
                view.filter.clone_from(&filter);
            }
        }
    }

    /// Shows `buffer` in a new view floating over the main one, focusing it
    /// if `options.focus` says so.
    pub fn float(&mut self, buffer: BufferId, options: FloatOptions) -> ViewId {
        let previous = self.focus();
        let view = self.add_view(buffer, Selection::point(0));
        if !options.focus || options.hidden {
            self.acting_client_mut().focus = previous;
        }
        let tab = options.tab.then(|| self.current_tab().id());
        let owner = self.owner_for(&options);
        self.floats.push(Float {
            view,
            options,
            return_to: previous,
            tab,
            owner,
        });
        view
    }

    /// Who a float shown as `options` says is shown to alone: the acting
    /// client, unless it's shared or belongs to a tab.
    fn owner_for(&self, options: &FloatOptions) -> Option<ClientId> {
        (!options.shared && !options.tab).then_some(self.acting)
    }

    /// The floating views the acting client is shown: those over every tab
    /// and the shown tab's own, bottom first, leaving out hidden ones and
    /// other clients' own.
    pub fn floats(&self) -> Vec<&Float> {
        self.floats_hidden_too()
            .into_iter()
            .filter(|f| !f.options.hidden)
            .collect()
    }

    /// The floating views over every tab and the shown tab's own, hidden
    /// or not, bottom first, leaving out other clients' own.
    pub fn floats_hidden_too(&self) -> Vec<&Float> {
        let tab = self.current_tab().id();
        self.floats
            .iter()
            .filter(|f| f.tab.is_none_or(|t| t == tab))
            .filter(|f| f.owner.is_none_or(|c| c == self.acting))
            .collect()
    }

    /// Closes the floating views client `id` alone was shown, returning
    /// them: it went, and they were open for it.
    pub fn close_floats_of(&mut self, id: ClientId) -> Vec<ViewId> {
        let views: Vec<ViewId> = self
            .floats
            .iter()
            .filter(|f| f.owner == Some(id))
            .map(|f| f.view)
            .collect();
        views.into_iter().filter(|view| self.close(*view)).collect()
    }

    /// Shows `buffer` in a new panel beside the main view, focusing it if
    /// `options.focus` says so. Later panels go inside earlier ones.
    pub fn panel(&mut self, buffer: BufferId, options: PanelOptions) -> ViewId {
        let previous = self.focus();
        let view = self.add_view(buffer, Selection::point(0));
        if !options.focus {
            self.acting_client_mut().focus = previous;
        }
        self.shown_arrangement_mut()
            .panels
            .push(Panel { view, options });
        view
    }

    /// Panels, outermost first on each side.
    pub fn panels(&self) -> &[Panel] {
        &self.shown_arrangement().panels
    }

    /// How `view` is shown, if it's a floating view.
    pub fn float_options(&self, view: ViewId) -> Option<&FloatOptions> {
        self.floats
            .iter()
            .find(|f| f.view == view)
            .map(|f| &f.options)
    }

    /// Changes how a floating view is shown. Returns false if `view` isn't
    /// floating. Hiding the focused one moves focus as closing it would. One
    /// no longer shared is the acting client's own from then on.
    pub fn configure_float(&mut self, view: ViewId, options: FloatOptions) -> bool {
        let owner = self.owner_for(&options);
        let Some(float) = self.floats.iter_mut().find(|f| f.view == view) else {
            return false;
        };
        let hidden = options.hidden;
        if options.shared != float.options.shared {
            float.owner = owner;
        }
        float.options = options;
        let (return_to, owner) = (float.return_to, float.owner);
        if hidden {
            self.refocus_from(view, Some(return_to));
        } else if let Some(owner) = owner {
            // The others' focus can't stay on what they aren't shown.
            self.as_each_client(|ed| {
                if ed.acting != owner && ed.focus() == view {
                    let next = ed.focus_after(view, Some(return_to));
                    ed.move_focus(next);
                }
            });
        }
        true
    }

    /// Moves the focus of each client that had it on `view`, which closed
    /// or hid, to what it goes to next (see `focus_after`).
    fn refocus_from(&mut self, view: ViewId, return_to: Option<ViewId>) {
        self.as_each_client(|ed| {
            if ed.focus() == view {
                let next = ed.focus_after(view, return_to);
                ed.move_focus(next);
            }
        });
    }

    /// What gets focus when `view` closes or hides: `return_to` if it's
    /// still there and shown, else the floating view in front, else the
    /// main view.
    fn focus_after(&self, view: ViewId, return_to: Option<ViewId>) -> ViewId {
        let shown = |v: &ViewId| {
            *v != view
                && self.views().contains_key(v)
                && self.float_options(*v).is_none_or(|o| !o.hidden)
        };
        return_to
            .filter(shown)
            .or_else(|| self.floats().iter().map(|f| f.view).rfind(shown))
            .unwrap_or(self.main())
    }

    /// Brings a floating view in front of the others. Returns false if
    /// `view` isn't floating.
    pub fn raise_float(&mut self, view: ViewId) -> bool {
        let Some(at) = self.floats.iter().position(|f| f.view == view) else {
            return false;
        };
        let float = self.floats.remove(at);
        self.floats.push(float);
        true
    }

    pub fn main(&self) -> ViewId {
        self.main_of(self.shown_index())
    }

    /// The view the status line is about: the focused one when it's a
    /// pane, a panel or one of the tab's floats (a floating terminal), else
    /// the main view, behind a picker or the command line.
    pub fn status_view(&self) -> ViewId {
        let focus = self.focus();
        let of_tab = |v: ViewId| {
            self.is_pane(v)
                || self.panels().iter().any(|p| p.view == v)
                || self.floats().iter().any(|f| f.view == v && f.tab.is_some())
        };
        if of_tab(focus) { focus } else { self.main() }
    }

    /// Moves the acting client's focus to its main view.
    fn focus_main(&mut self) {
        let main = self.main();
        self.move_focus(main);
    }

    /// Moves the acting client's focus to `view`. When that's another
    /// client's doing, it was moved under it: what it typed halfway is
    /// dropped, and it's told so with the focus change.
    fn move_focus(&mut self, view: ViewId) {
        let under = self.acting != self.doer;
        let client = self.acting_client_mut();
        if client.focus == view {
            return;
        }
        client.focus = view;
        if under {
            client.moved_under();
        }
    }

    /// Whether the acting client's focus was moved under it since this was
    /// last asked: by another client's doing, or by its following again.
    pub fn take_moved(&mut self) -> bool {
        std::mem::take(&mut self.acting_client_mut().moved)
    }

    /// Closes a view. Focus moves to the top floating view, or the main view.
    /// A buffer without a file goes away with its last view. Closing a tab's
    /// last pane closes the tab. Returns false for the project's last pane,
    /// which can't be closed.
    pub fn close(&mut self, view: ViewId) -> bool {
        if !self.views().contains_key(&view) || !self.remove_pane(view) {
            return false;
        }
        let Some(closed) = self.remove_view(view) else {
            return false;
        };
        let return_to = self
            .floats
            .iter()
            .find(|f| f.view == view)
            .map(|f| f.return_to);
        self.floats.retain(|f| f.view != view);
        for arrangement in self
            .projects
            .iter_mut()
            .flat_map(|p| p.arrangements.values_mut())
        {
            arrangement.panels.retain(|p| p.view != view);
        }
        self.refocus_from(view, return_to);
        self.drop_if_unused(closed.buffer);
        true
    }

    /// Opens a second view of the same buffer, with the same selection, and
    /// focuses it.
    pub fn split(&mut self, view: ViewId) -> ViewId {
        let copy = self.view(view).clone();
        let id = self.add_view(copy.buffer, copy.selection);
        self.view_mut(id).scroll = copy.scroll;
        id
    }

    /// Panics if the buffer doesn't exist; ids come from the editor itself.
    pub fn buffer(&self, id: BufferId) -> &Buffer {
        &self.buffers[&id]
    }

    /// Writes a buffer to its file.
    pub fn save(&mut self, id: BufferId) -> std::io::Result<()> {
        self.buffers.get_mut(&id).expect("buffer exists").save()
    }

    /// Reads a buffer's file again, as an edit by [`Author::External`] that
    /// undo can take back, and counts the buffer as saved. Returns whether
    /// the text changed.
    pub fn reload(&mut self, id: BufferId) -> std::io::Result<bool> {
        let buffer = &self.buffers[&id];
        let path = buffer
            .path()
            .ok_or_else(|| std::io::Error::other("this buffer has no file"))?;
        let disk = std::fs::read_to_string(path)?;
        let text = buffer.text().to_string();
        let changes = crate::diff::line_changes(&text, &disk);
        if !changes.is_empty() {
            let changes = ChangeSet::from_changes(
                text.len(),
                changes
                    .iter()
                    .map(|(range, new)| (range.start, range.end, Some(new.as_str()))),
            )
            .map_err(std::io::Error::other)?;
            // Not part of whatever the user has going, like an insert.
            let group = self.acting_client_mut().undo_group.take();
            let applied = self.apply_to_buffer(id, changes, Author::External, Some("reload"), None);
            self.acting_client_mut().undo_group = group;
            applied.map_err(std::io::Error::other)?;
        }
        self.buffers
            .get_mut(&id)
            .expect("buffer exists")
            .mark_saved();
        Ok(!changes.is_empty())
    }

    /// Writes the buffer to `path`, which becomes its file. A buffer whose
    /// file wasn't UTF-8 can be saved to another path, which then holds
    /// what it shows, but not over its own file.
    pub fn save_as(&mut self, id: BufferId, path: &Path) -> std::io::Result<()> {
        let detected = self.file_types.detect(path);
        let buffer = self.buffers.get_mut(&id).expect("buffer exists");
        let lossy = buffer.is_lossy();
        let path = file_path(path)?;
        if lossy && buffer.path() == Some(&path) {
            // Refused, as saving over it would be.
            return buffer.save();
        }
        let old = buffer.set_path(Some(path));
        buffer.set_lossy(false);
        let saved = buffer.save();
        if saved.is_err() {
            buffer.set_path(old);
            buffer.set_lossy(lossy);
        } else {
            buffer.set_detected(detected);
        }
        saved
    }

    /// The buffer with `id`, if it still exists.
    pub fn find_buffer(&self, id: BufferId) -> Option<&Buffer> {
        self.buffers.get(&id)
    }

    /// The first and last line (0-based, as the text is now) of what edits
    /// changed in buffer `id` since this was last called for it; `None` when
    /// they changed nothing, or without the buffer.
    pub fn take_changed_lines(&mut self, id: BufferId) -> Option<(usize, usize)> {
        let buffer = self.buffers.get_mut(&id)?;
        let range = buffer.take_changed()?;
        let text = buffer.text();
        let len = text.len_bytes();
        Some((
            text.byte_to_line(range.start.min(len)),
            text.byte_to_line(range.end.min(len)),
        ))
    }

    /// The view with `id`, if it's still open.
    pub fn find_view(&self, id: ViewId) -> Option<&View> {
        self.views().get(&id)
    }

    /// The acting client's view `id`, if it has it, to change.
    pub fn find_view_mut(&mut self, id: ViewId) -> Option<&mut View> {
        self.acting_client_mut().views.get_mut(&id)
    }

    pub fn buffers(&self) -> impl Iterator<Item = &Buffer> {
        self.buffers.values()
    }

    /// The views showing `buffer`.
    pub fn views_of(&self, buffer: BufferId) -> Vec<ViewId> {
        self.views()
            .iter()
            .filter(|(_, view)| view.buffer == buffer)
            .map(|(id, _)| *id)
            .collect()
    }

    /// Each open view that has been drawn, with its rows and columns.
    pub fn view_sizes(&self) -> impl Iterator<Item = (ViewId, (u16, u16))> + '_ {
        self.views()
            .iter()
            .filter_map(|(id, view)| Some((*id, view.size?)))
    }

    /// Each view's top line.
    pub fn view_scrolls(&self) -> impl Iterator<Item = (ViewId, usize)> + '_ {
        self.views()
            .iter()
            .map(|(id, view)| (*id, view.scroll.line))
    }

    /// Each view's buffer and selection, floats' too.
    pub fn view_selections(&self) -> impl Iterator<Item = (ViewId, BufferId, &Selection)> + '_ {
        self.views()
            .iter()
            .map(|(id, view)| (*id, view.buffer, &view.selection))
    }

    /// View `id` as the acting client sees it.
    pub fn view(&self, id: ViewId) -> &View {
        &self.views()[&id]
    }

    pub fn view_mut(&mut self, id: ViewId) -> &mut View {
        self.find_view_mut(id).expect("view exists")
    }

    /// The other attached clients and how each sees `view`: whose cursors
    /// the acting client sees there. One with its own layout, where `view`
    /// isn't shown, has its cursors where it works: in the view it has
    /// focused, when that shows the same buffer.
    pub fn peers(&self, view: ViewId) -> impl Iterator<Item = (&ClientState, &View)> + '_ {
        let buffer = self.views().get(&view).map(|v| v.buffer);
        let layout = self.layout_of(view);
        self.clients()
            .filter(|c| c.id != self.acting)
            .filter_map(move |c| {
                if layout.is_none_or(|l| l == c.layout) {
                    return Some((c, c.views.get(&view)?));
                }
                let focused = c.views.get(&c.focus)?;
                (Some(focused.buffer) == buffer).then_some((c, focused))
            })
    }

    /// The view the acting client's keys go to.
    pub fn focus(&self) -> ViewId {
        self.acting_client().focus
    }

    /// Focuses `view`, showing it if it's a hidden floating view.
    pub fn set_focus(&mut self, view: ViewId) {
        assert!(self.views().contains_key(&view), "no view {view:?}");
        if let Some(float) = self.floats.iter_mut().find(|f| f.view == view) {
            float.options.hidden = false;
        }
        self.acting_client_mut().focus = view;
        self.activate(view);
    }

    /// Applies a change to the buffer shown in `view`. The view's selection
    /// becomes `selection`, or is mapped through the change if `None`; other
    /// views of the same buffer are always mapped.
    pub fn apply(
        &mut self,
        view: ViewId,
        changes: ChangeSet,
        author: Author,
        cause: Option<&str>,
        selection: Option<Selection>,
    ) -> Result<(), Error> {
        self.apply_in_view(view, changes, author, cause, selection, true)
    }

    /// Applies a change as `apply` does, without keeping it to undo: undo
    /// and redo skip it (see `Buffer::apply_unrecorded`).
    pub fn apply_unrecorded(
        &mut self,
        view: ViewId,
        changes: ChangeSet,
        author: Author,
        selection: Option<Selection>,
    ) -> Result<(), Error> {
        self.apply_in_view(view, changes, author, None, selection, false)
    }

    fn apply_in_view(
        &mut self,
        view: ViewId,
        changes: ChangeSet,
        author: Author,
        cause: Option<&str>,
        selection: Option<Selection>,
        record: bool,
    ) -> Result<(), Error> {
        let id = self.view(view).buffer;
        let tx = Transaction {
            changes,
            selection,
            meta: self.meta(id, author, cause),
        };
        let current = self.view(view).selection.clone();
        let buffer = self.buffers.get_mut(&id).expect("view's buffer exists");
        let after = if record {
            buffer.apply(tx, &current)?
        } else {
            buffer
                .apply_unrecorded(tx, Some(&current))?
                .expect("a selection to map gives one back")
        };
        self.view_mut(view).selection = after;
        self.map_views(id, Some(view));
        Ok(())
    }

    /// Applies a change to a buffer, whether or not it's on screen. The
    /// acting client's views of it get `selection`; every other view is
    /// mapped through the change, as all are with `None`.
    pub fn apply_to_buffer(
        &mut self,
        id: BufferId,
        changes: ChangeSet,
        author: Author,
        cause: Option<&str>,
        selection: Option<Selection>,
    ) -> Result<(), Error> {
        self.apply_in_buffer(id, changes, author, cause, selection, true)
    }

    /// Applies a change as `apply_to_buffer` does, without keeping it to
    /// undo: undo and redo skip it (see `Buffer::apply_unrecorded`).
    pub fn apply_to_buffer_unrecorded(
        &mut self,
        id: BufferId,
        changes: ChangeSet,
        author: Author,
        selection: Option<Selection>,
    ) -> Result<(), Error> {
        self.apply_in_buffer(id, changes, author, None, selection, false)
    }

    fn apply_in_buffer(
        &mut self,
        id: BufferId,
        changes: ChangeSet,
        author: Author,
        cause: Option<&str>,
        selection: Option<Selection>,
        record: bool,
    ) -> Result<(), Error> {
        let tx = Transaction {
            changes,
            selection,
            meta: self.meta(id, author, cause),
        };
        let buffer = self.buffers.get_mut(&id).expect("buffer exists");
        let after = if record {
            buffer.apply_detached(tx)?
        } else {
            buffer.apply_unrecorded(tx, None)?
        };
        self.map_views(id, None);
        // A selection goes to the client the edit is made for, never to
        // every client: the others' cursors move with the text.
        if let Some(after) = after {
            let views = self.acting_client_mut().views.values_mut();
            for view in views.filter(|v| v.buffer == id) {
                view.selection = after.clone();
            }
        }
        Ok(())
    }

    /// Metadata for the next transaction on `buffer`.
    fn meta(&mut self, buffer: BufferId, author: Author, cause: Option<&str>) -> TxMeta {
        let version = self.buffers[&buffer].version();
        let mut meta = TxMeta::new(self.replica.next_id(), version, author);
        meta.group = self.acting_client().undo_group;
        if let Some(cause) = cause.or(self.cause.as_deref()) {
            meta = meta.with_cause(cause);
        }
        meta
    }

    /// Undoes the last change in `view`'s buffer. Returns false if there was
    /// nothing to undo.
    pub fn undo(&mut self, view: ViewId) -> Result<bool, Error> {
        self.history_step(view, true)
    }

    /// Redoes the last undone change in `view`'s buffer. Returns false if
    /// there was nothing to redo.
    pub fn redo(&mut self, view: ViewId) -> Result<bool, Error> {
        self.history_step(view, false)
    }

    /// Takes `view`'s buffer to node `target` of its undo tree, undoing up
    /// to where the two paths meet and redoing down the other branch, which
    /// redo follows from then on. Returns false if there's no such node or
    /// the text is there already.
    pub fn undo_to(&mut self, view: ViewId, target: usize) -> Result<bool, Error> {
        let id = self.view(view).buffer;
        let Some((up, down)) = self.buffers[&id].history().path_to(target) else {
            return Ok(false);
        };
        if up == 0 && down.is_empty() {
            return Ok(false);
        }
        for _ in 0..up {
            self.undo(view)?;
        }
        for node in down {
            self.buffers
                .get_mut(&id)
                .expect("view's buffer exists")
                .prefer_branch(node);
            self.redo(view)?;
        }
        Ok(true)
    }

    /// Starts grouping edits into one undo step, e.g. for an insert mode
    /// session. Does nothing if a group is already open.
    pub fn start_group(&mut self) {
        if self.acting_client().undo_group.is_none() {
            let group = self.new_group();
            self.acting_client_mut().undo_group = Some(group);
        }
    }

    pub fn end_group(&mut self) {
        self.acting_client_mut().undo_group = None;
    }

    /// A group id nothing has used yet.
    pub fn new_group(&mut self) -> u64 {
        let group = self.next_group;
        self.next_group += 1;
        group
    }

    /// The group edits go into now, if one is open.
    pub fn group(&self) -> Option<u64> {
        self.acting_client().undo_group
    }

    /// Puts the edits that follow into `group`, which can be one used
    /// before, or into none.
    pub fn set_group(&mut self, group: Option<u64>) {
        self.acting_client_mut().undo_group = group;
    }

    /// Sets why the edits that follow are made, for those that don't say.
    pub fn set_cause(&mut self, cause: Option<Arc<str>>) {
        self.cause = cause;
    }

    pub fn cause(&self) -> Option<&Arc<str>> {
        self.cause.as_ref()
    }

    /// Undoes `group` in every buffer it touched, as `author`. Returns the
    /// buffers that changed: none if the group was already undone or never
    /// used. Changes nothing if a buffer had something done on top of it.
    pub fn undo_group(&mut self, group: u64, author: &Author) -> Result<Vec<BufferId>, Error> {
        let mut current = Vec::new();
        for (id, buffer) in &self.buffers {
            match buffer.history().group_state(group) {
                GroupState::Buried => return Err(Error::GroupChanged),
                GroupState::Current
                    if buffer.is_readonly() && !matches!(author, Author::Plugin(_)) =>
                {
                    return Err(Error::ReadOnly);
                }
                GroupState::Current => current.push(*id),
                GroupState::Absent | GroupState::Undone => {}
            }
        }
        for &id in &current {
            let tx_id = self.replica.next_id();
            let buffer = self.buffers.get_mut(&id).expect("buffer exists");
            // Views keep their places, moved along with the text, rather than
            // jumping to wherever the group's edits were made from.
            buffer.undo(tx_id, author.clone(), &Selection::point(0))?;
            self.map_views(id, None);
        }
        Ok(current)
    }

    pub fn mode(&self) -> &str {
        &self.acting_client().mode
    }

    /// Switches mode. Returns false if already in that mode.
    pub fn set_mode(&mut self, mode: &str) -> bool {
        let client = self.acting_client_mut();
        if &*client.mode == mode {
            return false;
        }
        client.mode = mode.into();
        client.pending.clear();
        client.count = None;
        true
    }

    /// The menus for a window's menu bar.
    pub fn menus(&self) -> &[crate::render::Menu] {
        &self.menus
    }

    pub fn set_menus(&mut self, menus: Vec<crate::render::Menu>) {
        self.menus = menus;
    }

    pub fn theme(&self) -> &Arc<Theme> {
        &self.theme
    }

    pub fn images(&self) -> &crate::image::Images {
        &self.images
    }

    pub fn images_mut(&mut self) -> &mut crate::image::Images {
        &mut self.images
    }

    pub fn scenes(&self) -> &crate::scene::Scenes {
        &self.scenes
    }

    pub fn scenes_mut(&mut self) -> &mut crate::scene::Scenes {
        &mut self.scenes
    }

    /// A cell's width and height in pixels on the client's screen; 8 by 16
    /// until a client says.
    pub fn cell_size(&self) -> (u16, u16) {
        self.acting_client().cell_size
    }

    pub fn set_cell_size(&mut self, size: (u16, u16)) {
        if size.0 > 0 && size.1 > 0 {
            self.acting_client_mut().cell_size = size;
        }
    }

    pub fn theme_mut(&mut self) -> &mut Theme {
        Arc::make_mut(&mut self.theme)
    }

    /// The modes there are: those the keymap knows and those with a cursor
    /// shape.
    pub fn modes(&self) -> std::collections::BTreeSet<&str> {
        let mut modes = self.keymap().modes();
        modes.extend(self.cursor_shapes.keys().map(|mode| &**mode));
        modes
    }

    pub fn set_cursor_shape(&mut self, mode: &str, shape: CursorShape) {
        self.cursor_shapes.insert(mode.into(), shape);
    }

    /// How line numbers count, where buffers show them.
    pub fn line_numbers(&self) -> LineNumbers {
        self.line_numbers
    }

    pub fn set_line_numbers_style(&mut self, style: LineNumbers) {
        self.line_numbers = style;
    }

    /// When concealing marks whose `reveal` is [`Reveal::Auto`] show their
    /// text; never `Auto` itself.
    pub fn reveal(&self) -> Reveal {
        self.reveal
    }

    /// Sets when concealing marks whose `reveal` is [`Reveal::Auto`] show
    /// their text, e.g. on their line while typing and never otherwise.
    /// `Auto` is taken as `Line`.
    pub fn set_reveal(&mut self, reveal: Reveal) {
        self.reveal = settled(reveal);
    }

    /// When concealing marks whose `reveal` is [`Reveal::Typing`] show
    /// their text; never `Auto` or `Typing` itself.
    pub fn typing_reveal(&self) -> Reveal {
        self.typing_reveal
    }

    /// Sets when concealing marks whose `reveal` is [`Reveal::Typing`]
    /// show their text: as `Auto` ones while typing, and never otherwise.
    /// `Auto` and `Typing` are taken as `Line`.
    pub fn set_typing_reveal(&mut self, reveal: Reveal) {
        self.typing_reveal = settled(reveal);
    }

    /// What a mark's `reveal` comes to now: `Auto` and `Typing` as set.
    pub fn resolve_reveal(&self, reveal: Reveal) -> Reveal {
        match reveal {
            Reveal::Auto => self.reveal,
            Reveal::Typing => self.typing_reveal,
            Reveal::Line | Reveal::Cursor | Reveal::Never => reveal,
        }
    }

    /// The cursor shape for the current mode.
    pub fn cursor_shape(&self) -> CursorShape {
        self.cursor_shape_of(self.mode())
    }

    /// The cursor shape for `mode`: a block unless set otherwise.
    pub fn cursor_shape_of(&self, mode: &str) -> CursorShape {
        self.cursor_shapes.get(mode).copied().unwrap_or_default()
    }

    pub fn keymap(&self) -> &Keymap {
        &self.keymap
    }

    pub fn keymap_mut(&mut self) -> &mut Keymap {
        &mut self.keymap
    }

    /// Keys pressed so far in an unfinished sequence.
    pub fn pending(&self) -> &[Key] {
        &self.acting_client().pending
    }

    /// Binds `keys` for the next key press only (see `overlay`), or drops
    /// such bindings with `None`.
    pub fn set_overlay(&mut self, keys: Option<HashMap<Key, Arc<str>>>) {
        self.acting_client_mut().overlay = keys;
    }

    /// Whether `key`, pressed next by the acting client, would do something
    /// of its own: run a command or go on with a sequence, rather than fall
    /// to the mode's default (typing it) or to nothing.
    #[must_use]
    pub fn binds(&self, key: Key) -> bool {
        let client = &self.clients[&self.acting];
        let buffer = &self.buffers[&client.views[&client.focus].buffer];
        let fresh = client.pending.is_empty() && client.count.is_none();
        if fresh
            && (client
                .overlay
                .as_ref()
                .is_some_and(|o| o.contains_key(&key))
                || buffer.key(key).is_some())
        {
            return true;
        }
        let mut keys = client.pending.clone();
        keys.push(key);
        !matches!(
            self.keymap.resolve(&client.mode, buffer.kind(), &keys),
            Resolution::Unbound
        )
    }

    /// Feeds a key press into the keymap for the acting client's mode and
    /// focused buffer.
    pub fn press(&mut self, key: Key) -> KeyOutcome {
        let Editor {
            clients,
            acting,
            keymap,
            buffers,
            ..
        } = self;
        let client = clients.get_mut(acting).expect("the acting client exists");
        if client.pending.is_empty()
            && client.count.is_none()
            && let Some(overlay) = client.overlay.take()
            && let Some(name) = overlay.get(&key)
        {
            return KeyOutcome::Command {
                name: name.clone(),
                keys: vec![key],
                count: None,
            };
        }
        let buffer = &buffers[&client.views[&client.focus].buffer];
        if client.pending.is_empty()
            && client.count.is_none()
            && let Some(name) = buffer.key(key)
        {
            return KeyOutcome::Command {
                name: name.clone(),
                keys: vec![key],
                count: None,
            };
        }
        if let Some(digit) = count_digit(keymap, client, key) {
            client.count = Some(
                client
                    .count
                    .unwrap_or(0)
                    .saturating_mul(10)
                    .saturating_add(digit),
            );
            return KeyOutcome::Pending;
        }
        client.pending.push(key);
        match keymap.resolve(&client.mode, buffer.kind(), &client.pending) {
            Resolution::Pending => KeyOutcome::Pending,
            Resolution::Command(name) => KeyOutcome::Command {
                name,
                keys: std::mem::take(&mut client.pending),
                count: client.count.take(),
            },
            Resolution::Unbound => {
                let keys = std::mem::take(&mut client.pending);
                let count = client.count.take();
                match keymap.fallback(&client.mode) {
                    Some(name) if keys.len() == 1 => KeyOutcome::Command {
                        name: name.clone(),
                        keys,
                        count,
                    },
                    _ => KeyOutcome::Unbound(keys),
                }
            }
        }
    }

    /// The text of `view`'s buffer with its selection marked: `|` at each
    /// head and `^` at the anchor of each non-empty range. For tests and the
    /// REPL.
    pub fn marked_text(&self, view: ViewId) -> String {
        let view = self.view(view);
        let mut text = self.buffer(view.buffer).text().to_string();
        let mut marks: Vec<(usize, char)> = view
            .selection
            .ranges()
            .iter()
            .flat_map(|r| {
                let anchor = (!r.is_empty()).then_some((r.anchor, '^'));
                std::iter::once((r.head, '|')).chain(anchor)
            })
            .collect();
        marks.sort_unstable_by(|a, b| b.cmp(a));
        for (pos, mark) in marks {
            text.insert(pos, mark);
        }
        text
    }

    /// How many copies the clipboard remembers.
    const CLIPBOARD_HISTORY: usize = 20;

    /// Puts text on the clipboard: one piece per selection it came from.
    pub fn copy(&mut self, pieces: Vec<String>) {
        self.acting_client_mut().copied = Some(pieces.join("\n"));
        self.remember_copy(pieces);
    }

    fn remember_copy(&mut self, pieces: Vec<String>) {
        self.clipboard.push(pieces);
        let extra = self.clipboard.len().saturating_sub(Self::CLIPBOARD_HISTORY);
        self.clipboard.drain(..extra);
    }

    /// Makes `text`, from the system clipboard, the latest copy, unless it
    /// already is. It isn't sent back to the client.
    pub fn take_system_clipboard(&mut self, text: &str) {
        if self.clipboard().is_some_and(|last| last.join("\n") == text) {
            return;
        }
        self.remember_copy(vec![text.to_owned()]);
    }

    /// The latest copy, once, as one text, for the client to put on the
    /// system clipboard.
    pub fn take_copied(&mut self) -> Option<String> {
        self.acting_client_mut().copied.take()
    }

    /// Asks a client to notify the user's desktop: `to`, or without it the
    /// client used last. Nothing happens when that client isn't attached.
    pub fn notify(&mut self, notice: Notice, to: Option<ClientId>) {
        let to = to.unwrap_or(self.last_active);
        if let Some(client) = self.clients.get_mut(&to) {
            client.notices.push(notice);
        }
    }

    /// The notifications not yet sent to the acting client, oldest first.
    pub fn take_notices(&mut self) -> Vec<Notice> {
        std::mem::take(&mut self.acting_client_mut().notices)
    }

    /// Asks client `to` what `ask` says, which it finds out on its own
    /// machine: its answer, or nothing, comes on the channel returned. A
    /// client that has gone has nothing to give.
    pub fn ask_client(
        &mut self,
        to: ClientId,
        ask: Ask,
    ) -> crossbeam_channel::Receiver<Option<Answer>> {
        let (answer, answered) = crossbeam_channel::bounded(1);
        let Some(client) = self.clients.get_mut(&to).filter(|c| !c.parked) else {
            let _ = answer.send(None);
            return answered;
        };
        self.asked += 1;
        let id = self.asked;
        client.asks.push((id, ask));
        self.asks.insert(id, (to, answer));
        answered
    }

    /// Asks the acting client for the image on its system clipboard, which
    /// it reads on its own machine: its answer, PNG or nothing, comes on
    /// the channel returned.
    pub fn ask_clipboard_image(&mut self) -> crossbeam_channel::Receiver<Option<Answer>> {
        if let Some(fake) = &self.fake_clipboard_image {
            let (answer, answered) = crossbeam_channel::bounded(1);
            let png = Some(fake.clone()).filter(|png| !png.is_empty());
            let _ = answer.send(png.map(Answer::Png));
            return answered;
        }
        self.ask_client(self.acting, Ask::ClipboardImage)
    }

    /// What the acting client hasn't been asked yet, with each ask's number.
    pub fn take_asks(&mut self) -> Vec<(u64, Ask)> {
        std::mem::take(&mut self.acting_client_mut().asks)
    }

    /// Client `by`'s answer to ask `id`, or none. Only the client that was
    /// asked answers.
    pub fn answer_ask(&mut self, by: ClientId, id: u64, said: Option<Answer>) {
        if self.asks.get(&id).is_some_and(|(asked, _)| *asked == by)
            && let Some((_, answer)) = self.asks.remove(&id)
        {
            let _ = answer.send(said);
        }
    }

    /// Makes every ask for the clipboard's image get `png` at once, as if a
    /// client had answered, for tests: an empty one says there's none, and
    /// `None` asks clients again.
    pub fn fake_clipboard_image(&mut self, png: Option<Vec<u8>>) {
        self.fake_clipboard_image = png;
    }

    /// The latest copy, if any.
    pub fn clipboard(&self) -> Option<&[String]> {
        self.clipboard.last().map(Vec::as_slice)
    }

    /// Every remembered copy, newest first.
    pub fn clipboard_history(&self) -> impl Iterator<Item = &[String]> {
        self.clipboard.iter().rev().map(Vec::as_slice)
    }

    /// Asks whoever runs the editor to stop it.
    pub fn request_quit(&mut self) {
        self.quit_requested = true;
    }

    pub fn quit_requested(&self) -> bool {
        self.quit_requested
    }

    /// Asks whoever runs the editor to let the acting client go and keep
    /// running without it.
    pub fn request_detach(&mut self) {
        self.acting_client_mut().detach_requested = true;
    }

    /// Whether a detach was asked for since the last call.
    pub fn take_detach_request(&mut self) -> bool {
        std::mem::take(&mut self.acting_client_mut().detach_requested)
    }

    /// Asks whoever runs the editor to send the acting client to another
    /// session, which lets it go from this one.
    pub fn request_switch(&mut self, to: SwitchTo) {
        self.acting_client_mut().switch_requested = Some(to);
    }

    /// Where a switch was asked to go since the last call, if one was.
    pub fn take_switch_request(&mut self) -> Option<SwitchTo> {
        self.acting_client_mut().switch_requested.take()
    }

    /// Queues a message for the user.
    pub fn echo(&mut self, message: impl Into<String>) {
        let message = message.into();
        if self.recent.len() == RECENT_MESSAGES {
            self.recent.pop_front();
        }
        self.recent.push_back(message.clone());
        self.messages.push(message);
    }

    /// The last messages shown, oldest first, whole: the status line shows
    /// only a message's first line.
    pub fn recent_messages(&self) -> impl Iterator<Item = &str> {
        self.recent.iter().map(String::as_str)
    }

    pub fn take_messages(&mut self) -> Vec<String> {
        std::mem::take(&mut self.messages)
    }

    /// The messages queued after the first `count`, leaving those.
    pub fn take_messages_after(&mut self, count: usize) -> Vec<String> {
        self.messages.split_off(count.min(self.messages.len()))
    }

    /// The messages queued since they were last taken.
    pub fn messages(&self) -> &[String] {
        &self.messages
    }

    fn next_id(&mut self) -> u32 {
        let id = self.next_id;
        self.next_id += 1;
        id
    }

    /// Opens a view of `buffer` for every client, all with `selection`, and
    /// focuses it for the acting one.
    fn add_view(&mut self, buffer: BufferId, selection: Selection) -> ViewId {
        let id = self.new_view(buffer, selection);
        self.acting_client_mut().focus = id;
        id
    }

    /// Opens a view of `buffer` for every client, all with `selection`.
    fn new_view(&mut self, buffer: BufferId, selection: Selection) -> ViewId {
        self.open_view(&View {
            // `open_view` gives it its own.
            id: ViewId(0),
            buffer,
            selection,
            scroll: Scroll::default(),
            visible: None,
            size: None,
            area: None,
            lines: None,
            filter: None,
            columns: 0,
        })
    }

    /// Opens a view for every client, each seeing it as `view`.
    fn open_view(&mut self, view: &View) -> ViewId {
        let id = ViewId(self.next_id());
        let view = View { id, ..view.clone() };
        for client in self.clients.values_mut() {
            client.views.insert(id, view.clone());
        }
        id
    }

    /// Closes `buffer`, unsaved changes and all. Fails while a view shows it,
    /// so whoever closes it decides what those views show instead.
    pub fn close_buffer(&mut self, buffer: BufferId) -> Result<(), Error> {
        if self.shown(buffer) {
            return Err(Error::Shown);
        }
        self.buffers.remove(&buffer);
        self.buffer_projects.remove(&buffer);
        Ok(())
    }

    /// Removes a buffer that has no file and no view left.
    fn drop_if_unused(&mut self, buffer: BufferId) {
        let b = &self.buffers[&buffer];
        let unused = b.path().is_none() && !b.is_kept() && !self.shown(buffer);
        if unused {
            self.buffers.remove(&buffer);
        }
    }

    /// Undoes, or redoes unless `undoing`, in `view`'s buffer, for the
    /// acting client. A step it made itself puts its selection back where it
    /// was; another client's step moves its selection along with the text,
    /// as any edit does.
    fn history_step(&mut self, view: ViewId, undoing: bool) -> Result<bool, Error> {
        let id = self.view(view).buffer;
        let tx_id = self.replica.next_id();
        let acting = self.acting;
        let current = self.view(view).selection.clone();
        let buffer = self.buffers.get_mut(&id).expect("view's buffer exists");
        let (step, by): (HistoryStep, _) = if undoing {
            (Buffer::undo, buffer.history().undo_author())
        } else {
            (Buffer::redo, buffer.history().redo_author())
        };
        let theirs = matches!(by, Some(Author::User(client)) if *client != acting);
        let Some(restored) = step(buffer, tx_id, Author::User(acting), &current)? else {
            return Ok(false);
        };
        let selection = if theirs {
            current.map(buffer.history().latest())
        } else {
            restored
        };
        self.view_mut(view).selection = selection;
        self.map_views(id, Some(view));
        Ok(true)
    }

    /// Maps the selections of views on `buffer` through the buffer's latest
    /// transaction, for every client: all but the acting client's `except`.
    fn map_views(&mut self, buffer: BufferId, except: Option<ViewId>) {
        let changes = self.buffers[&buffer].history().latest();
        for (client, state) in &mut self.clients {
            for (id, other) in &mut state.views {
                let skipped = *client == self.acting && Some(*id) == except;
                if !skipped && other.buffer == buffer {
                    other.selection = other.selection.map(changes);
                }
            }
        }
    }
}

/// Cuts `marks` to `buffer`'s text.
fn clamp_marks(buffer: &Buffer, marks: &mut [Mark]) {
    let len = buffer.text().len_bytes();
    for mark in marks {
        let end = mark.range.end.min(len);
        mark.range = mark.range.start.min(end)..end;
    }
}

/// `reveal` as the editor keeps it: `Auto` and `Typing` as `Line`.
fn settled(reveal: Reveal) -> Reveal {
    match reveal {
        Reveal::Auto | Reveal::Typing => Reveal::Line,
        Reveal::Line | Reveal::Cursor | Reveal::Never => reveal,
    }
}

/// The digit `key` adds to `client`'s count: counts are on in its mode, no
/// sequence has started, and it's a plain digit (0 only after another).
fn count_digit(keymap: &Keymap, client: &ClientState, key: Key) -> Option<u32> {
    let KeyCode::Char(c) = key.code else {
        return None;
    };
    let digit = c.to_digit(10)?;
    let counting = key.mods == Mods::NONE
        && client.pending.is_empty()
        && (digit != 0 || client.count.is_some())
        && keymap.counts(&client.mode);
    counting.then_some(digit)
}

/// `path` as buffers know their files: absolute (from the current
/// directory when relative), with `.` and `..` worked out without following
/// symbolic links, so "src/a.rs", "./src/../src/a.rs" and "/home/me/src/a.rs"
/// are one buffer.
pub fn file_path(path: &Path) -> std::io::Result<PathBuf> {
    let mut clean = PathBuf::new();
    for part in std::path::absolute(path)?.components() {
        match part {
            Component::ParentDir => {
                clean.pop();
            }
            Component::CurDir => {}
            other => clean.push(other),
        }
    }
    Ok(clean)
}

/// Parses text written with [`Editor::marked_text`]'s markers: `|` at each
/// head and `^` before it at the anchor of a non-empty range. The first
/// range is primary.
pub fn parse_marked(marked: &str) -> Result<(String, Selection), greed_text::Error> {
    let mut text = String::with_capacity(marked.len());
    let mut ranges = Vec::new();
    let mut anchor = None;
    for c in marked.chars() {
        match c {
            '^' => anchor = Some(text.len()),
            '|' => ranges.push(Range::new(anchor.take().unwrap_or(text.len()), text.len())),
            c => text.push(c),
        }
    }
    Ok((text, Selection::new(ranges, 0)?))
}
