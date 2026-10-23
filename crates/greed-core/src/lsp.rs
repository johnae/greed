//! A language server client: starts servers, speaks the language server
//! protocol to them over [`rpc`](crate::rpc), and keeps their view of open
//! documents in sync.
//!
//! One server runs per language and root (see [`server_root`]), started the
//! first time a buffer that needs it shows up, and started again if it
//! stops. What servers send arrives as [`Event`]s, which the editor handles
//! on its own thread.

use std::borrow::Cow;
use std::collections::{HashMap, HashSet};
use std::io;
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, Sender};
use greed_text::{Operation, Rope, line_content};
use serde_json::{Value, json};

use crate::rpc::{Connection, Transport};
pub use crate::rpc::{Event, ServerId};
use crate::{Buffer, BufferId, Editor, Mark};

/// How to start the server for one language.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ServerConfig {
    pub language: String,
    /// Commands to try, in order: the first whose program is installed runs.
    pub commands: Vec<Vec<String>>,
    /// Files that mark a project's root, e.g. `Cargo.toml`, for where the
    /// server runs (see [`server_root`]).
    pub root_markers: Vec<String>,
    /// Whether the server only reads the project's files, never running
    /// its code (a build script, a config file), so it may start in a
    /// project nobody trusted (see [`Lsp::trust`]).
    pub reads_only: bool,
    /// The server's settings, as its documentation names them: sent once
    /// it's initialized, and what it gets when it asks for a section. A
    /// server keeps the ones it started with until it's restarted.
    pub settings: Value,
    /// What `initialize` sends as `initializationOptions`.
    pub init_options: Value,
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
        /// The folder the server runs in.
        root: PathBuf,
        method: String,
        params: Value,
    },
    /// The server stopped. Requests to it that weren't answered won't be.
    Exited {
        server: ServerId,
    },
    Nothing,
}

/// A problem a server reported in any file, open or not.
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

/// The mark namespace that holds each buffer's diagnostics, so they move
/// with edits.
pub const DIAGNOSTICS: &str = "diagnostics";

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
    /// A server kept stopping soon after starting, so it isn't started again.
    Stopped(String),
    Io(io::Error),
}

impl std::fmt::Display for LspError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LspError::NoServer(what) => write!(f, "no language server for {what}"),
            LspError::Stopped(what) => write!(f, "{what}"),
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
    /// The folder it runs in, its workspace.
    root: PathBuf,
    command: Vec<String>,
    connection: Connection,
    started: Instant,
    initialize_id: i64,
    ready: bool,
    encoding: Encoding,
    sync: SyncKind,
    /// What the server said it can do, in its answer to `initialize`.
    capabilities: Value,
    /// Messages to send once the server has answered `initialize`.
    queued: Vec<Value>,
    documents: HashMap<BufferId, Document>,
    /// The settings it started with ([`ServerConfig::settings`]).
    settings: Value,
}

/// An open document as the server has it.
struct Document {
    version: usize,
    uri: String,
    text: Rope,
}

/// How a server wants to hear about changes to a document.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SyncKind {
    /// The whole text each time.
    Full,
    /// What changed, as ranges.
    Incremental,
}

impl SyncKind {
    /// What `textDocumentSync` in a server's capabilities asks for: a kind,
    /// or options with a `change` kind. The whole text unless it says
    /// incremental.
    fn of(capabilities: &Value) -> Self {
        let sync = &capabilities["textDocumentSync"];
        match sync.as_u64().or_else(|| sync["change"].as_u64()) {
            Some(2) => SyncKind::Incremental,
            _ => SyncKind::Full,
        }
    }
}

impl Server {
    /// Sends `message`, or keeps it until the server has answered
    /// `initialize`.
    fn send(&mut self, message: Value) -> io::Result<()> {
        if !self.ready {
            self.queued.push(message);
            return Ok(());
        }
        self.connection.send(&message)
    }

    fn request(&mut self, method: &str, params: &Value) -> io::Result<i64> {
        let (id, message) = self.connection.request_message(method, params);
        self.send(message)?;
        Ok(id)
    }

    fn notify(&mut self, method: &str, params: &Value) -> io::Result<()> {
        self.send(Connection::notification(method, params))
    }

    fn alive(&self) -> bool {
        self.connection.is_alive()
    }

    /// Its root as the one workspace folder it has.
    fn workspace_folders(&self) -> Value {
        let name = self.root.file_name().map_or_else(
            || self.root.display().to_string(),
            |n| n.to_string_lossy().into_owned(),
        );
        json!([{ "uri": file_uri(&self.root), "name": name }])
    }
}

