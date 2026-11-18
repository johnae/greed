//! Syntax highlighting with tree-sitter.
//!
//! Buffers are parsed on a worker thread, which always works on the latest
//! text it has been sent. The server keeps the newest tree for each buffer
//! and queries it for just the visible range when rendering. While the
//! worker catches up after an edit, the tree is the one before, told about
//! the edits since, so highlights move with the text until the new one
//! comes.

use std::collections::HashMap;
use std::ops::{ControlFlow, Range};
use std::path::Path;
use std::sync::{Arc, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, Sender};
use greed_text::Rope;
use streaming_iterator::StreamingIterator;
use tree_sitter::wasmtime::Engine;
use tree_sitter::{Node, ParseOptions, Parser, Query, QueryCursor, TextProvider, Tree, WasmStore};

use crate::{Buffer, BufferId, Editor};
use injections::{InjectionQuery, Injections, Layer, Marked};

mod incremental;
mod injections;
mod tags;

pub use tags::{Definition, FileTags, Tagger};

/// Buffers larger than this aren't parsed, so huge files stay responsive.
pub const MAX_BYTES: usize = 4 * 1024 * 1024;

/// How long a parse on the editor's thread may take, when a plugin wants a
/// tree before the worker has one.
const IN_TIME: Duration = Duration::from_millis(3);

/// A buffer's tree, for its text as of some version.
struct Held {
    /// The buffer version and text the tree fits.
    version: usize,
    text: Rope,
    tree: Tree,
    /// The languages inside it.
    layers: Vec<Layer>,
    /// The version it was parsed from: `version`, or an earlier one whose
    /// tree was told about the edits since, while the worker parses again.
    parsed: usize,
}

impl Held {
    fn new(version: usize, text: Rope, tree: Tree, layers: Vec<Layer>) -> Self {
        Self {
            version,
            text,
            tree,
            layers,
            parsed: version,
        }
    }

    /// Brings the tree and its layers up to `buffer`'s text by telling them
    /// about each edit since, so their nodes move with the text.
    fn follow(&mut self, buffer: &Buffer) {
        let version = buffer.history().applied();
        if self.version == version {
            return;
        }
        let edits =
            incremental::edits_since(buffer.history(), self.version, &self.text, buffer.text());
        for edit in &edits {
            self.tree.edit(edit);
            for layer in &mut self.layers {
                layer.tree.edit(edit);
            }
        }
        self.version = version;
        self.text = buffer.text().clone();
    }
}

/// A query that picks out what to highlight, and its capture names, e.g.
/// "keyword" or "function.macro".
struct Highlights {
    query: Query,
    captures: Vec<Arc<str>>,
}

impl From<Query> for Highlights {
    fn from(query: Query) -> Self {
        let captures = query.capture_names().iter().map(|&c| c.into()).collect();
        Self { query, captures }
    }
}

/// A grammar and the queries that come with it. The queries compile the
/// first time they're needed, since most are replaced by query files and
/// compiling all of them would slow every start.
pub struct Language {
    pub name: &'static str,
    grammar: tree_sitter::Language,
    /// The grammar's own highlights query, used until a plugin sets one.
    default_highlights: &'static str,
    highlights: OnceLock<Highlights>,
    /// The grammar's own injections query, if it has one.
    default_injections: Option<&'static str>,
    /// The language whose grammar this one shares, and whose queries it
    /// uses where it has none of its own.
    shares: Option<&'static str>,
}

impl Language {
    fn new(
        name: &'static str,
        grammar: tree_sitter_language::LanguageFn,
        highlights: &'static str,
        injections: Option<&'static str>,
    ) -> Self {
        Self {
            name,
            grammar: tree_sitter::Language::new(grammar),
            default_highlights: highlights,
            highlights: OnceLock::new(),
            default_injections: injections,
            shares: None,
        }
    }

    /// A grammar loaded at run time. It comes without queries; they're set
    /// like any other.
    fn loaded(name: &'static str, grammar: tree_sitter::Language) -> Self {
        Self {
            name,
            grammar,
            default_highlights: "",
            highlights: OnceLock::new(),
            default_injections: None,
            shares: None,
        }
    }

