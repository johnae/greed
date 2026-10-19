//! What a view keeps of the lines it shows, as a float filtering a log.
//!
//! A filter is a query `core.query` parsed (see [`greed_index::query`]),
//! or a regex. Its words are found anywhere in a line, without minding
//! case; its fields are those of a line of JSON (a log as JSON lines, by a
//! dotted path like `HelmRelease.name`, through arrays) or of logfmt, and
//! compare as a table's `where` does ([`compare`](crate::compare)): on
//! other lines `key=value` is found in the text as it's written. A section,
//! like `.status.conditions`, keeps what's under those keys in nested text
//! (YAML, indented JSON, what `kubectl describe` prints) and the keys above
//! it; the last key matches by its start, so `.status.cond` keeps the same
//! while it's typed.

use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::ops::Range;
use std::sync::{Mutex, PoisonError};

use greed_index::query::{Answer, Node, Query, Row, Rows, Schema};
use greed_text::{Rope, line_content};
use regex_cursor::Input;
use regex_cursor::engines::meta::Regex;
use serde_json::Value;

use crate::nested;
use crate::search::compile;

/// How many lines' verdicts a filter keeps before starting over.
const REMEMBERED: usize = 200_000;

/// What a filter keeps: lines a regex matches, or those a query does, in
/// the section under some keys.
pub enum Keep {
    Regex(String),
    /// The query (none keeps every line of the section), the section, its
    /// keys between dots (`status.conditions`), empty for all of the text,
    /// and whether its words mind case.
    Query(Option<Box<Node>>, String, bool),
}

pub struct LineFilter {
    /// What was typed, as `view:filter()` gives it back.
    pub text: String,
    /// Its first `skip` lines always show, as a block's command does.
    pub skip: usize,
    regex: Option<Regex>,
    query: Option<Query>,
    /// The keys of the section it keeps, lowercase.
    section: Vec<String>,
    /// Whether each line it has seen shows, by a hash of its text, so a log
    /// that grows has only its new lines read.
    verdicts: Mutex<HashMap<u64, bool>>,
}

impl std::fmt::Debug for LineFilter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LineFilter")
            .field("text", &self.text)
            .field("skip", &self.skip)
            .finish_non_exhaustive()
    }
}

/// Where a line is in nested text: whether it's in the section a filter
/// keeps, and the line of the key it's under.
#[derive(Debug, Clone, Copy)]
struct Place {
    inside: bool,
    parent: Option<usize>,
}

impl LineFilter {
    /// A filter of `text`, as typed, keeping what `keep` says; fails on a
    /// regex or a query that can't run, saying why.
    pub fn new(text: &str, keep: Keep, skip: usize) -> Result<Self, String> {
        let mut filter = Self {
            text: text.to_owned(),
            skip,
            regex: None,
            query: None,
            section: Vec::new(),
            verdicts: Mutex::new(HashMap::new()),
        };
        match keep {
            Keep::Regex(pattern) => {
                filter.regex =
                    Some(compile(&pattern).map_err(|err| format!("not a regex: {err}"))?);
            }
            Keep::Query(node, section, case) => {
                let schema = Schema {
                    anywhere: true,
                    loose: true,
                    case,
                    ..Schema::default()
                };
                filter.query = node
                    .map(|n| Query::new(*n, schema))
                    .transpose()
                    .map_err(|bad| bad.0)?;
                filter.section = keys(&section.to_lowercase());
            }
        }
        Ok(filter)
    }

