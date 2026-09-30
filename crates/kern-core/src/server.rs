//! The editor server: one thread that owns all editor state and the Luau VM,
//! and talks to clients only through messages.
//!
//! Clients send input and get back frames. For now the client runs in the
//! same process and messages go over channels; a socket can replace them
//! without changing either side.

use std::sync::mpsc::{self, Receiver, Sender};
use std::thread::{self, JoinHandle};

use crate::keymap::Key;
use crate::luau::{Host, HostError};
use crate::render::{CellWidth, Frame, Renderer, Size};

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
/// resize.
pub fn spawn<F>(setup: F) -> Connection
where
    F: FnOnce() -> Result<Host, HostError> + Send + 'static,
{
    let (input, inbox) = mpsc::channel();
    let (outbox, output) = mpsc::channel();
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
    let mut size = None;
    let mut message: Option<String> = None;
    while let Ok(first) = inbox.recv() {
        for input in std::iter::once(first).chain(inbox.try_iter()) {
            match input {
                Input::Key(key) => {
                    message = host
                        .press(key)
                        .err()
                        .map(|err| first_line(&err.to_string()));
                }
                Input::Resize(new) => size = Some(new),
                Input::Quit => return,
            }
        }
        if let Some(latest) = host.with_editor_mut(|ed| ed.take_messages().pop()) {
            message = Some(latest);
        }
        if host.with_editor(crate::Editor::quit_requested) {
            return;
        }
        let Some(size) = size else { continue };
        let frame = host.with_editor_mut(|ed| renderer.frame(ed, size, message.as_deref()));
        if outbox.send(Output::Frame(frame)).is_err() {
            return;
        }
    }
}

fn first_line(text: &str) -> String {
    text.lines().next().unwrap_or_default().to_owned()
}