    /// Language `name` parsed with `other`'s grammar.
    fn sharing(name: &'static str, other: &Language) -> Self {
        Self {
            name,
            grammar: other.grammar.clone(),
            default_highlights: other.default_highlights,
            highlights: OnceLock::new(),
            default_injections: other.default_injections,
            shares: Some(other.shares.unwrap_or(other.name)),
        }
    }

    /// The grammar's own highlights query, compiled.
    #[allow(
        clippy::panic,
        reason = "only bundled queries are here, and tests compile each one"
    )]
    fn default_highlights(&self) -> &Highlights {
        self.highlights.get_or_init(|| {
            Query::new(&self.grammar, self.default_highlights).map_or_else(
                |err| panic!("bundled {} highlight query is broken: {err}", self.name),
                Highlights::from,
            )
        })
    }
}

/// The language of each file extension Greed knows.
pub(crate) const EXTENSIONS: &[(&str, &str)] = &[
    ("rs", "rust"),
    ("toml", "toml"),
    ("json", "json"),
    ("luau", "luau"),
    ("lua", "luau"),
    ("md", "markdown"),
    ("markdown", "markdown"),
    ("nix", "nix"),
    ("sh", "bash"),
    ("bash", "bash"),
    ("py", "python"),
    ("pyi", "python"),
    ("go", "go"),
    ("js", "javascript"),
    ("mjs", "javascript"),
    ("cjs", "javascript"),
    ("jsx", "javascript"),
    ("ts", "typescript"),
    ("mts", "typescript"),
    ("cts", "typescript"),
    ("tsx", "tsx"),
    ("c", "c"),
    ("h", "c"),
    ("yaml", "yaml"),
    ("yml", "yaml"),
];

/// The languages Greed has grammars for, sorted.
pub fn grammar_names() -> Vec<&'static str> {
    let mut names: Vec<&str> = EXTENSIONS.iter().map(|(_, name)| *name).collect();
    names.sort_unstable();
    names.dedup();
    names
}

/// The language of the file at `path`, going by its extension.
pub fn language_name(path: &Path) -> Option<&'static str> {
    let extension = path.extension()?.to_str()?;
    EXTENSIONS
        .iter()
        .find(|(e, _)| *e == extension)
        .map(|(_, name)| *name)
}

