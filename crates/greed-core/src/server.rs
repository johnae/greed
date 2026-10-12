//! The editor server: one thread that owns all editor state and the Luau VM,
//! and talks to clients only through messages.
//!
//! Clients send input and get back frames, over channels in the same
//! process or as JSON lines over a session socket.

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::io::Write;
use std::ops::Range;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, Sender, select};
use serde::{Deserialize, Serialize};

use crate::control::{Attachment, Session, read_line_within};
use crate::delta::FrameDelta;
use crate::image::{Image, ImageId};
use crate::keymap::{Key, KeyCode, Mods};
use crate::luau::{Host, HostError};
use crate::mouse::Mouse;
use crate::render::{CellWidth, Decorations, Frame, Renderer, Size, Status, StatusLine};
use crate::syntax::{Highlight, Syntax};
use crate::{BufferId, ClientInfo, Editor, FIRST_CLIENT, Notice, SwitchTo};
use greed_text::{ClientId, Rope};

/// A message from a client to the server.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Input {
    Key(Key),
    /// A key, or the text it types when the key isn't bound where it's
    /// pressed: macOS's Option keys, which are Alt to some and type
    /// characters to others (`[` on a Swedish keyboard).
    KeyOrText(Key, String),
    Resize(Size),
    Mouse(Mouse),
    /// How many pixels wide and high a cell is on the client's screen.
    CellSize(u16, u16),
    /// Run the command by this name, as from a window's menu; `name!`
    /// forces it, as on the command line.
    Run(String),
    /// Text pasted into the client, from the system clipboard: a terminal's
    /// bracketed paste, or a window's paste keys.
    Paste(String),
    /// What's on the system clipboard, which becomes the editor's clipboard,
    /// e.g. when a window gets focus after you copied in another program.
    Clipboard(String),
    /// The answer to `Output::ReadClipboardImage`: the image on the system
    /// clipboard, as PNG in base64, or none.
    ClipboardImage(u64, Option<String>),
    /// A file dropped on the client's window: its path there, and what's in it
    /// as base64 when it's small enough to send (see [`crate::dropped`]). It's
    /// pasted as a path the session can read.
    Dropped(String, Option<String>),
    /// The answer to `Output::SshAgentRequest`: what the ssh agent on the
    /// client's machine answered, the message's body in base64, or none
    /// when it couldn't be asked.
    SshAgentReply(u64, Option<String>),
    /// The answer to `Output::HomeStatus`: the status of the hub on the
    /// client's machine, or none when it couldn't be asked.
    HomeStatus(u64, Option<serde_json::Value>),
    /// A debug line from the client's side, sent while the frames it gets
    /// say the `client` topic is on (see [`crate::debug`]).
    Log(String),
    /// The client's frame doesn't match what it was sent, as when a delta
    /// didn't fit it (see [`crate::delta::FrameDelta::apply`]): the next
    /// frame comes whole.
    Refresh,
    /// Something went wrong on the client's side that you should know,
    /// like the ssh agent it relays not answering: said on its status line.
    Problem(String),
    /// The client is still there, sent every few seconds by one that asked
    /// for a heartbeat as it attached, so the session lets it go once they
    /// stop, as when the network went away under it.
    Ping,
    Quit,
}

/// A message from the server to a client.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Output {
    Frame(Frame),
    /// What changed since the last frame or delta this client got.
    Delta(FrameDelta),
    /// The server has stopped; no more messages will come.
    Exit,
    /// The server goes on without this client: it detached, or another
    /// client attached.
    Detached,
    /// The client should attach to another session instead; this one goes on
    /// without it.
    Switch(SwitchTo),
    /// Text Greed copied, for the client to put on the system clipboard.
    Clipboard(String),
    /// Asks for the image on the system clipboard, read on the client's own
    /// machine; the client answers with `Input::ClipboardImage` and this id.
    ReadClipboardImage(u64),
    /// A request from a program in the session for your ssh agent, the
    /// message's body in base64, for a client that relays it to ask the
    /// agent on its machine; it answers with `Input::SshAgentReply` and
    /// this id.
    SshAgentRequest(u64, String),
    /// Asks a client that said it would as it attached (over `greed ssh`)
    /// for the status of the hub on its own machine, which it asks as an
    /// ordinary client, so nothing there can be done through it; it answers
    /// with `Input::HomeStatus` and this id.
    HomeStatus(u64),
    /// An image frames will place, sent once before the first frame that
    /// does.
    Image(ImageData),
    /// A scene frames will place, sent before the first frame placing it
    /// and again when it changes.
    Scene(SceneData),
    /// A notification for the user's desktop, from `greed.client.notify`.
    Notify(Notice),
    /// The session is still there, sent every few seconds to a client that
    /// asked for a heartbeat as it attached, so it knows the connection went
    /// once they stop.
    Ping,
}

impl Output {
    /// Whether this is the last message a client gets on its connection: the
    /// session ended, let it go, or switched it to another session. A switch
    /// to another window leaves the client here.
    #[must_use]
    pub fn ends(&self) -> bool {
        match self {
            Output::Switch(to) => !to.window,
            other => matches!(other, Output::Exit | Output::Detached),
        }
    }
}

/// An image as it goes to a client: PNG, in base64, which is how terminal
/// image protocols take it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImageData {
    pub id: ImageId,
    pub width: u32,
    pub height: u32,
    pub png: String,
}

impl From<&Image> for ImageData {
    fn from(image: &Image) -> Self {
        use base64::Engine;
        Self {
            id: image.id,
            width: image.width,
            height: image.height,
            png: base64::engine::general_purpose::STANDARD.encode(&image.png),
        }
    }
}

/// A scene as it goes to a client: its id, version and spec, as JSON,
/// which the client reads as a `scene::Spec`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SceneData {
    pub id: crate::scene::SceneId,
    pub version: u64,
    pub spec: serde_json::Value,
}

impl From<&crate::scene::Scene> for SceneData {
    fn from(scene: &crate::scene::Scene) -> Self {
        Self {
            id: scene.id,
            version: scene.version,
            spec: serde_json::to_value(&scene.spec).unwrap_or_default(),
        }
    }
}

