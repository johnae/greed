//! JSON-RPC 2.0 with a child process over its stdin and stdout, each message
//! framed with a `Content-Length` header, as language servers speak it.
//! Debug adapters frame their messages the same way.
//!
//! A [`Connection`] numbers the requests it sends and matches responses to
//! them. A reader thread per connection turns what the other side writes
//! into [`Event`]s on a channel, which the editor handles on its own thread
//! by passing each to [`Connection::receive`] first. The process's stderr
//! is kept, its last lines, for saying why it stopped.

use std::collections::{HashSet, VecDeque};
use std::io::{self, BufRead, BufReader, BufWriter, Read, Write};
use std::path::Path;
use std::process::{Child, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use crossbeam_channel::Sender;
use serde_json::{Value, json};

/// Which connection an event came from. Never reused, so a response from a
/// server that stopped can't be taken for one from the server started after.
pub type ServerId = usize;

/// How many lines of a process's stderr are kept.
const STDERR_LINES: usize = 50;

/// How long a process gets to exit on its own once its input is closed,
/// before it's killed.
const GRACE: Duration = Duration::from_secs(2);

/// Something the other side sent.
#[derive(Debug, Clone)]
pub enum Event {
    /// The answer to a request. `result` is `Err` with the error object if
    /// the other side reported one.
    Response {
        server: ServerId,
        id: i64,
        result: Result<Value, Value>,
    },
    Notification {
        server: ServerId,
        method: String,
        params: Value,
    },
    /// The other side asked something, to answer with
    /// [`Connection::respond`].
    Request {
        server: ServerId,
        id: Value,
        method: String,
        params: Value,
    },
    /// Its output ended: the process exited or closed it. Always the last
    /// event from a connection.
    Exited { server: ServerId },
}

impl Event {
    /// The connection it came from.
    pub fn server(&self) -> ServerId {
        match self {
            Event::Response { server, .. }
            | Event::Notification { server, .. }
            | Event::Request { server, .. }
            | Event::Exited { server } => *server,
        }
    }
}

/// The two ends to talk over, and the process behind them if there's one.
pub struct Transport {
    input: Box<dyn Write + Send>,
    output: Box<dyn Read + Send>,
    stderr: Option<Box<dyn Read + Send>>,
    child: Option<Child>,
}

impl Transport {
    /// Starts `command` (a program and its arguments) in `dir`.
    pub fn spawn(command: &[String], dir: &Path) -> io::Result<Self> {
        crate::debug!(Rpc, "starting {} in {}", command.join(" "), dir.display());
        let mut child = crate::child::command(command, Some(dir), &[], false)?
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;
        Ok(Self {
            input: Box::new(child.stdin.take().expect("stdin is piped")),
            output: Box::new(child.stdout.take().expect("stdout is piped")),
            stderr: Some(Box::new(child.stderr.take().expect("stderr is piped"))),
            child: Some(child),
        })
    }

    /// Talks over `input` and `output` with no process behind them, e.g. to
    /// a server on a thread in tests.
    pub fn pipes(input: impl Write + Send + 'static, output: impl Read + Send + 'static) -> Self {
        Self {
            input: Box::new(input),
            output: Box::new(output),
            stderr: None,
            child: None,
        }
    }
}

/// One JSON-RPC peer: what's sent to it, the requests waiting for its
/// answer, and its process.
pub struct Connection {
    /// Which connection this is, as its events say.
    server: ServerId,
    input: BufWriter<Box<dyn Write + Send>>,
    child: Option<Child>,
    next_id: i64,
    /// Requests sent and not answered yet.
    pending: HashSet<i64>,
    alive: bool,
    stderr: Arc<Mutex<VecDeque<String>>>,
}

impl Connection {
    /// Starts reading what the other side sends, as events on `events`
    /// tagged with `id`.
    pub fn open(id: ServerId, transport: Transport, events: &Sender<Event>) -> Self {
        let sender = events.clone();
        let output = transport.output;
        thread::spawn(move || read_messages(id, output, &sender));
        let stderr = Arc::new(Mutex::new(VecDeque::new()));
        if let Some(from) = transport.stderr {
            let lines = stderr.clone();
            thread::spawn(move || keep_lines(from, &lines));
        }
        Self {
            server: id,
            input: BufWriter::new(transport.input),
            child: transport.child,
            next_id: 0,
            pending: HashSet::new(),
            alive: true,
            stderr,
        }
    }

    /// Whether the other side is still there: its output hasn't ended.
    pub fn is_alive(&self) -> bool {
        self.alive
    }

    /// Writes `message` as it is.
    pub fn send(&mut self, message: &Value) -> io::Result<()> {
        crate::debug!(Rpc, "server {}: -> {}", self.server, summary(message));
        write_message(&mut self.input, message)
    }

    /// A request for `method`, numbered and counted as waiting for its
    /// answer, to send now or later with [`Connection::send`]. Returns its
    /// id, which the response will carry.
    pub fn request_message(&mut self, method: &str, params: &Value) -> (i64, Value) {
        self.next_id += 1;
        let id = self.next_id;
        self.pending.insert(id);
        let message = json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params });
        (id, message)
    }

    /// Sends a request. Returns its id, which the response will carry.
    pub fn request(&mut self, method: &str, params: &Value) -> io::Result<i64> {
        let (id, message) = self.request_message(method, params);
        self.send(&message)?;
        Ok(id)
    }

    /// A notification for `method`, to send with [`Connection::send`].
    pub fn notification(method: &str, params: &Value) -> Value {
        json!({ "jsonrpc": "2.0", "method": method, "params": params })
    }

    pub fn notify(&mut self, method: &str, params: &Value) -> io::Result<()> {
        self.send(&Self::notification(method, params))
    }

    /// Answers request `id` from the other side with a result, or an error
    /// object.
    pub fn respond(&mut self, id: &Value, result: Result<&Value, &Value>) -> io::Result<()> {
        let message = match result {
            Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
            Err(error) => json!({ "jsonrpc": "2.0", "id": id, "error": error }),
        };
        self.send(&message)
    }

    /// Takes in an event from this connection. A response to no request
    /// waiting for one, like a second answer to the same request, is
    /// dropped: `None`. When its output ends, the connection is no longer
    /// alive and nothing is waiting any more.
    pub fn receive(&mut self, event: Event) -> Option<Event> {
        crate::debug!(Rpc, "<- {}", event_summary(&event));
        match &event {
            Event::Response { id, .. } if !self.pending.remove(id) => None,
            Event::Exited { .. } => {
                self.alive = false;
                self.pending.clear();
                Some(event)
            }
            _ => Some(event),
        }
    }

    /// Requests sent and not answered yet.
    pub fn pending(&self) -> impl Iterator<Item = i64> + '_ {
        self.pending.iter().copied()
    }

    /// The last lines the process wrote to stderr, oldest first.
    pub fn stderr(&self) -> Vec<String> {
        self.stderr
            .lock()
            .map(|lines| lines.iter().cloned().collect())
            .unwrap_or_default()
    }
}