/// The languages Greed knows out of the box.
fn builtin() -> Vec<Arc<Language>> {
    [
        Language::new(
            "rust",
            tree_sitter_rust::LANGUAGE,
            tree_sitter_rust::HIGHLIGHTS_QUERY,
            Some(tree_sitter_rust::INJECTIONS_QUERY),
        ),
        Language::new(
            "toml",
            tree_sitter_toml_ng::LANGUAGE,
            tree_sitter_toml_ng::HIGHLIGHTS_QUERY,
            None,
        ),
        Language::new(
            "json",
            tree_sitter_json::LANGUAGE,
            tree_sitter_json::HIGHLIGHTS_QUERY,
            None,
        ),
        Language::new(
            "luau",
            tree_sitter_luau::LANGUAGE,
            tree_sitter_luau::HIGHLIGHTS_QUERY,
            Some(tree_sitter_luau::INJECTIONS_QUERY),
        ),
        Language::new(
            "markdown",
            tree_sitter_md::LANGUAGE,
            tree_sitter_md::HIGHLIGHT_QUERY_BLOCK,
            Some(tree_sitter_md::INJECTION_QUERY_BLOCK),
        ),
        Language::new(
            "nix",
            tree_sitter_nix::LANGUAGE,
            tree_sitter_nix::HIGHLIGHTS_QUERY,
            Some(tree_sitter_nix::INJECTIONS_QUERY),
        ),
        Language::new(
            "bash",
            tree_sitter_bash::LANGUAGE,
            tree_sitter_bash::HIGHLIGHT_QUERY,
            None,
        ),
        Language::new(
            "python",
            tree_sitter_python::LANGUAGE,
            tree_sitter_python::HIGHLIGHTS_QUERY,
            None,
        ),
        Language::new(
            "go",
            tree_sitter_go::LANGUAGE,
            tree_sitter_go::HIGHLIGHTS_QUERY,
            None,
        ),
        Language::new(
            "javascript",
            tree_sitter_javascript::LANGUAGE,
            tree_sitter_javascript::HIGHLIGHT_QUERY,
            Some(tree_sitter_javascript::INJECTIONS_QUERY),
        ),
        Language::new(
            "typescript",
            tree_sitter_typescript::LANGUAGE_TYPESCRIPT,
            tree_sitter_typescript::HIGHLIGHTS_QUERY,
            None,
        ),
        Language::new(
            "tsx",
            tree_sitter_typescript::LANGUAGE_TSX,
            tree_sitter_typescript::HIGHLIGHTS_QUERY,
            None,
        ),
        Language::new(
            "c",
            tree_sitter_c::LANGUAGE,
            tree_sitter_c::HIGHLIGHT_QUERY,
            None,
        ),
        Language::new(
            "yaml",
            tree_sitter_yaml::LANGUAGE,
            tree_sitter_yaml::HIGHLIGHTS_QUERY,
            None,
        ),
        // Markdown's text within blocks: emphasis, links, code spans. Only
        // ever injected, never a file's own language.
        Language::new(
            "markdown_inline",
            tree_sitter_md::INLINE_LANGUAGE,
            tree_sitter_md::HIGHLIGHT_QUERY_INLINE,
            Some(tree_sitter_md::INJECTION_QUERY_INLINE),
        ),
    ]
    .into_iter()
    .map(Arc::new)
    .collect()
}

/// Text in `range` to style as `capture`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Highlight {
    pub range: Range<usize>,
    pub capture: Arc<str>,
    /// From a language a mark asked for, which colours over the buffer's
    /// own, and where a mark leaves that out (`plain`) too.
    pub marked: bool,
}

struct Request {
    buffer: BufferId,
    version: usize,
    text: Rope,
    language: Arc<Language>,
    injections: Injections,
    marked: Marked,
    /// Runs loaded grammars, once one has been.
    engine: Option<Engine>,
}

/// A finished parse from the worker.
pub struct Parsed {
    buffer: BufferId,
    version: usize,
    tree: Tree,
    text: Rope,
    layers: Vec<Layer>,
}

struct BufferSyntax {
    language: Arc<Language>,
    /// The last version sent to the worker, with the ranges marks had
    /// highlighted as other languages then.
    sent: Option<(usize, Marked)>,
    /// The newest tree, to draw with and to parse the next version from.
    held: Option<Held>,
}

pub struct Syntax {
    languages: Vec<Arc<Language>>,
    requests: Sender<Request>,
    results: Receiver<Parsed>,
    buffers: HashMap<BufferId, BufferSyntax>,
    /// For trees wanted right away, when the worker's is behind.
    parser: Parser,
    /// How long a parse on the editor's thread may take before it gives up
    /// and the tree before, with the edits applied, stands in.
    pub in_time: Duration,
    /// Queries plugins ran, by language and source, compiled once.
    queries: HashMap<(&'static str, String), Arc<Query>>,
    /// Queries plugins set, by language and kind ("highlights",
    /// "textobjects", ...).
    sources: HashMap<(String, String), String>,
    /// Highlights queries plugins set, in place of the grammars' own.
    highlights: HashMap<&'static str, Highlights>,
    /// Highlights queries set for languages no buffer was in yet, compiled
    /// once one is.
    pending: HashMap<&'static str, String>,
    /// What went wrong compiling queries, to tell the user.
    problems: Vec<String>,
    /// Each language's injections query, for the worker.
    injections: Injections,
    /// Runs grammars loaded from WebAssembly files, like downloaded ones, and
    /// loads them. Made with the first one, since making it takes longer
    /// than all the rest of starting up.
    wasm: Option<(Engine, WasmStore)>,
    /// The languages added at run time: loaded that way, or sharing
    /// another's grammar.
    loaded: Vec<&'static str>,
    pub max_bytes: usize,
}

impl Default for Syntax {
    fn default() -> Self {
        Self::new()
    }
}

impl Syntax {
    /// Loads the built-in languages and starts the parsing worker.
    pub fn new() -> Self {
        let (requests, inbox) = crossbeam_channel::unbounded();
        let (outbox, results) = crossbeam_channel::unbounded();
        thread::spawn(move || parse_worker(&inbox, &outbox));
        let languages = builtin();
        let injections = default_injections(&languages);
        Self {
            languages,
            requests,
            results,
            buffers: HashMap::new(),
            parser: Parser::new(),
            in_time: IN_TIME,
            queries: HashMap::new(),
            sources: HashMap::new(),
            highlights: HashMap::new(),
            pending: HashMap::new(),
            problems: Vec::new(),
            injections,
            wasm: None,
            loaded: Vec::new(),
            max_bytes: MAX_BYTES,
        }
    }