/// A client's end of the connection to a running server.
pub struct Connection {
    pub input: Sender<Input>,
    pub output: Receiver<Output>,
    pub server: JoinHandle<Result<(), HostError>>,
}

/// Starts a server on its own thread. `setup` runs on that thread and builds
/// the host, since the Luau VM can't move between threads. The server
/// renders a frame after every batch of input, starting with the first
/// resize, and again when a background parse brings new highlighting.
pub fn spawn<F>(setup: F) -> Connection
where
    F: FnOnce() -> Result<Host, HostError> + Send + 'static,
{
    spawn_with_session(setup, None)
}

/// Like [`spawn`], also answering requests that come in on `session`'s
/// socket, and letting clients attach through it, any number at once. The
/// client in this process is the first one; the socket closes when the
/// server stops.
pub fn spawn_with_session<F>(setup: F, session: Option<Session>) -> Connection
where
    F: FnOnce() -> Result<Host, HostError> + Send + 'static,
{
    let (input, inbox) = crossbeam_channel::unbounded();
    let (outbox, output) = crossbeam_channel::unbounded();
    let server = thread::spawn(move || {
        let host = match setup() {
            Ok(host) => host,
            Err(err) => {
                let _ = outbox.send(Output::Exit);
                return Err(err);
            }
        };
        host.use_event_loop();
        let (inbound, attached) = crossbeam_channel::unbounded();
        let mut server = Server {
            host: &host,
            clients: BTreeMap::from([(FIRST_CLIENT, Client::new(outbox, true, 0))]),
            inbound,
            connections: 0,
            watched_at: Instant::now(),
            drawn_at: Instant::now(),
            owed: false,
            key_at: None,
            reuse_status: false,
            agent_asks: HashMap::new(),
            agent_asked: 0,
            logs: session.is_some(),
        };
        if let Some(session) = &session {
            host.set_session_name(&session.name);
        }
        let started = host.started();
        server.report(started);
        server.run(&inbox, &attached, session.as_ref());
        for id in server.clients.keys().copied().collect::<Vec<_>>() {
            server.send_to(id, Output::Exit);
        }
        Ok(())
    });
    Connection {
        input,
        output,
        server,
    }
}

/// What an attached client's connection read: the client, which of its
/// connections (one coming back gets a new one), and its input, or `None`
/// once the connection closed.
type Inbound = (ClientId, u64, Option<Input>);

/// A client the server sends frames to.
struct Client {
    output: Sender<Output>,
    /// In the same process: when it goes, the editor goes with it. It gets
    /// whole frames, since nothing has to be sent anywhere.
    local: bool,
    /// Which connection is its, so what an earlier one of its read is left
    /// out.
    connection: u64,
    /// The last frame a remote client got, so the next can be sent as what
    /// changed, and how many it got (see [`Frame::seq`]).
    last: Option<Frame>,
    sent: u64,
    /// The images whose data it has.
    images: HashSet<ImageId>,
    /// The version of each scene it has.
    scenes: HashMap<crate::scene::SceneId, u64>,
    /// Lays out its frames, and knows where it put things for its clicks.
    renderer: Renderer<CellWidth>,
    /// Its screen's size, once it has said.
    size: Option<Size>,
    /// The latest message or error for its status line, until its next key.
    message: Option<String>,
    /// The status line a plugin built for its last frame, to draw again when
    /// only highlighting changed since: no plugin code ran to change it.
    status: Option<StatusLine>,
    /// What it typed (keys, pastes, clicks) while its last key's command
    /// was still at work, to handle in order once it's done. Another
    /// client's keys don't wait for it.
    held: VecDeque<Input>,
    /// Since when `held` has waited for the command at work now.
    held_since: Option<Instant>,
    /// What it answers for on its own machine.
    answers: crate::control::Answers,
}

impl Client {
    fn new(output: Sender<Output>, local: bool, connection: u64) -> Self {
        Self {
            output,
            local,
            connection,
            answers: crate::control::Answers::default(),
            last: None,
            sent: 0,
            images: HashSet::new(),
            scenes: HashMap::new(),
            renderer: Renderer::new(CellWidth),
            size: None,
            message: None,
            status: None,
            held: VecDeque::new(),
            held_since: None,
        }
    }

    /// What to send this client for `frame`, or `None` if nothing changed.
    fn output_for(&mut self, mut frame: Frame) -> Option<Output> {
        if self.local {
            return Some(Output::Frame(frame));
        }
        frame.seq = self.sent + 1;
        let output = match &self.last {
            None => Some(Output::Frame(frame.clone())),
            Some(last) => FrameDelta::between(last, &frame).map(Output::Delta),
        };
        // Numbered by what's sent: the client never sees one unchanged.
        match output {
            Some(_) => self.sent = frame.seq,
            None => frame.seq = self.sent,
        }
        self.last = Some(frame);
        output
    }
}

struct Server<'a> {
    host: &'a Host,
    /// The clients attached, by their editor ids; the one in this process
    /// is [`FIRST_CLIENT`], until it goes.
    clients: BTreeMap<ClientId, Client>,
    /// Where attached clients' connections send what they read.
    inbound: Sender<Inbound>,
    /// How many connections clients have attached with.
    connections: u64,
    /// When the watched files were last looked at.
    watched_at: Instant,
    /// When the last frame was drawn, and whether work since wants another.
    drawn_at: Instant,
    owed: bool,
    /// When the last key or paste came, until a terminal's output after it
    /// was drawn as its echo.
    key_at: Option<Instant>,
    /// Whether all that happened since the last frame was a parse, so each
    /// client's status line can be drawn again as it was.
    reuse_status: bool,
    /// Programs' ssh agent requests on their way, by id, and the last id.
    agent_asks: HashMap<u64, AgentAsk>,
    agent_asked: u64,
    /// Whether problems go to the session's log, which its output is. An
    /// editor in a terminal has none, and keeps the screen clean.
    logs: bool,
}

/// A program's ssh agent request on its way to the agent: the client
/// relaying it, whether it waits for plugins to allow it first, and
/// since when it waits.
struct AgentAsk {
    request: crate::ssh_agent::Request,
    client: ClientId,
    allowing: bool,
    since: Instant,
}