impl Drop for Server {
    /// Asks the server to shut down and exit; the connection then closes
    /// its input and kills it if it doesn't exit soon after.
    fn drop(&mut self) {
        if self.alive() {
            if self.ready {
                let _ = self.connection.request("shutdown", &Value::Null);
            }
            let _ = self.connection.notify("exit", &Value::Null);
        }
    }
}

/// Starts the server for a language in a root: the transport to talk to it
/// over, or `None` when it isn't installed. Tests start fake servers.
pub type Launcher = Box<dyn FnMut(&ServerConfig, &Path) -> io::Result<Option<Transport>> + Send>;

/// Runs the first of the config's commands that's installed.
fn launch(config: &ServerConfig, root: &Path) -> io::Result<Option<Transport>> {
    let Some(command) = config.installed_command() else {
        return Ok(None);
    };
    Transport::spawn(command, root)
        .map(Some)
        .map_err(|err| io::Error::other(format!("can't run {}: {err}", command[0])))
}

/// A server that stops sooner than this after starting counts towards
/// [`RESTARTS`]; one that ran longer starts the count again.
const STEADY: Duration = Duration::from_secs(60);

/// How many times in a row a server that stops soon after starting is
/// started again.
const RESTARTS: usize = 3;

/// A language and the root its server runs in.
type Key = (String, PathBuf);

/// Where a buffer's server is: its language, file and root, so roots aren't
/// looked for on every sync, and the server it was last sent to.
struct Placed {
    language: String,
    path: PathBuf,
    root: PathBuf,
    server: Option<ServerId>,
}

impl Placed {
    fn is_for(&self, path: &Path, language: &str) -> bool {
        self.path == path && self.language == language
    }
}

/// A server that's running, as [`Lsp::running`] lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Running {
    pub language: String,
    pub root: PathBuf,
    pub command: Vec<String>,
    /// Whether it answered `initialize`.
    pub ready: bool,
    /// The last lines it wrote to stderr.
    pub stderr: Vec<String>,
}

pub struct Lsp {
    configs: Vec<ServerConfig>,
    launcher: Launcher,
    servers: HashMap<ServerId, Server>,
    next_server: ServerId,
    /// The running server for each language and root.
    running: HashMap<Key, ServerId>,
    placed: HashMap<BufferId, Placed>,
    /// Servers that couldn't be started or kept stopping; not tried again
    /// until their language is set up again.
    failed: HashSet<Key>,
    /// How many times in a row each server stopped soon after starting.
    stops: HashMap<Key, usize>,
    /// Servers given up on since the last sync, to say so.
    given_up: Vec<LspError>,
    /// Every file's latest problems, by URI, including files not open, with
    /// how their server counts positions.
    problems: HashMap<String, (Encoding, Vec<Problem>)>,
    /// The folders servers may start in, as servers run a project's code
    /// (a build script, a config file): `None` lets them start anywhere.
    trusted: Option<Vec<PathBuf>>,
    /// Servers that would have started outside them, until they may.
    held: HashSet<Key>,
    events: Receiver<Event>,
    sender: Sender<Event>,
}

impl Default for Lsp {
    fn default() -> Self {
        let (sender, events) = crossbeam_channel::unbounded();
        Self {
            configs: Vec::new(),
            launcher: Box::new(launch),
            servers: HashMap::new(),
            next_server: 0,
            running: HashMap::new(),
            placed: HashMap::new(),
            failed: HashSet::new(),
            stops: HashMap::new(),
            given_up: Vec::new(),
            problems: HashMap::new(),
            trusted: None,
            held: HashSet::new(),
            events,
            sender,
        }
    }
}

impl Lsp {
    /// Sets how to start the server for a language, replacing any earlier
    /// setting. Servers that couldn't start or kept stopping are tried
    /// again.
    pub fn configure(&mut self, config: ServerConfig) {
        let language = config.language.clone();
        let markers = config.root_markers.clone();
        let old = self.configs.iter().position(|c| c.language == language);
        if old.is_none_or(|i| self.configs.remove(i).root_markers != markers) {
            // Its buffers' roots are looked for again.
            self.placed.retain(|_, p| p.language != language);
        }
        self.configs.push(config);
        self.failed.retain(|(l, _)| *l != language);
        self.stops.retain(|(l, _), _| *l != language);
    }

