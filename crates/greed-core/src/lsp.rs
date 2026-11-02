//! A language server client: starts servers, speaks the language server
//! protocol to them over [`rpc`](crate::rpc), and keeps their view of open
//! documents in sync.
//!
//! A language has a main server and may have others that run beside it,
//! like `eslint` beside TypeScript's. Each runs once per root (see
//! [`server_root`]), started the first time a buffer that needs it shows
//! up, and started again if it stops; a buffer is sent to all of its
//! language's that run for it. What servers send arrives as [`Event`]s,
//! which the editor handles on its own thread.

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

/// How to start a server for one language: its main one, or one that runs
/// beside it, like `eslint` beside TypeScript's.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ServerConfig {
    pub language: String,
    /// The name of a server that runs beside the language's main one;
    /// empty for the main one.
    pub name: String,
    /// Files that must be in the file's folder or one above it, within its
    /// project, for the server to run for it, in the folder that has one:
    /// `eslint` runs only where it's set up. Empty runs it everywhere.
    pub when: Vec<String>,
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
    /// The features it's used for, like `"hover"` or `"format"`, for the
    /// plugins that pick a buffer's server for one: only these, when there
    /// are any, and never those in `except`.
    pub only: Vec<String>,
    pub except: Vec<String>,
}

impl ServerConfig {
    /// What it's called: its name, or its language's for the main one.
    pub fn name(&self) -> &str {
        shown_name(&self.language, &self.name)
    }

    /// Whether it's `language`'s server called `name` (empty for the main
    /// one).
    fn is(&self, language: &str, name: &str) -> bool {
        self.language == language && self.name == name
    }

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
        server: ServerId,
        language: String,
        /// The server's name: its language's for the main one.
        name: String,
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
    /// The server that reported it.
    pub server: Option<ServerId>,
    /// What the server knows it by, its `code` and `data`: a server asked
    /// for fixes finds its own by them, as eslint finds a rule's.
    pub code: Value,
    pub data: Value,
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
    /// Its config's name: empty for the language's main server.
    name: String,
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
    /// The features it's used for, and not ([`ServerConfig::only`]).
    only: Vec<String>,
    except: Vec<String>,
    /// The diagnostics asked of it and not answered yet, as a server that
    /// reports them only when asked (`diagnosticProvider`) wants: by
    /// request id, the document's URI and the version they're for.
    pulls: HashMap<i64, (String, usize)>,
}

/// An open document as the server has it.
struct Document {
    version: usize,
    uri: String,
    text: Rope,
    /// How many times its buffer was saved, as the server last heard.
    saves: u64,
}