/// How often watched files are looked at.
const WATCH_EVERY: Duration = Duration::from_millis(500);

/// The least time between frames, about a fast screen's refresh. Work that
/// wakes the server more often than this (a program flooding a terminal, a
/// language server's burst of messages) is drawn once for each.
const FRAME_EVERY: Duration = Duration::from_millis(8);

/// How soon after a key a terminal's output counts as the program echoing
/// it, drawn at once as the key was instead of waiting its turn. The first
/// output after each key only, so a flood of output stays paced.
const ECHO_WITHIN: Duration = Duration::from_millis(100);

/// How long what's typed waits for a key's command still at work, like
/// one waiting on a slow program or the network, before it's handled
/// anyway, so the editor never seems frozen.
const KEYS_WAIT_AT_MOST: Duration = Duration::from_millis(500);

/// How `input` waits behind a key's command at work.
enum Turn {
    /// Typed by the user: it waits its turn.
    Waits,
    /// Esc and ctrl-c: they get through to cancel or interrupt the command,
    /// but keep their place behind keys already waiting, so typing ahead
    /// gives the same result as typing slowly.
    Interrupts,
    /// Never waits, like a resize.
    Never,
}

fn turn_of(input: &Input) -> Turn {
    match input {
        Input::Key(key)
            if matches!(
                (key.code, key.mods),
                (KeyCode::Esc, Mods::NONE) | (KeyCode::Char('c'), Mods::CTRL)
            ) =>
        {
            Turn::Interrupts
        }
        Input::Key(_)
        | Input::KeyOrText(..)
        | Input::Mouse(_)
        | Input::Paste(_)
        | Input::Dropped(..)
        | Input::Run(_) => Turn::Waits,
        Input::Resize(_)
        | Input::CellSize(..)
        | Input::Clipboard(_)
        | Input::ClipboardImage(..)
        | Input::HomeStatus(..)
        | Input::SshAgentReply(..)
        | Input::Log(_)
        | Input::Refresh
        | Input::Problem(_)
        | Input::Ping
        | Input::Quit => Turn::Never,
    }
}

/// The next message for a client, or None once there are no more: with a
/// heartbeat (`beat`), a `Ping` after that long with nothing to send, so it
/// hears the session is still there.
fn next_out(outgoing: &Receiver<Output>, beat: Option<Duration>) -> Option<Output> {
    let Some(beat) = beat else {
        return outgoing.recv().ok();
    };
    match outgoing.recv_timeout(beat) {
        Ok(message) => Some(message),
        Err(crossbeam_channel::RecvTimeoutError::Timeout) => Some(Output::Ping),
        Err(crossbeam_channel::RecvTimeoutError::Disconnected) => None,
    }
}

/// Whether a terminal's output now is the echo of the key at `key_at`.
fn is_echo(key_at: Option<Instant>, now: Instant) -> bool {
    key_at.is_some_and(|at| now.saturating_duration_since(at) < ECHO_WITHIN)
}