    /// Stops starting a server for `language`. One already running keeps
    /// running.
    pub fn remove(&mut self, language: &str) {
        self.configs.retain(|c| c.language != language);
    }

    /// Stops the servers running for `language` (every language with
    /// `None`), forgetting that any failed or kept stopping, so the next
    /// sync starts them fresh. Returns how many were running.
    pub fn restart(&mut self, language: Option<&str>) -> usize {
        let of = |l: &str| language.is_none_or(|language| l == language);
        let ids: Vec<ServerId> = (self.servers.iter())
            .filter(|(_, server)| of(&server.language))
            .map(|(id, _)| *id)
            .collect();
        for id in &ids {
            if let Some(server) = self.servers.remove(id) {
                self.running
                    .remove(&(server.language.clone(), server.root.clone()));
            }
        }
        self.failed.retain(|(l, _)| !of(l));
        self.stops.retain(|(l, _), _| !of(l));
        ids.len()
    }

    /// How each language's server starts.
    pub fn configs(&self) -> &[ServerConfig] {
        &self.configs
    }

    /// Lets servers start only in `folders` and the folders inside them
    /// (anywhere, with `None`). A server held back starts at the next sync
    /// once its folder is in them.
    pub fn trust(&mut self, folders: Option<Vec<PathBuf>>) {
        self.trusted = folders;
    }

    /// The servers held back, as their language and the folder they'd run
    /// in, sorted.
    pub fn held(&self) -> Vec<Key> {
        let mut held: Vec<Key> = self.held.iter().cloned().collect();
        held.sort();
        held
    }

    fn may_start(&self, root: &Path) -> bool {
        self.trusted
            .as_ref()
            .is_none_or(|folders| folders.iter().any(|folder| root.starts_with(folder)))
    }

    /// Starts servers with `launcher` instead of running their commands.
    pub fn set_launcher(&mut self, launcher: Launcher) {
        self.launcher = launcher;
    }

    /// Messages from servers, to pass to [`Lsp::handle`].
    pub fn events(&self) -> &Receiver<Event> {
        &self.events
    }

    /// Opens new documents, sends changed ones and closes those whose buffer
    /// was closed or now belongs to another server, starting servers on
    /// first use. Returns an error for each server that couldn't be reached
    /// or was given up on.
    pub fn sync(&mut self, editor: &Editor) -> Vec<LspError> {
        let projects = project_roots(editor);
        let mut errors = std::mem::take(&mut self.given_up);
        let mut sent: HashMap<BufferId, ServerId> = HashMap::new();
        for buffer in editor.buffers() {
            match self.sync_buffer(buffer, &projects) {
                Ok(Some(server)) => {
                    sent.insert(buffer.id(), server);
                }
                Ok(None) => {}
                Err(err) => errors.push(err),
            }
        }
        self.placed
            .retain(|id, _| editor.find_buffer(*id).is_some());
        for (&id, server) in &mut self.servers {
            let gone: Vec<String> = server
                .documents
                .extract_if(|buffer, _| sent.get(buffer) != Some(&id))
                .map(|(_, document)| document.uri)
                .collect();
            for uri in gone {
                if server.alive() {
                    let closed = json!({ "textDocument": { "uri": uri } });
                    let _ = server.notify("textDocument/didClose", &closed);
                }
            }
        }
        errors
    }

    /// Sends `buffer` to its server, starting the server if it isn't
    /// running. Returns the server, or `None` without one.
    fn sync_buffer(
        &mut self,
        buffer: &Buffer,
        projects: &[PathBuf],
    ) -> Result<Option<ServerId>, LspError> {
        let (Some(path), Some(language)) = (buffer.path(), buffer.language()) else {
            return Ok(None);
        };
        let Some(root) = self.place(buffer.id(), path, language, projects) else {
            return Ok(None);
        };
        let server = self.server_for(language, &root)?;
        if let Some(placed) = self.placed.get_mut(&buffer.id()) {
            placed.server = server;
        }
        let Some(server) = server else {
            return Ok(None);
        };
        self.send_document(server, buffer)?;
        Ok(Some(server))
    }

    /// The root `buffer`'s server runs in, worked out once per file and
    /// language. `None` when no server is set up for its language.
    fn place(
        &mut self,
        buffer: BufferId,
        path: &Path,
        language: &str,
        projects: &[PathBuf],
    ) -> Option<PathBuf> {
        if let Some(root) = self.placed_root(buffer, path, language) {
            return Some(root);
        }
        let config = self.configs.iter().find(|c| c.language == language)?;
        let root = server_root(path, &config.root_markers, projects);
        self.placed.insert(
            buffer,
            Placed {
                language: language.to_owned(),
                path: path.to_owned(),
                root: root.clone(),
                server: None,
            },
        );
        Some(root)
    }

