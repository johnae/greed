//! The editor server: one thread that owns all editor state and the Luau VM,
//! and talks to clients only through messages.
//!
//! Clients send input and get back frames, over channels in the same
//! process or as JSON lines over a session socket.

use std::collections::{HashSet, VecDeque};
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
use crate::{BufferId, Editor, FIRST_CLIENT, Notice, SwitchTo};
use greed_text::Rope;

/// A message from a client to the server.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Input {
    Key(Key),
    Resize(Size),
    Mouse(Mouse),
    /// How many pixels wide and high a cell is on the client's screen.
    CellSize(u16, u16),
    /// Run the command by this name, as from a window's menu.
    Run(String),
    /// Text pasted into the client, from the system clipboard: a terminal's
    /// bracketed paste, or a window's paste keys.
    Paste(String),
    /// What's on the system clipboard, which becomes the editor's clipboard,
    /// e.g. when a window gets focus after you copied in another program.
    Clipboard(String),
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
    /// An image frames will place, sent once before the first frame that
    /// does.
    Image(ImageData),
    /// A notification for the user's desktop, from `greed.client.notify`.
    Notify(Notice),
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
/// socket, and letting clients attach through it. A client that attaches
/// takes over from the one before. The socket closes when the server stops.
pub fn spawn_with_session<F>(setup: F, session: Option<Session>) -> Connection
where
    F: FnOnce() -> Result<Host, HostError> + Send + 'static,
{
    let (input, inbox) = crossbeam_channel::unbounded();
    let (outbox, output) = crossbeam_channel::unbounded();
    let inputs = input.clone();
    let server = thread::spawn(move || {
        let host = match setup() {
            Ok(host) => host,
            Err(err) => {
                let _ = outbox.send(Output::Exit);
                return Err(err);
            }
        };
        host.use_event_loop();
        let mut server = Server {
            host: &host,
            renderer: Renderer::new(CellWidth),
            size: None,
            message: None,
            client: Some(Client {
                output: outbox,
                local: true,
                last: None,
                images: HashSet::new(),
            }),
            inputs,
            watched_at: Instant::now(),
            drawn_at: Instant::now(),
            owed: false,
            key_at: None,
            held: VecDeque::new(),
            held_since: None,
            status: None,
            reuse_status: false,
        };
        if let Some(session) = &session {
            host.set_session_name(&session.name);
        }
        let started = host.started();
        server.report(started);
        server.run(&inbox, session.as_ref());
        server.send(Output::Exit);
        Ok(())
    });
    Connection {
        input,
        output,
        server,
    }
}

/// Where frames go.
struct Client {
    output: Sender<Output>,
    /// In the same process: when it goes, the editor goes with it. It gets
    /// whole frames, since nothing has to be sent anywhere.
    local: bool,
    /// The last frame a remote client got, so the next can be sent as what
    /// changed.
    last: Option<Frame>,
    /// The images whose data it has.
    images: HashSet<ImageId>,
}

impl Client {
    /// What to send this client for `frame`, or `None` if nothing changed.
    fn output_for(&mut self, frame: Frame) -> Option<Output> {
        if self.local {
            return Some(Output::Frame(frame));
        }
        let output = match &self.last {
            None => Some(Output::Frame(frame.clone())),
            Some(last) => FrameDelta::between(last, &frame).map(Output::Delta),
        };
        self.last = Some(frame);
        output
    }
}