impl Server<'_> {
    /// With files watched, when to wake up to look at them.
    fn watch_timer(&self) -> Receiver<Instant> {
        if self.host.watching() {
            crossbeam_channel::at(self.watched_at + WATCH_EVERY)
        } else {
            crossbeam_channel::never()
        }
    }

    /// With a frame owed, when to wake up to draw it.
    fn frame_timer(&self) -> Receiver<Instant> {
        if self.owed {
            crossbeam_channel::at(self.drawn_at + FRAME_EVERY)
        } else {
            crossbeam_channel::never()
        }
    }

    /// Whether to draw a frame now, after keys (`typed`) or other work. A
    /// frame too soon after the last is owed until [`FRAME_EVERY`] is up.
    fn frame_due(&mut self, typed: bool) -> bool {
        self.owed = !typed && self.drawn_at.elapsed() < FRAME_EVERY;
        if !self.owed {
            self.drawn_at = Instant::now();
        }
        !self.owed
    }

    /// With input held for a key's command, when to stop waiting for it.
    fn held_timer(&self) -> Receiver<Instant> {
        self.clients
            .values()
            .filter(|c| !c.held.is_empty())
            .filter_map(|c| c.held_since)
            .min()
            .map_or_else(crossbeam_channel::never, |since| {
                crossbeam_channel::at(since + KEYS_WAIT_AT_MOST)
            })
    }

    /// Handles a batch of messages from client `id`, or holds them while
    /// its last key's command is at work. False when the editor should
    /// stop.
    fn inputs(&mut self, id: ClientId, inputs: impl Iterator<Item = Input>) -> bool {
        for input in inputs {
            if self.must_wait(id, &input) {
                crate::debug!(
                    Keys,
                    "client {} {input:?} waits for its last key's command",
                    id.0
                );
                if let Some(client) = self.clients.get_mut(&id) {
                    client.held.push_back(input);
                }
            } else if !self.guarded(|s| s.input(id, &input)) {
                return false;
            }
        }
        true
    }

    /// What client `id`'s connection `connection` read. Input from one it
    /// had before, which closed, is left out. False when the editor should
    /// stop.
    fn inbound(&mut self, id: ClientId, connection: u64, input: Option<Input>) -> bool {
        if self
            .clients
            .get(&id)
            .is_none_or(|c| c.connection != connection)
        {
            return true;
        }
        if let Some(input) = input {
            return self.inputs(id, std::iter::once(input));
        }
        self.let_go(id);
        true
    }

    /// Handles what attached clients' connections read, `first` and the
    /// rest that came with it. False when the editor should stop.
    fn inbound_batch(&mut self, first: Inbound, attached: &Receiver<Inbound>) -> bool {
        std::iter::once(first)
            .chain(attached.try_iter())
            .all(|(id, connection, input)| self.inbound(id, connection, input))
    }

    /// Whether `input` from client `id` has to wait for its input held
    /// before it, or for its last key's command, which is still at work.
    fn must_wait(&mut self, id: ClientId, input: &Input) -> bool {
        let Some(client) = self.clients.get_mut(&id) else {
            return false;
        };
        let holding = !client.held.is_empty();
        match turn_of(input) {
            Turn::Interrupts | Turn::Waits if holding => true,
            Turn::Never | Turn::Interrupts => false,
            Turn::Waits => {
                let at_work = self.host.key_command_at_work(id);
                if at_work {
                    client.held_since = Some(Instant::now());
                }
                at_work
            }
        }
    }

    /// Handles the input held for each client's key's command, in order,
    /// once it's no longer at work or has held it up for
    /// [`KEYS_WAIT_AT_MOST`]. Input a held key's own command makes wait
    /// stays held. Sets `typed` when any was handled. False when the editor
    /// should stop.
    fn handle_held(&mut self, typed: &mut bool) -> bool {
        let ids: Vec<ClientId> = self.clients.keys().copied().collect();
        for id in ids {
            while let Some(input) = self.next_held(id) {
                *typed = true;
                if !self.guarded(|s| s.input(id, &input)) {
                    return false;
                }
                // A command this one starts holds up the rest from now.
                if let Some(client) = self.clients.get_mut(&id) {
                    client.held_since = Some(Instant::now());
                }
            }
        }
        true
    }

    /// Takes client `id`'s next held input once its key's command is no
    /// longer at work or has held it up for [`KEYS_WAIT_AT_MOST`]. `None`
    /// while it still waits, or with nothing held.
    fn next_held(&mut self, id: ClientId) -> Option<Input> {
        let client = self.clients.get_mut(&id)?;
        if client.held.is_empty() {
            client.held_since = None;
            return None;
        }
        if self.host.key_command_at_work(id) {
            let since = *client.held_since.get_or_insert_with(Instant::now);
            if since.elapsed() < KEYS_WAIT_AT_MOST {
                return None;
            }
            crate::debug!(
                Keys,
                "client {}: let through after {} ms, the command still at work",
                id.0,
                since.elapsed().as_millis()
            );
            self.host.let_keys_through(id);
        }
        client.held.pop_front()
    }

    /// Wakes the code waiting on timers that are due. The next frame can show
    /// the last status lines again when all that happened since was a parse
    /// (`only_parsed`): timers wake plugin code, which may change them.
    fn fire_timers(&mut self, only_parsed: bool) {
        let now = Instant::now();
        let due = self.host.next_timer().is_some_and(|due| due <= now);
        self.reuse_status = only_parsed && !due;
        let fired = self.host.fire_timers(now);
        self.report(fired);
    }

    /// Tells plugins about watched files that changed, at most every
    /// [`WATCH_EVERY`].
    fn look_at_watched_files(&mut self) {
        if self.watched_at.elapsed() >= WATCH_EVERY {
            self.watched_at = Instant::now();
            let checked = self.host.check_watches();
            self.report(checked);
        }
    }

    fn run(
        &mut self,
        inbox: &Receiver<Input>,
        attached: &Receiver<Inbound>,
        session: Option<&Session>,
    ) {
        let trees = self.host.parses();
        let lsp_events = self.host.lsp_events();
        let finished_jobs = self.host.finished_jobs();
        let terminal_events = self.host.terminal_events();
        let requests = session.map_or_else(crossbeam_channel::never, |s| s.requests().clone());
        let attachments =
            session.map_or_else(crossbeam_channel::never, |s| s.attachments().clone());
        let closed = session.map_or_else(crossbeam_channel::never, |s| s.closed().clone());
        let agent_requests =
            session.map_or_else(crossbeam_channel::never, Session::ssh_agent_requests);
        // Where selections and focus start, for the first frame to compare.
        let started = self.host.report_selections();
        self.report(started);
        loop {
            let mut problems = self.host.update_syntax();
            problems.extend(self.host.sync_lsp());
            if let Some(problem) = problems.pop() {
                self.say(problem);
            }
            // Wake up in time for the next timer a command is waiting on.
            let timer = self
                .host
                .next_timer()
                .map_or_else(crossbeam_channel::never, crossbeam_channel::at);
            let look = self.watch_timer();
            // What clients send is drawn at once; other work waits its turn.
            let (mut typed, mut only_parsed) = (false, false);
            select! {
                recv(inbox) -> first => {
                    let Ok(first) = first else { return };
                    typed = true;
                    if !self.inputs(FIRST_CLIENT, std::iter::once(first).chain(inbox.try_iter())) {
                        return;
                    }
                }
                recv(attached) -> first => {
                    if let Ok(first) = first {
                        typed = true;
                        if !self.inbound_batch(first, attached) {
                            return;
                        }
                    }
                }
                recv(trees) -> parsed => {
                    if let Ok(parsed) = parsed {
                        self.host.receive_parse(parsed);
                        only_parsed = true;
                    }
                }
                recv(lsp_events) -> event => {
                    if let Ok(event) = event {
                        let handled = self.host.handle_lsp(event);
                        self.report(handled);
                    }
                }
                recv(terminal_events) -> event => {
                    if let Ok(event) = event {
                        let handled = self.host.handle_terminal(event);
                        self.report(handled);
                        typed = is_echo(self.key_at.take(), Instant::now());
                    }
                }
                recv(finished_jobs) -> done => {
                    if let Ok(done) = done {
                        let finished = self.host.finish_job(done);
                        self.report(finished);
                    }
                }
                recv(requests) -> request => {
                    if let Ok(request) = request {
                        let handled = self.host.handle_request(request);
                        self.report(handled);
                    }
                }
                recv(closed) -> id => {
                    if let Ok(id) = id {
                        // The connection's last requests come first, so
                        // plugins hear it closed after them.
                        for request in requests.try_iter() {
                            let handled = self.host.handle_request(request);
                            self.report(handled);
                        }
                        let told = self.host.connection_closed(id);
                        self.report(told);
                    }
                }
                recv(attachments) -> attachment => {
                    if let Ok(attachment) = attachment {
                        self.attach(attachment);
                    }
                }
                recv(agent_requests) -> request => {
                    if let Ok(request) = request {
                        self.agent_request(request);
                    }
                }
                recv(timer) -> _ => {}
                recv(look) -> _ => {}
                recv(self.frame_timer()) -> _ => {}
                recv(self.held_timer()) -> _ => {}
            }
            if !self.carry_on(typed, only_parsed) {
                return;
            }
        }
    }

    /// What every turn of the loop ends with: timers, watched files, held
    /// input, messages, what the editor asked for and, when one is due, a
    /// frame for each client. False when the editor should stop.
    fn carry_on(&mut self, mut typed: bool, only_parsed: bool) -> bool {
        self.fire_timers(only_parsed);
        self.look_at_watched_files();
        if !self.handle_held(&mut typed) {
            return false;
        }
        if let Some(latest) = self.host.with_editor_mut(|ed| ed.take_messages().pop()) {
            self.say(latest);
        }
        if !self.follow_requests() {
            return false;
        }
        self.follow_agent_answers();
        if self.frame_due(typed) {
            let reported = self.host.report_selections();
            self.report(reported);
            return self.guarded(Self::draw);
        }
        true
    }

    /// Runs `f` with the editor acting for client `id`, then for the one it
    /// acted for before.
    fn as_client<R>(&self, id: ClientId, f: impl FnOnce(&mut Editor) -> R) -> R {
        self.host.with_editor_mut(|ed| {
            let outer = ed.act_as(id);
            let result = f(ed);
            ed.act_as(outer);
            result
        })
    }

    /// The client used last, of those attached: what goes to nobody in
    /// particular, like a message from a timer, goes to it.
    fn last_active(&self) -> Option<ClientId> {
        let last = self.host.with_editor(Editor::last_active);
        if self.clients.contains_key(&last) {
            return Some(last);
        }
        self.clients.keys().next_back().copied()
    }

    /// Shows `message` on the status line of the client used last.
    fn say(&mut self, message: String) {
        if let Some(client) = self.last_active().and_then(|id| self.clients.get_mut(&id)) {
            client.message = Some(message);
        }
    }

    /// Does what the editor asked for: quitting, notifying, switching a
    /// client to another session, or letting one go. Each client's own
    /// requests go to it alone. False when the editor ends.
    fn follow_requests(&mut self) -> bool {
        if self.host.with_editor(crate::Editor::quit_requested) {
            return false;
        }
        // Desktop notifications go to the client they're for; the client
        // used last's to the one used last that's attached.
        let notified = self.host.with_editor(Editor::last_active);
        let notices = self.as_client(notified, Editor::take_notices);
        if let Some(to) = self.last_active() {
            for notice in notices {
                self.send_to(to, Output::Notify(notice));
            }
        }
        let ids: Vec<ClientId> = self.clients.keys().copied().collect();
        for id in ids {
            for notice in self.as_client(id, Editor::take_notices) {
                self.send_to(id, Output::Notify(notice));
            }
            // Each client finds out what it's asked on its own machine.
            for (ask, what) in self.as_client(id, Editor::take_asks) {
                self.ask(id, ask, what);
            }
            let local = self.clients.get(&id).is_some_and(|c| c.local);
            if let Some(to) = self.as_client(id, Editor::take_switch_request) {
                // A client in this process can't go anywhere else.
                if local {
                    return false;
                }
                // For another window the client stays; a terminal client
                // goes, and its connection closing lets it go.
                let stays = to.window;
                self.send_to(id, Output::Switch(to));
                if !stays {
                    self.let_go(id);
                }
            } else if self.as_client(id, Editor::take_detach_request) {
                // A client in this process has nowhere to detach to: the
                // editor ends with it.
                if local {
                    return false;
                }
                self.detach(id);
            }
        }
        true
    }

    /// Sends the client `id` its next frame whole, as when its frame didn't
    /// match what it was sent (`Input::Refresh`).
    fn send_whole(&mut self, id: ClientId) {
        if let Some(client) = self.clients.get_mut(&id) {
            client.last = None;
            self.log(&format!(
                "client {}: its frame didn't match what it was sent; sending it whole",
                id.0
            ));
        }
    }

    /// Handles one message from client `id`. False when the editor should
    /// stop: the client in this process quit.
    fn input(&mut self, id: ClientId, input: &Input) -> bool {
        match *input {
            Input::Key(key) => {
                crate::debug!(Keys, "client {} pressed {key}", id.0);
                // A message lasts until the next key, unless that key
                // brings another.
                if let Some(client) = self.clients.get_mut(&id) {
                    client.message = None;
                }
                self.key_at = Some(Instant::now());
                let pressed = self.host.timed("a key", || self.host.press(id, key));
                self.report(pressed);
            }
            Input::KeyOrText(key, ref text) => {
                crate::debug!(Keys, "client {} pressed {key}, which types {text:?}", id.0);
                if let Some(client) = self.clients.get_mut(&id) {
                    client.message = None;
                }
                self.key_at = Some(Instant::now());
                let pressed = self
                    .host
                    .timed("a key", || self.host.press_or_type(id, key, text));
                self.report(pressed);
            }
            Input::Resize(new) => {
                let Some(client) = self.clients.get_mut(&id) else {
                    return true;
                };
                let size = new.limited();
                client.size = Some(size);
                self.host.with_editor_mut(|ed| {
                    ed.set_client_size(id, Some((size.width, size.height)));
                });
            }
            Input::Mouse(mouse) => {
                let Some(client) = self.clients.get(&id) else {
                    return true;
                };
                // Where it clicked in what it was shown.
                let hit = self.as_client(id, |ed| client.renderer.hit(ed, mouse.col, mouse.row));
                let handled = self.host.mouse(id, mouse, &hit);
                self.report(handled);
            }
            Input::CellSize(w, h) => self.as_client(id, |ed| ed.set_cell_size((w, h))),
            Input::Run(ref name) => {
                let ran = self.host.run(id, name);
                self.report(ran);
            }
            Input::Paste(ref text) => {
                if let Some(client) = self.clients.get_mut(&id) {
                    client.message = None;
                }
                self.key_at = Some(Instant::now());
                let pasted = self.host.paste(id, text);
                self.report(pasted);
            }
            Input::Clipboard(ref text) => {
                self.host
                    .with_editor_mut(|ed| ed.take_system_clipboard(text));
            }
            Input::ClipboardImage(ask, ref png) => {
                use base64::Engine;
                let png = png
                    .as_ref()
                    .and_then(|png| base64::engine::general_purpose::STANDARD.decode(png).ok());
                let png = png.map(crate::Answer::Png);
                self.host.with_editor_mut(|ed| ed.answer_ask(id, ask, png));
            }
            Input::HomeStatus(ask, ref status) => {
                let status = status.clone().map(crate::Answer::Json);
                self.host
                    .with_editor_mut(|ed| ed.answer_ask(id, ask, status));
            }
            Input::Dropped(ref path, ref data) => {
                let remote = self
                    .host
                    .with_editor(|ed| ed.client_state(id).is_some_and(crate::ClientState::remote));
                let dir = crate::dirs::dir(crate::dirs::Kind::Cache)
                    .unwrap_or_else(std::env::temp_dir)
                    .join("dropped");
                match crate::dropped::paste_text(path, data.as_deref(), remote, &dir) {
                    Ok(text) => {
                        let pasted = self.host.paste(id, &text);
                        self.report(pasted);
                    }
                    Err(why) => self.say(why),
                }
            }
            Input::SshAgentReply(ask, ref answer) => self.agent_reply(id, ask, answer.as_deref()),
            Input::Log(ref text) => crate::debug!(Client, "client {}: {text}", id.0),
            Input::Refresh => self.send_whole(id),
            Input::Problem(ref text) => {
                self.log(&format!("client {}: {text}", id.0));
                if let Some(client) = self.clients.get_mut(&id) {
                    client.message = Some(text.clone());
                }
            }
            Input::Ping => {}
            // The client in this process ends the editor; another leaves it.
            Input::Quit if id == FIRST_CLIENT => return false,
            Input::Quit => self.detach(id),
        }
        true
    }

    /// Runs `f`, which says whether to go on. A bug it runs into shows on
    /// the status line, and the editor goes on.
    fn guarded(&mut self, f: impl FnOnce(&mut Self) -> bool) -> bool {
        match crate::panics::catching(|| f(self)) {
            Ok(go_on) => go_on,
            Err(panic) => {
                self.log(&panic.to_string());
                self.say(first_line(&panic.to_string()));
                true
            }
        }
    }

    /// Writes `line` to the session's log, if it has one, and as a debug
    /// line on the `client` topic: what went wrong between the editor and
    /// its clients, for when a screen stops showing what it should.
    fn log(&self, line: &str) {
        crate::debug!(Client, "{line}");
        if self.logs {
            eprintln!("greed: {line}");
        }
    }

    /// Shows what went wrong, if anything did, on the status line.
    fn report(&mut self, result: Result<(), HostError>) {
        if let Err(err) = result {
            let text = err.to_string();
            // Without Luau's "runtime error:", which says nothing to you.
            let line = first_line(&err.brief());
            // For a bug, which plugin failed, and doing what; :errors has
            // the rest. A refusal ("unsaved changes in ...") is said as is.
            let source = err
                .is_located()
                .then(|| self.host.error_source(&text))
                .flatten();
            let message = match source {
                Some(source) => format!("{source}: {line}"),
                None => line,
            };
            self.say(message);
        }
    }

    fn send_to(&self, id: ClientId, output: Output) {
        if let Some(client) = self.clients.get(&id) {
            let _ = client.output.send(output);
        }
    }

    /// Asks client `id` what `what` says, as ask `ask`; one that said as it
    /// attached that it can't answer that has nothing to say.
    fn ask(&mut self, id: ClientId, ask: u64, what: crate::Ask) {
        match what {
            crate::Ask::ClipboardImage => self.send_to(id, Output::ReadClipboardImage(ask)),
            crate::Ask::HomeStatus if self.clients.get(&id).is_some_and(|c| c.answers.home) => {
                self.send_to(id, Output::HomeStatus(ask));
            }
            crate::Ask::HomeStatus => self.host.with_editor_mut(|ed| ed.answer_ask(id, ask, None)),
        }
    }

    /// Lets client `id` go; the editor carries on without it.
    fn detach(&mut self, id: ClientId) {
        self.send_to(id, Output::Detached);
        self.let_go(id);
    }

    /// Forgets client `id`, telling plugins, and parks its state for when
    /// it comes back.
    fn let_go(&mut self, id: ClientId) {
        if self.clients.remove(&id).is_none() {
            return;
        }
        self.fail_agent_asks(|ask| ask.client == id);
        let others = !self.clients.is_empty();
        let detached = self.host.client_detached(id, others);
        self.report(detached);
        self.host.with_editor_mut(|ed| ed.park_client(id));
        self.host.forget_client(id);
    }

    /// The client that relays your ssh agent and was used most recently.
    fn agent_client(&self) -> Option<ClientId> {
        self.host.with_editor(|ed| {
            self.clients
                .iter()
                .filter(|(_, c)| c.answers.ssh_agent)
                .max_by_key(|(id, _)| ed.client_state(**id).map(crate::ClientState::active_at))
                .map(|(id, _)| *id)
        })
    }

    /// Passes a program's ssh agent `request` on to the client relaying
    /// your agent. One to sign with a key waits for plugins to allow it
    /// first, with `ssh_agent.use`. With no such client, or no plugin to
    /// ask, it fails at once.
    fn agent_request(&mut self, request: crate::ssh_agent::Request) {
        let Some(client) = self.agent_client() else {
            crate::debug!(
                Client,
                "an ssh agent request, and no client relays an agent"
            );
            request.respond(None);
            return;
        };
        self.agent_asked += 1;
        let id = self.agent_asked;
        let allowing = request.is_sign();
        if allowing {
            // The machine the client is on, from its name ("tui@laptop").
            let host = self.host.with_editor(|ed| {
                ed.client_state(client)
                    .and_then(|c| c.name().split_once('@'))
                    .map(|(_, host)| host.split('#').next().unwrap_or(host).to_owned())
            });
            let asked = self.host.ask_ssh_agent_use(id, client, host.as_deref());
            let asked = match asked {
                Ok(asked) => asked,
                Err(err) => {
                    self.report(Err(err));
                    false
                }
            };
            if !asked {
                request.respond(None);
                return;
            }
        } else {
            self.relay_agent_request(id, client, &request);
        }
        let ask = AgentAsk {
            request,
            client,
            allowing,
            since: Instant::now(),
        };
        self.agent_asks.insert(id, ask);
    }

    fn relay_agent_request(&self, id: u64, client: ClientId, request: &crate::ssh_agent::Request) {
        use base64::Engine;
        let body = base64::engine::general_purpose::STANDARD.encode(&request.body);
        self.send_to(client, Output::SshAgentRequest(id, body));
    }

    /// Sends on the requests plugins allowed, and fails those they refused
    /// and those that waited longer than a program waits.
    fn follow_agent_answers(&mut self) {
        for (id, allowed) in self.host.take_ssh_agent_answers() {
            let Some(ask) = self.agent_asks.get_mut(&id).filter(|ask| ask.allowing) else {
                continue;
            };
            if allowed && self.clients.contains_key(&ask.client) {
                ask.allowing = false;
                let ask = &self.agent_asks[&id];
                self.relay_agent_request(id, ask.client, &ask.request);
            } else if let Some(ask) = self.agent_asks.remove(&id) {
                ask.request.respond(None);
            }
        }
        if !self.agent_asks.is_empty() {
            self.fail_agent_asks(|ask| ask.since.elapsed() >= crate::ssh_agent::WAIT);
        }
    }

    /// Client `by`'s answer to ssh agent request `id`, in base64, or none.
    /// Only the client that was asked answers.
    fn agent_reply(&mut self, by: ClientId, id: u64, answer: Option<&str>) {
        use base64::Engine;
        if self
            .agent_asks
            .get(&id)
            .is_some_and(|ask| ask.client == by && !ask.allowing)
            && let Some(ask) = self.agent_asks.remove(&id)
        {
            let answer =
                answer.and_then(|a| base64::engine::general_purpose::STANDARD.decode(a).ok());
            ask.request.respond(answer);
        }
    }

    /// Fails the ssh agent requests on their way that `which` picks, and
    /// tells plugins to stop asking about them.
    fn fail_agent_asks(&mut self, which: impl Fn(&AgentAsk) -> bool) {
        let failed: Vec<u64> = self
            .agent_asks
            .iter()
            .filter(|(_, ask)| which(ask))
            .map(|(id, _)| *id)
            .collect();
        for id in failed {
            if let Some(ask) = self.agent_asks.remove(&id) {
                if ask.allowing {
                    self.host.forget_ssh_agent_ask(id);
                }
                ask.request.respond(None);
            }
        }
    }

    /// Adds `attachment` as a client: the one that left by its name, back
    /// where it was, or a new one following the others, laid out as it
    /// asked if it did. Asking to take over lets the others go first. The
    /// client in this process, when it never showed anything, as when a
    /// session runs in the background, makes way for the first to attach.
    fn attach(&mut self, attachment: Attachment) {
        let Attachment {
            mut reader,
            mut writer,
            open,
            opening,
            remote,
            kind,
            name,
            layout,
            takeover,
            build,
            answers,
            heartbeat,
        } = attachment;
        let others: Vec<ClientId> = self
            .clients
            .iter()
            .filter(|(_, c)| takeover || (c.local && c.size.is_none()))
            .map(|(id, _)| *id)
            .collect();
        // What was said before anyone could see it, like a config's message
        // as a session starts, goes to the one attaching.
        let unseen = self
            .clients
            .values_mut()
            .find(|c| c.local && c.size.is_none())
            .and_then(|c| c.message.take());
        for id in others {
            self.detach(id);
        }
        let info = ClientInfo { name, kind, remote };
        let id = self.host.with_editor_mut(|ed| ed.attach_client(info));
        self.connections += 1;
        let connection = self.connections;
        let inbound = self.inbound.clone();
        // A client with a heartbeat that goes quiet for three beats is gone,
        // as when the network went away under it: reading gives up.
        if let Some(beat) = heartbeat {
            let _ = reader.get_ref().set_read_timeout(Some(beat * 3));
        }
        // A line that isn't input, even one that isn't UTF-8, is skipped; one
        // too long to read lets the client go.
        let reading = thread::Builder::new().spawn(move || {
            let mut line = Vec::new();
            loop {
                line.clear();
                if !matches!(read_line_within(&mut reader, &mut line), Ok(n) if n > 0) {
                    let _ = inbound.send((id, connection, None));
                    return;
                }
                let Ok(input) = serde_json::from_slice::<Input>(&line) else {
                    continue;
                };
                if inbound.send((id, connection, Some(input))).is_err() {
                    return;
                }
            }
        });
        let (output, outgoing) = crossbeam_channel::unbounded::<Output>();
        // With no thread to spare, the client is let go: it sees the
        // connection close.
        let logs = self.logs;
        let writing = reading.and_then(|_| {
            thread::Builder::new().spawn(move || {
                loop {
                    let Some(message) = next_out(&outgoing, heartbeat) else {
                        return;
                    };
                    let last = message.ends();
                    // Left out, a frame or delta the client goes without
                    // makes the next delta not fit, and it asks again.
                    let line = match serde_json::to_string(&message) {
                        Ok(line) => line,
                        Err(err) => {
                            if logs {
                                eprintln!("greed: client {}: couldn't send a message: {err}", id.0);
                            }
                            continue;
                        }
                    };
                    if writeln!(writer, "{line}").is_err() || last {
                        return;
                    }
                }
            })
        });
        if writing.is_err() {
            self.host.with_editor_mut(|ed| ed.park_client(id));
            return;
        }
        let mut client = Client::new(output, false, connection);
        client.answers = answers;
        client.message = unseen.or_else(|| other_build(build.as_deref()));
        self.clients.insert(id, client);
        if let Some(layout) = layout {
            let laid_out = self.host.set_client_layout(id, layout);
            self.report(laid_out);
        }
        let attached = self
            .host
            .client_attached(id, open.as_deref(), opening, remote);
        self.report(attached);
    }

    /// Sends each client that has said how big its screen is a frame, drawn
    /// as it sees the editor. Returns false once the editor should stop,
    /// because the client in this process went away.
    fn draw(&mut self) -> bool {
        let sized: Vec<(ClientId, Size)> = self
            .clients
            .iter()
            .filter_map(|(id, c)| Some((*id, c.size?)))
            .collect();
        if sized.is_empty() {
            return true;
        }
        let host = self.host;
        // A bug drawing one client's screen leaves the others theirs.
        let render_all = |server: &mut Self| -> Vec<(ClientId, Frame)> {
            sized
                .iter()
                .filter_map(|&(id, size)| {
                    match crate::panics::catching(|| server.render(id, size)) {
                        Ok(frame) => Some((id, frame?)),
                        Err(panic) => {
                            server.log(&format!("client {}: drawing its screen: {panic}", id.0));
                            None
                        }
                    }
                })
                .collect()
        };
        let mut frames = render_all(self);
        // Plugins may change views in answer (one scrolling another along),
        // which should show now rather than after the next key.
        let mut reported = host.report_views();
        if let Ok(true) = reported {
            frames = render_all(self);
            reported = host.report_views();
        }
        if let Err(err) = reported {
            self.say(first_line(&err.to_string()));
        }
        for (id, mut frame) in frames {
            frame.gui = host.gui_options(id);
            if !self.send_frame(id, frame) {
                return false;
            }
        }
        true
    }

    /// Client `id`'s frame at `size`, with its status line, drawn as it
    /// sees the editor; `None` without such a client.
    fn render(&mut self, id: ClientId, size: Size) -> Option<Frame> {
        let host = self.host;
        let (cached, message) = {
            let client = self.clients.get(&id)?;
            (client.status.clone(), client.message.clone())
        };
        let built = match cached {
            Some(line) if self.reuse_status => Ok(Some(line)),
            _ => {
                let outer = host.with_editor_mut(|ed| ed.act_as(id));
                let built = host.status_line(message.as_deref(), size.width);
                host.with_editor_mut(|ed| ed.act_as(outer));
                built
            }
        };
        let client = self.clients.get_mut(&id)?;
        let status = match built {
            Ok(Some(line)) => {
                client.status = Some(line.clone());
                Status::Line(line)
            }
            Ok(None) => {
                client.status = None;
                Status::Default {
                    message: client.message.as_deref(),
                }
            }
            Err(err) => {
                client.message = Some(format!("status line: {}", first_line(&err.to_string())));
                Status::Default {
                    message: client.message.as_deref(),
                }
            }
        };
        let render = || {
            host.with_editor_and_syntax(|ed, syntax| {
                let outer = ed.act_as(id);
                let frame = client.renderer.frame(ed, size, &status, &Shown { syntax });
                ed.act_as(outer);
                frame
            })
        };
        let started = crate::debug::on(crate::debug::Topic::Frames).then(Instant::now);
        let frame = host.timed("drawing", render);
        if let Some(started) = started {
            crate::debug!(
                Frames,
                "client {}: built a {}x{} frame in {:.2} ms",
                id.0,
                size.width,
                size.height,
                started.elapsed().as_secs_f64() * 1000.0
            );
        }
        Some(frame)
    }

    /// Sends client `id` its `frame`, with what it copied and the images
    /// the frame shows that it hasn't had. False once the editor should
    /// stop, because the client in this process went away.
    fn send_frame(&mut self, id: ClientId, frame: Frame) -> bool {
        let host = self.host;
        // What a client copied goes to it alone, for its system clipboard.
        let copied = self.as_client(id, Editor::take_copied);
        let Some(client) = self.clients.get_mut(&id) else {
            return true;
        };
        if let Some(text) = copied {
            let _ = client.output.send(Output::Clipboard(text));
        }
        // The data of images this client hasn't had yet goes first.
        let images: Vec<_> = frame
            .images
            .iter()
            .filter(|p| client.images.insert(p.id))
            .filter_map(|p| host.with_editor(|ed| ed.images().get(p.id).cloned()))
            .collect();
        let mut sent = images.iter().all(|image| {
            client
                .output
                .send(Output::Image(ImageData::from(&**image)))
                .is_ok()
        });
        // And of scenes it hasn't had as they are now.
        for placement in &frame.scenes {
            if client.scenes.insert(placement.id, placement.version) == Some(placement.version) {
                continue;
            }
            let scene = host.with_editor(|ed| ed.scenes().get(placement.id).cloned());
            if let Some(scene) = scene {
                sent &= client
                    .output
                    .send(Output::Scene(SceneData::from(&*scene)))
                    .is_ok();
            }
        }
        let Some(output) = host.timed("what changed on screen", || client.output_for(frame)) else {
            return true;
        };
        crate::debug!(
            Frames,
            "client {}: sent {}",
            id.0,
            if matches!(output, Output::Delta(_)) {
                "what changed"
            } else {
                "a whole frame"
            }
        );
        if sent && client.output.send(output).is_ok() {
            return true;
        }
        let local = client.local;
        self.let_go(id);
        !local
    }
}

fn first_line(text: &str) -> String {
    text.lines().next().unwrap_or_default().to_owned()
}

/// What's drawn over buffer text: syntax highlighting.
struct Shown<'a> {
    syntax: &'a Syntax,
}

impl Decorations for Shown<'_> {
    fn highlights(&self, buffer: BufferId, text: &Rope, range: Range<usize>) -> Vec<Highlight> {
        self.syntax.highlights(buffer, text, range)
    }
}

/// What a client of greed build `theirs` is told as it attaches to this
/// session when that's another build, as after a rebuild while the session
/// ran: which runs, and how to get a session of its own build.
fn other_build(theirs: Option<&str>) -> Option<String> {
    let ours = crate::control::build();
    let theirs = theirs?;
    (theirs != ours).then(|| {
        format!(
            "this session runs greed build {ours} and you attached with build {theirs}: \
             greed --new starts a session of yours, greed ctl quit stops this one"
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_terminals_output_right_after_a_key_is_its_echo_and_later_output_is_not() {
        let now = Instant::now();
        assert!(is_echo(Some(now), now + Duration::from_millis(2)));
        assert!(!is_echo(Some(now), now + ECHO_WITHIN));
        assert!(!is_echo(None, now), "no key, no echo");
    }
}
