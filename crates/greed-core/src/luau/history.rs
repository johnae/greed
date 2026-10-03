//! A buffer's history for plugins: `buffer:history(filter)` lists the
//! transactions applied to it, newest first, and `buffer:text_before(id)`
//! gives the text as it was before one of them.

use std::time::UNIX_EPOCH;

use greed_text::{Author, ChangeSet, Operation, Transaction};
use mlua::{Lua, Table, UserDataMethods};

use super::handles::BufferRef;

type LuaResult<T> = mlua::Result<T>;

pub(super) fn add_methods<M: UserDataMethods<BufferRef>>(methods: &mut M) {
    methods.add_method("history", |lua, this, filter: Option<Table>| {
        let filter = Filter::from_table(filter)?;
        this.with_buffer(lua, |b| {
            let list = lua.create_table()?;
            for tx in b
                .history()
                .log()
                .iter()
                .rev()
                .filter(|tx| filter.matches(tx))
                .take(filter.limit)
            {
                list.push(entry(lua, tx)?)?;
            }
            Ok(list)
        })
    });
    methods.add_method("text_before", |lua, this, id: u64| {
        this.with_buffer(lua, |b| {
            let history = b.history();
            Ok(history
                .log()
                .iter()
                .find(|tx| tx.meta.id.seq == id)
                .and_then(|tx| history.text_before(b.text(), tx.meta.id))
                .map(|text| text.to_string()))
        })
    });
}

/// Which transactions `buffer:history` returns.
struct Filter {
    author: Option<String>,
    plugin: Option<String>,
    cause: Option<String>,
    group: Option<u64>,
    /// Seconds since the Unix epoch.
    since: Option<f64>,
    limit: usize,
}

impl Filter {
    fn from_table(table: Option<Table>) -> LuaResult<Filter> {
        let Some(t) = table else {
            return Ok(Filter {
                author: None,
                plugin: None,
                cause: None,
                group: None,
                since: None,
                limit: usize::MAX,
            });
        };
        Ok(Filter {
            author: t.get("author")?,
            plugin: t.get("plugin")?,
            cause: t.get("cause")?,
            group: t.get("group")?,
            since: t.get("since")?,
            limit: t.get::<Option<usize>>("limit")?.unwrap_or(usize::MAX),
        })
    }

    fn matches(&self, tx: &Transaction) -> bool {
        let (author, plugin) = author_names(&tx.meta.author);
        self.author.as_deref().is_none_or(|a| a == author)
            && self.plugin.as_deref().is_none_or(|p| Some(p) == plugin)
            && self
                .cause
                .as_deref()
                .is_none_or(|c| Some(c) == tx.meta.cause.as_deref())
            && self.group.is_none_or(|g| Some(g) == tx.meta.group)
            && self.since.is_none_or(|s| seconds(tx) >= s)
    }
}

/// The author's kind, and the plugin's name for a plugin.
fn author_names(author: &Author) -> (&'static str, Option<&str>) {
    match author {
        Author::User(_) => ("user", None),
        Author::Plugin(name) => ("plugin", Some(name)),
        Author::Agent(_) => ("agent", None),
        Author::External => ("external", None),
    }
}

fn seconds(tx: &Transaction) -> f64 {
    tx.meta
        .time
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |d| d.as_secs_f64())
}

fn entry(lua: &Lua, tx: &Transaction) -> LuaResult<Table> {
    let t = lua.create_table()?;
    let (author, plugin) = author_names(&tx.meta.author);
    t.set("id", tx.meta.id.seq)?;
    t.set("author", author)?;
    t.set("plugin", plugin)?;
    t.set("cause", tx.meta.cause.as_deref())?;
    t.set("group", tx.meta.group)?;
    t.set("time", seconds(tx))?;
    let changes = lua.create_table()?;
    for (from, to, text) in changes_of(&tx.changes) {
        let change = lua.create_table()?;
        change.set("from", from)?;
        change.set("to", to)?;
        change.set("text", text)?;
        changes.push(change)?;
    }
    t.set("changes", changes)?;
    Ok(t)
}

/// The change set as replacements of `from..to` (in the text before it)
/// with text, in order.
fn changes_of(changes: &ChangeSet) -> Vec<(usize, usize, &str)> {
    let mut list: Vec<(usize, usize, &str)> = Vec::new();
    let mut pos = 0;
    for op in changes.ops() {
        match op {
            Operation::Retain(n) => pos += n,
            Operation::Insert(text) => list.push((pos, pos, text)),
            Operation::Delete(n) => {
                // An insert comes before a delete at the same place: together
                // they replace.
                match list.last_mut() {
                    Some((from, to, _)) if *from == pos && *to == pos => *to = pos + n,
                    _ => list.push((pos, pos + n, "")),
                }
                pos += n;
            }
        }
    }
    list
}
