//! An index on SQLite: items with a key, the item they're in, a name, text,
//! fields and flags, kept in one file that one program writes and any
//! number read. Searching narrows with SQL (words through FTS5), then the
//! same rules as rows in memory ([`crate::query`]) decide, over the items
//! SQL found, so an index and a list in memory can't disagree.

use std::collections::{BTreeSet, HashMap};
use std::path::Path;

use rusqlite::{Connection, OpenFlags, params_from_iter, types::Value};

use crate::compare;
use crate::query::{self, Answer, Flag, Kind, Node, Query, Row, Rows, Schema};

/// The version of the tables; an index made by another is made again.
const VERSION: &str = "3";

/// How many candidates are loaded and checked at a time.
const CHUNK: usize = 1000;

const SELECT_ITEMS: &str = "SELECT id, key, parent, name, text FROM items";

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
            tx.execute(
                "INSERT INTO words (rowid, text) VALUES (?1, ?2)",
                (id, &item.text),
            )?;
            for (field, values) in &item.fields {
                let field = field.to_lowercase();
                for value in values {
                    tx.execute(
                        "INSERT INTO item_values (item, field, value, lower, number) VALUES (?1, ?2, ?3, ?4, ?5)",
                        (id, &field, value, query::fold(value), compare::number(value, false)),
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
        let compiled = node
            .map(|n| Query::new(n.clone(), schema.clone()))
            .transpose()?;
        let mut args: Vec<Value> = Vec::new();
        let narrowed = node.and_then(|n| narrow(n, schema, &mut args));
        let sql = format!(
            "SELECT id FROM items WHERE {} ORDER BY id",
            narrowed.as_deref().unwrap_or("1")
        );
        let ids: Vec<i64> = {
            let mut statement = self.db.prepare(&sql)?;
            let found = statement.query_map(params_from_iter(args.iter()), |r| r.get(0))?;
            found.collect::<rusqlite::Result<_>>()?
        };
        // What the items are in, for `in:` and `under:`, and what they hold,
        // for `has:`.
        let up = node.is_some_and(|n| uses(n, &["in", "under"]));
        let down = node.is_some_and(|n| uses(n, &["has"]));
        let by: Vec<String> = view.sort.iter().map(|(f, _)| f.to_lowercase()).collect();
        // A limit without a sort stops once enough have matched, unless some
        // only might.
        let early = if by.is_empty() { view.limit } else { None };
        let mut matching: Vec<Match> = Vec::new();
        let mut any_maybe = false;
        for chunk in ids.chunks(CHUNK) {
            let mut loaded = Loaded::default();
            self.load(
                &mut loaded,
                &format!("id IN ({})", marks(chunk.len())),
                chunk,
            )?;
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
                let answer = compiled
                    .as_ref()
                    .map_or(Answer::Yes, |q| q.answer(&rows, at));
                if answer == Answer::No {
                    continue;
                }
                let maybe = answer == Answer::Maybe;
                any_maybe |= maybe;
                matching.push(Match {
                    key: loaded.keys[at].clone(),
                    maybe,
                    sort: by.iter().map(|f| first_value(&rows, at, f)).collect(),
                });
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

    // Loads the items `condition` picks, with `args` for its marks.
    fn load<T: rusqlite::ToSql>(
        &self,
        loaded: &mut Loaded,
        condition: &str,
        args: &[T],
    ) -> Result<(), Trouble> {
        let mut statement = self
            .db
            .prepare_cached(&format!("{SELECT_ITEMS} WHERE {condition} ORDER BY id"))?;
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
}