    /// The root found for `buffer` last time, if its file and language are
    /// still the same.
    fn placed_root(&self, buffer: BufferId, path: &Path, language: &str) -> Option<PathBuf> {
        self.placed
            .get(&buffer)
            .filter(|p| p.is_for(path, language))
            .map(|p| p.root.clone())
    }

    /// Opens `buffer` in `server`, or sends what changed since it last was.
    fn send_document(&mut self, server: ServerId, buffer: &Buffer) -> Result<(), LspError> {
        let (Some(path), Some(language)) = (buffer.path(), buffer.language()) else {
            return Ok(());
        };
        let server = self.servers.get_mut(&server).expect("a running server");
        if !server.alive() {
            return Ok(());
        }
        let version = buffer.history().applied();
        let uri = file_uri(path);
        // A file saved under another name is another document.
        if let Some(old) = server.documents.get(&buffer.id())
            && old.uri != uri
        {
            let closed = json!({ "textDocument": { "uri": old.uri } });
            server.documents.remove(&buffer.id());
            server.notify("textDocument/didClose", &closed)?;
        }
        let (sync, encoding) = (server.sync, server.encoding);
        let Some(document) = server.documents.get_mut(&buffer.id()) else {
            let text = buffer.text().to_string();
            server.documents.insert(
                buffer.id(),
                Document {
                    version,
                    uri: uri.clone(),
                    text: buffer.text().clone(),
                },
            );
            let params = json!({ "textDocument": {
                "uri": uri, "languageId": language, "version": version, "text": text,
            }});
            return Ok(server.notify("textDocument/didOpen", &params)?);
        };
        if document.version == version {
            return Ok(());
        }
        let ranged = if sync == SyncKind::Incremental {
            ranged_changes(&document.text, document.version, buffer, encoding)
        } else {
            None
        };
        let changes = ranged.unwrap_or_else(|| vec![json!({ "text": buffer.text().to_string() })]);
        document.version = version;
        document.text = buffer.text().clone();
        let params = json!({
            "textDocument": { "uri": uri, "version": version },
            "contentChanges": changes,
        });
        Ok(server.notify("textDocument/didChange", &params)?)
    }

