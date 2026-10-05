//! What each file in a project defines and uses, from its syntax tree: the
//! functions and types its "textobjects" query finds, and the names it
//! mentions. Plugins build on it, like the agent's repo map.

use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex, OnceLock};

use ignore::WalkState;
use streaming_iterator::StreamingIterator;
use tree_sitter::{Node, Parser, Query, QueryCursor};

use super::{Language, Syntax, language_name};

/// Files bigger than this are skipped: generated code, mostly.
const MAX_FILE: u64 = 1024 * 1024;

/// The most of a definition's first line kept as its signature.
const MAX_SIGNATURE: usize = 200;

/// A function or type a file defines.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Definition {
    pub name: String,
    /// "function" or "type".
    pub kind: &'static str,
    /// 0-based.
    pub line: usize,
    /// Its first line, trimmed.
    pub signature: String,
}

/// What one file defines and the names it uses, with how often.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileTags {
    /// Relative to the folder searched.
    pub path: String,
    pub language: &'static str,
    pub definitions: Vec<Definition>,
    pub references: Vec<(String, usize)>,
}

/// The languages with a textobjects query, to run on another thread. Each
/// query is compiled there, the first time a file needs it, since compiling
/// them all takes a while.
pub struct Tagger {
    languages: HashMap<&'static str, Tagged>,
}

struct Tagged {
    language: Arc<Language>,
    source: String,
    query: OnceLock<Option<Query>>,
}

impl Syntax {
    /// A [`Tagger`] for the languages that have a textobjects query.
    /// Grammars loaded from WebAssembly are left out: running them needs a
    /// store of the parser's own.
    pub fn tagger(&self) -> Tagger {
        let languages = self
            .languages
            .iter()
            .filter(|l| !self.loaded.contains(&l.name))
            .filter_map(|language| {
                let source = self.query_source(language.name, "textobjects")?;
                let tagged = Tagged {
                    language: language.clone(),
                    source,
                    query: OnceLock::new(),
                };
                Some((language.name, tagged))
            })
            .collect();
        Tagger { languages }
    }
}

impl Tagged {
    fn query(&self) -> Option<&Query> {
        self.query
            .get_or_init(|| Query::new(&self.language.grammar, &self.source).ok())
            .as_ref()
    }
}

impl Tagger {
    /// The tags of the source files under `dir`, skipping hidden and ignored
    /// ones, sorted by path; at most `limit` files.
    pub fn tags(&self, dir: &Path, limit: usize) -> Vec<FileTags> {
        let found = Mutex::new(Vec::new());
        ignore::WalkBuilder::new(dir)
            .require_git(false)
            .build_parallel()
            .run(|| {
                let mut parser = Parser::new();
                let found = &found;
                Box::new(move |entry| {
                    let Ok(entry) = entry else {
                        return WalkState::Continue;
                    };
                    let path = entry.path();
                    let Some(tagged) =
                        language_name(path).and_then(|name| self.languages.get(name))
                    else {
                        return WalkState::Continue;
                    };
                    if !entry
                        .metadata()
                        .is_ok_and(|m| m.is_file() && m.len() <= MAX_FILE)
                    {
                        return WalkState::Continue;
                    }
                    let Ok(text) = std::fs::read_to_string(path) else {
                        return WalkState::Continue;
                    };
                    let relative = path.strip_prefix(dir).unwrap_or(path);
                    if let Some(tags) = tagged.query().and_then(|query| {
                        let path = relative.to_string_lossy();
                        file_tags(&mut parser, &tagged.language, query, &path, &text)
                    }) {
                        let mut found = found.lock().expect("no panics while held");
                        if found.len() >= limit {
                            return WalkState::Quit;
                        }
                        found.push(tags);
                    }
                    WalkState::Continue
                })
            });
        let mut found = found.into_inner().expect("no panics while held");
        found.sort_by(|a, b| a.path.cmp(&b.path));
        found
    }
}

