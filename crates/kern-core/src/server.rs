//! The editor server: one thread that owns all editor state and the Luau VM,
//! and talks to clients only through messages.
//!
//! Clients send input and get back frames. For now the client runs in the
//! same process and messages go over channels; a socket can replace them
//! without changing either side.

use std::thread::{self, JoinHandle};
use std::time::Instant;

use crossbeam_channel::{Receiver, Sender, select};

use crate::keymap::Key;
use crate::luau::{Host, HostError};
use crate::render::{CellWidth, Frame, Renderer, Size, Status};
use crate::syntax::Syntax;

/// A message from a client to the server.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Input {
    Key(Key),
    Resize(Size),
    Quit,
}

/// A message from the server to a client.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Output {
    Frame(Frame),
    /// The server has stopped; no more messages will come.
    Exit,
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
    let (input, inbox) = crossbeam_channel::unbounded();
    let (outbox, output) = crossbeam_channel::unbounded();
    let server = thread::spawn(move || {
        let result = setup().map(|host| serve(&host, &inbox, &outbox));
        let _ = outbox.send(Output::Exit);
        result
    });
    Connection {
        input,
        output,
        server,
    }
}

fn serve(host: &Host, inbox: &Receiver<Input>, outbox: &Sender<Output>) {
    let renderer = Renderer::new(CellWidth);
    let mut syntax = Syntax::new();
    let mut size = None;
    let mut message: Option<String> = None;
    loop {
        host.with_editor(|ed| syntax.update(ed));
        // Wake up in time for the next timer a command is waiting on.
        let timer = host
            .next_timer()
            .map_or_else(crossbeam_channel::never, crossbeam_channel::at);
        select! {
            recv(inbox) -> first => {
                let Ok(first) = first else { return };
                for input in std::iter::once(first).chain(inbox.try_iter()) {
                    match input {
                        Input::Key(key) => {
                            message = host.press(key).err().map(|err| first_line(&err.to_string()));
                        }
                        Input::Resize(new) => size = Some(new),
                        Input::Quit => return,
                    }
                }
            }
            recv(syntax.results()) -> parsed => {
                if let Ok(parsed) = parsed {
                    syntax.receive(parsed);
                }
            }
            recv(timer) -> _ => {}
        }
        if let Err(err) = host.fire_timers(Instant::now()) {
            message = Some(first_line(&err.to_string()));
        }
        if let Some(latest) = host.with_editor_mut(|ed| ed.take_messages().pop()) {
            message = Some(latest);
        }
        if host.with_editor(crate::Editor::quit_requested) {
            return;
        }
        let Some(size) = size else { continue };
        let status = match host.status_line(message.as_deref(), size.width) {
            Ok(Some(line)) => Status::Line(line),
            Ok(None) => Status::Default {
                message: message.as_deref(),
            },
            Err(err) => {
                message = Some(format!("status line: {}", first_line(&err.to_string())));
                Status::Default {
                    message: message.as_deref(),
                }
            }
        };
        let highlighter = |buffer, text: &_, range| syntax.highlights(buffer, text, range);
        let frame = host.with_editor_mut(|ed| renderer.frame(ed, size, &status, &highlighter));
        if outbox.send(Output::Frame(frame)).is_err() {
            return;
        }
    }
}

fn first_line(text: &str) -> String {
    text.lines().next().unwrap_or_default().to_owned()
}