    /// The server for `language` in `root`, started if it isn't running yet.
    /// `None` if no server is set up for the language or it isn't installed.
    fn server_for(&mut self, language: &str, root: &Path) -> Result<Option<ServerId>, LspError> {
        let key = (language.to_owned(), root.to_owned());
        if let Some(&id) = self.running.get(&key) {
            return Ok(Some(id));
        }
        if self.failed.contains(&key) {
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
        if !config.reads_only && !self.may_start(root) {
            // Only one that would run: there's nothing to trust for one
            // that isn't installed.
            if config.installed_command().is_some() {
                self.held.insert(key);
            }
            return Ok(None);
        }
        self.held.remove(&key);
        let transport = match (self.launcher)(&config, root) {
            Ok(Some(transport)) => transport,
            // Not having a server installed is normal, so it's not an error.
            Ok(None) => {
                self.failed.insert(key);
                return Ok(None);
            }
            Err(err) => {
                self.failed.insert(key);
                return Err(LspError::NoServer(format!("{language}: {err}")));
            }
        };
        self.start(key, &config, transport).map(Some)
    }

    /// Talks to a new server of `config` over `transport`, and sends
    /// `initialize`.
    fn start(
        &mut self,
        key: Key,
        config: &ServerConfig,
        transport: Transport,
    ) -> Result<ServerId, LspError> {
        let id = self.next_server;
        self.next_server += 1;
        let (language, root) = key.clone();
        let command = config
            .installed_command()
            .or(config.commands.first())
            .cloned()
            .unwrap_or_default();
        let mut server = Server {
            language,
            root,
            command,
            connection: Connection::open(id, transport, &self.sender),
            started: Instant::now(),
            initialize_id: 0,
            ready: false,
            encoding: Encoding::Utf16,
            sync: SyncKind::Full,
            capabilities: Value::Null,
            queued: Vec::new(),
            documents: HashMap::new(),
            settings: config.settings.clone(),
        };
        let mut params = json!({
            "processId": std::process::id(),
            "rootUri": file_uri(&server.root),
            "rootPath": server.root,
            "workspaceFolders": server.workspace_folders(),
            "clientInfo": { "name": "greed" },
            "capabilities": client_capabilities(),
        });
        if !config.init_options.is_null() {
            params["initializationOptions"] = config.init_options.clone();
        }
        server.initialize_id = server.connection.request("initialize", &params)?;
        self.servers.insert(id, server);
        self.running.insert(key, id);
        Ok(id)
    }

    /// Sends a request about `buffer` to its server, after the buffer's
    /// latest text, so an edit made just before is seen. Returns the server
    /// and the request's id, which the response will carry.
    pub fn request(
        &mut self,
        buffer: &Buffer,
        method: &str,
        params: &Value,
    ) -> Result<(ServerId, i64), LspError> {
        let server = self.server_of(buffer)?;
        self.send_document(server, buffer)?;
        let id = self
            .servers
            .get_mut(&server)
            .expect("a running server")
            .request(method, params)?;
        Ok((server, id))
    }

    /// The running server `buffer` was last sent to.
    fn server_of(&self, buffer: &Buffer) -> Result<ServerId, LspError> {
        self.placed
            .get(&buffer.id())
            .filter(|p| {
                Some(p.path.as_path()) == buffer.path()
                    && Some(p.language.as_str()) == buffer.language()
            })
            .and_then(|p| p.server)
            .filter(|id| self.servers.get(id).is_some_and(Server::alive))
            .ok_or_else(|| LspError::NoServer(format!("buffer {}", buffer.id().0)))
    }

    /// The folder `buffer`'s server runs in, or would: `None` without a file
    /// or a server set up for its language.
    pub fn root(&self, buffer: &Buffer, editor: &Editor) -> Option<PathBuf> {
        let (path, language) = (buffer.path()?, buffer.language()?);
        if let Some(root) = self.placed_root(buffer.id(), path, language) {
            return Some(root);
        }
        let config = self.configs.iter().find(|c| c.language == language)?;
        Some(server_root(
            path,
            &config.root_markers,
            &project_roots(editor),
        ))
    }

    /// Whether `buffer`'s server is held back until its folder is trusted:
    /// one is set up for its language and installed, runs the project's
    /// code, and may not start where it would run.
    pub fn waits(&self, buffer: &Buffer, editor: &Editor) -> bool {
        let Some(language) = buffer.language() else {
            return false;
        };
        let Some(config) = self.configs.iter().find(|c| c.language == language) else {
            return false;
        };
        !config.reads_only
            && config.installed_command().is_some()
            && self
                .root(buffer, editor)
                .is_some_and(|root| !self.may_start(&root))
    }

    /// The servers running now, by language and then root.
    pub fn running(&self) -> Vec<Running> {
        let mut list: Vec<Running> = self
            .servers
            .values()
            .filter(|s| s.alive())
            .map(|s| Running {
                language: s.language.clone(),
                root: s.root.clone(),
                command: s.command.clone(),
                ready: s.ready,
                stderr: s.connection.stderr(),
            })
            .collect();
        list.sort_by(|a, b| (&a.language, &a.root).cmp(&(&b.language, &b.root)));
        list
    }

    /// Deals with one event from a server: finishes starting it, answers its
    /// requests, marks diagnostics, and passes responses back.
    pub fn handle(&mut self, event: Event, editor: &mut Editor) -> Handled {
        let Some(server) = self.servers.get_mut(&event.server()) else {
            return Handled::Nothing;
        };
        // An answer nothing waits for any more is dropped here.
        let Some(event) = server.connection.receive(event) else {
            return Handled::Nothing;
        };
        match event {
            Event::Response { server, id, result } if id == self.servers[&server].initialize_id => {
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
                language: self.servers[&server].language.clone(),
                root: self.servers[&server].root.clone(),
                method,
                params,
            },
            Event::Request {
                server,
                id,
                method,
                params,
            } if method == "workspace/configuration" => {
                let settings = self
                    .servers
                    .get(&server)
                    .map_or(&Value::Null, |s| &s.settings);
                let answers: Vec<Value> = params["items"]
                    .as_array()
                    .map(|items| {
                        items
                            .iter()
                            .map(|item| section(settings, item["section"].as_str()))
                            .collect()
                    })
                    .unwrap_or_default();
                self.respond(server, &id, &Value::Array(answers));
                Handled::Nothing
            }
            Event::Request {
                server, id, method, ..
            } if method == "workspace/workspaceFolders" => {
                let folders = self.servers[&server].workspace_folders();
                self.respond(server, &id, &folders);
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
                self.stopped(server);
                Handled::Exited { server }
            }
        }
    }

    /// Forgets `server`, which stopped, so the next sync starts it again,
    /// unless it keeps stopping soon after starting.
    fn stopped(&mut self, id: ServerId) {
        let Some(server) = self.servers.remove(&id) else {
            return;
        };
        let key = (server.language.clone(), server.root.clone());
        if self.running.get(&key) == Some(&id) {
            self.running.remove(&key);
        }
        let stops = self.stops.entry(key.clone()).or_default();
        *stops = if server.started.elapsed() < STEADY {
            *stops + 1
        } else {
            1
        };
        if *stops > RESTARTS {
            let program = server
                .command
                .first()
                .map_or("the language server", String::as_str);
            let why = server
                .connection
                .stderr()
                .last()
                .map(|line| format!(": {line}"))
                .unwrap_or_default();
            self.given_up.push(LspError::Stopped(format!(
                "{program} keeps stopping in {}, not starting it again{why}",
                server.root.display()
            )));
            self.failed.insert(key);
        }
    }

    /// Answers request `id` from `server`. A server that stopped hears
    /// nothing.
    pub fn respond(&mut self, server: ServerId, id: &Value, result: &Value) {
        if let Some(server) = self.servers.get_mut(&server) {
            let _ = server.connection.respond(id, Ok(result));
        }
    }

    /// What `buffer`'s server said it can do, e.g. `renameProvider`.
    pub fn capabilities(&self, buffer: &Buffer) -> Result<&Value, LspError> {
        Ok(&self.servers[&self.server_of(buffer)?].capabilities)
    }

    fn finish_initialize(&mut self, server: ServerId, result: Option<&Value>) {
        let Some(server) = self.servers.get_mut(&server) else {
            return;
        };
        if let Some(capabilities) = result.map(|r| &r["capabilities"]) {
            if capabilities["positionEncoding"].as_str() == Some("utf-8") {
                server.encoding = Encoding::Utf8;
            }
            server.sync = SyncKind::of(capabilities);
            server.capabilities = capabilities.clone();
        }
        server.ready = true;
        let _ = server.notify("initialized", &json!({}));
        // Servers that don't ask for their settings read them from here.
        if !server.settings.is_null() {
            let settings = json!({ "settings": server.settings });
            let _ = server.notify("workspace/didChangeConfiguration", &settings);
        }
        for message in std::mem::take(&mut server.queued) {
            let _ = server.send(message);
        }
    }

    fn store_diagnostics(
        &mut self,
        server: ServerId,
        params: &Value,
        editor: &mut Editor,
    ) -> Handled {
        let encoding = self.servers[&server].encoding;
        let Some(uri) = params["uri"].as_str() else {
            return Handled::Nothing;
        };
        let buffer = buffer_at(editor, uri).map(|b| (b.id(), b.history().applied()));
        // Positions for an older version of the text than the buffer's would
        // land in the wrong places; the server sends new ones for the latest.
        if let (Some(version), Some((_, current))) = (params["version"].as_u64(), buffer)
            && usize::try_from(version).is_ok_and(|v| v < current)
        {
            return Handled::Nothing;
        }
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
            self.problems.insert(uri.to_owned(), (encoding, problems));
        }
        let Some((buffer, _)) = buffer else {
            return Handled::Nothing;
        };
        let text = editor.buffer(buffer).text();
        let mut reported: Vec<&Value> = reported.iter().collect();
        // The worst last, so its style is drawn on top.
        reported.sort_by_key(|d| std::cmp::Reverse(severity(d)));
        let marks = reported
            .into_iter()
            .filter_map(|d| diagnostic_mark(text, d, encoding))
            .collect();
        editor.decorate(buffer, DIAGNOSTICS, marks);
        Handled::Diagnostics(buffer)
    }

