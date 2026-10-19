//! Running a parsed query over rows: which rows match it, and which might,
//! where the answer depends on a flag only the source can work out.
//!
//! The query comes parsed and checked from Luau (`core.query`), with each
//! date already read into the days it covers (`from` and `to`). What a field
//! means comes with it, in a [`Schema`]. `runtime/plugins/core/test/query_cases.json`
//! holds what every way of running a query must agree on.

use std::collections::HashMap;
use std::iter;

use regex::Regex;
use serde::Deserialize;

use crate::compare::{self, Op};

/// A part of a query, as `core.query` makes it: `kind` is "word", "field",
/// "regex", "and", "or" or "not".
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Node {
    pub kind: String,
    pub text: Option<String>,
    pub phrase: bool,
    pub prefix: bool,
    pub field: Option<String>,
    pub op: Option<String>,
    pub value: Option<String>,
    pub low: Option<String>,
    pub high: Option<String>,
    pub regex: Option<String>,
    /// For a date field: the first and last day the value covers, or a
    /// range's ends, as "YYYY-MM-DD"; either missing for an open end.
    pub from: Option<String>,
    pub to: Option<String>,
    pub items: Vec<Node>,
}

/// How a field's values match.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    /// By words.
    Text,
    /// As whole values, without minding case: tags, states, names.
    Exact,
    /// Through [`compare`]: numbers, sizes, durations, levels.
    Value,
    /// As dates, by their first ten characters ("2026-10-14").
    Date,
}

/// Where a flag comes from: stored on the rows, or worked out by the source
/// when the query runs, which this can't do (those rows are a maybe).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Flag {
    Row,
    Computed,
}

/// What a query's fields and flags mean, by their names in lower case.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Schema {
    pub fields: HashMap<String, Kind>,
    pub flags: HashMap<String, Flag>,
    /// Words match anywhere in the text, as the shell's filters do, rather
    /// than as whole words.
    pub anywhere: bool,
    /// Fields not in `fields` compare as values, from each row's own (a log
    /// line's JSON or logfmt), as the shell's filters take any field.
    pub loose: bool,
    /// Words mind case, as a search typed with a capital letter can.
    pub case: bool,
}

/// A row to match: its text for words, its fields' values, the flags it
/// has, its name (for `in:NAME`) and the row it's in, by index.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Row {
    pub text: String,
    pub fields: HashMap<String, Vec<String>>,
    pub flags: Vec<String>,
    pub name: Option<String>,
    pub parent: Option<usize>,
    /// A plain line, with no fields of its own: a loose field it hasn't
    /// matches when its text has the term in it, `key=value` as written.
    pub plain: bool,
}

/// Whether a row matches.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Answer {
    Yes,
    No,
    /// It depends on a flag the source works out.
    Maybe,
}

impl Answer {
    fn from(yes: bool) -> Answer {
        if yes { Answer::Yes } else { Answer::No }
    }

    fn not(self) -> Answer {
        match self {
            Answer::Yes => Answer::No,
            Answer::No => Answer::Yes,
            Answer::Maybe => Answer::Maybe,
        }
    }
}

/// A query that couldn't run, saying why.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bad(pub String);

/// A query ready to run over rows: its regexes compiled once.
pub struct Query {
    node: Node,
    schema: Schema,
    regexes: HashMap<String, Regex>,
}

impl Query {
    /// `node` ready to run as `schema` says; `Bad` for a regex that
    /// doesn't compile.
    pub fn new(node: Node, schema: Schema) -> Result<Query, Bad> {
        let mut regexes = HashMap::new();
        compile(&node, &mut regexes)?;
        Ok(Query {
            node,
            schema,
            regexes,
        })
    }

    /// Whether row `at` of `rows` matches.
    pub fn answer(&self, rows: &Rows, at: usize) -> Answer {
        self.matches(&self.node, rows, at)
    }

