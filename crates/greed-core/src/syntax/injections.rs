//! Languages inside other languages: code blocks in Markdown, Markdown's
//! inline text, macro bodies in Rust. A language's "injections" query
//! captures the text to parse as another language (`@injection.content`)
//! and says which, by a captured name (`@injection.language`) or a setting
//! (`#set! injection.language "rust"`). Each piece is parsed on its own as
//! a layer over the buffer's tree, and layers can hold layers of their own.

use std::collections::HashMap;
use std::ops::Range;
use std::sync::{Arc, OnceLock};

use greed_text::Rope;
use streaming_iterator::StreamingIterator;
use tree_sitter::{Node, Parser, Query, QueryCursor, Tree};

use super::{EXTENSIONS, Language, RopeText};

/// How deep layers go: a code block in Markdown inline text in Markdown is
/// three.
const MAX_DEPTH: usize = 4;

/// At most this many layers per buffer, so a file of a thousand code blocks
/// can't hold the worker up.
const MAX_LAYERS: usize = 2000;

/// Every language, with the injections query it uses.
pub type Injections = Arc<HashMap<&'static str, (Arc<Language>, Arc<InjectionQuery>)>>;

/// A language's injections query, compiled the first time a buffer needs
/// it (or when it's set, if one did already).
pub struct InjectionQuery {
    source: Option<String>,
    compiled: OnceLock<Option<Query>>,
}

impl InjectionQuery {
    pub fn lazy(source: Option<String>) -> Self {
        Self {
            source,
            compiled: OnceLock::new(),
        }
    }

    pub fn compiled(query: Query) -> Self {
        Self {
            source: None,
            compiled: OnceLock::from(Some(query)),
        }
    }

    fn get(&self, language: &Language) -> Option<&Query> {
        self.compiled
            .get_or_init(|| {
                let source = self.source.as_deref()?;
                Query::new(&language.grammar, source).ok()
            })
            .as_ref()
    }
}

/// A piece of the buffer parsed as another language.
pub struct Layer {
    pub language: Arc<Language>,
    pub tree: Tree,
    /// Whether a mark asked for it (or for the one it's in), so it
    /// colours over the buffer's own language, even where that's left out.
    pub marked: bool,
}

/// The language a code block, setting or comment names: a language's own
/// name, or a file extension, like "rs" or "lua". A comment's markers don't
/// count, so `/* lua */` and `# bash` name Lua and Bash.
fn find<'a>(injections: &'a Injections, name: &str) -> Option<&'a Arc<Language>> {
    let markers = ['#', '/', '*', '-', ';', ' ', '\t'];
    let name = name.trim_matches(markers).to_ascii_lowercase();
    let name = EXTENSIONS
        .iter()
        .find(|(extension, _)| *extension == name)
        .map_or(name.as_str(), |(_, language)| language);
    injections.get(name).map(|(language, _)| language)
}

/// `node`'s text, without its named children unless `include_children`.
/// Unnamed ones (punctuation the outer grammar split out, like the `*` of
/// emphasis inside Markdown's inline text) stay, since they're part of the
/// inner language's text.
fn content_ranges(node: Node, include_children: bool) -> Vec<tree_sitter::Range> {
    if include_children {
        return vec![node.range()];
    }
    let mut ranges = Vec::new();
    let mut push = |start_byte, start_point, end_byte, end_point| {
        if end_byte > start_byte {
            ranges.push(tree_sitter::Range {
                start_byte,
                end_byte,
                start_point,
                end_point,
            });
        }
    };
    let (mut byte, mut point) = (node.start_byte(), node.start_position());
    let mut cursor = node.walk();
    for child in node.named_children(&mut cursor) {
        push(byte, point, child.start_byte(), child.start_position());
        (byte, point) = (child.end_byte(), child.end_position());
    }
    push(byte, point, node.end_byte(), node.end_position());
    ranges
}

/// What one match of an injections query asks for.
struct Injection<'t> {
    language: String,
    content: Node<'t>,
    include_children: bool,
    /// Parsed together with the other matches of the same pattern, like the
    /// pieces of a Nix string around its `${...}`s.
    combined: bool,
}

