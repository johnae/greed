//! A language server client: starts servers, speaks JSON-RPC to them over
//! stdio, and keeps their view of open documents in sync.
//!
//! One server runs per language, started the first time a buffer of that
//! language shows up. Each server has a reader thread that turns its output
//! into [`Event`]s; the editor handles them on its own thread.

use std::collections::{HashMap, HashSet};
use std::io::{self, BufRead, BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;

use crossbeam_channel::{Receiver, Sender};
use greed_text::Rope;
use serde_json::{Value, json};

use crate::{Buffer, BufferId, Editor};

pub type ServerId = usize;

/// How to start the server for one language.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerConfig {
    pub language: String,
    /// Commands to try, in order: the first whose program is installed runs.
    pub commands: Vec<Vec<String>>,
    /// Files that mark a project's root, e.g. `Cargo.toml`. The server starts
    /// in the nearest directory above the first file that has one.
    pub root_markers: Vec<String>,
}

impl ServerConfig {
    /// The first command whose program is installed.
    pub fn installed_command(&self) -> Option<&Vec<String>> {
        self.commands
            .iter()
            .find(|c| c.first().is_some_and(|program| which(program).is_some()))
    }
}

/// Where `program` is: on `PATH`, or the path itself if it has a slash.
pub fn which(program: &str) -> Option<PathBuf> {
    if program.contains('/') {
        let path = PathBuf::from(program);
        return is_executable(&path).then_some(path);
    }
    std::env::split_paths(&std::env::var_os("PATH")?)
        .map(|dir| dir.join(program))
        .find(|path| is_executable(path))
}

fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    path.metadata()
        .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// Something a server sent.
#[derive(Debug, Clone)]
pub enum Event {
    /// The answer to a request. `result` is `Err` with the error object if
    /// the server reported one.
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
    /// The server asked the editor something.
    Request {
        server: ServerId,
        id: Value,
        method: String,
        params: Value,
    },
    /// The server's output ended.
    Exited { server: ServerId },
}

/// What [`Lsp::handle`] did with an event.
#[derive(Debug, Clone, PartialEq)]
pub enum Handled {
    /// The answer to a request made with [`Lsp::request`].
    Response {
        server: ServerId,
        id: i64,
        result: Result<Value, Value>,
    },
    /// New diagnostics arrived for this buffer.
    Diagnostics(BufferId),
    /// The server asked something the editor doesn't answer itself; answer
    /// with [`Lsp::respond`].
    Request {
        server: ServerId,
        id: Value,
        method: String,
        params: Value,
    },
    /// The server told the editor something it doesn't deal with itself,
    /// like `$/progress`, for plugins to hear.
    Notification {
        language: String,
        method: String,
        params: Value,
    },
    Nothing,
}

/// A problem a server reported in any file, open or not, as the server sent
/// it.
#[derive(Debug, Clone, PartialEq)]
pub struct Problem {
    pub uri: String,
    /// The LSP range: `{ start, end }` positions.
    pub range: Value,
    pub severity: u8,
    pub message: String,
    pub source: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Encoding {
    Utf8,
    Utf16,
}

/// A problem a server found, in byte offsets.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Diagnostic {
    pub from: usize,
    pub to: usize,
    /// 1 error, 2 warning, 3 information, 4 hint.
    pub severity: u8,
    pub message: String,
    pub source: Option<String>,
}

#[derive(Debug)]
pub enum LspError {
    NoServer(String),
    Io(io::Error),
}

impl std::fmt::Display for LspError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LspError::NoServer(what) => write!(f, "no language server for {what}"),
            LspError::Io(err) => write!(f, "language server: {err}"),
        }
    }
}

impl std::error::Error for LspError {}

impl From<io::Error> for LspError {
    fn from(err: io::Error) -> Self {
        LspError::Io(err)
    }
}

struct Server {
    language: String,
    child: Option<Child>,
    stdin: BufWriter<Box<dyn Write + Send>>,
    next_id: i64,
    initialize_id: i64,
    ready: bool,
    alive: bool,
    encoding: Encoding,
    /// What the server said it can do, in its answer to `initialize`.
    capabilities: Value,
    /// Messages to send once the server has answered `initialize`.
    queued: Vec<Value>,
    /// The version and URI of each open document the server has.
    documents: HashMap<BufferId, (usize, String)>,
}

impl Server {
    fn send(&mut self, message: &Value) -> io::Result<()> {
        if !self.ready && message.get("method").and_then(Value::as_str) != Some("initialize") {
            self.queued.push(message.clone());
            return Ok(());
        }
        let body = message.to_string();
        write!(self.stdin, "Content-Length: {}\r\n\r\n{body}", body.len())?;
        self.stdin.flush()
    }