    /// The ranges of lines it hides of `shown`, those of `text` a view
    /// shows; lines in `cursors` always show.
    pub fn hidden(&self, text: &Rope, shown: Range<usize>, cursors: &[usize]) -> Vec<Range<usize>> {
        let all = text.len_lines();
        let lines = (shown.start + self.skip).min(all)..shown.end.min(all);
        let places = (!self.section.is_empty()).then(|| self.places(text, lines.clone()));
        let parent = |i: usize| places.as_ref().and_then(|p| p[i].parent);
        let mut kept = vec![false; lines.len()];
        for (i, line) in lines.clone().enumerate() {
            let inside = places.as_ref().is_none_or(|p| p[i].inside);
            if cursors.contains(&line) || inside && self.keeps(&content(text, line)) {
                kept[i] = true;
                // The keys it's under show too, to say where it is. One
                // kept already has its own shown.
                let mut up = parent(i);
                while let Some(at) = up.filter(|at| !kept[*at]) {
                    kept[at] = true;
                    up = parent(at);
                }
            }
        }
        let mut runs: Vec<Range<usize>> = Vec::new();
        for (line, _) in lines.zip(kept).filter(|(_, kept)| !kept) {
            match runs.last_mut() {
                Some(run) if run.end == line => run.end = line + 1,
                _ => runs.push(line..line + 1),
            }
        }
        runs
    }

    /// Whether `line` matches the query, or the regex.
    pub fn keeps(&self, line: &str) -> bool {
        if let Some(regex) = &self.regex {
            return regex.find_iter(Input::new(line)).next().is_some();
        }
        let Some(query) = &self.query else {
            return true;
        };
        let mut hasher = std::hash::DefaultHasher::new();
        line.hash(&mut hasher);
        let hash = hasher.finish();
        let mut verdicts = self.verdicts.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(kept) = verdicts.get(&hash) {
            return *kept;
        }
        let rows = Rows::new(vec![row(line)]);
        let kept = query.answer(&rows, 0) != Answer::No;
        if verdicts.len() >= REMEMBERED {
            verdicts.clear();
        }
        verdicts.insert(hash, kept);
        kept
    }

    /// Where each of `lines` is, from how far each is indented under the
    /// keys above it.
    fn places(&self, text: &Rope, lines: Range<usize>) -> Vec<Place> {
        let mut places = Vec::with_capacity(lines.len());
        // The keys the line is under: how far each is indented, the key,
        // and its line.
        let mut above: Vec<(usize, String, usize)> = Vec::new();
        for (i, line) in lines.enumerate() {
            let content = content(text, line);
            let Some((indent, key)) = nested::shape(&content, true) else {
                // A blank line goes with what's before it.
                let inside = places.last().is_some_and(|p: &Place| p.inside);
                places.push(Place {
                    inside,
                    parent: None,
                });
                continue;
            };
            let key = key.map(str::to_lowercase);
            while above.last().is_some_and(|(at, ..)| *at >= indent) {
                above.pop();
            }
            let mut path: Vec<&str> = above.iter().map(|(_, k, _)| k.as_str()).collect();
            if let Some(key) = &key {
                path.push(key);
            }
            places.push(Place {
                inside: path.windows(self.section.len()).any(|run| self.leads(run)),
                parent: above.last().map(|(.., at)| *at),
            });
            if let Some(key) = key {
                above.push((indent, key, i));
            }
        }
        places
    }

    /// Whether keys `run` are the section's: the same, the last only starting
    /// with the section's, so `.status.cond` is `.status.conditions` while
    /// it's typed.
    fn leads(&self, run: &[&str]) -> bool {
        let Some((last, keys)) = self.section.split_last() else {
            return false;
        };
        run.len() == self.section.len()
            && run[..keys.len()] == *keys
            && run[keys.len()].starts_with(last.as_str())
    }
}

/// `path`'s keys, split at dots.
fn keys(path: &str) -> Vec<String> {
    path.split('.')
        .filter(|k| !k.is_empty())
        .map(str::to_owned)
        .collect()
}

/// `line` of `text` without its line ending.
fn content(text: &Rope, line: usize) -> String {
    line_content(text, line).to_string()
}

/// `line` as a row to match: its fields those of its JSON, by dotted paths
/// in lower case, or of its logfmt (`key=value`, the value in quotes or up
/// to the next space); a line that isn't JSON is plain, so `key=value`
/// is found in its text where it has no such field.
fn row(line: &str) -> Row {
    let mut fields = HashMap::new();
    let json = if line.trim_start().starts_with('{') {
        serde_json::from_str::<Value>(line).ok()
    } else {
        None
    };
    if let Some(value) = &json {
        flatten(value, "", &mut fields);
    } else {
        logfmt(line, &mut fields);
    }
    Row {
        text: line.to_owned(),
        fields,
        plain: json.is_none(),
        ..Row::default()
    }
}