    /// Every file's latest problems, open or not. Those in open buffers are
    /// where they are now, after any edits since the server sent them.
    pub fn problems(&self, editor: &Editor) -> Vec<Problem> {
        let mut problems = Vec::new();
        for (uri, (encoding, reported)) in &self.problems {
            let Some(buffer) = buffer_at(editor, uri) else {
                problems.extend(reported.iter().cloned());
                continue;
            };
            let text = buffer.text();
            problems.extend(diagnostics(buffer).into_iter().map(|d| Problem {
                uri: uri.clone(),
                range: json!({
                    "start": position(text, d.from, *encoding),
                    "end": position(text, d.to, *encoding),
                }),
                severity: d.severity,
                message: d.message,
                source: d.source,
            }));
        }
        problems
    }

    /// How `buffer`'s server counts positions within a line.
    pub fn encoding(&self, buffer: &Buffer) -> Result<Encoding, LspError> {
        Ok(self.servers[&self.server_of(buffer)?].encoding)
    }
}

/// A diagnostic's severity, an error when the server doesn't say.
fn severity(diagnostic: &Value) -> u8 {
    diagnostic["severity"]
        .as_u64()
        .and_then(|s| u8::try_from(s).ok())
        .unwrap_or(1)
}

/// The problems a server found in `buffer`, where they are now, in order.
pub fn diagnostics(buffer: &Buffer) -> Vec<Diagnostic> {
    let mut list: Vec<Diagnostic> = buffer
        .marks(DIAGNOSTICS)
        .iter()
        .map(|mark| {
            let data = mark.data.as_ref().unwrap_or(&Value::Null);
            Diagnostic {
                from: mark.range.start,
                to: mark.range.end,
                severity: severity(data),
                message: data["message"].as_str().unwrap_or_default().to_owned(),
                source: data["source"].as_str().map(str::to_owned),
            }
        })
        .collect();
    list.sort_by_key(|d| (d.from, d.to));
    list
}

