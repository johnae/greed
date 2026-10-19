//! An index on SQLite: items with a key, the item they're in, a name, text,
//! fields and flags, kept in one file that one program writes and any
//! number read. Searching narrows with SQL (words through FTS5), then the
//! same rules as rows in memory ([`crate::query`]) decide, over the items
//! SQL found, so an index and a list in memory can't disagree.

use std::collections::HashMap;
use std::path::Path;

use rusqlite::{Connection, OpenFlags, params_from_iter, types::Value};

use crate::compare;
use crate::query::{self, Answer, Flag, Kind, Node, Query, Row, Rows, Schema};

/// The version of the tables; an index made by another is made again.
const VERSION: &str = "1";

const SELECT_ITEMS: &str = "SELECT id, key, parent, name, text FROM items";

const TABLES: &str = "
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS items (
    id INTEGER PRIMARY KEY,
    key TEXT NOT NULL UNIQUE,
    parent TEXT,
    name TEXT,
    text TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS items_parent ON items (parent);
CREATE INDEX IF NOT EXISTS items_name ON items (lower(name));
CREATE TABLE IF NOT EXISTS item_values (
    item INTEGER NOT NULL,
    field TEXT NOT NULL,
    value TEXT NOT NULL,
    lower TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS values_field ON item_values (field, lower);
CREATE INDEX IF NOT EXISTS values_item ON item_values (item);
CREATE TABLE IF NOT EXISTS item_flags (item INTEGER NOT NULL, flag TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS flags_flag ON item_flags (flag);
CREATE INDEX IF NOT EXISTS flags_item ON item_flags (item);
CREATE VIRTUAL TABLE IF NOT EXISTS words USING fts5 (
    text, tokenize = 'unicode61 remove_diacritics 2'
);
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
/// values by name and its flags.
#[derive(Debug, Clone, Default)]
pub struct Item {
    pub key: String,
    pub parent: Option<String>,
    pub name: Option<String>,
    pub text: String,
    pub fields: HashMap<String, Vec<String>>,
    pub flags: Vec<String>,
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
            tx.execute(
                "INSERT INTO items (key, parent, name, text) VALUES (?1, ?2, ?3, ?4)",
                (&item.key, &item.parent, &item.name, &item.text),
            )?;
            let id = tx.last_insert_rowid();
            tx.execute(
                "INSERT INTO words (rowid, text) VALUES (?1, ?2)",
                (id, &item.text),
            )?;
            for (field, values) in &item.fields {
                let field = field.to_lowercase();
                for value in values {
                    tx.execute(
                        "INSERT INTO item_values (item, field, value, lower) VALUES (?1, ?2, ?3, ?4)",
                        (id, &field, value, value.to_lowercase()),
                    )?;
                    tx.execute(
                        "INSERT INTO field_words (value, field, item) VALUES (?1, ?2, ?3)",
                        (value, &field, id),
                    )?;
                }
            }
            for flag in &item.flags {
                tx.execute(
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
        let compiled = node.map(|n| Query::new(n, schema)).transpose()?;
        let mut args: Vec<Value> = Vec::new();
        let narrowed = node.and_then(|n| narrow(n, schema, &mut args));
        let sql = format!(
            "{SELECT_ITEMS} WHERE {}",
            narrowed.as_deref().unwrap_or("1")
        );
        let mut loaded = Loaded::default();
        {
            let mut statement = self.db.prepare(&sql)?;
            let mut rows = statement.query(params_from_iter(args.iter()))?;
            while let Some(row) = rows.next()? {
                loaded.add(row)?;
            }
        }
        let wanted = loaded.ids.len();
        if node.is_some_and(uses_places) {
            self.load_around(&mut loaded)?;
        }
        self.load_values(&mut loaded)?;
        let rows = Rows::new(std::mem::take(&mut loaded.rows));
        let mut matching: Vec<(usize, bool)> = Vec::new();
        for at in 0..wanted {
            match compiled
                .as_ref()
                .map_or(Answer::Yes, |q| q.answer(&rows, at))
            {
                Answer::Yes => matching.push((at, false)),
                Answer::Maybe => matching.push((at, true)),
                Answer::No => {}
            }
        }
        sort(&mut matching, &rows, schema, view);
        let any_maybe = matching.iter().any(|(_, maybe)| *maybe);
        if let Some(limit) = view.limit
            && !any_maybe
        {
            matching.truncate(limit);
        }
        let key = |&(at, _): &(usize, bool)| loaded.keys[at].clone();
        Ok(Found {
            keys: matching.iter().map(key).collect(),
            maybe: matching
                .iter()
                .filter(|(_, maybe)| *maybe)
                .map(key)
                .collect(),
        })
    }

    // Adds the items the loaded ones are in, all the way up, and those they
    // hold, so `in:`, `under:` and `has:` can look at them.
    fn load_around(&self, loaded: &mut Loaded) -> Result<(), Trouble> {
        let mut statement = self.db.prepare(&format!("{SELECT_ITEMS} WHERE key = ?1"))?;
        let mut at = 0;
        while at < loaded.rows.len() {
            if let Some(parent) = loaded.parents[at].clone()
                && !loaded.by_key.contains_key(&parent)
            {
                let mut rows = statement.query([&parent])?;
                if let Some(row) = rows.next()? {
                    loaded.add(row)?;
                }
            }
            at += 1;
        }
        let keys: Vec<String> = loaded.keys.clone();
        let mut children = self
            .db
            .prepare(&format!("{SELECT_ITEMS} WHERE parent = ?1"))?;
        for key in keys {
            let mut rows = children.query([&key])?;
            while let Some(row) = rows.next()? {
                let child: String = row.get(1)?;
                if !loaded.by_key.contains_key(&child) {
                    loaded.add(row)?;
                }
            }
        }
        Ok(())
    }

    // Fills in the loaded items' fields, flags and the rows they're in.
    fn load_values(&self, loaded: &mut Loaded) -> Result<(), Trouble> {
        let mut values = self
            .db
            .prepare("SELECT field, value FROM item_values WHERE item = ?1")?;
        let mut flags = self
            .db
            .prepare("SELECT flag FROM item_flags WHERE item = ?1")?;
        for at in 0..loaded.rows.len() {
            let id = loaded.ids[at];
            let mut rows = values.query([id])?;
            while let Some(row) = rows.next()? {
                let field: String = row.get(0)?;
                let value: String = row.get(1)?;
                loaded.rows[at].fields.entry(field).or_default().push(value);
            }
            let mut rows = flags.query([id])?;
            while let Some(row) = rows.next()? {
                loaded.rows[at].flags.push(row.get(0)?);
            }
            loaded.rows[at].parent = loaded.parents[at]
                .as_ref()
                .and_then(|p| loaded.by_key.get(p).copied());
        }
        Ok(())
    }
}

fn read_version(db: &Connection) -> rusqlite::Result<String> {
    db.query_row("SELECT value FROM meta WHERE key = 'version'", [], |r| {
        r.get(0)
    })
}

// Takes the item with `key` out, with its values, flags and words.
fn forget(tx: &rusqlite::Transaction, key: &str) -> Result<(), Trouble> {
    let id: Option<i64> = tx
        .query_row("SELECT id FROM items WHERE key = ?1", [key], |r| r.get(0))
        .ok();
    if let Some(id) = id {
        tx.execute("DELETE FROM item_values WHERE item = ?1", [id])?;
        tx.execute("DELETE FROM item_flags WHERE item = ?1", [id])?;
        tx.execute("DELETE FROM field_words WHERE item = ?1", [id])?;
        tx.execute("DELETE FROM words WHERE rowid = ?1", [id])?;
        tx.execute("DELETE FROM items WHERE id = ?1", [id])?;
    }
    Ok(())
}

// Items read from the index, as rows, with what finds them again.
#[derive(Default)]
struct Loaded {
    rows: Vec<Row>,
    ids: Vec<i64>,
    keys: Vec<String>,
    parents: Vec<Option<String>>,
    by_key: HashMap<String, usize>,
}

impl Loaded {
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

// Whether `node` looks at where items are: `in:`, `under:` or `has:`.
fn uses_places(node: &Node) -> bool {
    let place = node.kind == "field"
        && matches!(
            node.field.as_deref().map(str::to_lowercase).as_deref(),
            Some("in" | "under" | "has")
        );
    place || node.items.iter().any(uses_places)
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

fn narrow_field(node: &Node, schema: &Schema, args: &mut Vec<Value>) -> Option<String> {
    let name = node.field.as_deref()?.to_lowercase();
    let value = node.value.as_deref().unwrap_or("");
    let op = node.op.as_deref().unwrap_or(":");
    match name.as_str() {
        "is" => {
            let wanted = value.to_lowercase();
            let mut flags = Vec::new();
            for (flag, from) in &schema.flags {
                if *flag == wanted || (node.prefix && flag.starts_with(&wanted)) {
                    if *from == Flag::Computed {
                        return None;
                    }
                    flags.push(flag.clone());
                }
            }
            if flags.is_empty() {
                return Some("0".into());
            }
            let marks = vec!["?"; flags.len()].join(", ");
            args.extend(flags.into_iter().map(Value::Text));
            Some(format!(
                "id IN (SELECT item FROM item_flags WHERE flag IN ({marks}))"
            ))
        }
        "in" if node.items.is_empty() => {
            args.push(Value::Text(value.to_lowercase()));
            Some("parent IN (SELECT key FROM items WHERE lower(name) = ?)".into())
        }
        "in" | "under" | "has" => None,
        _ => {
            let kind = *schema.fields.get(&name)?;
            if node.regex.is_some() || !node.items.is_empty() || op == "!=" || op == "!~" {
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
    let lower = value.to_lowercase();
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
        // Numbers, sizes and levels compare in Rust (`compare`), not SQL.
        Kind::Value => None,
    }
}

// Sorts `matching` as `view` says, by each row's first value of a field.
fn sort(matching: &mut [(usize, bool)], rows: &Rows, schema: &Schema, view: &View) {
    if view.sort.is_empty() {
        return;
    }
    let by: Vec<(String, bool)> = view
        .sort
        .iter()
        .map(|(field, descending)| (field.to_lowercase(), *descending))
        .collect();
    let first = |at: usize, field: &str| -> &str {
        rows.rows[at]
            .fields
            .get(field)
            .and_then(|v| v.first())
            .map_or("", String::as_str)
    };
    matching.sort_by(|(a, _), (b, _)| {
        for (field, descending) in &by {
            let (x, y) = (first(*a, field), first(*b, field));
            let order = match schema.fields.get(field) {
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
        assert_eq!(
            found(&index, "cafe"),
            Vec::<String>::new(),
            "the rules decide: no folding yet"
        );
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
}
