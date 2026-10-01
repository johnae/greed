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

use crate::{BufferId, Editor};

/// Buffers larger than this aren't parsed, so huge files stay responsive.
pub const MAX_BYTES: usize = 4 * 1024 * 1024;

/// A grammar and the query that picks out what to highlight.
pub struct Language {
    pub name: &'static str,
    grammar: tree_sitter::Language,
    highlights: Query,
    /// The query's capture names, e.g. "keyword" or "function.macro".
    captures: Vec<Arc<str>>,
}

impl Language {
    fn new(
        name: &'static str,
        grammar: tree_sitter_language::LanguageFn,
        highlights: &str,
    ) -> Self {
        let grammar = tree_sitter::Language::new(grammar);
        let highlights = Query::new(&grammar, highlights)
            .unwrap_or_else(|err| panic!("bundled {name} highlight query is broken: {err}"));
        let captures = highlights
            .capture_names()
            .iter()
            .map(|&c| c.into())
            .collect();
        Self {
            name,
            grammar,
            highlights,
            captures,
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
        ),
        Language::new(
            "toml",
            tree_sitter_toml_ng::LANGUAGE,
            tree_sitter_toml_ng::HIGHLIGHTS_QUERY,
        ),
        Language::new(
            "json",
            tree_sitter_json::LANGUAGE,
            tree_sitter_json::HIGHLIGHTS_QUERY,
        ),
        Language::new(
            "luau",
            tree_sitter_luau::LANGUAGE,
            tree_sitter_luau::HIGHLIGHTS_QUERY,
        ),
        Language::new(
            "markdown",
            tree_sitter_md::LANGUAGE,
            tree_sitter_md::HIGHLIGHT_QUERY_BLOCK,
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
}

/// A finished parse from the worker.
pub struct Parsed {
    buffer: BufferId,
    version: usize,
    tree: Tree,
}

struct BufferSyntax {
    language: Arc<Language>,
    /// The last version sent to the worker.
    sent: Option<usize>,
    /// The newest tree, and the version it was parsed from.
    tree: Option<(usize, Tree)>,
}

pub struct Syntax {
    languages: Vec<Arc<Language>>,
    requests: Sender<Request>,
    results: Receiver<Parsed>,
    buffers: HashMap<BufferId, BufferSyntax>,
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
        Self {
            languages: builtin(),
            requests,
            results,
            buffers: HashMap::new(),
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

    /// Sends buffers that changed since their last parse to the worker.
    pub fn update(&mut self, editor: &Editor) {
        for buffer in editor.buffers() {
            let id = buffer.id();
            let Some(name) = buffer.language() else {
                self.buffers.remove(&id);
                continue;
            };
            if self
                .buffers
                .get(&id)
                .is_none_or(|s| s.language.name != name)
            {
                let Some(language) = self.language_named(name) else {
                    self.buffers.remove(&id);
                    continue;
                };
                self.buffers.insert(
                    id,
                    BufferSyntax {
                        language,
                        sent: None,
                        tree: None,
                    },
                );
            }
            let state = self.buffers.get_mut(&id).expect("just inserted");
            if buffer.text().len_bytes() > self.max_bytes {
                state.tree = None;
                continue;
            }
            let version = buffer.history().log().len();
            if state.sent != Some(version) {
                state.sent = Some(version);
                let _ = self.requests.send(Request {
                    buffer: id,
                    version,
                    text: buffer.text().clone(),
                    language: state.language.clone(),
                });
            }
        }
    }

    /// Keeps a finished parse if it's newer than what we have.
    pub fn receive(&mut self, parsed: Parsed) {
        if let Some(state) = self.buffers.get_mut(&parsed.buffer)
            && state.tree.as_ref().is_none_or(|(v, _)| *v < parsed.version)
        {
            state.tree = Some((parsed.version, parsed.tree));
        }
    }

    /// Highlights overlapping `range` of `buffer`, whose text is `text`.
    pub fn highlights(&self, buffer: BufferId, text: &Rope, range: Range<usize>) -> Vec<Highlight> {
        let Some(BufferSyntax {
            language,
            tree: Some((_, tree)),
            ..
        }) = self.buffers.get(&buffer)
        else {
            return Vec::new();
        };
        let mut cursor = QueryCursor::new();
        cursor.set_byte_range(range);
        cursor
            .captures(&language.highlights, tree.root_node(), RopeText(text))
            .map_deref(|(m, i)| {
                let capture = m.captures()[*i];
                Highlight {
                    range: capture.node.byte_range(),
                    capture: language.captures[capture.index as usize].clone(),
                }
            })
            .collect()
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
            let text = &request.text;
            let tree = parser.parse_with_options(
                &mut |byte, _| {
                    let (chunk, start, _, _) = text.chunk_at_byte(byte);
                    &chunk.as_bytes()[byte - start..]
                },
                None,
                None,
            );
            let Some(tree) = tree else { continue };
            let parsed = Parsed {
                buffer: request.buffer,
                version: request.version,
                tree,
            };
            if outbox.send(parsed).is_err() {
                return;
            }
        }
    }
}

/// Lets queries read node text straight from a rope.
struct RopeText<'a>(&'a Rope);

impl<'a> TextProvider<&'a [u8]> for RopeText<'a> {
    type I = std::iter::Map<ropey::iter::Chunks<'a>, fn(&'a str) -> &'a [u8]>;

    fn text(&mut self, node: Node) -> Self::I {
        let len = self.0.len_bytes();
        let range = node.start_byte().min(len)..node.end_byte().min(len);
        self.0.byte_slice(range).chunks().map(str::as_bytes)
    }
}