    /// Loads the grammar for `language` from a WebAssembly file's `bytes`,
    /// like one built with `tree-sitter build --wasm`. `symbol` is the
    /// grammar's own name for itself (`tree_sitter_<symbol>` in the file),
    /// for when it differs from the language's, e.g. `c_sharp` for `c-sharp`.
    /// Queries set for the language before are used from now on, and
    /// buffers in it are parsed again.
    pub fn load_grammar(
        &mut self,
        language: &str,
        symbol: &str,
        bytes: &[u8],
    ) -> Result<(), String> {
        if self.wasm.is_none() {
            let engine = Engine::default();
            let loader = WasmStore::new(&engine).map_err(|err| err.to_string())?;
            let ours = WasmStore::new(&engine).map_err(|err| err.to_string())?;
            self.parser
                .set_wasm_store(ours)
                .map_err(|err| err.to_string())?;
            self.wasm = Some((engine, loader));
        }
        let (_, store) = self.wasm.as_mut().expect("just made");
        let grammar = store
            .load_language(symbol, bytes)
            .map_err(|err| err.to_string())?;
        let name = self.lasting_name(language);
        self.add(Language::loaded(name, grammar));
        Ok(())
    }

    /// Lets `language` use the grammar of `other`, like Starlark Python's.
    /// Its queries are `other`'s, except those set for it. Buffers in it are
    /// parsed again.
    pub fn share_grammar(&mut self, language: &str, other: &str) -> Result<(), String> {
        let other = self
            .language_named(other)
            .ok_or_else(|| format!("there's no grammar for {other}"))?;
        if other.name != language {
            let name = self.lasting_name(language);
            self.add(Language::sharing(name, &other));
        }
        Ok(())
    }

    /// `language` as a name that lives as long as the editor, like the
    /// built-in ones.
    fn lasting_name(&self, language: &str) -> &'static str {
        match self.languages.iter().find(|l| l.name == language) {
            Some(known) => known.name,
            None => Box::leak(language.into()),
        }
    }

    /// Adds a language at run time, in place of one of the same name.
    fn add(&mut self, language: Language) {
        let name = language.name;
        let language = Arc::new(language);
        self.languages.retain(|l| l.name != name);
        self.languages.push(language.clone());
        if !self.loaded.contains(&name) {
            self.loaded.push(name);
        }
        self.highlights.remove(name);
        if let Some(highlights) = self
            .sources
            .get(&(name.to_owned(), "highlights".to_owned()))
        {
            self.pending.insert(name, highlights.clone());
        }
        let query = InjectionQuery::lazy(self.query_source(name, "injections"));
        let mut injections = (*self.injections).clone();
        injections.insert(name, (language, Arc::new(query)));
        self.injections = Arc::new(injections);
        self.buffers.retain(|_, state| state.language.name != name);
    }