impl Drop for Connection {
    /// Closes the process's input and gives it a moment to exit on its own,
    /// in the background, before killing it.
    fn drop(&mut self) {
        let _ = self.input.flush();
        // Dropping the writer closes the pipe; swap in a sink to drop it now.
        drop(std::mem::replace(
            &mut self.input,
            BufWriter::new(Box::new(io::sink())),
        ));
        if let Some(mut child) = self.child.take() {
            thread::spawn(move || {
                let until = Instant::now() + GRACE;
                while Instant::now() < until {
                    if !matches!(child.try_wait(), Ok(None)) {
                        return;
                    }
                    thread::sleep(Duration::from_millis(20));
                }
                let _ = child.kill();
                let _ = child.wait();
            });
        }
    }
}

/// The largest message read: a server saying more is broken.
pub const MAX_MESSAGE: usize = 256 << 20;

/// Writes `message` with its `Content-Length` header.
pub fn write_message(writer: &mut impl Write, message: &Value) -> io::Result<()> {
    let body = message.to_string();
    write!(writer, "Content-Length: {}\r\n\r\n{body}", body.len())?;
    writer.flush()
}

/// Reads the next message. `Ok(None)` when the stream ends; a body that
/// isn't JSON is an `InvalidData` error, after which the next message can
/// still be read.
pub fn read_message(reader: &mut impl BufRead) -> io::Result<Option<Value>> {
    let mut length = None;
    let mut headers = 0;
    loop {
        let mut line = String::new();
        // A header line is short; a longer one is read in pieces, which
        // are no header the reader knows.
        if reader.by_ref().take(4096).read_line(&mut line)? == 0 {
            return Ok(None);
        }
        let line = line.trim_end();
        if line.is_empty() {
            // Blank lines between messages aren't a header block's end.
            if headers == 0 {
                continue;
            }
            break;
        }
        headers += 1;
        if let Some((name, value)) = line.split_once(':')
            && name.trim().eq_ignore_ascii_case("content-length")
        {
            length = value.trim().parse::<usize>().ok();
        }
    }
    let length = length
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "a message without a length"))?;
    if length > MAX_MESSAGE {
        // Its body can't be skipped reliably, so the stream is given up.
        return Err(io::Error::other(format!(
            "a message of {length} bytes, more than the {MAX_MESSAGE} taken"
        )));
    }
    let mut body = vec![0; length];
    reader.read_exact(&mut body)?;
    serde_json::from_slice(&body)
        .map(Some)
        .map_err(|err| io::Error::new(io::ErrorKind::InvalidData, err))
}