    fn matches(&self, node: &Node, rows: &Rows, at: usize) -> Answer {
        match node.kind.as_str() {
            "and" => all(node.items.iter().map(|item| self.matches(item, rows, at))),
            "or" => any(node.items.iter().map(|item| self.matches(item, rows, at))),
            "not" => node
                .items
                .first()
                .map_or(Answer::No, |item| self.matches(item, rows, at).not()),
            "word" => {
                let word = node.text.as_deref().unwrap_or("");
                let found = if self.schema.case {
                    has_word(&rows.rows[at].text, word, node.prefix, self.schema.anywhere)
                } else {
                    let word = word.to_lowercase();
                    has_word(rows.text(at), &word, node.prefix, self.schema.anywhere)
                };
                Answer::from(found)
            }
            "regex" => {
                let regex = node.text.as_deref().and_then(|p| self.regexes.get(p));
                Answer::from(regex.is_some_and(|r| r.is_match(&rows.rows[at].text)))
            }
            "field" => self.field(node, rows, at),
            _ => Answer::No,
        }
    }

    fn field(&self, node: &Node, rows: &Rows, at: usize) -> Answer {
        let name = node.field.as_deref().unwrap_or("").to_lowercase();
        match name.as_str() {
            "is" => self.flagged(node, rows, at),
            "in" | "under" => self.placed(node, rows, at, name == "under"),
            "has" => {
                let children = rows.children(at).iter();
                any(children.map(|&child| match node.items.first() {
                    Some(sub) => self.matches(sub, rows, child),
                    None => self.flagged(node, rows, child),
                }))
            }
            _ => {
                let kind = match self.schema.fields.get(&name) {
                    Some(&kind) => kind,
                    None if self.schema.loose => Kind::Value,
                    None => return Answer::No,
                };
                let row = &rows.rows[at];
                let have = row.fields.get(&name).map_or(&[][..], Vec::as_slice);
                let op = node.op.as_deref().unwrap_or(":");
                if have.is_empty() && row.plain && (op == ":" || op == "=") {
                    let term = format!(
                        "{name}{op}{}",
                        node.value.as_deref().unwrap_or("").to_lowercase()
                    );
                    return Answer::from(rows.text(at).contains(&term));
                }
                Answer::from(self.values_match(kind, node, have))
            }
        }
    }

    /// Whether row `at` is any of the flags `node` names: the one by its
    /// name, or every one it starts with a prefix.
    fn flagged(&self, node: &Node, rows: &Rows, at: usize) -> Answer {
        let name = node.value.as_deref().unwrap_or("").to_lowercase();
        let named = self
            .schema
            .flags
            .iter()
            .filter(|(flag, _)| **flag == name || (node.prefix && flag.starts_with(&name)));
        any(named.map(|(flag, from)| match from {
            Flag::Computed => Answer::Maybe,
            Flag::Row => Answer::from(
                rows.rows[at]
                    .flags
                    .iter()
                    .any(|f| f.eq_ignore_ascii_case(flag)),
            ),
        }))
    }

    /// Whether row `at` is in (or with `deep`, under) what `node` names or
    /// matches.
    fn placed(&self, node: &Node, rows: &Rows, at: usize, deep: bool) -> Answer {
        let ups = iter::successors(rows.rows[at].parent, |&parent| rows.rows[parent].parent)
            .take(if deep { usize::MAX } else { 1 });
        any(ups.map(|parent| {
            if let Some(sub) = node.items.first() {
                self.matches(sub, rows, parent)
            } else {
                let want = node.value.as_deref().unwrap_or("");
                let name = rows.rows[parent].name.as_deref();
                Answer::from(name.is_some_and(|n| n.eq_ignore_ascii_case(want)))
            }
        }))
    }

    /// Whether `have`, a field's values, pass the field term `node`. A
    /// negative test (`!=`, `!~`) passes when none of them is what it says,
    /// and when there are none.
    fn values_match(&self, kind: Kind, node: &Node, have: &[String]) -> bool {
        let op = node.op.as_deref().unwrap_or(":");
        let want = node.value.as_deref().unwrap_or("");
        if op == "!=" || op == "!~" {
            let positive = if op == "!=" { "=" } else { "~" };
            return !have.iter().any(|v| passes(kind, node, v, positive, want));
        }
        if let Some(sub) = node.items.first() {
            return within(kind, sub, have);
        }
        have.iter().any(|value| {
            if let Some(pattern) = &node.regex {
                self.regexes.get(pattern).is_some_and(|r| r.is_match(value))
            } else if kind != Kind::Date && (node.low.is_some() || node.high.is_some()) {
                node.low
                    .as_deref()
                    .is_none_or(|low| compare::order(value, low, false).is_ge())
                    && node
                        .high
                        .as_deref()
                        .is_none_or(|high| compare::order(value, high, false).is_le())
            } else {
                passes(kind, node, value, op, want)
            }
        })
    }
}