/// A diagnostic as a mark: its text underlined and its line number styled
/// by severity, with the server's details kept in its data.
fn diagnostic_mark(text: &Rope, diagnostic: &Value, encoding: Encoding) -> Option<Mark> {
    let from = offset(text, &diagnostic["range"]["start"], encoding)?;
    let to = offset(text, &diagnostic["range"]["end"], encoding)?;
    let severity = severity(diagnostic);
    let name = match severity {
        1 => "error",
        2 => "warning",
        3 => "info",
        _ => "hint",
    };
    Some(Mark {
        range: shown_range(text, from, to.max(from)),
        style: format!("diagnostic.{name}").into(),
        gutter: Some(format!("ui.gutter.diagnostic.{name}").into()),
        above: true,
        data: Some(json!({
            "severity": severity,
            "message": diagnostic["message"],
            "source": diagnostic["source"],
        })),
        ..Mark::default()
    })
}

/// `from..to`, but an empty range covers the character after it, or the one
/// before it at the end of a line, so that it shows.
fn shown_range(text: &Rope, from: usize, to: usize) -> Range<usize> {
    if from < to {
        return from..to;
    }
    let on_line = |c: &char| *c != '\n' && *c != '\r';
    let at = text.byte_to_char(from);
    if let Some(c) = text.get_char(at).filter(on_line) {
        return from..from + c.len_utf8();
    }
    match at
        .checked_sub(1)
        .and_then(|i| text.get_char(i))
        .filter(on_line)
    {
        Some(c) => from - c.len_utf8()..from,
        None => from..from,
    }
}

/// The open buffer of the file at `uri`.
fn buffer_at<'a>(editor: &'a Editor, uri: &str) -> Option<&'a Buffer> {
    editor
        .buffers()
        .find(|b| b.path().is_some_and(|p| file_uri(p) == uri))
}

