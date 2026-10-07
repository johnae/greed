//! Syntax trees for plugins: `buffer:tree()`, `buffer:node_at(from, to)`
//! and `buffer:query(source)`. A node describes the buffer as it was when
//! the node was found; after an edit, ask again.

use mlua::{Function, Lua, MetaMethod, Table, UserData, UserDataFields, UserDataMethods};
use std::path::Path;
use std::sync::Arc;
use streaming_iterator::StreamingIterator;

use tree_sitter::{Node, QueryCursor, Tree};

use super::handles::BufferRef;
use super::jobs::{self, Output};
use super::{state, state_mut};
use crate::BufferId;
use crate::registry::PluginId;
use crate::syntax::{FileTags, Language, RopeText};

type LuaResult<T> = mlua::Result<T>;

/// A node in a buffer's syntax tree. It keeps the tree it came from and
/// the way down to it from the root, child by child.
pub(super) struct NodeRef {
    buffer: BufferId,
    /// The buffer's version the tree was parsed from.
    version: usize,
    tree: Tree,
    path: Vec<u32>,
}

impl NodeRef {
    fn new(buffer: BufferId, version: usize, tree: Tree, path: Vec<u32>) -> NodeRef {
        NodeRef {
            buffer,
            version,
            tree,
            path,
        }
    }

    fn node(&self) -> Node<'_> {
        let mut node = self.tree.root_node();
        for &i in &self.path {
            node = node.child(i).expect("the path was taken in this tree");
        }
        node
    }

    fn at(&self, path: Vec<u32>) -> NodeRef {
        NodeRef::new(self.buffer, self.version, self.tree.clone(), path)
    }

    fn parent(&self) -> Option<NodeRef> {
        let (_, up) = self.path.split_last()?;
        Some(self.at(up.to_vec()))
    }

    fn child(&self, i: u32) -> NodeRef {
        let mut path = self.path.clone();
        path.push(i);
        self.at(path)
    }

    /// The sibling `step` places away (+1 next, -1 previous) that is named.
    fn sibling(&self, step: i64) -> Option<NodeRef> {
        let (&last, up) = self.path.split_last()?;
        let parent = self.at(up.to_vec());
        let node = parent.node();
        let count = i64::from(node.child_count());
        let mut i = i64::from(last) + step;
        while (0..count).contains(&i) {
            let index = u32::try_from(i).expect("in range");
            if node.child(index).is_some_and(|n| n.is_named()) {
                return Some(parent.child(index));
            }
            i += step;
        }
        None
    }

    fn children(&self, named_only: bool) -> Vec<NodeRef> {
        let node = self.node();
        (0..node.child_count())
            .filter(|&i| !named_only || node.child(i).is_some_and(|n| n.is_named()))
            .map(|i| self.child(i))
            .collect()
    }
}

/// Which of `parent`'s children `node` is.
fn child_index(parent: Node, node: Node) -> u32 {
    (0..parent.child_count())
        .find(|&i| parent.child(i).is_some_and(|c| c.id() == node.id()))
        .expect("a node is one of its parent's children")
}

/// The way down from `root` to `node`. Each step goes to the child holding
/// `node` by its position, so a node among thousands of siblings (the
/// items of a long file) costs a few steps, not a scan of the siblings.
fn path_to(root: Node, node: Node) -> Vec<u32> {
    let mut path = Vec::new();
    let mut cursor = root.walk();
    let mut at = root;
    while at.id() != node.id() {
        let Some(child) = at.child_with_descendant(node) else {
            break;
        };
        // The first child ending after where `node` starts, then on to
        // `child`: past any empty ones that start there too.
        let index = cursor
            .goto_first_child_for_byte(node.start_byte())
            .and_then(|mut index| {
                while cursor.node().id() != child.id() && cursor.goto_next_sibling() {
                    index += 1;
                }
                (cursor.node().id() == child.id()).then_some(index)
            });
        if let Some(index) = index {
            path.push(u32::try_from(index).expect("a node has fewer than 2^32 children"));
        } else {
            // No child ends after `node` starts, or an empty node at the end
            // of `child` sits past where that looks.
            path.push(child_index(at, child));
            cursor.reset(child);
        }
        at = child;
    }
    path
}