    /// Every language with a grammar: the built-in ones and those loaded,
    /// sorted.
    pub fn names(&self) -> Vec<&'static str> {
        let mut names = grammar_names();
        names.extend(&self.loaded);
        names.sort_unstable();
        names.dedup();
        names
    }

    /// Finished parses, to pass to [`Syntax::receive`].
    pub fn results(&self) -> &Receiver<Parsed> {
        &self.results
    }

    pub fn language_for(&self, path: &Path) -> Option<Arc<Language>> {
        self.language_named(language_name(path)?)
    }

    fn language_named(&self, name: &str) -> Option<Arc<Language>> {
        self.languages.iter().find(|l| l.name == name).cloned()
    }

    /// The syntax state for `buffer`, set up for its current language, or
    /// `None` if it has no language Greed knows or is too big to parse.
    fn state_for(&mut self, buffer: &Buffer) -> Option<&mut BufferSyntax> {
        let id = buffer.id();
        let Some(name) = buffer.language() else {
            self.buffers.remove(&id);
            return None;
        };
        if self
            .buffers
            .get(&id)
            .is_none_or(|s| s.language.name != name)
        {
            let Some(language) = self.language_named(name) else {
                self.buffers.remove(&id);
                return None;
            };
            self.buffers.insert(
                id,
                BufferSyntax {
                    language,
                    sent: None,
                    held: None,
                },
            );
        }
        let too_big = buffer.text().len_bytes() > self.max_bytes;
        let state = self.buffers.get_mut(&id).expect("just inserted");
        if too_big {
            state.held = None;
            return None;
        }
        Some(state)
    }

    /// Sends buffers that changed since their last parse to the worker,
    /// brings their trees up to their text in the meantime, and forgets
    /// closed ones.
    pub fn update(&mut self, editor: &Editor) {
        self.buffers
            .retain(|id, _| editor.find_buffer(*id).is_some());
        for buffer in editor.buffers() {
            let Some(state) = self.state_for(buffer) else {
                continue;
            };
            if let Some(held) = &mut state.held {
                held.follow(buffer);
            }
            let language = state.language.clone();
            self.prepare(&language);
            self.send(buffer);
        }
    }

    /// Sends `buffer` to the worker, unless its version was already.
    fn send(&mut self, buffer: &Buffer) {
        let version = buffer.history().applied();
        let Some(state) = self.buffers.get_mut(&buffer.id()) else {
            return;
        };
        let marked = buffer.marked_languages();
        if state
            .sent
            .as_ref()
            .is_some_and(|(sent, was)| *sent == version && *was == marked)
        {
            return;
        }
        state.sent = Some((version, marked.clone()));
        let _ = self.requests.send(Request {
            buffer: buffer.id(),
            version,
            text: buffer.text().clone(),
            language: state.language.clone(),
            injections: self.injections.clone(),
            marked,
            engine: self.wasm.as_ref().map(|(engine, _)| engine.clone()),
        });
    }

    /// Compiles the highlights query set for `language`, now that a buffer
    /// needs it. One that doesn't compile is reported, and the grammar's own
    /// is used instead. The one set for the language it shares a grammar
    /// with compiles too, since it's used when it has none of its own.
    fn prepare(&mut self, language: &Language) {
        for name in [Some(language.name), language.shares].into_iter().flatten() {
            let Some(source) = self.pending.remove(name) else {
                continue;
            };
            match Query::new(&language.grammar, &source) {
                Ok(query) => {
                    self.highlights.insert(name, Highlights::from(query));
                }
                Err(err) => self
                    .problems
                    .push(format!("the {name} highlights query: {err}")),
            }
        }
    }

    /// What went wrong compiling queries since the last call, one line
    /// each.
    pub fn take_problems(&mut self) -> Vec<String> {
        std::mem::take(&mut self.problems)
    }

    /// Keeps a finished parse unless what we have was parsed from a newer
    /// version. One of the same version is a parse again, after the
    /// injections changed. One older than the text is brought up to it by
    /// the next [`Syntax::update`].
    pub fn receive(&mut self, parsed: Parsed) {
        for layer in &parsed.layers {
            self.prepare(&layer.language);
        }
        if let Some(state) = self.buffers.get_mut(&parsed.buffer)
            && state
                .held
                .as_ref()
                .is_none_or(|held| held.parsed <= parsed.version)
        {
            state.held = Some(Held::new(
                parsed.version,
                parsed.text,
                parsed.tree,
                parsed.layers,
            ));
        }
    }

    /// The syntax tree of `buffer` as its text is now, and its language.
    /// When the worker hasn't caught up with the latest edit, the buffer is
    /// parsed here and then, from the tree before the edit, so only what
    /// changed is parsed again. A parse that would hold up the key that
    /// asked for it (in code tree-sitter has to recover from) gives up, and
    /// the tree before, told about the edits, stands in until the worker
    /// brings the new one. `None` if it has no language Greed knows or is
    /// too big to parse.
    pub fn tree(&mut self, buffer: &Buffer) -> Option<(Arc<Language>, Tree)> {
        let version = buffer.history().applied();
        let state = self.state_for(buffer)?;
        let language = state.language.clone();
        let before = state.held.as_mut().map(|held| {
            held.follow(buffer);
            (held.parsed == version, held.tree.clone())
        });
        let edited = match before {
            Some((true, tree)) => return Some((language, tree)),
            Some((false, edited)) => Some(edited),
            None => None,
        };
        self.parser.set_language(&language.grammar).ok()?;
        let parsed = match &edited {
            Some(edited) => {
                let deadline = Some(Instant::now() + self.in_time);
                parse_from(&mut self.parser, buffer.text(), Some(edited), deadline)
            }
            None => parse(&mut self.parser, buffer.text()),
        };
        let state = self.buffers.get_mut(&buffer.id())?;
        match (parsed, &mut state.held) {
            // The layers stay as they were edited; the worker brings new
            // ones.
            (Some(tree), Some(held)) => {
                held.tree = tree.clone();
                held.parsed = version;
                Some((language, tree))
            }
            (Some(tree), None) => {
                let held = Held::new(version, buffer.text().clone(), tree.clone(), Vec::new());
                state.held = Some(held);
                Some((language, tree))
            }
            (None, Some(held)) => {
                let tree = held.tree.clone();
                self.send(buffer);
                Some((language, tree))
            }
            (None, None) => None,
        }
    }

    /// `source` compiled as a query for `language`. Compiled queries are
    /// kept, so running one again is cheap.
    pub fn query(&mut self, language: &Language, source: &str) -> Result<Arc<Query>, String> {
        let key = (language.name, source.to_owned());
        if let Some(query) = self.queries.get(&key) {
            return Ok(query.clone());
        }
        let query = Arc::new(Query::new(&language.grammar, source).map_err(|e| e.to_string())?);
        self.queries.insert(key, query.clone());
        Ok(query)
    }

    /// Sets the query of `kind` for `language`, or with `None` goes back to
    /// none (for highlights and injections, the grammar's own). "highlights"
    /// and "injections" are used for highlighting; any other kind is kept
    /// for plugins to read with [`Syntax::query_source`]. For a language
    /// Greed has a grammar for, the query is checked against it first, and an
    /// error says what's wrong.
    pub fn set_query(
        &mut self,
        language: &str,
        kind: &str,
        source: Option<String>,
    ) -> Result<(), String> {
        let key = (language.to_owned(), kind.to_owned());
        if self.sources.get(&key) == source.as_ref() {
            return Ok(());
        }
        if let Some(grammar) = self.language_named(language) {
            // A query for a language a buffer is in is checked now, and kept
            // compiled. Any other waits until a buffer needs it, so starting
            // doesn't compile every query there is.
            let in_use = self
                .buffers
                .values()
                .any(|s| s.language.name == grammar.name);
            let compiled = source
                .as_deref()
                .filter(|_| in_use)
                .map(|s| Query::new(&grammar.grammar, s).map_err(|err| err.to_string()))
                .transpose()?;
            match kind {
                "highlights" => {
                    self.highlights.remove(grammar.name);
                    self.pending.remove(grammar.name);
                    if let Some(query) = compiled {
                        self.highlights
                            .insert(grammar.name, Highlights::from(query));
                    } else if let Some(source) = &source {
                        self.pending.insert(grammar.name, source.clone());
                    }
                }
                "injections" => {
                    let query = match compiled {
                        Some(query) => InjectionQuery::compiled(query),
                        None => InjectionQuery::lazy(
                            source
                                .clone()
                                .or_else(|| grammar.default_injections.map(str::to_owned)),
                        ),
                    };
                    let query = Arc::new(query);
                    let mut injections = (*self.injections).clone();
                    injections.insert(grammar.name, (grammar.clone(), query.clone()));
                    // And of the languages sharing its grammar that have
                    // none of their own.
                    for sharing in &self.languages {
                        if sharing.shares == Some(grammar.name)
                            && !self
                                .sources
                                .contains_key(&(sharing.name.to_owned(), kind.to_owned()))
                        {
                            injections.insert(sharing.name, (sharing.clone(), query.clone()));
                        }
                    }
                    self.injections = Arc::new(injections);
                    // Parse everything again, to find the languages inside anew.
                    for state in self.buffers.values_mut() {
                        state.sent = None;
                    }
                }
                _ => {
                    if let (Some(query), Some(source)) = (compiled, &source) {
                        self.queries
                            .insert((grammar.name, source.clone()), Arc::new(query));
                    }
                }
            }
        }
        match source {
            Some(source) => self.sources.insert(key, source),
            None => self.sources.remove(&key),
        };
        Ok(())
    }

    /// The query of `kind` for `language` that's in use: the one a plugin
    /// set, the one set for the language it shares a grammar with, or for
    /// highlights and injections the grammar's own.
    pub fn query_source(&self, language: &str, kind: &str) -> Option<String> {
        if let Some(source) = self.sources.get(&(language.to_owned(), kind.to_owned())) {
            return Some(source.clone());
        }
        let grammar = self.language_named(language)?;
        if let Some(source) = grammar
            .shares
            .and_then(|other| self.sources.get(&(other.to_owned(), kind.to_owned())))
        {
            return Some(source.clone());
        }
        match kind {
            "highlights" => Some(grammar.default_highlights.to_owned()),
            "injections" => grammar.default_injections.map(str::to_owned),
            _ => None,
        }
    }

    /// Highlights overlapping `range` of `buffer`, whose text is `text`.
    /// Languages inside it come after the buffer's own, so they draw over it.
    pub fn highlights(&self, buffer: BufferId, text: &Rope, range: Range<usize>) -> Vec<Highlight> {
        let Some(BufferSyntax {
            language,
            held: Some(held),
            ..
        }) = self.buffers.get(&buffer)
        else {
            return Vec::new();
        };
        let mut found = Vec::new();
        self.highlight(language, &held.tree, text, &range, false, &mut found);
        for layer in &held.layers {
            let (language, tree) = (&layer.language, &layer.tree);
            self.highlight(language, tree, text, &range, layer.marked, &mut found);
        }
        found
    }

    /// Adds the highlights in `range` of `tree`, a parse as `language`.
    fn highlight(
        &self,
        language: &Language,
        tree: &Tree,
        text: &Rope,
        range: &Range<usize>,
        marked: bool,
        found: &mut Vec<Highlight>,
    ) {
        let highlights = self
            .highlights
            .get(language.name)
            .or_else(|| language.shares.and_then(|other| self.highlights.get(other)))
            .unwrap_or_else(|| language.default_highlights());
        let mut cursor = QueryCursor::new();
        cursor.set_byte_range(range.clone());
        let mut captures = cursor.captures(&highlights.query, tree.root_node(), RopeText(text));
        while let Some((m, i)) = captures.next() {
            let capture = m.captures()[*i];
            let name = &highlights.captures[capture.index as usize];
            // Captures like `@_name` are only there for a predicate.
            if name.starts_with('_') {
                continue;
            }
            found.push(Highlight {
                range: capture.node.byte_range(),
                capture: name.clone(),
                marked,
            });
        }
    }
}