// The fields of `value` under `path`, each by its dotted path in lower
// case, through any item of an array.
fn flatten(value: &Value, path: &str, fields: &mut HashMap<String, Vec<String>>) {
    let mut put = |text: String| fields.entry(path.to_owned()).or_default().push(text);
    match value {
        Value::Object(map) => {
            for (key, inner) in map {
                let key = key.to_lowercase();
                let path = if path.is_empty() {
                    key
                } else {
                    format!("{path}.{key}")
                };
                flatten(inner, &path, fields);
            }
        }
        Value::Array(items) => {
            for item in items {
                flatten(item, path, fields);
            }
        }
        Value::String(text) => put(text.clone()),
        Value::Number(_) | Value::Bool(_) | Value::Null => put(value.to_string()),
    }
}

// The logfmt fields of `line`: `key=value` at its start or after a space.
fn logfmt(line: &str, fields: &mut HashMap<String, Vec<String>>) {
    let mut rest = line;
    while let Some(eq) = rest.find('=') {
        let key = rest[..eq].rsplit(char::is_whitespace).next().unwrap_or("");
        let after = &rest[eq + 1..];
        let (value, next) = if let Some(quoted) = after.strip_prefix('"') {
            let end = quoted.find('"').unwrap_or(quoted.len());
            (&quoted[..end], &quoted[(end + 1).min(quoted.len())..])
        } else {
            let end = after.find(char::is_whitespace).unwrap_or(after.len());
            (&after[..end], &after[end..])
        };
        if !key.is_empty() {
            fields
                .entry(key.to_lowercase())
                .or_default()
                .push(value.to_owned());
        }
        rest = next;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::compare::Op;

    // What `core.query` parses the simple filters here into: words, fields
    // (`key=value` and the like), and a word starting with `.` the section.
    fn keep(filter: &str) -> Keep {
        let mut items = Vec::new();
        let mut section = String::new();
        for word in filter.split_whitespace() {
            if let Some(path) = word.strip_prefix('.') {
                section = path.to_owned();
            } else if let Some((at, op, len)) = Op::find(word).filter(|(at, ..)| *at > 0) {
                items.push(Node {
                    kind: "field".into(),
                    field: Some(word[..at].into()),
                    op: Some(op.sign().into()),
                    value: Some(word[at + len..].into()),
                    ..Node::default()
                });
            } else {
                items.push(Node {
                    kind: "word".into(),
                    text: Some(word.into()),
                    ..Node::default()
                });
            }
        }
        let node = match items.len() {
            0 => None,
            1 => items.pop(),
            _ => Some(Node {
                kind: "and".into(),
                items,
                ..Node::default()
            }),
        };
        Keep::Query(node.map(Box::new), section, false)
    }

    fn kept(filter: &str, text: &str) -> Vec<String> {
        let filter = LineFilter::new(filter, keep(filter), 0).unwrap();
        let rope = Rope::from(text);
        let hidden = filter.hidden(&rope, 0..rope.len_lines(), &[]);
        (0..rope.len_lines())
            .filter(|line| !hidden.iter().any(|run| run.contains(line)))
            .map(|line| content(&rope, line))
            .filter(|line| !line.is_empty())
            .collect()
    }

    #[test]
    fn words_are_all_needed_in_any_case() {
        assert_eq!(
            kept("err db", "ERR db down\nerr web\ninfo db\n"),
            ["ERR db down"]
        );
    }

    #[test]
    fn a_field_looks_in_json_lines_and_in_text_elsewhere() {
        let log = concat!(
            r#"{"level":"error","msg":"db down","HelmRelease":{"name":"vikunja"}}"#,
            "\n",
            r#"{"level":"info","msg":"error count 0"}"#,
            "\n",
            "level=error msg=plain\n",
            "level=info\n",
        );
        assert_eq!(
            kept("level=error", log),
            [
                r#"{"level":"error","msg":"db down","HelmRelease":{"name":"vikunja"}}"#,
                "level=error msg=plain",
            ]
        );
        assert_eq!(kept("helmrelease.name=vikunja", log).len(), 1);
        // `=` is the whole value; `~` has it in it.
        assert_eq!(kept("helmrelease.name=vik", log).len(), 0);
        assert_eq!(kept("helmrelease.name~vik", log).len(), 1);
        assert_eq!(kept("msg~count", log).len(), 1);
        assert_eq!(kept("msg!~count", log).len(), 3);
        assert_eq!(kept("level=error down", log).len(), 1);
    }

    #[test]
    fn a_field_compares_levels_in_their_order_and_numbers_as_numbers() {
        let log = concat!(
            r#"{"level":"debug","took":9,"msg":"a"}"#,
            "\n",
            r#"{"level":"warn","took":700,"msg":"b"}"#,
            "\n",
            "level=error took=1200 msg=c\n",
            "level=info took=30 msg=d\n",
            "no fields here\n",
        );
        let msgs = |filter: &str| -> Vec<String> {
            kept(filter, log)
                .iter()
                .map(|line| {
                    line.chars()
                        .rfind(char::is_ascii_lowercase)
                        .unwrap()
                        .to_string()
                })
                .collect()
        };
        assert_eq!(msgs("level>=warn"), ["b", "c"]);
        assert_eq!(msgs("level<info"), ["a"]);
        assert_eq!(msgs("took>500"), ["b", "c"]);
        assert_eq!(msgs("took<=30"), ["a", "d"]);
        // A line without the field isn't the value it's not.
        assert_eq!(msgs("level!=info"), ["a", "b", "c", "e"]);
    }

    #[test]
    fn a_field_looks_through_arrays() {
        let line = r#"{"items":[{"phase":"Running"},{"phase":"Failed"}]}"#;
        assert_eq!(kept("items.phase=failed", line).len(), 1);
        assert_eq!(kept("items.phase=pending", line).len(), 0);
    }

    #[test]
    fn a_section_keeps_what_is_under_its_keys_and_the_keys_above() {
        let yaml = "\
metadata:
  name: api
status:
  phase: Running
  conditions:
  - type: Ready
    status: \"True\"
  - type: PodScheduled
    status: \"True\"
  podIP: 10.0.0.1
spec:
  nodeName: n1
";
        assert_eq!(
            kept(".conditions", yaml),
            [
                "status:",
                "  conditions:",
                "  - type: Ready",
                "    status: \"True\"",
                "  - type: PodScheduled",
                "    status: \"True\"",
            ]
        );
        assert_eq!(kept(".status.phase", yaml), ["status:", "  phase: Running"]);
        // Typed so far.
        assert_eq!(kept(".status.cond", yaml), kept(".status.conditions", yaml));
        assert_eq!(
            kept(".conditions podscheduled", yaml),
            ["status:", "  conditions:", "  - type: PodScheduled"]
        );
    }

    #[test]
    fn a_section_of_indented_json_and_of_describe() {
        let json =
            "{\n    \"status\": {\n        \"phase\": \"Running\"\n    },\n    \"spec\": {}\n}\n";
        assert_eq!(
            kept(".status", json),
            ["    \"status\": {", "        \"phase\": \"Running\""]
        );
        let describe = "\
Name:         api
Conditions:
  Type              Status
  Ready             True
Volumes:
  data:
    Type:  EmptyDir
";
        assert_eq!(
            kept(".conditions", describe),
            [
                "Conditions:",
                "  Type              Status",
                "  Ready             True"
            ]
        );
    }

    #[test]
    fn the_first_lines_and_cursor_lines_always_show() {
        let filter = LineFilter::new("x", keep("x"), 1).unwrap();
        let rope = Rope::from("cmd\na\nb\nx\n");
        assert_eq!(
            filter.hidden(&rope, 0..rope.len_lines(), &[2]),
            [1..2, 4..5]
        );
    }
}