/// Reads messages until the stream ends, then sends `Exited`.
fn read_messages(server: ServerId, output: impl Read, events: &Sender<Event>) {
    let mut reader = BufReader::new(output);
    loop {
        let message = match read_message(&mut reader) {
            Ok(Some(message)) => message,
            Err(err) if err.kind() == io::ErrorKind::InvalidData => continue,
            Ok(None) | Err(_) => break,
        };
        let Some(event) = classify(server, message) else {
            continue;
        };
        if events.send(event).is_err() {
            return;
        }
    }
    let _ = events.send(Event::Exited { server });
}

/// What a message is: a request or notification by its method, or a
/// response by its id. `None` for anything else.
fn classify(server: ServerId, mut message: Value) -> Option<Event> {
    let params = message.get_mut("params").map_or(Value::Null, Value::take);
    if let Some(method) = message["method"].as_str() {
        let method = method.to_owned();
        return Some(match message.get_mut("id") {
            Some(id) => Event::Request {
                server,
                id: id.take(),
                method,
                params,
            },
            None => Event::Notification {
                server,
                method,
                params,
            },
        });
    }
    let id = message["id"].as_i64()?;
    let result = match message.get_mut("error") {
        Some(error) => Err(error.take()),
        None => Ok(message.get_mut("result").map_or(Value::Null, Value::take)),
    };
    Some(Event::Response { server, id, result })
}

/// Keeps the last [`STDERR_LINES`] lines read from `from`.
fn keep_lines(from: impl Read, lines: &Mutex<VecDeque<String>>) {
    let mut reader = BufReader::new(from);
    let mut line = Vec::new();
    loop {
        line.clear();
        match reader.read_until(b'\n', &mut line) {
            Ok(0) | Err(_) => return,
            Ok(_) => {}
        }
        let text = String::from_utf8_lossy(&line).trim_end().to_owned();
        let Ok(mut kept) = lines.lock() else {
            return;
        };
        if kept.len() == STDERR_LINES {
            kept.pop_front();
        }
        kept.push_back(text);
    }
}

/// A message in a few words, for debug lines: its method and id, or that
/// it answers one.
fn summary(message: &Value) -> String {
    let id = message.get("id").map(Value::to_string);
    match (message.get("method").and_then(Value::as_str), id) {
        (Some(method), Some(id)) => format!("request {id} {method}"),
        (Some(method), None) => format!("notification {method}"),
        (None, Some(id)) if message.get("error").is_some() => format!("error answering {id}"),
        (None, Some(id)) => format!("answer to {id}"),
        (None, None) => "a message with neither method nor id".to_owned(),
    }
}

/// An event from the other side in a few words, for debug lines.
fn event_summary(event: &Event) -> String {
    match event {
        Event::Response { server, id, result } => format!(
            "server {server}: {} {id}",
            if result.is_ok() {
                "answer to"
            } else {
                "error answering"
            }
        ),
        Event::Notification { server, method, .. } => {
            format!("server {server}: notification {method}")
        }
        Event::Request {
            server, method, id, ..
        } => format!("server {server}: request {id} {method}"),
        Event::Exited { server, .. } => format!("server {server} exited"),
    }
}