// Yes when one of `answers` is, else Maybe when one is, else No.
fn any(answers: impl Iterator<Item = Answer>) -> Answer {
    let mut answer = Answer::No;
    for got in answers {
        match got {
            Answer::Yes => return Answer::Yes,
            Answer::Maybe => answer = Answer::Maybe,
            Answer::No => {}
        }
    }
    answer
}

// No when one of `answers` is, else Maybe when one is, else Yes.
fn all(answers: impl Iterator<Item = Answer>) -> Answer {
    any(answers.map(Answer::not)).not()
}

// Compiles every regex in `node`, once each.
fn compile(node: &Node, regexes: &mut HashMap<String, Regex>) -> Result<(), Bad> {
    let pattern = if node.kind == "regex" {
        node.text.as_ref()
    } else {
        node.regex.as_ref()
    };
    if let Some(pattern) = pattern
        && !regexes.contains_key(pattern)
    {
        let regex =
            Regex::new(pattern).map_err(|e| Bad(format!("a regex that doesn't work: {e}")))?;
        regexes.insert(pattern.clone(), regex);
    }
    for item in &node.items {
        compile(item, regexes)?;
    }
    Ok(())
}

/// Whether one of a field's values passes `op` against `want`, as `kind`
/// says. A date compares with the days `node` covers.
fn passes(kind: Kind, node: &Node, have: &str, op: &str, want: &str) -> bool {
    let prefix = node.prefix;
    match kind {
        Kind::Date => {
            let day = have.get(..10).unwrap_or(have);
            let from = node.from.as_deref();
            let to = node.to.as_deref();
            match op {
                ":" | "=" => from.is_none_or(|f| day >= f) && to.is_none_or(|t| day <= t),
                "<" => from.is_some_and(|f| day < f),
                "<=" => to.is_some_and(|t| day <= t),
                ">" => to.is_some_and(|t| day > t),
                ">=" => from.is_some_and(|f| day >= f),
                _ => false,
            }
        }
        Kind::Value => {
            let op = if op == ":" { "=" } else { op };
            Op::parse(op)
                .is_some_and(|op| compare::passes(have, op, want, compare::is_duration(want)))
        }
        Kind::Text | Kind::Exact => {
            let text = have.to_lowercase();
            let wanted = want.to_lowercase();
            match op {
                ":" if kind == Kind::Text => has_word(&text, &wanted, prefix, false),
                ":" | "=" => {
                    if prefix {
                        text.starts_with(&wanted)
                    } else {
                        text == wanted
                    }
                }
                "~" => text.contains(&wanted),
                _ => Op::parse(op)
                    .is_some_and(|op| compare::passes(have, op, want, compare::is_duration(want))),
            }
        }
    }
}

/// Whether `have`, a field's values, match `node` with its words read as
/// that field's values: the inside of `tag:(garden OR kitchen)`, where
/// `tag:(work money)` wants both.
fn within(kind: Kind, node: &Node, have: &[String]) -> bool {
    match node.kind.as_str() {
        "word" => {
            let want = node.text.as_deref().unwrap_or("");
            have.iter().any(|v| passes(kind, node, v, ":", want))
        }
        "and" => node.items.iter().all(|item| within(kind, item, have)),
        "or" => node.items.iter().any(|item| within(kind, item, have)),
        "not" => !node
            .items
            .first()
            .is_some_and(|item| within(kind, item, have)),
        _ => false,
    }
}

/// Whether `text` (in lower case) has `word` (in lower case): as a whole
/// word, or one starting with it with `prefix`, or anywhere with
/// `anywhere`. Where a word starts or ends with something that isn't a
/// letter or digit ("c++"), that end matches wherever it is.
pub fn has_word(text: &str, word: &str, prefix: bool, anywhere: bool) -> bool {
    if anywhere || word.is_empty() {
        return text.contains(word);
    }
    let head = word.chars().next().is_some_and(char::is_alphanumeric);
    let tail = !prefix && word.chars().next_back().is_some_and(char::is_alphanumeric);
    text.match_indices(word).any(|(at, found)| {
        let before = text[..at].chars().next_back();
        let after = text[at + found.len()..].chars().next();
        (!head || !before.is_some_and(char::is_alphanumeric))
            && (!tail || !after.is_some_and(char::is_alphanumeric))
    })
}