struct Server<'a> {
    host: &'a Host,
    renderer: Renderer<CellWidth>,
    /// The attached client's screen size, once it has said.
    size: Option<Size>,
    message: Option<String>,
    client: Option<Client>,
    /// For attached clients to send their input with the local client's.
    inputs: Sender<Input>,
    /// When the watched files were last looked at.
    watched_at: Instant,
    /// When the last frame was drawn, and whether work since wants another.
    drawn_at: Instant,
    owed: bool,
    /// When the last key or paste came, until a terminal's output after it
    /// was drawn as its echo.
    key_at: Option<Instant>,
    /// What the user typed (keys, pastes, clicks) while the last key's
    /// command was still at work, to handle in order once it's done.
    held: VecDeque<Input>,
    /// Since when `held` has waited for the command at work now.
    held_since: Option<Instant>,
    /// The status line a plugin built for the last frame, to draw again when
    /// only highlighting changed since: no plugin code ran to change it.
    status: Option<StatusLine>,
    reuse_status: bool,
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
        Input::Key(_) | Input::Mouse(_) | Input::Paste(_) | Input::Run(_) => Turn::Waits,
        Input::Resize(_) | Input::CellSize(..) | Input::Clipboard(_) | Input::Quit => Turn::Never,
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
        match self.held_since {
            Some(since) if !self.held.is_empty() => {
                crossbeam_channel::at(since + KEYS_WAIT_AT_MOST)
            }
            _ => crossbeam_channel::never(),
        }
    }

    /// Handles a batch of messages from the client, or holds them while a
    /// key's command is at work. False when it asked to quit.
    fn inputs(&mut self, inputs: impl Iterator<Item = Input>) -> bool {
        for input in inputs {
            if self.must_wait(&input) {
                self.held.push_back(input);
            } else if !self.guarded(|s| s.input(&input)) {
                return false;
            }
        }
        true
    }

    /// Whether `input` has to wait for the input held before it, or for the
    /// last key's command, which is still at work.
    fn must_wait(&mut self, input: &Input) -> bool {
        match turn_of(input) {
            Turn::Never => return false,
            Turn::Interrupts => return !self.held.is_empty(),
            Turn::Waits if !self.held.is_empty() => return true,
            Turn::Waits => {}
        }
        let wait = self.host.key_command_at_work(FIRST_CLIENT);
        if wait {
            self.held_since = Some(Instant::now());
        }
        wait
    }

    /// Handles the input held for a key's command, in order, once it's no
    /// longer at work or has held it up for [`KEYS_WAIT_AT_MOST`]. Input a
    /// held key's own command makes wait stays held. Sets `typed` when any
    /// was handled. False when the editor should stop.
    fn handle_held(&mut self, typed: &mut bool) -> bool {
        while !self.held.is_empty() {
            if self.host.key_command_at_work(FIRST_CLIENT) {
                let since = *self.held_since.get_or_insert_with(Instant::now);
                if since.elapsed() < KEYS_WAIT_AT_MOST {
                    return true;
                }
                self.host.let_keys_through(FIRST_CLIENT);
            }
            let input = self.held.pop_front().expect("not empty");
            *typed = true;
            if !self.guarded(|s| s.input(&input)) {
                return false;
            }
            // A command this one starts holds up the rest from now.
            self.held_since = Some(Instant::now());
        }
        self.held_since = None;
        true
    }

    /// Wakes the code waiting on timers that are due. The next frame can show
    /// the last status line again when all that happened since was a parse
    /// (`only_parsed`): timers wake plugin code, which may change it.
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

    fn run(&mut self, inbox: &Receiver<Input>, session: Option<&Session>) {
        let trees = self.host.parses();
        let lsp_events = self.host.lsp_events();
        let finished_jobs = self.host.finished_jobs();
        let terminal_events = self.host.terminal_events();
        let requests = session.map_or_else(crossbeam_channel::never, |s| s.requests().clone());
        let attachments =
            session.map_or_else(crossbeam_channel::never, |s| s.attachments().clone());
        let closed = session.map_or_else(crossbeam_channel::never, |s| s.closed().clone());
        // Where selections and focus start, for the first frame to compare.
        let started = self.host.report_selections();
        self.report(started);
        loop {
            let mut problems = self.host.update_syntax();
            problems.extend(self.host.sync_lsp());
            if let Some(problem) = problems.pop() {
                self.message = Some(problem);
            }
            // Wake up in time for the next timer a command is waiting on.
            let timer = self
                .host
                .next_timer()
                .map_or_else(crossbeam_channel::never, crossbeam_channel::at);
            let look = self.watch_timer();
            // What the client sends is drawn at once; other work waits its turn.
            let (mut typed, mut only_parsed) = (false, false);
            select! {
                recv(inbox) -> first => {
                    let Ok(first) = first else { return };
                    typed = true;
                    if !self.inputs(std::iter::once(first).chain(inbox.try_iter())) {
                        return;
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
                recv(timer) -> _ => {}
                recv(look) -> _ => {}
                recv(self.frame_timer()) -> _ => {}
                recv(self.held_timer()) -> _ => {}
            }
            self.fire_timers(only_parsed);
            self.look_at_watched_files();
            if !self.handle_held(&mut typed) {
                return;
            }
            if let Some(latest) = self.host.with_editor_mut(|ed| ed.take_messages().pop()) {
                self.message = Some(latest);
            }
            if !self.follow_requests() {
                return;
            }
            if self.frame_due(typed) {
                let reported = self.host.report_selections();
                self.report(reported);
                if !self.guarded(Self::draw) {
                    return;
                }
            }
        }
    }

    /// Does what the editor asked for: quitting, switching the client to
    /// another session, or letting it go. False when the editor ends.
    fn follow_requests(&mut self) -> bool {
        if self.host.with_editor(crate::Editor::quit_requested) {
            return false;
        }
        // Without a client attached they go nowhere.
        for notice in self.host.with_editor_mut(Editor::take_notices) {
            self.send(Output::Notify(notice));
        }
        if let Some(to) = self
            .host
            .with_editor_mut(crate::Editor::take_switch_request)
        {
            // A client in this process can't go anywhere else.
            if self.client.as_ref().is_some_and(|c| c.local) {
                return false;
            }
            self.send(Output::Switch(to));
            self.let_client_go();
        }
        if self
            .host
            .with_editor_mut(crate::Editor::take_detach_request)
        {
            // A client in this process has nowhere to detach to: the
            // editor ends with it.
            if self.client.as_ref().is_some_and(|c| c.local) {
                return false;
            }
            self.detach();
        }
        true
    }

    /// Handles one message from the client. False when it asked to quit.
    fn input(&mut self, input: &Input) -> bool {
        match *input {
            Input::Key(key) => {
                // A message lasts until the next key, unless that key
                // brings another.
                self.message = None;
                self.key_at = Some(Instant::now());
                let pressed = self
                    .host
                    .timed("a key", || self.host.press(FIRST_CLIENT, key));
                self.report(pressed);
            }
            Input::Resize(new) => {
                let size = new.limited();
                self.size = Some(size);
                self.host.with_editor_mut(|ed| {
                    ed.set_client_size(FIRST_CLIENT, Some((size.width, size.height)));
                });
            }
            Input::Mouse(mouse) => {
                let hit = self
                    .host
                    .with_editor(|ed| self.renderer.hit(ed, mouse.col, mouse.row));
                let handled = self.host.mouse(FIRST_CLIENT, mouse, &hit);
                self.report(handled);
            }
            Input::CellSize(w, h) => {
                self.host.with_editor_mut(|ed| ed.set_cell_size((w, h)));
            }
            Input::Run(ref name) => {
                let ran = self.host.run(FIRST_CLIENT, name);
                self.report(ran);
            }
            Input::Paste(ref text) => {
                self.message = None;
                self.key_at = Some(Instant::now());
                let pasted = self.host.paste(FIRST_CLIENT, text);
                self.report(pasted);
            }
            Input::Clipboard(ref text) => {
                self.host
                    .with_editor_mut(|ed| ed.take_system_clipboard(text));
            }
            Input::Quit => return false,
        }
        true
    }

    /// Runs `f`, which says whether to go on. A bug it runs into shows on
    /// the status line, and the editor goes on.
    fn guarded(&mut self, f: impl FnOnce(&mut Self) -> bool) -> bool {
        match crate::panics::catching(|| f(self)) {
            Ok(go_on) => go_on,
            Err(panic) => {
                self.message = Some(first_line(&panic.to_string()));
                true
            }
        }
    }

    /// Shows what went wrong, if anything did, on the status line.
    fn report(&mut self, result: Result<(), HostError>) {
        if let Err(err) = result {
            let text = err.to_string();
            let line = first_line(&text);
            // Which plugin failed, and doing what; :errors has the rest.
            self.message = Some(match self.host.error_source(&text) {
                Some(source) => format!("{source}: {line}"),
                None => line,
            });
        }
    }

    fn send(&mut self, output: Output) {
        if let Some(client) = &self.client {
            let _ = client.output.send(output);
        }
    }

    /// Lets the attached client go; the editor carries on without one.
    fn detach(&mut self) {
        self.send(Output::Detached);
        self.let_client_go();
    }

    /// Forgets the client, telling plugins if there was one.
    fn let_client_go(&mut self) {
        self.size = None;
        if self.client.take().is_some() {
            let detached = self.host.client_detached(FIRST_CLIENT, false);
            self.report(detached);
        }
    }

    /// Makes `attachment` the client, after telling the one before it.
    fn attach(&mut self, attachment: Attachment) {
        self.detach();
        let Attachment {
            mut reader,
            mut writer,
            open,
            terminal,
            remote,
        } = attachment;
        let inputs = self.inputs.clone();
        // A line that isn't input, even one that isn't UTF-8, is skipped; one
        // too long to read lets the client go.
        let reading = thread::Builder::new().spawn(move || {
            let mut line = Vec::new();
            loop {
                line.clear();
                if !matches!(read_line_within(&mut reader, &mut line), Ok(n) if n > 0) {
                    return;
                }
                let Ok(input) = serde_json::from_slice::<Input>(&line) else {
                    continue;
                };
                if inputs.send(input).is_err() {
                    return;
                }
            }
        });
        let (output, outgoing) = crossbeam_channel::unbounded::<Output>();
        // With no thread to spare, the client is let go: it sees the
        // connection close.
        let writing = reading.and_then(|_| {
            thread::Builder::new().spawn(move || {
                for message in outgoing {
                    let last =
                        matches!(message, Output::Exit | Output::Detached | Output::Switch(_));
                    let Ok(line) = serde_json::to_string(&message) else {
                        continue;
                    };
                    if writeln!(writer, "{line}").is_err() || last {
                        return;
                    }
                }
            })
        });
        if writing.is_err() {
            return;
        }
        self.client = Some(Client {
            output,
            local: false,
            last: None,
            images: HashSet::new(),
        });
        let attached = self
            .host
            .client_attached(FIRST_CLIENT, open.as_deref(), terminal, remote);
        self.report(attached);
    }

    /// Sends the client a frame, if there is a client that has said how big
    /// its screen is. Returns false once the editor should stop, because
    /// the client in this process went away.
    fn draw(&mut self) -> bool {
        let (Some(size), Some(_)) = (self.size, &self.client) else {
            return true;
        };
        let host = self.host;
        let built = match (&self.status, self.reuse_status) {
            (Some(line), true) => Ok(Some(line.clone())),
            _ => host.status_line(self.message.as_deref(), size.width),
        };
        let status = match built {
            Ok(Some(line)) => {
                self.status = Some(line.clone());
                Status::Line(line)
            }
            Ok(None) => {
                self.status = None;
                Status::Default {
                    message: self.message.as_deref(),
                }
            }
            Err(err) => {
                self.message = Some(format!("status line: {}", first_line(&err.to_string())));
                Status::Default {
                    message: self.message.as_deref(),
                }
            }
        };
        let render = || {
            host.with_editor_and_syntax(|ed, syntax| {
                self.renderer.frame(ed, size, &status, &Shown { syntax })
            })
        };
        let mut frame = host.timed("drawing", render);
        // Plugins may change views in answer (one scrolling another along),
        // which should show now rather than after the next key.
        let mut reported = host.report_views();
        if let Ok(true) = reported {
            frame = host.timed("drawing", render);
            reported = host.report_views();
        }
        if let Err(err) = reported {
            self.message = Some(first_line(&err.to_string()));
        }
        frame.gui = host.gui_options();
        let Some(client) = &mut self.client else {
            return true;
        };
        if let Some(text) = host.with_editor_mut(Editor::take_copied) {
            let _ = client.output.send(Output::Clipboard(text));
        }
        // The data of images this client hasn't had yet goes first.
        let images: Vec<_> = frame
            .images
            .iter()
            .filter(|p| client.images.insert(p.id))
            .filter_map(|p| host.with_editor(|ed| ed.images().get(p.id).cloned()))
            .collect();
        let sent = images.iter().all(|image| {
            client
                .output
                .send(Output::Image(ImageData::from(&**image)))
                .is_ok()
        });
        let Some(output) = host.timed("what changed on screen", || client.output_for(frame)) else {
            return true;
        };
        if sent && client.output.send(output).is_ok() {
            return true;
        }
        let local = client.local;
        self.let_client_go();
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