    fn request(&mut self, method: &str, params: &Value) -> io::Result<i64> {
        self.next_id += 1;
        let id = self.next_id;
        self.send(&json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }))?;
        Ok(id)
    }

    fn notify(&mut self, method: &str, params: &Value) -> io::Result<()> {
        self.send(&json!({ "jsonrpc": "2.0", "method": method, "params": params }))
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        if self.alive {
            let _ = self.request("shutdown", &Value::Null);
            let _ = self.notify("exit", &Value::Null);
        }
        if let Some(child) = &mut self.child {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

pub struct Lsp {
    configs: Vec<ServerConfig>,
    servers: Vec<Server>,
    by_language: HashMap<String, ServerId>,
    /// Languages whose server couldn't be started; not tried again.
    failed: HashSet<String>,
    diagnostics: HashMap<BufferId, Vec<Diagnostic>>,
    /// Every file's latest problems, by URI, including files not open.
    problems: HashMap<String, Vec<Problem>>,
    events: Receiver<Event>,
    sender: Sender<Event>,
}

impl Default for Lsp {
    fn default() -> Self {
        let (sender, events) = crossbeam_channel::unbounded();
        Self {
            configs: Vec::new(),
            servers: Vec::new(),
            by_language: HashMap::new(),
            failed: HashSet::new(),
            diagnostics: HashMap::new(),
            problems: HashMap::new(),
            events,
            sender,
        }
    }
}

impl Lsp {
    /// Sets how to start the server for a language, replacing any earlier
    /// setting.
    pub fn configure(&mut self, config: ServerConfig) {
        self.configs.retain(|c| c.language != config.language);
        self.configs.push(config);
    }

    /// Stops starting a server for `language`. One already running keeps
    /// running.
    pub fn remove(&mut self, language: &str) {
        self.configs.retain(|c| c.language != language);
    }

    /// How each language's server starts.
    pub fn configs(&self) -> &[ServerConfig] {
        &self.configs
    }

    /// Messages from servers, to pass to [`Lsp::handle`].
    pub fn events(&self) -> &Receiver<Event> {
        &self.events
    }

    /// Opens new documents, sends changed ones and closes those whose buffer
    /// was closed, starting servers on first use. Returns an error for each
    /// server that couldn't be reached.
    pub fn sync(&mut self, editor: &Editor) -> Vec<LspError> {
        let mut errors = Vec::new();
        for buffer in editor.buffers() {
            if let Err(err) = self.sync_buffer(buffer) {
                errors.push(err);
            }
        }
        let open: HashSet<BufferId> = editor.buffers().map(Buffer::id).collect();
        for server in &mut self.servers {
            let gone: Vec<(usize, String)> = server
                .documents
                .extract_if(|id, _| !open.contains(id))
                .map(|(_, document)| document)
                .collect();
            for (_, uri) in gone {
                if server.alive {
                    let closed = json!({ "textDocument": { "uri": uri } });
                    let _ = server.notify("textDocument/didClose", &closed);
                }
            }
        }
        self.diagnostics.retain(|id, _| open.contains(id));
        errors
    }

    fn sync_buffer(&mut self, buffer: &Buffer) -> Result<(), LspError> {
        let Some(path) = buffer.path() else {
            return Ok(());
        };
        let Some(language) = buffer.language() else {
            return Ok(());
        };
        let Some(server) = self.server_for(language, path)? else {
            return Ok(());
        };
        let version = buffer.history().log().len();
        let server = &mut self.servers[server];
        if !server.alive {
            return Ok(());
        }
        let uri = file_uri(path);
        match server.documents.insert(buffer.id(), (version, uri.clone())) {
            None => server.notify(
                "textDocument/didOpen",
                &json!({ "textDocument": {
                    "uri": uri, "languageId": language, "version": version,
                    "text": buffer.text().to_string(),
                }}),
            )?,
            Some((old, _)) if old != version => server.notify(
                "textDocument/didChange",
                &json!({
                    "textDocument": { "uri": uri, "version": version },
                    "contentChanges": [{ "text": buffer.text().to_string() }],
                }),
            )?,
            Some(_) => {}
        }
        Ok(())
    }

    /// The server for `language`, started if it isn't running yet. `None` if
    /// no server is configured for it.
    fn server_for(&mut self, language: &str, path: &Path) -> Result<Option<ServerId>, LspError> {
        if let Some(&id) = self.by_language.get(language) {
            return Ok(Some(id));
        }
        if self.failed.contains(language) {
            return Ok(None);
        }
        let Some(config) = self
            .configs
            .iter()
            .find(|c| c.language == language)
            .cloned()
        else {
            return Ok(None);
        };
        let root = project_root(path, &config.root_markers);
        // Not having a server installed is normal, so it's not an error.
        let Some((program, args)) = config
            .installed_command()
            .and_then(|command| command.split_first())
        else {
            self.failed.insert(language.to_owned());
            return Ok(None);
        };
        let mut child = Command::new(program)
            .args(args)
            .current_dir(&root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|err| {
                self.failed.insert(language.to_owned());
                LspError::NoServer(format!("{language}: can't run {program}: {err}"))
            })?;
        let stdin = child.stdin.take().expect("stdin is piped");
        let stdout = child.stdout.take().expect("stdout is piped");
        let id = self.connect(language, Box::new(stdin), stdout, &root)?;
        self.servers[id].child = Some(child);
        Ok(Some(id))
    }

    /// Talks to a server over `input` and `output`, and sends `initialize`.
    /// Servers normally start from their config; tests connect directly.
    pub fn connect(
        &mut self,
        language: &str,
        input: Box<dyn Write + Send>,
        output: impl Read + Send + 'static,
        root: &Path,
    ) -> Result<ServerId, LspError> {
        let id = self.servers.len();
        let sender = self.sender.clone();
        thread::spawn(move || read_messages(id, output, &sender));
        let mut server = Server {
            language: language.to_owned(),
            child: None,
            stdin: BufWriter::new(input),
            next_id: 0,
            initialize_id: 0,
            ready: false,
            alive: true,
            encoding: Encoding::Utf16,
            capabilities: Value::Null,
            queued: Vec::new(),
            documents: HashMap::new(),
        };
        server.initialize_id = server.request(
            "initialize",
            &json!({
                "processId": std::process::id(),
                "rootUri": file_uri(root),
                "clientInfo": { "name": "greed" },
                "capabilities": client_capabilities(),
            }),
        )?;
        self.servers.push(server);
        self.by_language.insert(language.to_owned(), id);
        Ok(id)
    }

    /// Sends a request about `buffer` to its language's server, after the
    /// buffer's latest text, so an edit made just before is seen. Returns
    /// the server and the request's id, which the response will carry.
    pub fn request(
        &mut self,
        buffer: &Buffer,
        method: &str,
        params: &Value,
    ) -> Result<(ServerId, i64), LspError> {
        let server = self.server_of(buffer)?;
        self.sync_buffer(buffer)?;
        let id = self.servers[server].request(method, params)?;
        Ok((server, id))
    }

    fn server_of(&self, buffer: &Buffer) -> Result<ServerId, LspError> {
        buffer
            .path()
            .and(buffer.language())
            .and_then(|l| self.by_language.get(l).copied())
            .filter(|&id| self.servers[id].alive)
            .ok_or_else(|| LspError::NoServer(format!("buffer {}", buffer.id().0)))
    }

    /// Deals with one event from a server: finishes starting it, answers its
    /// requests, stores diagnostics, and passes responses back.
    pub fn handle(&mut self, event: Event, editor: &Editor) -> Handled {
        match event {
            Event::Response { server, id, result } if id == self.servers[server].initialize_id => {
                self.finish_initialize(server, result.as_ref().ok());
                Handled::Nothing
            }
            Event::Response { server, id, result } => Handled::Response { server, id, result },
            Event::Notification {
                server,
                method,
                params,
            } if method == "textDocument/publishDiagnostics" => {
                self.store_diagnostics(server, &params, editor)
            }
            Event::Notification {
                server,
                method,
                params,
            } => Handled::Notification {
                language: self.servers[server].language.clone(),
                method,
                params,
            },
            Event::Request {
                server,
                id,
                method,
                params,
            } if method == "workspace/configuration" => {
                let count = params["items"].as_array().map_or(0, Vec::len);
                self.respond(server, &id, &Value::Array(vec![Value::Null; count]));
                Handled::Nothing
            }
            Event::Request {
                server,
                id,
                method,
                params,
            } => Handled::Request {
                server,
                id,
                method,
                params,
            },
            Event::Exited { server } => {
                let server = &mut self.servers[server];
                server.alive = false;
                self.by_language.remove(&server.language);
                Handled::Nothing
            }
        }
    }

    /// Answers request `id` from `server`.
    pub fn respond(&mut self, server: ServerId, id: &Value, result: &Value) {
        let _ = self.servers[server].send(&json!({ "jsonrpc": "2.0", "id": id, "result": result }));
    }

    /// What `buffer`'s server said it can do, e.g. `renameProvider`.
    pub fn capabilities(&self, buffer: &Buffer) -> Result<&Value, LspError> {
        Ok(&self.servers[self.server_of(buffer)?].capabilities)
    }

    fn finish_initialize(&mut self, server: ServerId, result: Option<&Value>) {
        let server = &mut self.servers[server];
        if let Some(capabilities) = result.map(|r| &r["capabilities"]) {
            if capabilities["positionEncoding"].as_str() == Some("utf-8") {
                server.encoding = Encoding::Utf8;
            }
            server.capabilities = capabilities.clone();
        }
        server.ready = true;
        let _ = server.notify("initialized", &json!({}));
        for message in std::mem::take(&mut server.queued) {
            let _ = server.send(&message);
        }
    }

    fn store_diagnostics(&mut self, server: ServerId, params: &Value, editor: &Editor) -> Handled {
        let encoding = self.servers[server].encoding;
        let Some(uri) = params["uri"].as_str() else {
            return Handled::Nothing;
        };
        let reported = params["diagnostics"]
            .as_array()
            .map_or(&[][..], Vec::as_slice);
        let problems: Vec<Problem> = reported
            .iter()
            .map(|d| Problem {
                uri: uri.to_owned(),
                range: d["range"].clone(),
                severity: severity(d),
                message: d["message"].as_str().unwrap_or_default().to_owned(),
                source: d["source"].as_str().map(str::to_owned),
            })
            .collect();
        if problems.is_empty() {
            self.problems.remove(uri);
        } else {
            self.problems.insert(uri.to_owned(), problems);
        }
        let Some(buffer) = editor
            .buffers()
            .find(|b| b.path().is_some_and(|p| file_uri(p) == uri))
        else {
            return Handled::Nothing;
        };
        let text = buffer.text();
        let diagnostics = reported
            .iter()
            .filter_map(|d| {
                let from = offset(text, &d["range"]["start"], encoding)?;
                let to = offset(text, &d["range"]["end"], encoding)?;
                Some(Diagnostic {
                    from,
                    to: to.max(from),
                    severity: severity(d),
                    message: d["message"].as_str().unwrap_or_default().to_owned(),
                    source: d["source"].as_str().map(str::to_owned),
                })
            })
            .collect();
        self.diagnostics.insert(buffer.id(), diagnostics);
        Handled::Diagnostics(buffer.id())
    }

    /// Every buffer's latest diagnostics.
    pub fn all_diagnostics(&self) -> impl Iterator<Item = (BufferId, &[Diagnostic])> {
        self.diagnostics.iter().map(|(id, d)| (*id, d.as_slice()))
    }

    /// Every file's latest problems, open or not.
    pub fn problems(&self) -> impl Iterator<Item = &Problem> {
        self.problems.values().flatten()
    }

    pub fn diagnostics(&self, buffer: BufferId) -> &[Diagnostic] {
        self.diagnostics.get(&buffer).map_or(&[], Vec::as_slice)
    }

    /// How `buffer`'s server counts positions within a line.
    pub fn encoding(&self, buffer: &Buffer) -> Result<Encoding, LspError> {
        Ok(self.servers[self.server_of(buffer)?].encoding)
    }
}

/// A diagnostic's severity, an error when the server doesn't say.
fn severity(diagnostic: &Value) -> u8 {
    diagnostic["severity"]
        .as_u64()
        .and_then(|s| u8::try_from(s).ok())
        .unwrap_or(1)
}

/// What the editor tells servers it can do. Plugins build the features on
/// top: rename, references, code actions and signature help in the lsp
/// plugin, and edits from servers through `workspace/applyEdit` handlers.
fn client_capabilities() -> Value {
    json!({
        "general": { "positionEncodings": ["utf-8", "utf-16"] },
        "window": { "workDoneProgress": true },
        "workspace": {
            "applyEdit": true,
            "workspaceEdit": { "documentChanges": true },
            "configuration": true,
        },
        "textDocument": {
            "hover": { "contentFormat": ["plaintext", "markdown"] },
            "publishDiagnostics": {},
            "synchronization": { "didSave": false },
            "definition": {},
            "references": {},
            "rename": { "prepareSupport": true },
            "codeAction": {
                "codeActionLiteralSupport": { "codeActionKind": { "valueSet": [
                    "", "quickfix", "refactor", "refactor.extract", "refactor.inline",
                    "refactor.rewrite", "source", "source.organizeImports",
                ] } },
                "isPreferredSupport": true,
                "dataSupport": true,
                "resolveSupport": { "properties": ["edit"] },
            },
            "signatureHelp": {
                "signatureInformation": {
                    "documentationFormat": ["plaintext", "markdown"],
                    "parameterInformation": { "labelOffsetSupport": true },
                    "activeParameterSupport": true,
                },
            },
        },
    })
}

/// `file://` URI for a path.
pub fn file_uri(path: &Path) -> String {
    let path = std::path::absolute(path).unwrap_or_else(|_| path.to_owned());
    url::Url::from_file_path(&path)
        .map_or_else(|()| format!("file://{}", path.display()), String::from)
}

/// The path in a `file://` URI.
pub fn uri_path(uri: &str) -> Option<PathBuf> {
    url::Url::parse(uri).ok()?.to_file_path().ok()
}

/// Where a server for the file at `path` runs: the nearest directory with one
/// of `markers`, or the file's own directory.
pub fn project_root(path: &Path, markers: &[String]) -> PathBuf {
    // A bare file name like "notes.md" has an empty parent: the current
    // directory.
    let dir = match path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent.to_owned(),
        _ => PathBuf::from("."),
    };
    let dir = std::path::absolute(&dir).unwrap_or(dir);
    // A new file can be in folders that don't exist yet; the server runs
    // in the nearest one that does.
    let existing = dir
        .ancestors()
        .find(|d| d.is_dir())
        .unwrap_or(&dir)
        .to_owned();
    existing
        .ancestors()
        .find(|d| markers.iter().any(|m| d.join(m).exists()))
        .unwrap_or(&existing)
        .to_owned()
}

/// An LSP position (`{ line, character }`) for byte `pos`.
pub fn position(text: &Rope, pos: usize, encoding: Encoding) -> Value {
    let pos = pos.min(text.len_bytes());
    let line = text.byte_to_line(pos);
    let start = text.line_to_byte(line);
    let character = match encoding {
        Encoding::Utf8 => pos - start,
        Encoding::Utf16 => text
            .byte_slice(start..pos)
            .chars()
            .map(char::len_utf16)
            .sum(),
    };
    json!({ "line": line, "character": character })
}

/// The byte offset of an LSP position, clamped to the line it's on.
pub fn offset(text: &Rope, position: &Value, encoding: Encoding) -> Option<usize> {
    let line = usize::try_from(position["line"].as_u64()?).ok()?;
    let character = usize::try_from(position["character"].as_u64()?).ok()?;
    if line >= text.len_lines() {
        return Some(text.len_bytes());
    }
    let mut byte = text.line_to_byte(line);
    let mut units = 0;
    for c in text.line(line).chars() {
        if units >= character || c == '\n' {
            return Some(byte);
        }
        units += match encoding {
            Encoding::Utf8 => c.len_utf8(),
            Encoding::Utf16 => c.len_utf16(),
        };
        byte += c.len_utf8();
    }
    Some(byte)
}

/// Reads framed JSON-RPC messages until the stream ends.
fn read_messages(server: ServerId, output: impl Read, events: &Sender<Event>) {
    let mut reader = BufReader::new(output);
    while let Some(message) = read_message(&mut reader) {
        let event = if let Some(method) = message["method"].as_str() {
            let params = message.get("params").cloned().unwrap_or(Value::Null);
            match message.get("id") {
                Some(id) => Event::Request {
                    server,
                    id: id.clone(),
                    method: method.to_owned(),
                    params,
                },
                None => Event::Notification {
                    server,
                    method: method.to_owned(),
                    params,
                },
            }
        } else if let Some(id) = message["id"].as_i64() {
            let result = match message.get("error") {
                Some(error) => Err(error.clone()),
                None => Ok(message.get("result").cloned().unwrap_or(Value::Null)),
            };
            Event::Response { server, id, result }
        } else {
            continue;
        };
        if events.send(event).is_err() {
            return;
        }
    }
    let _ = events.send(Event::Exited { server });
}

fn read_message(reader: &mut impl BufRead) -> Option<Value> {
    let mut length = None;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).ok()? == 0 {
            return None;
        }
        let line = line.trim_end();
        if line.is_empty() {
            break;
        }
        if let Some(value) = line.strip_prefix("Content-Length:") {
            length = value.trim().parse::<usize>().ok();
        }
    }
    let mut body = vec![0; length?];
    reader.read_exact(&mut body).ok()?;
    serde_json::from_slice(&body).ok()
}