/// Parses requests as they come, skipping versions that are already stale.
fn parse_worker(inbox: &Receiver<Request>, outbox: &Sender<Parsed>) {
    let mut parser = Parser::new();
    // Whether the parser can run loaded grammars, which it gets a store of
    // its own for with the first request after one was loaded.
    let mut can_run_loaded = false;
    // Each buffer's last tree, with its language and text, to parse the
    // next version from.
    let mut last: HashMap<BufferId, (&'static str, Tree, Rope)> = HashMap::new();
    while let Ok(first) = inbox.recv() {
        let mut latest: HashMap<BufferId, Request> = HashMap::new();
        for request in std::iter::once(first).chain(inbox.try_iter()) {
            latest.insert(request.buffer, request);
        }
        for request in latest.into_values() {
            if let Some(engine) = &request.engine
                && !can_run_loaded
                && let Ok(store) = WasmStore::new(engine)
            {
                can_run_loaded = parser.set_wasm_store(store).is_ok();
            }
            if parser.set_language(&request.language.grammar).is_err() {
                continue;
            }
            let tree = match last.get(&request.buffer) {
                Some((language, old, old_text)) if *language == request.language.name => {
                    incremental::reparse(&mut parser, old, old_text, &request.text, None)
                }
                _ => parse(&mut parser, &request.text),
            };
            let Some(tree) = tree else {
                continue;
            };
            // Closed buffers' trees aren't wanted again; letting them all go
            // now and then costs a whole parse of each open one.
            if last.len() >= 64 {
                last.clear();
            }
            last.insert(
                request.buffer,
                (request.language.name, tree.clone(), request.text.clone()),
            );
            let layers = injections::layers(
                &mut parser,
                &request.text,
                &request.language,
                &tree,
                &request.injections,
                &request.marked,
            );
            let parsed = Parsed {
                buffer: request.buffer,
                version: request.version,
                tree,
                text: request.text,
                layers,
            };
            if outbox.send(parsed).is_err() {
                return;
            }
        }
    }
}

/// Parses `text` from scratch with the parser's language.
fn parse(parser: &mut Parser, text: &Rope) -> Option<Tree> {
    parse_from(parser, text, None, None)
}

/// Parses `text` with the parser's language, reusing `old` (already told
/// about the edits since) where the text didn't change. With a `deadline`,
/// gives up at it and returns `None`.
fn parse_from(
    parser: &mut Parser,
    text: &Rope,
    old: Option<&Tree>,
    deadline: Option<Instant>,
) -> Option<Tree> {
    let mut in_time = |_: &tree_sitter::ParseState| match deadline {
        Some(deadline) if Instant::now() > deadline => ControlFlow::Break(()),
        _ => ControlFlow::Continue(()),
    };
    let tree = parser.parse_with_options(
        &mut |byte, _| {
            let (chunk, start, _, _) = text.chunk_at_byte(byte);
            &chunk.as_bytes()[byte - start..]
        },
        old,
        Some(ParseOptions::new().progress_callback(&mut in_time)),
    );
    if tree.is_none() {
        // Otherwise the next parse would carry on with this one's text.
        parser.reset();
    }
    tree
}

/// Lets queries read node text straight from a rope.
pub(crate) struct RopeText<'a>(pub &'a Rope);

impl<'a> TextProvider<&'a [u8]> for RopeText<'a> {
    type I = std::iter::Map<ropey::iter::Chunks<'a>, fn(&'a str) -> &'a [u8]>;

    fn text(&mut self, node: Node) -> Self::I {
        let len = self.0.len_bytes();
        let range = node.start_byte().min(len)..node.end_byte().min(len);
        self.0.byte_slice(range).chunks().map(str::as_bytes)
    }
}

/// Each language with its grammar's own injections query, compiled when
/// first needed.
fn default_injections(languages: &[Arc<Language>]) -> Injections {
    let map = languages.iter().map(|language| {
        let query = InjectionQuery::lazy(language.default_injections.map(str::to_owned));
        (language.name, (language.clone(), Arc::new(query)))
    });
    Arc::new(map.collect())
}