/// Rows to run a query over, with their text in lower case and the rows
/// each holds, worked out once.
pub struct Rows {
    pub rows: Vec<Row>,
    lower: Vec<String>,
    children: Vec<Vec<usize>>,
}

impl Rows {
    pub fn new(rows: Vec<Row>) -> Rows {
        let lower = rows.iter().map(|r| r.text.to_lowercase()).collect();
        let mut children = vec![Vec::new(); rows.len()];
        for (i, row) in rows.iter().enumerate() {
            if let Some(parent) = row.parent
                && parent < rows.len()
            {
                children[parent].push(i);
            }
        }
        Rows {
            rows,
            lower,
            children,
        }
    }

    fn text(&self, at: usize) -> &str {
        &self.lower[at]
    }

    fn children(&self, at: usize) -> &[usize] {
        &self.children[at]
    }

    pub fn len(&self) -> usize {
        self.rows.len()
    }

    pub fn is_empty(&self) -> bool {
        self.rows.is_empty()
    }
}

/// Which of `rows` match `query` (all of them, without one), in their
/// order, and which of those only might.
pub fn run(query: Option<&Query>, rows: &Rows) -> (Vec<usize>, Vec<usize>) {
    let mut matching = Vec::new();
    let mut maybe = Vec::new();
    for at in 0..rows.len() {
        match query.map_or(Answer::Yes, |q| q.answer(rows, at)) {
            Answer::Yes => matching.push(at),
            Answer::Maybe => {
                matching.push(at);
                maybe.push(at);
            }
            Answer::No => {}
        }
    }
    (matching, maybe)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whole_words_prefixes_and_words_that_end_in_symbols() {
        assert!(has_word("pay invoice-41 now", "invoice", false, false));
        assert!(!has_word("invoices", "invoice", false, false));
        assert!(has_word("invoices", "invoice", true, false));
        assert!(has_word("tips on c++ today", "c++", false, false));
        assert!(!has_word("abc++", "c++", false, false));
        assert!(has_word("cafés", "café", true, false), "letters past ASCII");
        assert!(has_word("receipts", "eip", false, true), "anywhere");
    }

    #[test]
    fn maybe_follows_and_or_not() {
        let schema = Schema {
            flags: HashMap::from([("overdue".to_string(), Flag::Computed)]),
            ..Schema::default()
        };
        let rows = Rows::new(vec![Row {
            text: "pay rent".into(),
            ..Row::default()
        }]);
        let flag = |value: &str| Node {
            kind: "field".into(),
            field: Some("is".into()),
            op: Some(":".into()),
            value: Some(value.into()),
            ..Node::default()
        };
        let word = |text: &str| Node {
            kind: "word".into(),
            text: Some(text.into()),
            ..Node::default()
        };
        let and = Node {
            kind: "and".into(),
            items: vec![flag("overdue"), word("rent")],
            ..Node::default()
        };
        let or = Node {
            kind: "or".into(),
            items: vec![flag("overdue"), word("rent")],
            ..Node::default()
        };
        let not = Node {
            kind: "not".into(),
            items: vec![flag("overdue")],
            ..Node::default()
        };
        let answer = |node: &Node| {
            Query::new(node.clone(), schema.clone())
                .unwrap()
                .answer(&rows, 0)
        };
        assert_eq!(answer(&and), Answer::Maybe);
        assert_eq!(answer(&or), Answer::Yes, "rent decides it");
        assert_eq!(answer(&not), Answer::Maybe);
        assert_eq!(answer(&word("bills")), Answer::No);
    }

    #[test]
    fn a_regex_that_doesnt_compile_says_so() {
        let node = Node {
            kind: "regex".into(),
            text: Some("(open".into()),
            ..Node::default()
        };
        let schema = Schema::default();
        let Err(Bad(why)) = Query::new(node, schema) else {
            panic!("it compiled");
        };
        assert!(why.starts_with("a regex that doesn't work"), "{why}");
    }
}