impl UserData for NodeRef {
    fn add_fields<F: UserDataFields<Self>>(fields: &mut F) {
        fields.add_field_method_get("kind", |_, this| Ok(this.node().kind().to_owned()));
        fields.add_field_method_get("from", |_, this| Ok(this.node().start_byte()));
        fields.add_field_method_get("to", |_, this| Ok(this.node().end_byte()));
        fields.add_field_method_get("named", |_, this| Ok(this.node().is_named()));
        fields.add_field_method_get("error", |_, this| {
            let node = this.node();
            Ok(node.is_error() || node.is_missing())
        });
        fields.add_field_method_get("field", |_, this| {
            let Some((&last, up)) = this.path.split_last() else {
                return Ok(None);
            };
            Ok(this
                .at(up.to_vec())
                .node()
                .field_name_for_child(last)
                .map(str::to_owned))
        });
    }

    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method("parent", |_, this, ()| Ok(this.parent()));
        methods.add_method("children", |_, this, ()| Ok(this.children(false)));
        methods.add_method("named_children", |_, this, ()| Ok(this.children(true)));
        methods.add_method("child", |_, this, field: String| {
            let node = this.node();
            Ok(node
                .child_by_field_name(&field)
                .map(|child| this.child(child_index(node, child))))
        });
        methods.add_method("next", |_, this, ()| Ok(this.sibling(1)));
        methods.add_method("prev", |_, this, ()| Ok(this.sibling(-1)));
        methods.add_method("text", |lua, this, ()| {
            let state = state(lua);
            let buffer = state
                .editor
                .find_buffer(this.buffer)
                .ok_or_else(|| mlua::Error::runtime("this buffer was closed"))?;
            if buffer.history().applied() != this.version {
                return Err(mlua::Error::runtime(
                    "the buffer changed since this node was found; find it again",
                ));
            }
            let node = this.node();
            Ok(buffer
                .text()
                .byte_slice(node.start_byte()..node.end_byte())
                .to_string())
        });
        methods.add_meta_method(MetaMethod::ToString, |_, this, ()| {
            Ok(this.node().to_sexp())
        });
        methods.add_meta_method(
            MetaMethod::Eq,
            |_, this, other: mlua::UserDataRef<NodeRef>| {
                Ok(this.buffer == other.buffer
                    && this.version == other.version
                    && this.path == other.path)
            },
        );
    }
}

/// The buffer's current tree and its version, or `None` without one.
fn tree_of(lua: &Lua, buffer: &BufferRef) -> LuaResult<Option<(Arc<Language>, Tree, usize)>> {
    // Parsing here, when the worker hasn't caught up, is the editor's own
    // work, timed apart from the plugin code that asked.
    super::stalls::timed(lua, None, "parsing", || {
        let state = &mut *state_mut(lua);
        let found = state
            .editor
            .find_buffer(buffer.buffer)
            .ok_or_else(|| mlua::Error::runtime("this buffer was closed"))?;
        let version = found.history().applied();
        Ok(state
            .syntax
            .tree(found)
            .map(|(language, tree)| (language, tree, version)))
    })
    .0
}

/// Runs `source` over the buffer (or `from`..`to` of it): one table per
/// match, from capture name to node.
fn query(lua: &Lua, buffer: &BufferRef, source: &str, range: Option<Table>) -> LuaResult<Table> {
    let matches = lua.create_table()?;
    let Some((language, tree, version)) = tree_of(lua, buffer)? else {
        return Ok(matches);
    };
    let compiled = state_mut(lua)
        .syntax
        .query(&language, source)
        .map_err(|err| mlua::Error::runtime(format!("query: {err}")))?;
    let state = state(lua);
    let text = state
        .editor
        .find_buffer(buffer.buffer)
        .expect("checked above")
        .text();
    let mut cursor = QueryCursor::new();
    if let Some(range) = range {
        let from: Option<usize> = range.get("from")?;
        let to: Option<usize> = range.get("to")?;
        cursor.set_byte_range(from.unwrap_or(0)..to.unwrap_or(usize::MAX));
    }
    let names = compiled.capture_names();
    let base = NodeRef::new(buffer.buffer, version, tree.clone(), Vec::new());
    let mut found = cursor.matches(&compiled, tree.root_node(), RopeText(text));
    while let Some(m) = found.next() {
        let captures = lua.create_table()?;
        for capture in m.captures() {
            let name = names[capture.index as usize];
            if !captures.contains_key(name)? {
                captures.set(name, base.at(path_to(tree.root_node(), capture.node)))?;
            }
        }
        matches.push(captures)?;
    }
    Ok(matches)
}

