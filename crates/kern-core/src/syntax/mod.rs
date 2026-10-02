//! Syntax highlighting with tree-sitter.
//!
//! Buffers are parsed on a worker thread, which always works on the latest
//! text it has been sent. The server keeps the newest tree for each buffer
//! and queries it for just the visible range when rendering. While the
//! worker catches up after an edit, the tree can be one version behind.

use std::collections::HashMap;
use std::ops::Range;
use std::path::Path;
use std::sync::Arc;
use std::thread;

use crossbeam_channel::{Receiver, Sender};
use kern_text::Rope;
use streaming_iterator::StreamingIterator;
use tree_sitter::{Node, Parser, Query, QueryCursor, TextProvider, Tree};

use crate::{Buffer, BufferId, Editor};
use injections::{Injections, Layer};

mod injections;

/// Buffers larger than this aren't parsed, so huge files stay responsive.
pub const MAX_BYTES: usize = 4 * 1024 * 1024;

/// A query that picks out what to highlight, and its capture names, e.g.
/// "keyword" or "function.macro".
struct Highlights {
    query: Query,
    captures: Vec<Arc<str>>,
}

impl Highlights {
    fn new(grammar: &tree_sitter::Language, source: &str) -> Result<Self, String> {
        let query = Query::new(grammar, source).map_err(|err| err.to_string())?;
        let captures = query.capture_names().iter().map(|&c| c.into()).collect();
        Ok(Self { query, captures })
    }
}

/// A grammar and the queries that come with it.
pub struct Language {
    pub name: &'static str,
    grammar: tree_sitter::Language,
    /// The grammar's own highlights query, used until a plugin sets one.
    default_highlights: &'static str,
    highlights: Highlights,
    /// The grammar's own injections query, if it has one.
    default_injections: Option<&'static str>,
}

impl Language {
    fn new(
        name: &'static str,
        grammar: tree_sitter_language::LanguageFn,
        highlights: &'static str,
        injections: Option<&'static str>,
    ) -> Self {
        let grammar = tree_sitter::Language::new(grammar);
        let compiled = Highlights::new(&grammar, highlights)
            .unwrap_or_else(|err| panic!("bundled {name} highlight query is broken: {err}"));
        Self {
            name,
            grammar,
            default_highlights: highlights,
            highlights: compiled,
            default_injections: injections,
        }
    }
}

/// The language of each file extension Kern knows.
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
];

/// The languages Kern has grammars for, sorted.
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

/// The languages Kern knows out of the box.
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
}

struct Request {
    buffer: BufferId,
    version: usize,
    text: Rope,
    language: Arc<Language>,
    injections: Injections,
}

/// A finished parse from the worker.
pub struct Parsed {
    buffer: BufferId,
    version: usize,
    tree: Tree,
    layers: Vec<Layer>,
}

struct BufferSyntax {
    language: Arc<Language>,
    /// The last version sent to the worker.
    sent: Option<usize>,
    /// The newest tree, and the version it was parsed from.
    tree: Option<(usize, Tree)>,
    /// The languages inside it, from the same parse.
    layers: Vec<Layer>,
}

