//! The editor server: one thread that owns all editor state and the Luau VM,
//! and talks to clients only through messages.
//!
//! Clients send input and get back frames, over channels in the same
//! process or as JSON lines over a session socket.

use std::collections::{HashMap, HashSet};
use std::io::{BufRead, Write};
use std::ops::Range;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, Sender, select};
use serde::{Deserialize, Serialize};

use crate::control::{Attachment, Session};
use crate::delta::FrameDelta;
use crate::image::{Image, ImageId};
use crate::keymap::Key;
use crate::luau::{Host, HostError};
use crate::mouse::Mouse;
use crate::render::{CellWidth, Decorations, Frame, Renderer, Size, Status};
use crate::syntax::{Highlight, Syntax};
use crate::{BufferId, Editor, SwitchTo};
use greed_text::Rope;

/// A message from a client to the server.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Input {
    Key(Key),
    Resize(Size),
    Mouse(Mouse),
    /// How many pixels wide and high a cell is on the client's screen.
    CellSize(u16, u16),
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
}

/// How often watched files are looked at.
const WATCH_EVERY: Duration = Duration::from_millis(500);

/// The least time between frames, about a fast screen's refresh. Work that
/// wakes the server more often than this (a program flooding a terminal, a
/// language server's burst of messages) is drawn once for each.
const FRAME_EVERY: Duration = Duration::from_millis(8);

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
            let mut typed = false;
            select! {
                recv(inbox) -> first => {
                    let Ok(first) = first else { return };
                    typed = true;
                    for input in std::iter::once(first).chain(inbox.try_iter()) {
                        if !self.input(&input) {
                            return;
                        }
                    }
                }
                recv(trees) -> parsed => {
                    if let Ok(parsed) = parsed {
                        self.host.receive_parse(parsed);
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
                recv(attachments) -> attachment => {
                    if let Ok(attachment) = attachment {
                        self.attach(attachment);
                    }
                }
                recv(timer) -> _ => {}
                recv(look) -> _ => {}
                recv(self.frame_timer()) -> _ => {}
            }
            let fired = self.host.fire_timers(Instant::now());
            self.report(fired);
            self.look_at_watched_files();
            if let Some(latest) = self.host.with_editor_mut(|ed| ed.take_messages().pop()) {
                self.message = Some(latest);
            }
            if self.host.with_editor(crate::Editor::quit_requested) {
                return;
            }
            if let Some(to) = self
                .host
                .with_editor_mut(crate::Editor::take_switch_request)
            {
                // A client in this process can't go anywhere else.
                if self.client.as_ref().is_some_and(|c| c.local) {
                    return;
                }
                self.send(Output::Switch(to));
                self.client = None;
                self.size = None;
            }
            if self
                .host
                .with_editor_mut(crate::Editor::take_detach_request)
            {
                // A client in this process has nowhere to detach to: the
                // editor ends with it.
                if self.client.as_ref().is_some_and(|c| c.local) {
                    return;
                }
                self.detach();
            }
            if self.frame_due(typed) && !self.draw() {
                return;
            }
        }
    }

    /// Handles one message from the client. False when it asked to quit.
    fn input(&mut self, input: &Input) -> bool {
        match *input {
            Input::Key(key) => {
                // A message lasts until the next key, unless that key
                // brings another.
                self.message = None;
                let pressed = self.host.press(key);
                self.report(pressed);
            }
            Input::Resize(new) => self.size = Some(new),
            Input::Mouse(mouse) => {
                let hit = self
                    .host
                    .with_editor(|ed| self.renderer.hit(ed, mouse.col, mouse.row));
                let handled = self.host.mouse(mouse, &hit);
                self.report(handled);
            }
            Input::CellSize(w, h) => {
                self.host.with_editor_mut(|ed| ed.set_cell_size((w, h)));
            }
            Input::Quit => return false,
        }
        true
    }

    /// Shows what went wrong, if anything did, on the status line.
    fn report(&mut self, result: Result<(), HostError>) {
        if let Err(err) = result {
            self.message = Some(first_line(&err.to_string()));
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
        self.client = None;
        self.size = None;
    }

    /// Makes `attachment` the client, after telling the one before it.
    fn attach(&mut self, attachment: Attachment) {
        self.detach();
        let Attachment {
            reader,
            mut writer,
            open,
            terminal,
        } = attachment;
        let inputs = self.inputs.clone();
        thread::spawn(move || {
            for line in reader.lines() {
                let Ok(line) = line else { return };
                let Ok(input) = serde_json::from_str::<Input>(&line) else {
                    continue;
                };
                if inputs.send(input).is_err() {
                    return;
                }
            }
        });
        let (output, outgoing) = crossbeam_channel::unbounded::<Output>();
        thread::spawn(move || {
            for message in outgoing {
                let last = matches!(message, Output::Exit | Output::Detached | Output::Switch(_));
                let Ok(line) = serde_json::to_string(&message) else {
                    continue;
                };
                if writeln!(writer, "{line}").is_err() || last {
                    return;
                }
            }
        });
        self.client = Some(Client {
            output,
            local: false,
            last: None,
            images: HashSet::new(),
        });
        let attached = self.host.client_attached(open.as_deref(), terminal);
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
        let status = match host.status_line(self.message.as_deref(), size.width) {
            Ok(Some(line)) => Status::Line(line),
            Ok(None) => Status::Default {
                message: self.message.as_deref(),
            },
            Err(err) => {
                self.message = Some(format!("status line: {}", first_line(&err.to_string())));
                Status::Default {
                    message: self.message.as_deref(),
                }
            }
        };
        let diagnostics = host.diagnostic_marks();
        let render = || {
            host.with_editor_and_syntax(|ed, syntax| {
                let shown = Shown {
                    syntax,
                    diagnostics: &diagnostics,
                };
                self.renderer.frame(ed, size, &status, &shown)
            })
        };
        let mut frame = render();
        // Plugins may change views in answer (one scrolling another along),
        // which should show now rather than after the next key.
        let mut reported = host.report_views();
        if let Ok(true) = reported {
            frame = render();
            reported = host.report_views();
        }
        if let Err(err) = reported {
            self.message = Some(first_line(&err.to_string()));
        }
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
        let Some(output) = client.output_for(frame) else {
            return true;
        };
        if sent && client.output.send(output).is_ok() {
            return true;
        }
        let local = client.local;
        self.client = None;
        self.size = None;
        !local
    }
}

fn first_line(text: &str) -> String {
    text.lines().next().unwrap_or_default().to_owned()
}

/// What's drawn over buffer text: syntax highlighting and diagnostics.
struct Shown<'a> {
    syntax: &'a Syntax,
    diagnostics: &'a HashMap<BufferId, Vec<(Range<usize>, u8)>>,
}

impl Decorations for Shown<'_> {
    fn highlights(&self, buffer: BufferId, text: &Rope, range: Range<usize>) -> Vec<Highlight> {
        self.syntax.highlights(buffer, text, range)
    }

    fn diagnostics(&self, buffer: BufferId) -> &[(Range<usize>, u8)] {
        self.diagnostics.get(&buffer).map_or(&[], Vec::as_slice)
    }
}