/// `greed.syntax`: the queries languages use, set by the plugin `owner`.
pub(super) fn module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let syntax = lua.create_table()?;
    let o = owner.clone();
    syntax.set(
        "set_query",
        lua.create_function(
            move |lua, (language, kind, source): (String, String, Option<String>)| {
                let state = &mut *state_mut(lua);
                // So it knows which languages buffers are in, and checks
                // queries for those now.
                state.syntax.update(&state.editor);
                let owners = state
                    .query_owners
                    .entry((language.clone(), kind.clone()))
                    .or_default();
                // Without a source, the query in use goes back to the one
                // another plugin set before, if any.
                let in_use = source.clone().or_else(|| {
                    owners
                        .iter()
                        .rev()
                        .find(|(owner, _)| owner != &o)
                        .map(|(_, source)| source.clone())
                });
                state
                    .syntax
                    .set_query(&language, &kind, in_use)
                    .map_err(|err| {
                        mlua::Error::runtime(format!("the {kind} query for {language}: {err}"))
                    })?;
                owners.retain(|(owner, _)| owner != &o);
                if let Some(source) = source {
                    owners.push((o.clone(), source));
                }
                Ok(())
            },
        )?,
    )?;
    syntax.set(
        "load_grammar",
        lua.create_function(
            |lua, (language, path, symbol): (String, String, Option<String>)| {
                let bytes = std::fs::read(&path)
                    .map_err(|err| mlua::Error::runtime(format!("{path}: {err}")))?;
                let symbol = symbol.unwrap_or_else(|| language.replace('-', "_"));
                state_mut(lua)
                    .syntax
                    .load_grammar(&language, &symbol, &bytes)
                    .map_err(|err| {
                        mlua::Error::runtime(format!("the {language} grammar in {path}: {err}"))
                    })
            },
        )?,
    )?;
    syntax.set(
        "query",
        lua.create_function(|lua, (language, kind): (String, String)| {
            Ok(state(lua).syntax.query_source(&language, &kind))
        })?,
    )?;
    syntax.set("tags", tags_function(lua)?)?;
    Ok(syntax)
}

/// `greed.syntax.tags`, which parses a project's files in the background
/// and waits, like `greed.fs.grep`.
fn tags_function(lua: &Lua) -> LuaResult<Function> {
    let start = lua.create_function(|lua, (dir, opts): (Option<String>, Option<Table>)| {
        let limit: Option<usize> = match &opts {
            Some(opts) => opts.get("limit")?,
            None => None,
        };
        let dir = dir.unwrap_or_else(|| ".".to_owned());
        let tagger = state(lua).syntax.tagger();
        Ok(jobs::start(
            lua,
            format!("greed.syntax.tags in {dir}"),
            move || Output::Tags(tagger.tags(Path::new(&dir), limit.unwrap_or(10_000))),
        ))
    })?;
    jobs::waiting(lua, "greed.syntax.tags", start)
}

pub(super) fn tags_to_lua(lua: &Lua, files: Vec<FileTags>) -> LuaResult<Table> {
    let list = lua.create_table()?;
    for file in files {
        let entry = lua.create_table()?;
        entry.set("path", file.path)?;
        entry.set("language", file.language)?;
        let definitions = lua.create_table()?;
        for d in file.definitions {
            let definition = lua.create_table()?;
            definition.set("name", d.name)?;
            definition.set("kind", d.kind)?;
            definition.set("line", d.line)?;
            definition.set("signature", d.signature)?;
            definitions.push(definition)?;
        }
        entry.set("definitions", definitions)?;
        let references = lua.create_table()?;
        for (name, count) in file.references {
            references.set(name, count)?;
        }
        entry.set("references", references)?;
        list.push(entry)?;
    }
    Ok(list)
}

/// `buffer:tree()`, `buffer:node_at()` and `buffer:query()`.
pub(super) fn add_methods<M: UserDataMethods<BufferRef>>(methods: &mut M) {
    methods.add_method("tree", |lua, this, ()| {
        Ok(tree_of(lua, this)?
            .map(|(_, tree, version)| NodeRef::new(this.buffer, version, tree, Vec::new())))
    });
    methods.add_method(
        "node_at",
        |lua, this, (from, to): (usize, Option<usize>)| {
            let Some((_, tree, version)) = tree_of(lua, this)? else {
                return Ok(None);
            };
            let to = to.unwrap_or(from);
            let path = tree
                .root_node()
                .named_descendant_for_byte_range(from, to)
                .map(|node| path_to(tree.root_node(), node));
            Ok(path.map(|path| NodeRef::new(this.buffer, version, tree, path)))
        },
    );
    methods.add_method(
        "query",
        |lua, this, (source, range): (String, Option<Table>)| query(lua, this, &source, range),
    );
}