pub struct Syntax {
    languages: Vec<Arc<Language>>,
    requests: Sender<Request>,
    results: Receiver<Parsed>,
    buffers: HashMap<BufferId, BufferSyntax>,
    /// For trees wanted right away, when the worker's is behind.
    parser: Parser,
    /// Queries plugins ran, by language and source, compiled once.
    queries: HashMap<(&'static str, String), Arc<Query>>,
    /// Queries plugins set, by language and kind ("highlights",
    /// "textobjects", ...).
    sources: HashMap<(String, String), String>,
    /// Highlights queries plugins set, in place of the grammars' own.
    highlights: HashMap<&'static str, Highlights>,
    /// Each language's injections query, for the worker.
    injections: Injections,
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
        let injections = injections_of(&languages, &HashMap::new());
        Self {
            languages,
            requests,
            results,
            buffers: HashMap::new(),
            parser: Parser::new(),
            queries: HashMap::new(),
            sources: HashMap::new(),
            highlights: HashMap::new(),
            injections,
            max_bytes: MAX_BYTES,
        }
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
    /// `None` if it has no language Kern knows or is too big to parse.
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
                    tree: None,
                    layers: Vec::new(),
                },
            );
        }
        let too_big = buffer.text().len_bytes() > self.max_bytes;
        let state = self.buffers.get_mut(&id).expect("just inserted");
        if too_big {
            state.tree = None;
            state.layers.clear();
            return None;
        }
        Some(state)
    }

    /// Sends buffers that changed since their last parse to the worker, and
    /// forgets closed ones.
    pub fn update(&mut self, editor: &Editor) {
        self.buffers
            .retain(|id, _| editor.find_buffer(*id).is_some());
        for buffer in editor.buffers() {
            let version = buffer.history().log().len();
            let Some(state) = self.state_for(buffer) else {
                continue;
            };
            if state.sent != Some(version) {
                state.sent = Some(version);
                let language = state.language.clone();
                let _ = self.requests.send(Request {
                    buffer: buffer.id(),
                    version,
                    text: buffer.text().clone(),
                    language,
                    injections: self.injections.clone(),
                });
            }
        }
    }

    /// Keeps a finished parse unless what we have is newer. One of the same
    /// version is a parse again, after the injections changed.
    pub fn receive(&mut self, parsed: Parsed) {
        if let Some(state) = self.buffers.get_mut(&parsed.buffer)
            && state
                .tree
                .as_ref()
                .is_none_or(|(v, _)| *v <= parsed.version)
        {
            state.tree = Some((parsed.version, parsed.tree));
            state.layers = parsed.layers;
        }
    }

    /// The syntax tree of `buffer` as its text is now, and its language.
    /// When the worker hasn't caught up with the latest edit, the buffer is
    /// parsed here and then. `None` if it has no language Kern knows or is
    /// too big to parse.
    pub fn tree(&mut self, buffer: &Buffer) -> Option<(Arc<Language>, Tree)> {
        let version = buffer.history().log().len();
        let state = self.state_for(buffer)?;
        if let Some((v, tree)) = &state.tree
            && *v == version
        {
            return Some((state.language.clone(), tree.clone()));
        }
        let language = state.language.clone();
        self.parser.set_language(&language.grammar).ok()?;
        let tree = parse(&mut self.parser, buffer.text())?;
        let state = self.buffers.get_mut(&buffer.id())?;
        state.tree = Some((version, tree.clone()));
        // The layers were for the text before; the worker brings new ones.
        state.layers.clear();
        Some((language, tree))
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
    /// Kern has a grammar for, the query is checked against it first, and an
    /// error says what's wrong.
    pub fn set_query(
        &mut self,
        language: &str,
        kind: &str,
        source: Option<String>,
    ) -> Result<(), String> {
        if let Some(grammar) = self.language_named(language) {
            let compiled = source
                .as_deref()
                .map(|s| Highlights::new(&grammar.grammar, s))
                .transpose()?;
            if kind == "highlights" {
                match compiled {
                    Some(compiled) => self.highlights.insert(grammar.name, compiled),
                    None => self.highlights.remove(grammar.name),
                };
            }
        }
        let key = (language.to_owned(), kind.to_owned());
        match source {
            Some(source) => self.sources.insert(key, source),
            None => self.sources.remove(&key),
        };
        if kind == "injections" {
            self.injections = injections_of(&self.languages, &self.sources);
            // Parse everything again, to find the languages inside anew.
            for state in self.buffers.values_mut() {
                state.sent = None;
            }
        }
        Ok(())
    }

    /// The query of `kind` for `language` that's in use: the one a plugin
    /// set, or for highlights and injections the grammar's own.
    pub fn query_source(&self, language: &str, kind: &str) -> Option<String> {
        if let Some(source) = self.sources.get(&(language.to_owned(), kind.to_owned())) {
            return Some(source.clone());
        }
        let grammar = self.language_named(language)?;
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
            tree: Some((_, tree)),
            layers,
            ..
        }) = self.buffers.get(&buffer)
        else {
            return Vec::new();
        };
        let mut found = Vec::new();
        self.highlight(language, tree, text, &range, &mut found);
        for layer in layers {
            self.highlight(&layer.language, &layer.tree, text, &range, &mut found);
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
        found: &mut Vec<Highlight>,
    ) {
        let highlights = self
            .highlights
            .get(language.name)
            .unwrap_or(&language.highlights);
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
            });
        }
    }
}

/// Parses requests as they come, skipping versions that are already stale.
fn parse_worker(inbox: &Receiver<Request>, outbox: &Sender<Parsed>) {
    let mut parser = Parser::new();
    while let Ok(first) = inbox.recv() {
        let mut latest: HashMap<BufferId, Request> = HashMap::new();
        for request in std::iter::once(first).chain(inbox.try_iter()) {
            latest.insert(request.buffer, request);
        }
        for request in latest.into_values() {
            if parser.set_language(&request.language.grammar).is_err() {
                continue;
            }
            let Some(tree) = parse(&mut parser, &request.text) else {
                continue;
            };
            let layers = injections::layers(
                &mut parser,
                &request.text,
                &request.language,
                &tree,
                &request.injections,
            );
            let parsed = Parsed {
                buffer: request.buffer,
                version: request.version,
                tree,
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
    parser.parse_with_options(
        &mut |byte, _| {
            let (chunk, start, _, _) = text.chunk_at_byte(byte);
            &chunk.as_bytes()[byte - start..]
        },
        None,
        None,
    )
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

/// Each language with the injections query it uses: the one a plugin set,
/// or the grammar's own.
fn injections_of(
    languages: &[Arc<Language>],
    sources: &HashMap<(String, String), String>,
) -> Injections {
    let map = languages.iter().map(|language| {
        let key = (language.name.to_owned(), "injections".to_owned());
        let source = sources
            .get(&key)
            .map(String::as_str)
            .or(language.default_injections);
        let query = source
            .and_then(|s| Query::new(&language.grammar, s).ok())
            .map(Arc::new);
        (language.name, (language.clone(), query))
    });
    Arc::new(map.collect())
}