/// The injection `m` asks for, if it names both a language and the text to
/// parse as it.
fn injection<'t>(
    query: &Query,
    m: &tree_sitter::QueryMatch<'_, 't>,
    text: &Rope,
) -> Option<Injection<'t>> {
    let names = query.capture_names();
    let mut language = None;
    let mut content = None;
    for capture in m.captures() {
        match names[capture.index as usize] {
            "injection.content" => content = Some(capture.node),
            "injection.language" => {
                let range = capture.node.byte_range();
                language = Some(text.byte_slice(range).to_string());
            }
            _ => {}
        }
    }
    let (mut include_children, mut combined) = (false, false);
    for property in query.property_settings(m.pattern_index) {
        match (&*property.key, &property.value) {
            ("injection.language", Some(value)) => language = Some(value.to_string()),
            ("injection.include-children", _) => include_children = true,
            ("injection.combined", _) => combined = true,
            _ => {}
        }
    }
    Some(Injection {
        language: language?,
        content: content?,
        include_children,
        combined,
    })
}

/// Ranges of a buffer its marks highlight as another language, with the
/// language's name or extension.
pub type Marked = Vec<(Arc<str>, Range<usize>)>;

/// The layers inside `tree`, a parse of `text` as `language`, then those
/// `marked` asks for, each with the layers inside it. The marked ones come
/// last, so they draw over the rest.
pub fn layers(
    parser: &mut Parser,
    text: &Rope,
    language: &Language,
    tree: &Tree,
    injections: &Injections,
    marked: &Marked,
) -> Vec<Layer> {
    let mut found = Vec::new();
    inject(parser, text, language, tree, injections, 0, &mut found);
    let unmarked = found.len();
    let len = text.len_bytes();
    for (name, range) in marked {
        let Some(inner) = find(injections, name) else {
            continue;
        };
        let range = range.start.min(len)..range.end.min(len);
        if range.is_empty() {
            continue;
        }
        let ranges = [tree_sitter::Range {
            start_byte: range.start,
            end_byte: range.end,
            start_point: point(text, range.start),
            end_point: point(text, range.end),
        }];
        parse_layer(
            parser,
            text,
            inner.clone(),
            &ranges,
            injections,
            0,
            &mut found,
        );
    }
    for layer in &mut found[unmarked..] {
        layer.marked = true;
    }
    found
}

/// Where `byte` is in `text` as tree-sitter counts: its row, and its column
/// in bytes.
fn point(text: &Rope, byte: usize) -> tree_sitter::Point {
    let row = text.byte_to_line(byte);
    tree_sitter::Point::new(row, byte - text.line_to_byte(row))
}

/// Parses `ranges` of `text` as `inner`, adding the layer to `found` after
/// the layers inside it, unless there are enough already.
fn parse_layer(
    parser: &mut Parser,
    text: &Rope,
    inner: Arc<Language>,
    ranges: &[tree_sitter::Range],
    injections: &Injections,
    depth: usize,
    found: &mut Vec<Layer>,
) {
    if found.len() >= MAX_LAYERS
        || ranges.is_empty()
        || parser.set_language(&inner.grammar).is_err()
        || parser.set_included_ranges(ranges).is_err()
    {
        return;
    }
    let parsed = super::parse(parser, text);
    let _ = parser.set_included_ranges(&[]);
    let Some(parsed) = parsed else { return };
    inject(parser, text, &inner, &parsed, injections, depth + 1, found);
    found.push(Layer {
        language: inner,
        tree: parsed,
        marked: false,
    });
}

fn inject(
    parser: &mut Parser,
    text: &Rope,
    language: &Language,
    tree: &Tree,
    injections: &Injections,
    depth: usize,
    found: &mut Vec<Layer>,
) {
    let Some(query) = injections
        .get(language.name)
        .and_then(|(_, query)| query.get(language))
    else {
        return;
    };
    if depth >= MAX_DEPTH {
        return;
    }
    let mut wanted: Vec<(Arc<Language>, Vec<tree_sitter::Range>)> = Vec::new();
    // Where in `wanted` each combined pattern's layer is, by pattern and
    // language.
    let mut combined: HashMap<(usize, &'static str), usize> = HashMap::new();
    let mut cursor = QueryCursor::new();
    let mut matches = cursor.matches(query, tree.root_node(), RopeText(text));
    while let Some(m) = matches.next() {
        let Some(asked) = injection(query, m, text) else {
            continue;
        };
        let Some(inner) = find(injections, &asked.language) else {
            continue;
        };
        let ranges = content_ranges(asked.content, asked.include_children);
        if asked.combined {
            let key = (m.pattern_index, inner.name);
            if let Some(&at) = combined.get(&key) {
                wanted[at].1.extend(ranges);
                continue;
            }
            combined.insert(key, wanted.len());
        }
        wanted.push((inner.clone(), ranges));
    }
    for (_, ranges) in &mut wanted {
        ranges.sort_by_key(|r| r.start_byte);
    }
    for (inner, ranges) in wanted {
        parse_layer(parser, text, inner, &ranges, injections, depth, found);
    }
}