/// Whether a server wants to hear when a document is saved, as
/// `textDocumentSync` in its capabilities says, and if so whether with its
/// text.
fn save_wanted(capabilities: &Value) -> Option<bool> {
    match &capabilities["textDocumentSync"]["save"] {
        Value::Bool(true) => Some(false),
        Value::Object(save) => Some(save.get("includeText") == Some(&Value::Bool(true))),
        _ => None,
    }
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
    fn key(&self) -> Key {
        (self.language.clone(), self.name.clone(), self.root.clone())
    }

    /// Asks for the diagnostics of the document at `uri`, at `version`, if
    /// the server reports them only when asked; the answer goes where
    /// published ones do.
    fn pull(&mut self, uri: &str, version: usize) -> io::Result<()> {
        if self.capabilities["diagnosticProvider"].is_null() {
            return Ok(());
        }
        let params = json!({ "textDocument": { "uri": uri } });
        let id = self.request("textDocument/diagnostic", &params)?;
        self.pulls.insert(id, (uri.to_owned(), version));
        Ok(())
    }

    /// Asks again for the diagnostics of every document it has open, as
    /// when it says they changed.
    fn pull_all(&mut self) -> io::Result<()> {
        let open: Vec<(String, usize)> = (self.documents.values())
            .map(|d| (d.uri.clone(), d.version))
            .collect();
        for (uri, version) in open {
            self.pull(&uri, version)?;
        }
        Ok(())
    }

    /// Its name, or its language's for the main one.
    fn shown_name(&self) -> &str {
        shown_name(&self.language, &self.name)
    }

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

/// A language, a server's name for it (empty for its main one), and the
/// root the server runs in.
pub type Key = (String, String, PathBuf);

/// Where a set of diagnostics came from: the server, and whether it was
/// asked for them (pulled) or published them. A server may do both, as
/// rust-analyzer answers for what it sees itself and publishes what
/// `cargo check` found; each replaces only its own.
type Origin = (ServerId, bool);

/// Where a buffer's servers are: its language and file, and the root each
/// of its language's servers runs in for it (by name, the main one first),
/// so roots aren't looked for on every sync; and the servers it was last
/// sent to, in the same order.
struct Placed {
    language: String,
    path: PathBuf,
    roots: Vec<(String, PathBuf)>,
    servers: Vec<ServerId>,
}

impl Placed {
    fn is_for(&self, path: &Path, language: &str) -> bool {
        self.path == path && self.language == language
    }
}

/// A server that's running, as [`Lsp::running`] lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Running {
    pub id: ServerId,
    pub language: String,
    /// Its name: the language's for its main server.
    pub name: String,
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
    /// Every file's latest problems, by URI, including files not open, as
    /// each server reported them (by [`Origin`]), with how it counts
    /// positions.
    problems: HashMap<String, HashMap<Origin, (Encoding, Vec<Problem>)>>,
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
        let (language, name) = (config.language.clone(), config.name.clone());
        let old = self.configs.iter().position(|c| c.is(&language, &name));
        // A new server, or one running elsewhere: its language's buffers'
        // roots are looked for again.
        if old.is_none_or(|i| {
            let old = &self.configs[i];
            old.root_markers != config.root_markers || old.when != config.when
        }) {
            self.placed.retain(|_, p| p.language != language);
        }
        match old {
            Some(i) => self.configs[i] = config,
            None => self.configs.push(config),
        }
        self.failed.retain(|(l, n, _)| (l, n) != (&language, &name));
        self.stops
            .retain(|(l, n, _), _| (l, n) != (&language, &name));
    }

    /// Stops starting `language`'s server called `name` (empty for its main
    /// one), or every server for it with `None`. One already running keeps
    /// running.
    pub fn remove(&mut self, language: &str, name: Option<&str>) {
        self.configs
            .retain(|c| c.language != language || name.is_some_and(|name| c.name != name));
        self.placed.retain(|_, p| p.language != language);
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
                self.running.remove(&server.key());
            }
        }
        self.failed.retain(|(l, _, _)| !of(l));
        self.stops.retain(|(l, _, _), _| !of(l));
        ids.len()
    }

    /// `language`'s servers, its main one first and then the others in the
    /// order they were set up.
    fn configs_of(&self, language: &str) -> Vec<&ServerConfig> {
        let mut found: Vec<&ServerConfig> = (self.configs.iter())
            .filter(|c| c.language == language)
            .collect();
        found.sort_by_key(|c| !c.name.is_empty());
        found
    }

    /// Where `config`'s server runs for the file at `path`: `None` when it
    /// only runs where one of its `when` files is and there's none.
    fn root_of(config: &ServerConfig, path: &Path, projects: &[PathBuf]) -> Option<PathBuf> {
        if config.when.is_empty() {
            Some(server_root(path, &config.root_markers, projects))
        } else {
            marked_root(path, &config.when, projects)
        }
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
    /// was closed or no longer belongs to the server, starting servers on
    /// first use. Returns an error for each server that couldn't be reached
    /// or was given up on.
    pub fn sync(&mut self, editor: &Editor) -> Vec<LspError> {
        let projects = project_roots(editor);
        let mut errors = std::mem::take(&mut self.given_up);
        let mut sent: HashMap<BufferId, Vec<ServerId>> = HashMap::new();
        for buffer in editor.buffers() {
            let servers = self.sync_buffer(buffer, &projects, &mut errors);
            sent.insert(buffer.id(), servers);
        }
        self.placed
            .retain(|id, _| editor.find_buffer(*id).is_some());
        for (&id, server) in &mut self.servers {
            let gone: Vec<String> = server
                .documents
                .extract_if(|buffer, _| !sent.get(buffer).is_some_and(|s| s.contains(&id)))
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

    /// Sends `buffer` to its servers, starting those that aren't running,
    /// and returns them, adding to `errors` for each that couldn't be.
    fn sync_buffer(
        &mut self,
        buffer: &Buffer,
        projects: &[PathBuf],
        errors: &mut Vec<LspError>,
    ) -> Vec<ServerId> {
        let (Some(path), Some(language)) = (buffer.path(), buffer.language()) else {
            return Vec::new();
        };
        let mut servers = Vec::new();
        for (name, root) in self.place(buffer.id(), path, language, projects) {
            match self.server_for(language, &name, &root) {
                Ok(Some(server)) => servers.push(server),
                Ok(None) => {}
                Err(err) => errors.push(err),
            }
        }
        if let Some(placed) = self.placed.get_mut(&buffer.id()) {
            placed.servers.clone_from(&servers);
        }
        servers.retain(|&server| match self.send_document(server, buffer) {
            Ok(()) => true,
            Err(err) => {
                errors.push(err);
                false
            }
        });
        servers
    }

    /// The root each of `buffer`'s language's servers runs in for it, by
    /// name, worked out once per file and language: empty when none is set
    /// up for its language, or runs for this file.
    fn place(
        &mut self,
        buffer: BufferId,
        path: &Path,
        language: &str,
        projects: &[PathBuf],
    ) -> Vec<(String, PathBuf)> {
        if let Some(placed) = self.placed_of(buffer, path, language) {
            return placed.roots.clone();
        }
        let roots: Vec<(String, PathBuf)> = (self.configs_of(language).into_iter())
            .filter_map(|c| Some((c.name.clone(), Self::root_of(c, path, projects)?)))
            .collect();
        self.placed.insert(
            buffer,
            Placed {
                language: language.to_owned(),
                path: path.to_owned(),
                roots: roots.clone(),
                servers: Vec::new(),
            },
        );
        roots
    }

    /// Where `buffer`'s servers were found last time, if its file and
    /// language are still the same.
    fn placed_of(&self, buffer: BufferId, path: &Path, language: &str) -> Option<&Placed> {
        self.placed
            .get(&buffer)
            .filter(|p| p.is_for(path, language))
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
        let save = save_wanted(&server.capabilities);
        let Some(document) = server.documents.get_mut(&buffer.id()) else {
            let text = buffer.text().to_string();
            server.documents.insert(
                buffer.id(),
                Document {
                    version,
                    uri: uri.clone(),
                    text: buffer.text().clone(),
                    saves: buffer.saves(),
                },
            );
            let params = json!({ "textDocument": {
                "uri": uri, "languageId": language, "version": version, "text": text,
            }});
            server.notify("textDocument/didOpen", &params)?;
            return Ok(server.pull(&uri, version)?);
        };
        let mut told = Vec::new();
        let edited = document.version != version;
        if edited {
            let ranged = if sync == SyncKind::Incremental {
                ranged_changes(&document.text, document.version, buffer, encoding)
            } else {
                None
            };
            let changes =
                ranged.unwrap_or_else(|| vec![json!({ "text": buffer.text().to_string() })]);
            document.version = version;
            document.text = buffer.text().clone();
            let params = json!({
                "textDocument": { "uri": uri, "version": version },
                "contentChanges": changes,
            });
            told.push(("textDocument/didChange", params));
        }
        // A save after what changed, so the server checks the text saved, as
        // rust-analyzer runs the compiler on save.
        if document.saves != buffer.saves() {
            document.saves = buffer.saves();
            if let Some(with_text) = save {
                let mut params = json!({ "textDocument": { "uri": uri } });
                if with_text {
                    params["text"] = Value::from(buffer.text().to_string());
                }
                told.push(("textDocument/didSave", params));
            }
        }
        for (method, params) in told {
            server.notify(method, &params)?;
        }
        if edited {
            server.pull(&uri, version)?;
        }
        Ok(())
    }

    /// `language`'s server called `name` (empty for its main one) in
    /// `root`, started if it isn't running yet. `None` if it isn't set up or
    /// isn't installed.
    fn server_for(
        &mut self,
        language: &str,
        name: &str,
        root: &Path,
    ) -> Result<Option<ServerId>, LspError> {
        let key = (language.to_owned(), name.to_owned(), root.to_owned());
        if let Some(&id) = self.running.get(&key) {
            return Ok(Some(id));
        }
        if self.failed.contains(&key) {
            return Ok(None);
        }
        let Some(config) = self.configs.iter().find(|c| c.is(language, name)).cloned() else {
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
                return Err(LspError::NoServer(format!("{}: {err}", config.name())));
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
        let (language, name, root) = key.clone();
        let command = config
            .installed_command()
            .or(config.commands.first())
            .cloned()
            .unwrap_or_default();
        let mut server = Server {
            language,
            name,
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
            only: config.only.clone(),
            except: config.except.clone(),
            pulls: HashMap::new(),
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

    /// Sends a request about `buffer` to its first server, after the
    /// buffer's latest text, so an edit made just before is seen. Returns
    /// the server and the request's id, which the response will carry.
    pub fn request(
        &mut self,
        buffer: &Buffer,
        method: &str,
        params: &Value,
    ) -> Result<(ServerId, i64), LspError> {
        let server = self.server_of(buffer)?;
        self.request_to(server, buffer, method, params)
    }

    /// Sends a request about `buffer` to `server`, one of its servers, as
    /// [`Lsp::request`] does.
    pub fn request_to(
        &mut self,
        server: ServerId,
        buffer: &Buffer,
        method: &str,
        params: &Value,
    ) -> Result<(ServerId, i64), LspError> {
        if !self.servers_of(buffer).contains(&server) {
            return Err(LspError::NoServer(format!(
                "server {server} for buffer {}",
                buffer.id().0
            )));
        }
        self.send_document(server, buffer)?;
        let id = self
            .servers
            .get_mut(&server)
            .expect("a running server")
            .request(method, params)?;
        Ok((server, id))
    }

    /// The running servers `buffer` was last sent to, its language's main
    /// one first and then the others in the order they were set up.
    pub fn servers_of(&self, buffer: &Buffer) -> Vec<ServerId> {
        let (Some(path), Some(language)) = (buffer.path(), buffer.language()) else {
            return Vec::new();
        };
        self.placed_of(buffer.id(), path, language)
            .into_iter()
            .flat_map(|p| p.servers.iter().copied())
            .filter(|id| self.servers.get(id).is_some_and(Server::alive))
            .collect()
    }

    /// The first of `buffer`'s running servers.
    fn server_of(&self, buffer: &Buffer) -> Result<ServerId, LspError> {
        self.servers_of(buffer)
            .first()
            .copied()
            .ok_or_else(|| LspError::NoServer(format!("buffer {}", buffer.id().0)))
    }

    /// The folder `buffer`'s first server runs in, or would: `None` without
    /// a file or a server set up for its language that runs for it.
    pub fn root(&self, buffer: &Buffer, editor: &Editor) -> Option<PathBuf> {
        let (path, language) = (buffer.path()?, buffer.language()?);
        if let Some(placed) = self.placed_of(buffer.id(), path, language) {
            return placed.roots.first().map(|(_, root)| root.clone());
        }
        let projects = project_roots(editor);
        (self.configs_of(language).into_iter()).find_map(|c| Self::root_of(c, path, &projects))
    }

    /// Whether one of `buffer`'s servers is held back until its folder is
    /// trusted: set up for its language and installed, it runs the
    /// project's code and may not start where it would run.
    pub fn waits(&self, buffer: &Buffer, editor: &Editor) -> bool {
        let (Some(path), Some(language)) = (buffer.path(), buffer.language()) else {
            return false;
        };
        let projects = project_roots(editor);
        self.configs_of(language).into_iter().any(|config| {
            !config.reads_only
                && config.installed_command().is_some()
                && Self::root_of(config, path, &projects).is_some_and(|root| !self.may_start(&root))
        })
    }

    /// The servers running now, by language, name and root.
    pub fn running(&self) -> Vec<Running> {
        let mut list: Vec<Running> = self
            .servers
            .iter()
            .filter(|(_, s)| s.alive())
            .map(|(&id, s)| Running {
                id,
                language: s.language.clone(),
                name: s.shown_name().to_owned(),
                root: s.root.clone(),
                command: s.command.clone(),
                ready: s.ready,
                stderr: s.connection.stderr(),
            })
            .collect();
        list.sort_by(|a, b| (&a.language, &a.name, &a.root).cmp(&(&b.language, &b.name, &b.root)));
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
            Event::Response { server, id, result }
                if self.servers[&server].pulls.contains_key(&id) =>
            {
                self.pulled(server, id, result, editor)
            }
            Event::Response { server, id, result } => Handled::Response { server, id, result },
            Event::Notification {
                server,
                method,
                params,
            } if method == "textDocument/publishDiagnostics" => {
                self.store_diagnostics((server, false), &params, editor)
            }
            Event::Request {
                server, id, method, ..
            } if method == "workspace/diagnostic/refresh" => {
                self.respond(server, &id, &Value::Null);
                if let Some(server) = self.servers.get_mut(&server) {
                    let _ = server.pull_all();
                }
                Handled::Nothing
            }
            Event::Notification {
                server,
                method,
                params,
            } => {
                let from = &self.servers[&server];
                Handled::Notification {
                    server,
                    language: from.language.clone(),
                    name: from.shown_name().to_owned(),
                    root: from.root.clone(),
                    method,
                    params,
                }
            }
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
        let key = server.key();
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

    /// What `buffer`'s first server said it can do, e.g. `renameProvider`.
    pub fn capabilities(&self, buffer: &Buffer) -> Result<&Value, LspError> {
        Ok(&self.servers[&self.server_of(buffer)?].capabilities)
    }

    /// What `server` said it can do, while it runs.
    pub fn capabilities_of(&self, server: ServerId) -> Option<&Value> {
        self.servers.get(&server).map(|s| &s.capabilities)
    }

    /// How `server` counts positions within a line, while it runs.
    pub fn encoding_of(&self, server: ServerId) -> Option<Encoding> {
        self.servers.get(&server).map(|s| s.encoding)
    }

    /// `server`'s name, its language's for the main one, while it runs.
    pub fn name_of(&self, server: ServerId) -> Option<&str> {
        self.servers.get(&server).map(Server::shown_name)
    }

    /// The features `server` is used for, and those it isn't, as its
    /// config said when it started.
    pub fn features_of(&self, server: ServerId) -> Option<(&[String], &[String])> {
        self.servers
            .get(&server)
            .map(|s| (s.only.as_slice(), s.except.as_slice()))
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
        // Documents opened before it could say how it reports diagnostics.
        let _ = server.pull_all();
    }

    /// Takes in `server`'s answer to the diagnostics asked with request `id`:
    /// stored as published ones are, unless the document changed since,
    /// when the answer for its newer text is on its way.
    fn pulled(
        &mut self,
        server: ServerId,
        id: i64,
        result: Result<Value, Value>,
        editor: &mut Editor,
    ) -> Handled {
        let Some(asked) = self.servers.get_mut(&server) else {
            return Handled::Nothing;
        };
        let Some((uri, version)) = asked.pulls.remove(&id) else {
            return Handled::Nothing;
        };
        let Ok(report) = result else {
            return Handled::Nothing;
        };
        let current = asked
            .documents
            .values()
            .any(|d| d.uri == uri && d.version == version);
        // "unchanged" keeps what it reported last.
        if !current || report["kind"] != "full" {
            return Handled::Nothing;
        }
        let params = json!({ "uri": uri, "diagnostics": report["items"] });
        self.store_diagnostics((server, true), &params, editor)
    }

    /// Stores the diagnostics in `params` (a `publishDiagnostics`'s) as
    /// `origin`'s, in place of what it reported before for the document,
    /// leaving every other's.
    fn store_diagnostics(
        &mut self,
        origin: Origin,
        params: &Value,
        editor: &mut Editor,
    ) -> Handled {
        let server = origin.0;
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
        // Each origin's own: one clearing its problems leaves the others'.
        let by_origin = self.problems.entry(uri.to_owned()).or_default();
        if problems.is_empty() {
            by_origin.remove(&origin);
        } else {
            by_origin.insert(origin, (encoding, problems));
        }
        if by_origin.is_empty() {
            self.problems.remove(uri);
        }
        let Some((buffer, _)) = buffer else {
            return Handled::Nothing;
        };
        let text = editor.buffer(buffer).text();
        // The others' marks stay where edits since moved them.
        let others = (editor.buffer(buffer).marks(DIAGNOSTICS).iter())
            .filter(|mark| mark_origin(mark) != Some(origin))
            .cloned();
        let mut marks: Vec<Mark> = reported
            .iter()
            .filter_map(|d| diagnostic_mark(text, d, encoding, origin))
            .chain(others)
            .collect();
        // The worst last, so its style is drawn on top.
        marks.sort_by_key(|mark| std::cmp::Reverse(mark.data.as_ref().map_or(1, severity)));
        editor.decorate(buffer, DIAGNOSTICS, marks);
        Handled::Diagnostics(buffer)
    }

    /// Every file's latest problems, open or not, from every server. Those
    /// in open buffers are where they are now, after any edits since the
    /// servers sent them.
    pub fn problems(&self, editor: &Editor) -> Vec<Problem> {
        let mut problems = Vec::new();
        for (uri, by_origin) in &self.problems {
            let Some(buffer) = buffer_at(editor, uri) else {
                for (_, reported) in by_origin.values() {
                    problems.extend(reported.iter().cloned());
                }
                continue;
            };
            let text = buffer.text();
            let encoding = |server: Option<ServerId>| {
                (by_origin.iter())
                    .find(|((from, _), _)| Some(*from) == server)
                    .map_or(Encoding::Utf16, |(_, (encoding, _))| *encoding)
            };
            problems.extend(diagnostics(buffer).into_iter().map(|d| {
                let encoding = encoding(d.server);
                Problem {
                    uri: uri.clone(),
                    range: json!({
                        "start": position(text, d.from, encoding),
                        "end": position(text, d.to, encoding),
                    }),
                    severity: d.severity,
                    message: d.message,
                    source: d.source,
                }
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
                server: mark_server(mark),
                code: data["code"].clone(),
                data: data["data"].clone(),
            }
        })
        .collect();
    list.sort_by_key(|d| (d.from, d.to));
    list
}

/// The server a diagnostic's mark came from.
fn mark_server(mark: &Mark) -> Option<ServerId> {
    mark_origin(mark).map(|(server, _)| server)
}

/// Where a diagnostic's mark came from.
fn mark_origin(mark: &Mark) -> Option<Origin> {
    let data = mark.data.as_ref()?;
    let server = data["server"]
        .as_u64()
        .and_then(|id| ServerId::try_from(id).ok())?;
    Some((server, data["pulled"] == true))
}

/// A diagnostic `origin` reported as a mark: its text underlined and its
/// line number styled by severity, with the server's details kept in its
/// data.
fn diagnostic_mark(
    text: &Rope,
    diagnostic: &Value,
    encoding: Encoding,
    (server, pulled): Origin,
) -> Option<Mark> {
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
            "code": diagnostic["code"],
            "data": diagnostic["data"],
            "server": server,
            "pulled": pulled,
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
            "diagnostics": { "refreshSupport": true },
        },
        "textDocument": {
            "hover": { "contentFormat": ["plaintext", "markdown"] },
            "publishDiagnostics": {},
            "diagnostic": { "dynamicRegistration": false },
            "synchronization": { "didSave": true },
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
    let Some(project) = project_of(&dir, projects) else {
        return project_root(path, markers);
    };
    dir.ancestors()
        .take_while(|d| d.starts_with(&project))
        .filter(|d| has_marker(d, markers))
        .last()
        .unwrap_or(&project)
        .to_owned()
}

/// Where a server that only runs where one of `markers` is runs for the
/// file at `path`: the nearest folder from the file up that has one, within
/// the file's project when it's in one. `None` without one.
pub fn marked_root(path: &Path, markers: &[String], projects: &[PathBuf]) -> Option<PathBuf> {
    let dir = existing_folder(path);
    let project = project_of(&dir, projects);
    dir.ancestors()
        .take_while(|d| project.as_ref().is_none_or(|p| d.starts_with(p)))
        .find(|d| has_marker(d, markers))
        .map(Path::to_owned)
}

/// The innermost of `projects`, or else the repository, that holds `dir`.
fn project_of(dir: &Path, projects: &[PathBuf]) -> Option<PathBuf> {
    let repository = dir
        .ancestors()
        .find(|d| has_marker(d, &crate::project::MARKERS));
    projects
        .iter()
        .map(PathBuf::as_path)
        .chain(repository)
        .filter(|p| dir.starts_with(p))
        .max_by_key(|p| p.components().count())
        .map(Path::to_owned)
}

/// What a server is called: its name, or its language's for the main one.
fn shown_name<'a>(language: &'a str, name: &'a str) -> &'a str {
    if name.is_empty() { language } else { name }
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
