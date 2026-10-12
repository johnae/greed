//! What a view keeps of the lines it shows, as a float filtering a log.
//!
//! A filter is words, each of which a line must have in it, without minding
//! case, or else a regex. Among the words, `key=value` looks in a line of
//! JSON (a log as JSON lines) for `value` in its field `key`, a dotted path
//! like `HelmRelease.name`; other lines must have `key=value` in their text,
//! as logfmt does. A word starting with `.`, like `.status.conditions`, keeps
//! the section of nested text under those keys (YAML, indented JSON, what
//! `kubectl describe` prints) and the keys above it; the last key matches by
//! its start, so `.status.cond` keeps the same while it's typed.

use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::ops::Range;
use std::sync::{Mutex, PoisonError};

use greed_text::Rope;
use regex_cursor::Input;
use regex_cursor::engines::meta::Regex;
use serde_json::Value;

use crate::search::{BadPattern, compile};

/// How many lines' verdicts a filter keeps before starting over.
const REMEMBERED: usize = 200_000;

#[derive(Debug)]
pub struct LineFilter {
    pub text: String,
    /// Its first `skip` lines always show, as a block's command does.
    pub skip: usize,
    regex: Option<Regex>,
    words: Vec<String>,
    fields: Vec<Field>,
    /// The keys of the section it keeps, lowercase.
    section: Vec<String>,
    /// Whether each line it has seen shows, by a hash of its text, so a log
    /// that grows has only its new lines read.
    verdicts: Mutex<HashMap<u64, bool>>,
}

/// A `key=value` word, lowercase.
#[derive(Debug)]
struct Field {
    path: Vec<String>,
    value: String,
    /// The word itself, for lines that aren't JSON.
    word: String,
}

/// Where a line is in nested text: whether it's in the section a filter
/// keeps, and the line of the key it's under.
#[derive(Debug, Clone, Copy)]
struct Place {
    inside: bool,
    parent: Option<usize>,
}

impl LineFilter {
    /// A filter of `text`, a regex with `regex`; fails on a regex that isn't
    /// one.
    pub fn new(text: &str, regex: bool, skip: usize) -> Result<Self, BadPattern> {
        let mut filter = Self {
            text: text.to_owned(),
            skip,
            regex: None,
            words: Vec::new(),
            fields: Vec::new(),
            section: Vec::new(),
            verdicts: Mutex::new(HashMap::new()),
        };
        if regex {
            filter.regex = Some(compile(text)?);
            return Ok(filter);
        }
        for word in text.split_whitespace().map(str::to_lowercase) {
            if let Some(path) = word.strip_prefix('.').filter(|p| !p.is_empty()) {
                filter.section = keys(path);
            } else if let Some((key, value)) = word.split_once('=').filter(|(k, _)| !k.is_empty()) {
                filter.fields.push(Field {
                    path: keys(key),
                    value: value.to_owned(),
                    word: word.clone(),
                });
            } else {
                filter.words.push(word);
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

    /// Whether `line` has every word in it, or the regex matches it.
    pub fn keeps(&self, line: &str) -> bool {
        if let Some(regex) = &self.regex {
            return regex.find_iter(Input::new(line)).next().is_some();
        }
        if self.words.is_empty() && self.fields.is_empty() {
            return true;
        }
        let mut hasher = std::hash::DefaultHasher::new();
        line.hash(&mut hasher);
        let hash = hasher.finish();
        let mut verdicts = self.verdicts.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(kept) = verdicts.get(&hash) {
            return *kept;
        }
        let kept = self.reads(line);
        if verdicts.len() >= REMEMBERED {
            verdicts.clear();
        }
        verdicts.insert(hash, kept);
        kept
    }

    fn reads(&self, line: &str) -> bool {
        let lower = line.to_lowercase();
        if !self.words.iter().all(|word| lower.contains(word.as_str())) {
            return false;
        }
        if self.fields.is_empty() {
            return true;
        }
        let json = if line.trim_start().starts_with('{') {
            serde_json::from_str::<Value>(line).ok()
        } else {
            None
        };
        self.fields.iter().all(|field| match &json {
            Some(value) => holds(value, &field.path, &field.value),
            None => lower.contains(field.word.as_str()),
        })
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
            let Some((indent, key)) = shape(&content) else {
                // A blank line goes with what's before it.
                let inside = places.last().is_some_and(|p: &Place| p.inside);
                places.push(Place {
                    inside,
                    parent: None,
                });
                continue;
            };
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
    let mut content = text.line(line).to_string();
    content.truncate(content.trim_end_matches(['\n', '\r']).len());
    content
}

/// How far `line` is indented, counting a list item's `- ` as indent, and
/// the key it starts with, lowercase, if any; `None` for a blank line.
fn shape(line: &str) -> Option<(usize, Option<String>)> {
    let mut rest = line.trim_start();
    if rest.is_empty() {
        return None;
    }
    let mut indent = line.len() - rest.len();
    while let Some(item) = rest.strip_prefix("- ") {
        let after = item.trim_start();
        indent += rest.len() - after.len();
        rest = after;
    }
    Some((indent, key(rest).map(str::to_lowercase)))
}

/// The key `text` starts with: `name:` or `"name":`, before a colon that
/// ends the line or has a space after it.
fn key(text: &str) -> Option<&str> {
    if let Some(quoted) = text.strip_prefix('"') {
        let (key, after) = quoted.split_once('"')?;
        return after.trim_start().starts_with(':').then_some(key);
    }
    let colon = text.match_indices(':').find_map(|(at, _)| {
        let after = &text[at + 1..];
        (after.is_empty() || after.starts_with(' ')).then_some(at)
    })?;
    let key = &text[..colon];
    (!key.is_empty() && key.len() <= 64 && !key.contains(['{', '[', '"'])).then_some(key)
}

/// Whether `value` holds `want` at `path`: in a field by that name (in any
/// case), in any item of an array on the way, as text containing it.
fn holds(value: &Value, path: &[String], want: &str) -> bool {
    let Some((first, rest)) = path.split_first() else {
        return match value {
            Value::String(text) => text.to_lowercase().contains(want),
            Value::Number(_) | Value::Bool(_) | Value::Null => value.to_string().contains(want),
            Value::Array(_) | Value::Object(_) => want.is_empty(),
        };
    };
    match value {
        Value::Object(fields) => fields
            .iter()
            .filter(|(key, _)| key.to_lowercase() == *first)
            .any(|(_, field)| holds(field, rest, want)),
        Value::Array(items) => items.iter().any(|item| holds(item, path, want)),
        Value::String(_) | Value::Number(_) | Value::Bool(_) | Value::Null => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kept(filter: &str, text: &str) -> Vec<String> {
        let filter = LineFilter::new(filter, false, 0).unwrap();
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
        assert_eq!(kept("helmrelease.name=vik", log).len(), 1);
        assert_eq!(kept("level=error down", log).len(), 1);
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
        let filter = LineFilter::new("x", false, 1).unwrap();
        let rope = Rope::from("cmd\na\nb\nx\n");
        assert_eq!(
            filter.hidden(&rope, 0..rope.len_lines(), &[2]),
            [1..2, 4..5]
        );
    }
}