/// The tags of one file, `text`, at `path`.
fn file_tags(
    parser: &mut Parser,
    language: &Language,
    query: &Query,
    path: &str,
    text: &str,
) -> Option<FileTags> {
    parser.set_language(&language.grammar).ok()?;
    let tree = parser.parse(text, None)?;
    let names = query.capture_names();
    let mut definitions = Vec::new();
    let mut cursor = QueryCursor::new();
    let mut matches = cursor.matches(query, tree.root_node(), text.as_bytes());
    while let Some(m) = matches.next() {
        for capture in m.captures() {
            let kind = match names[capture.index as usize] {
                "function.around" => "function",
                "type.around" => "type",
                _ => continue,
            };
            let node = capture.node;
            let Some(name) = node
                .child_by_field_name("name")
                .or_else(|| node.child_by_field_name("type"))
            else {
                continue;
            };
            let line = &text[node.start_byte()..];
            let line = line.lines().next().unwrap_or_default().trim();
            definitions.push(Definition {
                name: text[name.byte_range()].to_owned(),
                kind,
                line: node.start_position().row,
                signature: cut(line, MAX_SIGNATURE).to_owned(),
            });
        }
    }
    definitions.sort_by_key(|d| d.line);
    definitions.dedup();
    let mut references: HashMap<&str, usize> = HashMap::new();
    count_names(tree.root_node(), text, &mut references);
    let mut references: Vec<(String, usize)> = references
        .into_iter()
        .map(|(name, count)| (name.to_owned(), count))
        .collect();
    references.sort();
    Some(FileTags {
        path: path.to_owned(),
        language: language.name,
        definitions,
        references,
    })
}

/// Counts the identifiers under `node` by name.
fn count_names<'a>(node: Node, text: &'a str, counts: &mut HashMap<&'a str, usize>) {
    let mut cursor = node.walk();
    let mut descend = true;
    loop {
        let node = cursor.node();
        if descend && node.child_count() == 0 && node.kind().ends_with("identifier") {
            *counts.entry(&text[node.byte_range()]).or_default() += 1;
        }
        if descend && cursor.goto_first_child() {
            continue;
        }
        if cursor.goto_next_sibling() {
            descend = true;
            continue;
        }
        if !cursor.goto_parent() {
            return;
        }
        descend = false;
    }
}

/// `text` up to `max` bytes, at a character boundary.
fn cut(text: &str, max: usize) -> &str {
    if text.len() <= max {
        return text;
    }
    let mut end = max;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_folders_source_files_are_tagged_and_the_rest_left_out() {
        let dir = std::env::temp_dir().join(format!("greed-tags-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("src")).unwrap();
        std::fs::write(dir.join("src/a.rs"), "fn a() {}\n").unwrap();
        std::fs::write(dir.join("notes.txt"), "fn not_code() {}\n").unwrap();
        let mut syntax = Syntax::new();
        syntax
            .set_query(
                "rust",
                "textobjects",
                Some("(function_item) @function.around".to_owned()),
            )
            .unwrap();
        let tags = syntax.tagger().tags(&dir, 10);
        std::fs::remove_dir_all(&dir).unwrap();
        let paths: Vec<&str> = tags.iter().map(|t| t.path.as_str()).collect();
        assert_eq!(paths, ["src/a.rs"]);
        assert_eq!(tags[0].definitions[0].name, "a");
    }

    #[test]
    fn a_rust_file_tells_its_functions_and_types_and_the_names_it_uses() {
        let mut syntax = Syntax::new();
        syntax
            .set_query(
                "rust",
                "textobjects",
                Some(
                    "(function_item) @function.around (struct_item) @type.around (impl_item) @type.around"
                        .to_owned(),
                ),
            )
            .unwrap();
        let tagger = syntax.tagger();
        let rust = &tagger.languages["rust"];
        let (language, query) = (&rust.language, rust.query().unwrap());
        let text = "struct Point { x: i32 }\nimpl Point {\n    fn len(&self) -> i32 { helper(self.x) }\n}\nfn helper(x: i32) -> i32 { x }\n";
        let tags = file_tags(&mut Parser::new(), language, query, "a.rs", text).unwrap();
        let defined: Vec<(&str, &str, usize)> = tags
            .definitions
            .iter()
            .map(|d| (d.name.as_str(), d.kind, d.line))
            .collect();
        assert_eq!(
            defined,
            [
                ("Point", "type", 0),
                ("Point", "type", 1),
                ("len", "function", 2),
                ("helper", "function", 4)
            ]
        );
        assert_eq!(
            tags.definitions[2].signature,
            "fn len(&self) -> i32 { helper(self.x) }"
        );
        let used: HashMap<&str, usize> = tags
            .references
            .iter()
            .map(|(name, count)| (name.as_str(), *count))
            .collect();
        assert_eq!(used["helper"], 2);
        assert_eq!(used["Point"], 2);
    }
}