/// The part of `settings` a server asks for by its `section`, like
/// `rust-analyzer.cargo`: all of them without one, null when it isn't there.
fn section(settings: &Value, name: Option<&str>) -> Value {
    let mut found = settings;
    for key in name
        .unwrap_or_default()
        .split('.')
        .filter(|k| !k.is_empty())
    {
        found = &found[key];
    }
    found.clone()
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

/// Where a server for the file at `path` runs, as editors decide it.
///
/// Inside a project, the deepest of `projects` or of the version control
/// roots that holds the file, it's the topmost folder from the file up to
/// the project's root that has one of `markers`, so a Cargo or npm
/// workspace gets one server for all its members; without one, the
/// project's root. Outside any project it's [`project_root`].
pub fn server_root(path: &Path, markers: &[String], projects: &[PathBuf]) -> PathBuf {
    let dir = existing_folder(path);
    let repository = dir
        .ancestors()
        .find(|d| has_marker(d, &crate::project::MARKERS));
    let project = projects
        .iter()
        .map(PathBuf::as_path)
        .chain(repository)
        .filter(|p| dir.starts_with(p))
        .max_by_key(|p| p.components().count());
    let Some(project) = project else {
        return project_root(path, markers);
    };
    dir.ancestors()
        .take_while(|d| d.starts_with(project))
        .filter(|d| has_marker(d, markers))
        .last()
        .unwrap_or(project)
        .to_owned()
}

fn project_roots(editor: &Editor) -> Vec<PathBuf> {
    editor
        .projects()
        .iter()
        .map(|p| p.root().to_owned())
        .collect()
}

/// Where a server for the file at `path` runs outside a project: the
/// nearest directory with one of `markers`, or the file's own directory.
pub fn project_root(path: &Path, markers: &[String]) -> PathBuf {
    let existing = existing_folder(path);
    existing
        .ancestors()
        .find(|d| has_marker(d, markers))
        .unwrap_or(&existing)
        .to_owned()
}

fn has_marker(dir: &Path, markers: &[impl AsRef<Path>]) -> bool {
    markers.iter().any(|m| dir.join(m).exists())
}

/// The folder of the file at `path`, as a full path, or the nearest one up
/// that exists: a new file can be in folders not made yet.
fn existing_folder(path: &Path) -> PathBuf {
    // A bare file name like "notes.md" has an empty parent: the current
    // directory.
    let dir = match path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent.to_owned(),
        _ => PathBuf::from("."),
    };
    let dir = std::path::absolute(&dir).unwrap_or(dir);
    dir.ancestors()
        .find(|d| d.is_dir())
        .unwrap_or(&dir)
        .to_owned()
}

/// The changes that took `text`, the document as the server last had it
/// at version `since`, to `buffer`'s text now, as LSP content changes in
/// the order they apply, each range against the text after the ones
/// before. `None` when they can't be told apart that way: the buffer
/// doesn't keep the transactions since, or the text has line breaks LSP
/// doesn't count as such.
fn ranged_changes(
    text: &Rope,
    since: usize,
    buffer: &Buffer,
    encoding: Encoding,
) -> Option<Vec<Value>> {
    let history = buffer.history();
    let log = history.log();
    let count = history.applied().checked_sub(since)?;
    let first = log.len().checked_sub(count)?;
    let mut text = text.clone();
    let mut changes = Vec::new();
    for tx in &log[first..] {
        if tx.changes.len() != text.len_bytes() {
            return None;
        }
        let mut pos = 0;
        let mut ops = tx.changes.ops().iter().peekable();
        while let Some(op) = ops.next() {
            let (deleted, inserted) = match op {
                Operation::Retain(n) => {
                    pos += n;
                    continue;
                }
                Operation::Delete(n) => (*n, ""),
                // An insert before a delete at the same place replaces it.
                Operation::Insert(new) => {
                    match ops.next_if(|op| matches!(op, Operation::Delete(_))) {
                        Some(Operation::Delete(n)) => (*n, new.as_str()),
                        _ => (0, new.as_str()),
                    }
                }
            };
            changes.push(replace(&mut text, pos..pos + deleted, inserted, encoding));
            pos += inserted.len();
        }
    }
    (text == *buffer.text()).then_some(changes)
}

/// Replaces `range` of `text` with `new`, and returns that as an LSP content
/// change against the text before. A range starting or ending between a
/// `\r` and its `\n` takes in the whole line break, since servers can't
/// place a position there.
fn replace(text: &mut Rope, range: Range<usize>, new: &str, encoding: Encoding) -> Value {
    let splits = |at: usize| {
        at > 0 && at < text.len_bytes() && text.byte(at - 1) == b'\r' && text.byte(at) == b'\n'
    };
    let (mut from, mut to) = (range.start, range.end);
    let mut new = Cow::Borrowed(new);
    if splits(from) {
        from -= 1;
        new = format!("\r{new}").into();
    }
    if splits(to) {
        to += 1;
        new = format!("{new}\n").into();
    }
    let change = json!({
        "range": { "start": position(text, from, encoding), "end": position(text, to, encoding) },
        "text": new,
    });
    let (start, end) = (text.byte_to_char(from), text.byte_to_char(to));
    text.remove(start..end);
    text.insert(start, &new);
    change
}

/// An LSP position (`{ line, character }`) for byte `pos`, or for the start
/// of the character it is inside.
pub fn position(text: &Rope, pos: usize, encoding: Encoding) -> Value {
    let pos = text.char_to_byte(text.byte_to_char(pos.min(text.len_bytes())));
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
    for c in line_content(text, line).chars() {
        if units >= character {
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
