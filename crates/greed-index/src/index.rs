//! An index on SQLite: items with a key, the item they're in, a name, text,
//! fields and flags, kept in one file that one program writes and any
//! number read. Searching narrows with SQL (words through FTS5), then the
//! same rules as rows in memory ([`crate::query`]) decide, over the items
//! SQL found, so an index and a list in memory can't disagree.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::Path;

use rusqlite::{Connection, OpenFlags, params_from_iter, types::Value};

use crate::compare;
use crate::query::{self, Answer, Flag, Kind, Node, Query, Row, Rows, Schema};

/// The version of the tables; an index made by another is made again.
const VERSION: &str = "5";

/// How many candidates are loaded and checked at a time.
const CHUNK: usize = 1000;

/// How many are loaded first: a search sorted in SQL that wants a page
/// usually has it in the first few hundred.
const FIRST_CHUNK: usize = 250;

/// From how many candidates a search sorted by a date, newest first, walks
/// that date's values in order rather than sorting the candidates: many
/// fill a page in the first stretch of the walk, few are quicker sorted.
const WALK: i64 = 2000;

const TABLES: &str = "
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS items (
    id INTEGER PRIMARY KEY,
    key TEXT NOT NULL UNIQUE,
    parent TEXT,
    name TEXT,
    -- The name folded (`query::fold`), for `in:NAME`.
    folded TEXT,
    text TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS items_parent ON items (parent);
CREATE INDEX IF NOT EXISTS items_name ON items (folded);
CREATE TABLE IF NOT EXISTS item_values (
    item INTEGER NOT NULL,
    field TEXT NOT NULL,
    value TEXT NOT NULL,
    lower TEXT NOT NULL,
    number REAL
);
CREATE INDEX IF NOT EXISTS values_field ON item_values (field, lower);
CREATE INDEX IF NOT EXISTS values_number ON item_values (field, number);
-- By item and field: loading an item's values, and the value it's sorted by.
CREATE INDEX IF NOT EXISTS values_item ON item_values (item, field, lower);
CREATE TABLE IF NOT EXISTS item_flags (item INTEGER NOT NULL, flag TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS flags_flag ON item_flags (flag);
CREATE INDEX IF NOT EXISTS flags_item ON item_flags (item);
CREATE VIRTUAL TABLE IF NOT EXISTS words USING fts5 (
    text, tokenize = 'unicode61 remove_diacritics 2'
);
-- Each value's words, under the rowid of its row in item_values.
CREATE VIRTUAL TABLE IF NOT EXISTS field_words USING fts5 (
    value, field UNINDEXED, item UNINDEXED, tokenize = 'unicode61 remove_diacritics 2'
);
";

/// Something that went wrong with an index, in words.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Trouble(pub String);

impl From<rusqlite::Error> for Trouble {
    fn from(error: rusqlite::Error) -> Trouble {
        Trouble(error.to_string())
    }
}

impl From<query::Bad> for Trouble {
    fn from(bad: query::Bad) -> Trouble {
        Trouble(bad.0)
    }
}

/// An item to put in an index: its `key`, unique in it, the key of the
/// item it's in, its name (for `in:NAME`), its text for words, its fields'
/// values by name and its flags. `words` names the fields whose values are
/// searched by word (text fields); without it, every field's are.
#[derive(Debug, Clone, Default)]
pub struct Item {
    pub key: String,
    pub parent: Option<String>,
    pub name: Option<String>,
    pub text: String,
    pub fields: HashMap<String, Vec<String>>,
    pub flags: Vec<String>,
    pub words: Option<Vec<String>>,
}

/// How results come back: sorted by fields (each descending or not), and
/// at most `limit` of them.
#[derive(Debug, Clone, Default)]
pub struct View {
    pub sort: Vec<(String, bool)>,
    pub limit: Option<usize>,
}

/// What a search found: the keys of the items that match, and of those
/// that only might, where it depends on a flag the source works out.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Found {
    pub keys: Vec<String>,
    pub maybe: Vec<String>,
}

/// An index in a file.
pub struct Index {
    db: Connection,
}

impl Index {
    /// The index at `path`, made if it isn't there, or made again when an
    /// older Greed made it, for writing.
    pub fn open(path: &Path) -> Result<Index, Trouble> {
        let db = Connection::open(path)?;
        db.pragma_update(None, "journal_mode", "WAL")?;
        db.pragma_update(None, "synchronous", "NORMAL")?;
        if read_version(&db).is_ok_and(|v| v != VERSION) {
            db.execute_batch(
                "DROP TABLE IF EXISTS items; DROP TABLE IF EXISTS item_values;
                 DROP TABLE IF EXISTS item_flags; DROP TABLE IF EXISTS words;
                 DROP TABLE IF EXISTS field_words;",
            )?;
        }
        db.execute_batch(TABLES)?;
        db.execute(
            "INSERT OR REPLACE INTO meta (key, value) VALUES ('version', ?1)",
            [VERSION],
        )?;
        Ok(Index { db })
    }

    /// The index at `path` to read, while another program may write it.
    pub fn open_read(path: &Path) -> Result<Index, Trouble> {
        let db = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        let version = read_version(&db)?;
        if version != VERSION {
            return Err(Trouble(format!(
                "this index was made by another Greed (version {version}); it's made again when written"
            )));
        }
        Ok(Index { db })
    }

    /// Puts `items` in, in one go, each in place of the one with its key.
    pub fn write(&mut self, items: &[Item]) -> Result<(), Trouble> {
        let tx = self.db.transaction()?;
        for item in items {
            forget(&tx, &item.key)?;
            run(
                &tx,
                "INSERT INTO items (key, parent, name, folded, text) VALUES (?1, ?2, ?3, ?4, ?5)",
                (
                    &item.key,
                    &item.parent,
                    &item.name,
                    item.name.as_deref().map(query::fold),
                    &item.text,
                ),
            )?;
            let id = tx.last_insert_rowid();
            run(
                &tx,
                "INSERT INTO words (rowid, text) VALUES (?1, ?2)",
                (id, &item.text),
            )?;
            for (field, values) in &item.fields {
                let field = field.to_lowercase();
                let worded = item
                    .words
                    .as_ref()
                    .is_none_or(|words| words.iter().any(|name| name.eq_ignore_ascii_case(&field)));
                for value in values {
                    run(
                        &tx,
                        "INSERT INTO item_values (item, field, value, lower, number) VALUES (?1, ?2, ?3, ?4, ?5)",
                        (
                            id,
                            &field,
                            value,
                            query::fold(value),
                            compare::number(value, false),
                        ),
                    )?;
                    if worded {
                        run(
                            &tx,
                            "INSERT INTO field_words (rowid, value, field, item) VALUES (?1, ?2, ?3, ?4)",
                            (tx.last_insert_rowid(), value, &field, id),
                        )?;
                    }
                }
            }
            for flag in &item.flags {
                run(
                    &tx,
                    "INSERT INTO item_flags (item, flag) VALUES (?1, ?2)",
                    (id, flag.to_lowercase()),
                )?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// Takes the items with `keys` out.
    pub fn remove(&mut self, keys: &[String]) -> Result<(), Trouble> {
        let tx = self.db.transaction()?;
        for key in keys {
            forget(&tx, key)?;
        }
        tx.commit()?;
        Ok(())
    }

    /// How many items it holds.
    pub fn count(&self) -> Result<usize, Trouble> {
        let n: i64 = self
            .db
            .query_row("SELECT count(*) FROM items", [], |r| r.get(0))?;
        Ok(usize::try_from(n).unwrap_or(0))
    }

    /// The items matching `node` (every item, without one), as `schema`
    /// says what its fields and flags mean, sorted and cut as `view` says.
    pub fn search(
        &self,
        node: Option<&Node>,
        schema: &Schema,
        view: &View,
    ) -> Result<Found, Trouble> {
        let compiled = node
            .map(|n| Query::new(n.clone(), schema.clone()))
            .transpose()?;
        let mut args: Vec<Value> = Vec::new();
        let narrowed = node.and_then(|n| narrow(n, schema, &mut args));
        // Sorted by one date, the candidates come in that order from SQL, so
        // the first that match are the ones wanted. Other sorts compare in
        // Rust (`compare::order`), which SQL can't.
        let by_date = match view.sort.as_slice() {
            [(field, descending)]
                if schema.fields.get(&field.to_lowercase()) == Some(&Kind::Date) =>
            {
                Some((field.to_lowercase(), *descending))
            }
            _ => None,
        };
        // What the items are in, for `in:` and `under:`, and what they hold,
        // for `has:`; their text only when words or regexes read it.
        let up = node.is_some_and(|n| uses(n, &["in", "under"]));
        let down = node.is_some_and(|n| uses(n, &["has"]));
        let text = node.is_some_and(reads_text);
        let by: Vec<String> = view.sort.iter().map(|(f, _)| f.to_lowercase()).collect();
        // A limit stops once enough have matched, when the candidates come
        // in the order wanted, unless some only might.
        let early = if by.is_empty() || by_date.is_some() {
            view.limit
        } else {
            None
        };
        let walk = by_date.is_some()
            && node
                .and_then(|n| estimate(&self.db, n, schema))
                .is_none_or(|n| n >= WALK);
        let mut candidates = Candidates::new(
            narrowed.as_deref().unwrap_or("1"),
            args,
            by_date.as_ref(),
            walk,
        );
        let mut matching: Vec<Match> = Vec::new();
        let mut any_maybe = false;
        // Without a limit every candidate is looked at: all in one go.
        let mut size = if early.is_some() {
            FIRST_CHUNK
        } else {
            usize::MAX
        };
        loop {
            let ids = candidates.next(&self.db, size)?;
            size = CHUNK;
            if ids.is_empty() {
                break;
            }
            for chunk in ids.chunks(CHUNK) {
                self.check(
                    chunk,
                    text,
                    (up, down),
                    by_date.is_some(),
                    compiled.as_ref(),
                    &by,
                    &mut matching,
                    &mut any_maybe,
                )?;
            }
            if early.is_some_and(|limit| !any_maybe && matching.len() >= limit) {
                break;
            }
        }
        sort(&mut matching, schema, view);
        if let Some(limit) = view.limit
            && !any_maybe
        {
            matching.truncate(limit);
        }
        Ok(Found {
            maybe: matching
                .iter()
                .filter(|m| m.maybe)
                .map(|m| m.key.clone())
                .collect(),
            keys: matching.into_iter().map(|m| m.key).collect(),
        })
    }

    // Loads the candidates `chunk` and adds those `compiled` takes to
    // `matching`, in the chunk's order when `ordered`.
    #[allow(clippy::too_many_arguments)]
    fn check(
        &self,
        chunk: &[i64],
        text: bool,
        (up, down): (bool, bool),
        ordered: bool,
        compiled: Option<&Query>,
        by: &[String],
        matching: &mut Vec<Match>,
        any_maybe: &mut bool,
    ) -> Result<(), Trouble> {
        let mut loaded = Loaded {
            text,
            ..Loaded::default()
        };
        self.load(
            &mut loaded,
            &format!("id IN ({})", marks(chunk.len())),
            chunk,
        )?;
        // The order SQL gave, as `load` reads them by id.
        if ordered {
            loaded.reorder(chunk);
        }
        let wanted = loaded.ids.len();
        if up {
            self.load_up(&mut loaded)?;
        }
        if down {
            self.load_down(&mut loaded, wanted)?;
        }
        self.load_values(&mut loaded)?;
        let rows = Rows::new(std::mem::take(&mut loaded.rows));
        for at in 0..wanted {
            let answer = compiled.map_or(Answer::Yes, |q| q.answer(&rows, at));
            if answer == Answer::No {
                continue;
            }
            let maybe = answer == Answer::Maybe;
            *any_maybe |= maybe;
            matching.push(Match {
                key: loaded.keys[at].clone(),
                maybe,
                sort: by.iter().map(|f| first_value(&rows, at, f)).collect(),
            });
        }
        Ok(())
    }

    // Loads the items `condition` picks, with `args` for its marks.
    fn load<T: rusqlite::ToSql>(
        &self,
        loaded: &mut Loaded,
        condition: &str,
        args: &[T],
    ) -> Result<(), Trouble> {
        let text = if loaded.text { "text" } else { "''" };
        let mut statement = self.db.prepare_cached(&format!(
            "SELECT id, key, parent, name, {text} FROM items WHERE {condition} ORDER BY id"
        ))?;
        let mut rows = statement.query(params_from_iter(args.iter()))?;
        while let Some(row) = rows.next()? {
            let key: String = row.get(1)?;
            if !loaded.by_key.contains_key(&key) {
                loaded.add(row)?;
            }
        }
        Ok(())
    }

    // Adds the items the loaded ones are in, all the way up, so `in:` and
    // `under:` can look at them.
    fn load_up(&self, loaded: &mut Loaded) -> Result<(), Trouble> {
        let mut from = 0;
        loop {
            let missing: BTreeSet<&String> = loaded.parents[from..]
                .iter()
                .flatten()
                .filter(|p| !loaded.by_key.contains_key(*p))
                .collect();
            let missing: Vec<String> = missing.into_iter().cloned().collect();
            from = loaded.rows.len();
            if missing.is_empty() {
                break;
            }
            for keys in missing.chunks(CHUNK) {
                self.load(loaded, &format!("key IN ({})", marks(keys.len())), keys)?;
            }
        }
        Ok(())
    }

    // Adds the items the first `wanted` loaded ones hold, so `has:` can look
    // at them.
    fn load_down(&self, loaded: &mut Loaded, wanted: usize) -> Result<(), Trouble> {
        let keys = loaded.keys[..wanted].to_vec();
        for keys in keys.chunks(CHUNK) {
            self.load(loaded, &format!("parent IN ({})", marks(keys.len())), keys)?;
        }
        Ok(())
    }

    // Fills in the loaded items' fields, flags and the rows they're in.
    fn load_values(&self, loaded: &mut Loaded) -> Result<(), Trouble> {
        let at: HashMap<i64, usize> = loaded
            .ids
            .iter()
            .enumerate()
            .map(|(i, id)| (*id, i))
            .collect();
        for ids in loaded.ids.chunks(CHUNK) {
            let marks = marks(ids.len());
            let mut values = self.db.prepare_cached(&format!(
                "SELECT item, field, value FROM item_values WHERE item IN ({marks})"
            ))?;
            let mut rows = values.query(params_from_iter(ids.iter()))?;
            while let Some(row) = rows.next()? {
                let item: i64 = row.get(0)?;
                let field: String = row.get(1)?;
                let value: String = row.get(2)?;
                loaded.rows[at[&item]]
                    .fields
                    .entry(field)
                    .or_default()
                    .push(value);
            }
            let mut flags = self.db.prepare_cached(&format!(
                "SELECT item, flag FROM item_flags WHERE item IN ({marks})"
            ))?;
            let mut rows = flags.query(params_from_iter(ids.iter()))?;
            while let Some(row) = rows.next()? {
                let item: i64 = row.get(0)?;
                loaded.rows[at[&item]].flags.push(row.get(1)?);
            }
        }
        for (row, parent) in loaded.rows.iter_mut().zip(&loaded.parents) {
            row.parent = parent.as_ref().and_then(|p| loaded.by_key.get(p).copied());
        }
        Ok(())
    }
}

fn read_version(db: &Connection) -> rusqlite::Result<String> {
    db.query_row("SELECT value FROM meta WHERE key = 'version'", [], |r| {
        r.get(0)
    })
}

// Runs `sql` with `params`, its statement prepared once and kept: writing
// many items runs the same few statements many thousand times.
fn run(db: &Connection, sql: &str, params: impl rusqlite::Params) -> rusqlite::Result<usize> {
    db.prepare_cached(sql)?.execute(params)
}

// Takes the item with `key` out, with its values, flags and words.
fn forget(tx: &rusqlite::Transaction, key: &str) -> Result<(), Trouble> {
    let id: Option<i64> = tx
        .prepare_cached("SELECT id FROM items WHERE key = ?1")?
        .query_row([key], |r| r.get(0))
        .ok();
    if let Some(id) = id {
        // By rowid: field_words can't look up by item without reading all of it.
        run(
            tx,
            "DELETE FROM field_words WHERE rowid IN (SELECT rowid FROM item_values WHERE item = ?1)",
            [id],
        )?;
        run(tx, "DELETE FROM item_values WHERE item = ?1", [id])?;
        run(tx, "DELETE FROM item_flags WHERE item = ?1", [id])?;
        run(tx, "DELETE FROM words WHERE rowid = ?1", [id])?;
        run(tx, "DELETE FROM items WHERE id = ?1", [id])?;
    }
    Ok(())
}

// The ids of the items a search looks at, a page at a time, in the order
// wanted: by id, or by one date field. Newest first, it walks the field's
// values in order, then takes the items with none (they sort last, as an
// empty value does); oldest first, it sorts the candidates.
struct Candidates {
    // Each part's query, without its LIMIT and OFFSET, and its values.
    parts: Vec<(String, Vec<Value>)>,
    part: usize,
    offset: i64,
    seen: HashSet<i64>,
}

impl Candidates {
    fn new(
        condition: &str,
        args: Vec<Value>,
        by: Option<&(String, bool)>,
        walk: bool,
    ) -> Candidates {
        let parts = match by {
            None => vec![(
                format!("SELECT id FROM items WHERE {condition} ORDER BY id"),
                args,
            )],
            Some((field, true)) if walk => {
                let field = Value::Text(field.clone());
                let mut walk_args = vec![field.clone()];
                walk_args.extend(args.iter().cloned());
                // The CROSS JOIN keeps the walk over the values outside.
                let walk = (
                    format!(
                        "SELECT v.item FROM item_values v CROSS JOIN items ON items.id = v.item
                         WHERE v.field = ? AND {condition} ORDER BY v.lower DESC, v.item"
                    ),
                    walk_args,
                );
                let mut undated_args = args;
                undated_args.push(field);
                let undated = (
                    format!(
                        "SELECT id FROM items WHERE {condition} AND NOT EXISTS
                         (SELECT 1 FROM item_values WHERE item = items.id AND field = ?)
                         ORDER BY id"
                    ),
                    undated_args,
                );
                vec![walk, undated]
            }
            Some((field, descending)) => {
                // Few candidates, or oldest first: sorted as they are. No
                // value sorts as an empty one; of several, the newest or
                // oldest counts.
                let (way, pick) = if *descending {
                    ("DESC", "max")
                } else {
                    ("ASC", "min")
                };
                let mut sorted_args = args;
                sorted_args.push(Value::Text(field.clone()));
                vec![(
                    format!(
                        "SELECT id FROM items WHERE {condition} ORDER BY coalesce(
                         (SELECT {pick}(lower) FROM item_values WHERE item = items.id AND field = ?),
                         '') {way}, id"
                    ),
                    sorted_args,
                )]
            }
        };
        Candidates {
            parts,
            part: 0,
            offset: 0,
            seen: HashSet::new(),
        }
    }

    // Up to `most` more ids, none twice; none once they're all given.
    fn next(&mut self, db: &Connection, most: usize) -> Result<Vec<i64>, Trouble> {
        let mut out = Vec::new();
        while out.len() < most && self.part < self.parts.len() {
            let (sql, args) = &self.parts[self.part];
            let want = i64::try_from(most - out.len()).unwrap_or(-1);
            let mut statement = db.prepare_cached(&format!("{sql} LIMIT ? OFFSET ?"))?;
            let params = args
                .iter()
                .cloned()
                .chain([Value::Integer(want), Value::Integer(self.offset)]);
            let ids: Vec<i64> = statement
                .query_map(params_from_iter(params), |r| r.get(0))?
                .collect::<rusqlite::Result<_>>()?;
            if want < 0 || i64::try_from(ids.len()).unwrap_or(i64::MAX) < want {
                self.part += 1;
                self.offset = 0;
            } else {
                self.offset += want;
            }
            out.extend(ids.into_iter().filter(|id| self.seen.insert(*id)));
        }
        Ok(out)
    }
}

// Items read from the index, as rows, with what finds them again; their
// text only with `text`.
#[derive(Default)]
struct Loaded {
    text: bool,
    rows: Vec<Row>,
    ids: Vec<i64>,
    keys: Vec<String>,
    parents: Vec<Option<String>>,
    by_key: HashMap<String, usize>,
}

impl Loaded {
    // Puts the rows loaded so far in the order of `ids`, which are all of
    // them; nothing else is loaded yet.
    fn reorder(&mut self, ids: &[i64]) {
        let at: HashMap<i64, usize> = self
            .ids
            .iter()
            .enumerate()
            .map(|(i, id)| (*id, i))
            .collect();
        let order: Vec<usize> = ids.iter().filter_map(|id| at.get(id).copied()).collect();
        self.rows = reordered(std::mem::take(&mut self.rows), &order);
        self.ids = reordered(std::mem::take(&mut self.ids), &order);
        self.keys = reordered(std::mem::take(&mut self.keys), &order);
        self.parents = reordered(std::mem::take(&mut self.parents), &order);
        self.by_key = self
            .keys
            .iter()
            .enumerate()
            .map(|(i, k)| (k.clone(), i))
            .collect();
    }

    fn add(&mut self, row: &rusqlite::Row) -> Result<(), Trouble> {
        let key: String = row.get(1)?;
        self.by_key.insert(key.clone(), self.rows.len());
        self.ids.push(row.get(0)?);
        self.keys.push(key);
        self.parents.push(row.get(2)?);
        self.rows.push(Row {
            name: row.get(3)?,
            text: row.get(4)?,
            ..Row::default()
        });
        Ok(())
    }
}

// `items` in `order`, given as their places.
fn reordered<T>(items: Vec<T>, order: &[usize]) -> Vec<T> {
    let mut old: Vec<Option<T>> = items.into_iter().map(Some).collect();
    order.iter().filter_map(|&i| old[i].take()).collect()
}

// Whether `node` reads items' text: its words and regexes do.
fn reads_text(node: &Node) -> bool {
    node.kind == "word" || node.kind == "regex" || node.items.iter().any(reads_text)
}

// Whether `node` uses any of the fields `names` (`in:`, `under:`, `has:`).
fn uses(node: &Node, names: &[&str]) -> bool {
    let field = node.field.as_deref().map(str::to_lowercase);
    let used = node.kind == "field" && field.is_some_and(|f| names.contains(&f.as_str()));
    used || node.items.iter().any(|item| uses(item, names))
}

// `text` as an FTS5 phrase: quoted, its quotes doubled, by prefix with `*`.
fn phrase(text: &str, prefix: bool) -> String {
    let quoted = format!("\"{}\"", text.replace('"', "\"\""));
    if prefix { quoted + "*" } else { quoted }
}

// `text` for LIKE, its `%`, `_` and `\` kept as they are.
fn like(text: &str) -> String {
    text.replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_")
}

/// An SQL condition on `items` that every item matching `node` passes (and
/// maybe others: the rules in [`crate::query`] decide), its values in
/// `args`; None where SQL can't narrow it.
fn narrow(node: &Node, schema: &Schema, args: &mut Vec<Value>) -> Option<String> {
    match node.kind.as_str() {
        "and" => {
            let parts: Vec<String> = node
                .items
                .iter()
                .filter_map(|item| narrow(item, schema, args))
                .collect();
            (!parts.is_empty()).then(|| format!("({})", parts.join(" AND ")))
        }
        "or" => {
            // Every side must narrow, or none does: their values go in only
            // once all of them have.
            let mut parts = Vec::new();
            let mut values = Vec::new();
            for item in &node.items {
                parts.push(narrow(item, schema, &mut values)?);
            }
            args.extend(values);
            Some(format!("({})", parts.join(" OR ")))
        }
        "word" if !schema.anywhere => {
            let text = node.text.as_deref().unwrap_or("");
            if text.trim().is_empty() {
                return None;
            }
            args.push(Value::Text(phrase(text, node.prefix)));
            Some("id IN (SELECT rowid FROM words WHERE words MATCH ?)".into())
        }
        "field" => narrow_field(node, schema, args),
        _ => None,
    }
}

// The flags `is:VALUE` names, stored on the items; None when one of them
// is one the source works out, which the index doesn't have.
fn stored_flags(node: &Node, schema: &Schema) -> Option<Vec<String>> {
    let wanted = node.value.as_deref().unwrap_or("").to_lowercase();
    let mut flags = Vec::new();
    for (flag, from) in &schema.flags {
        if *flag == wanted || (node.prefix && flag.starts_with(&wanted)) {
            if *from == Flag::Computed {
                return None;
            }
            flags.push(flag.clone());
        }
    }
    Some(flags)
}

/// At most how many items `node` can match, counted no further than
/// `WALK`, from its terms that are cheap to count (words, flags, places,
/// whole values); None where none of them is.
fn estimate(db: &Connection, node: &Node, schema: &Schema) -> Option<i64> {
    let count = |sql: &str, args: Vec<Value>| -> Option<i64> {
        db.prepare_cached(&format!("SELECT count(*) FROM ({sql} LIMIT {WALK})"))
            .ok()?
            .query_row(params_from_iter(args), |r| r.get(0))
            .ok()
    };
    let value = node.value.as_deref().unwrap_or("");
    let op = node.op.as_deref().unwrap_or(":");
    let plain = op == ":" || op == "=";
    let whole = plain
        && !node.prefix
        && node.items.is_empty()
        && node.regex.is_none()
        && node.low.is_none()
        && node.high.is_none();
    match node.kind.as_str() {
        "and" => node
            .items
            .iter()
            .filter_map(|item| estimate(db, item, schema))
            .min(),
        "or" => node
            .items
            .iter()
            .map(|item| estimate(db, item, schema))
            .sum::<Option<i64>>()
            .map(|n| n.min(WALK)),
        "word" if !schema.anywhere => {
            let text = node.text.as_deref().unwrap_or("");
            if text.trim().is_empty() {
                return None;
            }
            count(
                "SELECT 1 FROM words WHERE words MATCH ?",
                vec![Value::Text(phrase(text, node.prefix))],
            )
        }
        "field" => {
            let name = node.field.as_deref()?.to_lowercase();
            match name.as_str() {
                "is" => {
                    let flags = stored_flags(node, schema)?;
                    let marks = marks(flags.len());
                    count(
                        &format!("SELECT 1 FROM item_flags WHERE flag IN ({marks})"),
                        flags.into_iter().map(Value::Text).collect(),
                    )
                }
                "in" if node.items.is_empty() => {
                    let folded = Value::Text(query::fold(value));
                    let held = count(
                        "SELECT 1 FROM items WHERE parent IN (SELECT key FROM items WHERE folded = ?)",
                        vec![folded.clone()],
                    )?;
                    let placed = match &schema.places {
                        Some(places) => count(
                            "SELECT 1 FROM item_values WHERE field = ? AND lower = ?",
                            vec![Value::Text(places.to_lowercase()), folded],
                        )?,
                        None => 0,
                    };
                    Some((held + placed).min(WALK))
                }
                _ if whole => match schema.fields.get(&name)? {
                    Kind::Exact => count(
                        "SELECT 1 FROM item_values WHERE field = ? AND lower = ?",
                        vec![Value::Text(name), Value::Text(query::fold(value))],
                    ),
                    Kind::Text if op == ":" && !value.trim().is_empty() => count(
                        "SELECT 1 FROM field_words WHERE field = ? AND field_words MATCH ?",
                        vec![Value::Text(name), Value::Text(phrase(value, false))],
                    ),
                    _ => None,
                },
                _ => None,
            }
        }
        _ => None,
    }
}

fn narrow_field(node: &Node, schema: &Schema, args: &mut Vec<Value>) -> Option<String> {
    let name = node.field.as_deref()?.to_lowercase();
    let value = node.value.as_deref().unwrap_or("");
    let op = node.op.as_deref().unwrap_or(":");
    match name.as_str() {
        "is" => {
            let flags = stored_flags(node, schema)?;
            if flags.is_empty() {
                return Some("0".into());
            }
            let marks = marks(flags.len());
            args.extend(flags.into_iter().map(Value::Text));
            Some(format!(
                "id IN (SELECT item FROM item_flags WHERE flag IN ({marks}))"
            ))
        }
        "in" if node.items.is_empty() => {
            let parent = "parent IN (SELECT key FROM items WHERE folded = ?)";
            let folded = query::fold(value);
            args.push(Value::Text(folded.clone()));
            let Some(places) = &schema.places else {
                return Some(parent.into());
            };
            args.push(Value::Text(places.to_lowercase()));
            args.push(Value::Text(folded));
            Some(format!(
                "({parent} OR id IN (SELECT item FROM item_values WHERE field = ? AND lower = ?))"
            ))
        }
        "in" | "under" | "has" => None,
        _ => {
            let kind = *schema.fields.get(&name)?;
            // A range of text compares in Rust (`compare::order`).
            let text_range = matches!(kind, Kind::Text | Kind::Exact)
                && (node.low.is_some() || node.high.is_some());
            if node.regex.is_some()
                || !node.items.is_empty()
                || op == "!="
                || op == "!~"
                || text_range
            {
                return None;
            }
            let (condition, values) = narrow_value(kind, node, op, value)?;
            args.push(Value::Text(name));
            args.extend(values);
            Some(condition)
        }
    }
}

// A condition on one field's values, after `field = ?`, and its values.
fn narrow_value(kind: Kind, node: &Node, op: &str, value: &str) -> Option<(String, Vec<Value>)> {
    let lower = query::fold(value);
    let pick =
        |rest: &str| format!("id IN (SELECT item FROM item_values WHERE field = ? AND {rest})");
    match kind {
        Kind::Text if op == ":" => {
            if value.trim().is_empty() {
                return None;
            }
            Some((
                "id IN (SELECT item FROM field_words WHERE field = ? AND field_words MATCH ?)"
                    .into(),
                vec![Value::Text(phrase(value, node.prefix))],
            ))
        }
        Kind::Text | Kind::Exact => match op {
            ":" | "=" if node.prefix => Some((
                pick("lower LIKE ? ESCAPE '\\'"),
                vec![Value::Text(format!("{}%", like(&lower)))],
            )),
            ":" | "=" => Some((pick("lower = ?"), vec![Value::Text(lower)])),
            "~" => Some((
                pick("lower LIKE ? ESCAPE '\\'"),
                vec![Value::Text(format!("%{}%", like(&lower)))],
            )),
            _ => None,
        },
        Kind::Date => {
            let day = "substr(value, 1, 10)";
            let from = node.from.clone().map(Value::Text);
            let to = node.to.clone().map(Value::Text);
            match op {
                ":" | "=" => {
                    let mut rest = Vec::new();
                    let mut values = Vec::new();
                    if let Some(from) = from {
                        rest.push(format!("{day} >= ?"));
                        values.push(from);
                    }
                    if let Some(to) = to {
                        rest.push(format!("{day} <= ?"));
                        values.push(to);
                    }
                    if rest.is_empty() {
                        return None;
                    }
                    Some((pick(&rest.join(" AND ")), values))
                }
                "<" => Some((pick(&format!("{day} < ?")), vec![from?])),
                "<=" => Some((pick(&format!("{day} <= ?")), vec![to?])),
                ">" => Some((pick(&format!("{day} > ?")), vec![to?])),
                ">=" => Some((pick(&format!("{day} >= ?")), vec![from?])),
                _ => None,
            }
        }
        // By the number each value was read as when written, as `compare`
        // reads them when `want` isn't a duration. A value that isn't a
        // number compares as a level or text, so it stays a candidate.
        Kind::Value => {
            let number = |text: &str| -> Option<Value> {
                (!compare::is_duration(text))
                    .then(|| compare::number(text, false))
                    .flatten()
                    .map(Value::Real)
            };
            if node.low.is_some() || node.high.is_some() {
                let mut rest = Vec::new();
                let mut values = Vec::new();
                for (end, sign) in [(&node.low, ">="), (&node.high, "<=")] {
                    if let Some(end) = end {
                        values.push(number(end)?);
                        rest.push(format!("(number {sign} ? OR number IS NULL)"));
                    }
                }
                return Some((pick(&rest.join(" AND ")), values));
            }
            let sign = match op {
                ":" | "=" => "=",
                "<" | "<=" | ">" | ">=" => op,
                _ => return None,
            };
            Some((
                pick(&format!("(number {sign} ? OR number IS NULL)")),
                vec![number(value)?],
            ))
        }
    }
}

// A match, with the values it's sorted by.
struct Match {
    key: String,
    maybe: bool,
    sort: Vec<String>,
}

// Row `at`'s first value of `field`, or nothing.
fn first_value(rows: &Rows, at: usize, field: &str) -> String {
    rows.rows[at]
        .fields
        .get(field)
        .and_then(|v| v.first())
        .cloned()
        .unwrap_or_default()
}

// `n` marks for SQL's values, "?, ?, ?".
fn marks(n: usize) -> String {
    vec!["?"; n].join(", ")
}

// Sorts `matching` as `view` says, by each match's first value of a field.
fn sort(matching: &mut [Match], schema: &Schema, view: &View) {
    if view.sort.is_empty() {
        return;
    }
    let kinds: Vec<(Option<Kind>, bool)> = view
        .sort
        .iter()
        .map(|(field, descending)| {
            (
                schema.fields.get(&field.to_lowercase()).copied(),
                *descending,
            )
        })
        .collect();
    matching.sort_by(|a, b| {
        for (i, (kind, descending)) in kinds.iter().enumerate() {
            let (x, y) = (&a.sort[i], &b.sort[i]);
            let order = match kind {
                Some(Kind::Date) => x.cmp(y),
                _ => compare::order(x, y, false),
            };
            if order.is_ne() {
                return if *descending { order.reverse() } else { order };
            }
        }
        std::cmp::Ordering::Equal
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("greed-index-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("index.db")
    }

    fn item(key: &str, text: &str) -> Item {
        Item {
            key: key.into(),
            text: text.into(),
            ..Item::default()
        }
    }

    fn word(text: &str) -> Node {
        Node {
            kind: "word".into(),
            text: Some(text.into()),
            ..Node::default()
        }
    }

    #[test]
    fn written_items_are_found_by_their_words_and_replaced_by_key() {
        let path = temp("words");
        let mut index = Index::open(&path).unwrap();
        index
            .write(&[
                item("a", "Invoice 41 for October"),
                item("b", "Weekly news, café"),
            ])
            .unwrap();
        let schema = Schema::default();
        let view = View::default();
        let found = |index: &Index, text: &str| {
            index
                .search(Some(&word(text)), &schema, &view)
                .unwrap()
                .keys
        };
        assert_eq!(found(&index, "invoice"), ["a"]);
        assert_eq!(found(&index, "invo"), Vec::<String>::new(), "whole words");
        assert_eq!(found(&index, "cafe"), ["b"], "accents folded");
        assert_eq!(found(&index, "café"), ["b"]);
        index.write(&[item("a", "Receipt")]).unwrap();
        assert_eq!(
            found(&index, "invoice"),
            Vec::<String>::new(),
            "a is replaced"
        );
        assert_eq!(found(&index, "receipt"), ["a"]);
        assert_eq!(index.count().unwrap(), 2);
        index.remove(&["a".into()]).unwrap();
        assert_eq!(index.count().unwrap(), 1);
    }

    #[test]
    fn a_fields_words_go_with_its_item() {
        let path = temp("field-words");
        let mut index = Index::open(&path).unwrap();
        // Only the title is searched by word; the note's name is matched whole.
        let titled = |key: &str, title: &str| Item {
            fields: HashMap::from([
                ("title".to_string(), vec![title.to_string()]),
                ("note".to_string(), vec![format!("{key} garden")]),
            ]),
            words: Some(vec!["Title".to_string()]),
            ..item(key, "")
        };
        index
            .write(&[titled("a", "Garden plans"), titled("b", "Garden tools")])
            .unwrap();
        let schema = Schema {
            fields: HashMap::from([("title".to_string(), Kind::Text)]),
            ..Schema::default()
        };
        let found = |index: &Index, title: &str| {
            let node = Node {
                kind: "field".into(),
                field: Some("title".into()),
                op: Some(":".into()),
                value: Some(title.into()),
                ..Node::default()
            };
            index
                .search(Some(&node), &schema, &View::default())
                .unwrap()
                .keys
        };
        assert_eq!(found(&index, "garden"), ["a", "b"]);
        index.write(&[titled("a", "Kitchen plans")]).unwrap();
        assert_eq!(found(&index, "garden"), ["b"], "a's old title is gone");
        assert_eq!(found(&index, "kitchen"), ["a"]);
        index.remove(&["b".into()]).unwrap();
        assert_eq!(found(&index, "garden"), Vec::<String>::new());
        let rows = |table: &str| -> i64 {
            index
                .db
                .query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
                .unwrap()
        };
        assert_eq!(rows("field_words"), 1);
        assert_eq!(rows("item_values"), 2);
    }

    #[test]
    fn another_program_reads_what_one_writes() {
        let path = temp("readers");
        let mut writer = Index::open(&path).unwrap();
        writer.write(&[item("a", "hello there")]).unwrap();
        let reader = Index::open_read(&path).unwrap();
        let found = reader
            .search(Some(&word("hello")), &Schema::default(), &View::default())
            .unwrap();
        assert_eq!(found.keys, ["a"]);
        writer.write(&[item("b", "hello again")]).unwrap();
        let found = reader
            .search(Some(&word("hello")), &Schema::default(), &View::default())
            .unwrap();
        assert_eq!(found.keys.len(), 2, "a reader sees later writes");
    }

    #[test]
    fn a_flag_the_source_works_out_comes_back_as_maybe_and_limit_waits() {
        let path = temp("maybe");
        let mut index = Index::open(&path).unwrap();
        index
            .write(&[item("a", "pay rent"), item("b", "pay tax")])
            .unwrap();
        let schema = Schema {
            flags: HashMap::from([("overdue".to_string(), Flag::Computed)]),
            ..Schema::default()
        };
        let node = Node {
            kind: "and".into(),
            items: vec![
                word("pay"),
                Node {
                    kind: "field".into(),
                    field: Some("is".into()),
                    op: Some(":".into()),
                    value: Some("overdue".into()),
                    ..Node::default()
                },
            ],
            ..Node::default()
        };
        let view = View {
            limit: Some(1),
            ..View::default()
        };
        let found = index.search(Some(&node), &schema, &view).unwrap();
        assert_eq!(
            found.keys,
            ["a", "b"],
            "not cut while some only might match"
        );
        assert_eq!(found.maybe, ["a", "b"]);
    }

    #[test]
    fn an_or_with_a_side_sql_cant_narrow_still_runs() {
        let path = temp("or");
        let mut index = Index::open(&path).unwrap();
        index
            .write(&[item("a", "pay rent"), item("b", "rent due")])
            .unwrap();
        let node = Node {
            kind: "and".into(),
            items: vec![
                word("rent"),
                Node {
                    kind: "or".into(),
                    items: vec![
                        word("pay"),
                        Node {
                            kind: "regex".into(),
                            text: Some("^rent".into()),
                            ..Node::default()
                        },
                    ],
                    ..Node::default()
                },
            ],
            ..Node::default()
        };
        let found = index
            .search(Some(&node), &Schema::default(), &View::default())
            .unwrap();
        assert_eq!(found.keys, ["a", "b"]);
    }

    #[test]
    fn numbers_narrow_in_sql_but_values_that_arent_numbers_stay_candidates() {
        let path = temp("numbers");
        let mut index = Index::open(&path).unwrap();
        let sized = |key: &str, size: &str, tag: &str| Item {
            key: key.into(),
            fields: HashMap::from([
                ("size".to_string(), vec![size.to_string()]),
                ("tag".to_string(), vec![tag.to_string()]),
            ]),
            ..Item::default()
        };
        index
            .write(&[
                sized("small", "3k", "apple"),
                sized("big", "2M", "kiwi"),
                sized("odd", "huge", "pear"),
            ])
            .unwrap();
        let schema = Schema {
            fields: HashMap::from([
                ("size".to_string(), Kind::Value),
                ("tag".to_string(), Kind::Exact),
            ]),
            ..Schema::default()
        };
        let field = |name: &str, op: &str, value: &str| Node {
            kind: "field".into(),
            field: Some(name.into()),
            op: Some(op.into()),
            value: Some(value.into()),
            ..Node::default()
        };
        let found = |node: &Node| {
            index
                .search(Some(node), &schema, &View::default())
                .unwrap()
                .keys
        };
        assert_eq!(
            found(&field("size", ">", "1M")),
            ["big", "odd"],
            "text sorts after numbers"
        );
        assert_eq!(found(&field("size", "<", "10k")), ["small"]);
        let range = Node {
            low: Some("b".into()),
            high: Some("l".into()),
            ..field("tag", ":", "")
        };
        assert_eq!(
            found(&range),
            ["big"],
            "a range of tags isn't narrowed to nothing"
        );
    }

    #[test]
    fn a_page_sorted_by_date_is_the_same_page_walked_or_sorted() {
        let path = temp("by-date");
        let mut index = Index::open(&path).unwrap();
        // 3000 items over many days, some on the same one, two in three
        // "often" (enough to walk to), every hundredth "seldom" (few enough
        // to sort), a few with no date at all.
        let items: Vec<Item> = (0..3000)
            .map(|i| {
                let mut fields = HashMap::new();
                if i % 97 != 0 {
                    let day = (i * 7919) % 400;
                    fields.insert(
                        "date".to_string(),
                        vec![format!(
                            "2025-{:02}-{:02}T10:00:00Z",
                            day / 31 % 12 + 1,
                            day % 28 + 1
                        )],
                    );
                }
                let mut flags = Vec::new();
                if i % 3 != 0 {
                    flags.push("often".to_string());
                }
                if i % 100 == 0 {
                    flags.push("seldom".to_string());
                }
                Item {
                    key: format!("k{i:04}"),
                    fields,
                    flags,
                    ..Item::default()
                }
            })
            .collect();
        index.write(&items).unwrap();
        let schema = Schema {
            fields: HashMap::from([("date".to_string(), Kind::Date)]),
            flags: HashMap::from([
                ("often".to_string(), Flag::Row),
                ("seldom".to_string(), Flag::Row),
            ]),
            ..Schema::default()
        };
        let is = |flag: &str| Node {
            kind: "field".into(),
            field: Some("is".into()),
            op: Some(":".into()),
            value: Some(flag.into()),
            ..Node::default()
        };
        // What a page must be: the matches sorted by date (none sorting as
        // empty), ties by order of writing, cut.
        let expected = |flag: Option<&str>, descending: bool, limit: usize| -> Vec<String> {
            let mut matching: Vec<&Item> = items
                .iter()
                .filter(|i| flag.is_none_or(|f| i.flags.iter().any(|g| g == f)))
                .collect();
            let date = |i: &Item| {
                i.fields
                    .get("date")
                    .map_or(String::new(), |d| d[0].to_lowercase())
            };
            matching.sort_by(|a, b| {
                let order = date(a).cmp(&date(b));
                if descending { order.reverse() } else { order }
            });
            matching.iter().take(limit).map(|i| i.key.clone()).collect()
        };
        for flag in [None, Some("often"), Some("seldom")] {
            for descending in [true, false] {
                for limit in [1, 50, 2000] {
                    let view = View {
                        sort: vec![("date".into(), descending)],
                        limit: Some(limit),
                    };
                    let node = flag.map(is);
                    let found = index.search(node.as_ref(), &schema, &view).unwrap();
                    assert_eq!(
                        found.keys,
                        expected(flag, descending, limit),
                        "{flag:?}, descending {descending}, limit {limit}"
                    );
                }
            }
        }
    }
}
