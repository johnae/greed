//! The editor server: one thread that owns all editor state and the Luau VM,
//! and talks to clients only through messages.
//!
//! Clients send input and get back frames, over channels in the same
//! process or as JSON lines over a session socket.

use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::ops::Range;
use std::thread::{self, JoinHandle};
use std::time::Instant;

use crossbeam_channel::{Receiver, Sender, select};
use serde::{Deserialize, Serialize};

use crate::BufferId;
use crate::control::{Attachment, Session};
use crate::delta::FrameDelta;
use crate::keymap::Key;
use crate::luau::{Host, HostError};
use crate::render::{CellWidth, Decorations, Frame, Renderer, Size, Status};
use crate::syntax::{Highlight, Syntax};
use kern_text::Rope;

/// A message from a client to the server.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Input {
    Key(Key),
    Resize(Size),
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
            syntax: Syntax::new(),
            size: None,
            message: None,
            client: Some(Client {
                output: outbox,
                local: true,
                last: None,
            }),
            inputs,
        };
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
    syntax: Syntax,
    /// The attached client's screen size, once it has said.
    size: Option<Size>,
    message: Option<String>,
    client: Option<Client>,
    /// For attached clients to send their input with the local client's.
    inputs: Sender<Input>,
}

impl Server<'_> {
    fn run(&mut self, inbox: &Receiver<Input>, session: Option<&Session>) {
        let lsp_events = self.host.lsp_events();
        let finished_jobs = self.host.finished_jobs();
        let requests = session.map_or_else(crossbeam_channel::never, |s| s.requests().clone());
        let attachments =
            session.map_or_else(crossbeam_channel::never, |s| s.attachments().clone());
        loop {
            self.host.with_editor(|ed| self.syntax.update(ed));
            if let Some(problem) = self.host.sync_lsp().pop() {
                self.message = Some(problem);
            }
            // Wake up in time for the next timer a command is waiting on.
            let timer = self
                .host
                .next_timer()
                .map_or_else(crossbeam_channel::never, crossbeam_channel::at);
            select! {
                recv(inbox) -> first => {
                    let Ok(first) = first else { return };
                    for input in std::iter::once(first).chain(inbox.try_iter()) {
                        match input {
                            Input::Key(key) => {
                                let pressed = self.host.press(key);
                                self.report(pressed);
                            }
                            Input::Resize(new) => self.size = Some(new),
                            Input::Quit => return,
                        }
                    }
                }
                recv(self.syntax.results()) -> parsed => {
                    if let Ok(parsed) = parsed {
                        self.syntax.receive(parsed);
                    }
                }
                recv(lsp_events) -> event => {
                    if let Ok(event) = event {
                        let handled = self.host.handle_lsp(event);
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
            }
            let fired = self.host.fire_timers(Instant::now());
            self.report(fired);
            if let Some(latest) = self.host.with_editor_mut(|ed| ed.take_messages().pop()) {
                self.message = Some(latest);
            }
            if self.host.with_editor(crate::Editor::quit_requested) {
                return;
            }
            if self
                .host
                .with_editor_mut(crate::Editor::take_detach_request)
            {
                self.detach();
            }
            if !self.draw() {
                return;
            }
        }
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
        let Attachment { reader, mut writer } = attachment;
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
                let last = matches!(message, Output::Exit | Output::Detached);
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
        });
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
        let decorations = Shown {
            syntax: &self.syntax,
            diagnostics: host.diagnostic_marks(),
        };
        let frame = host.with_editor_mut(|ed| self.renderer.frame(ed, size, &status, &decorations));
        let Some(client) = &mut self.client else {
            return true;
        };
        let Some(output) = client.output_for(frame) else {
            return true;
        };
        if client.output.send(output).is_ok() {
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
    diagnostics: HashMap<BufferId, Vec<(Range<usize>, u8)>>,
}

impl Decorations for Shown<'_> {
    fn highlights(&self, buffer: BufferId, text: &Rope, range: Range<usize>) -> Vec<Highlight> {
        self.syntax.highlights(buffer, text, range)
    }

    fn diagnostics(&self, buffer: BufferId) -> &[(Range<usize>, u8)] {
        self.diagnostics.get(&buffer).map_or(&[], Vec::as_slice)
    }
}
