//! Regex search: over a rope without copying the text out of it, and
//! across the files in a directory.

use std::ops::Range;
use std::path::Path;
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

use ignore::WalkState;

use greed_text::Rope;
use regex_cursor::Input;
use regex_cursor::engines::meta::Regex;

/// Which way to look from a position.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Forward,
    Backward,
}

/// Why a pattern couldn't be used, in words.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BadPattern(pub String);

impl std::fmt::Display for BadPattern {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for BadPattern {}

pub(crate) fn compile(pattern: &str) -> Result<Regex, BadPattern> {
    // The syntax error says what's wrong and where; the build error only
    // says that something is.
    Regex::new(pattern).map_err(|err| {
        BadPattern(
            err.syntax_error()
                .map_or_else(|| err.to_string(), ToString::to_string),
        )
    })
}

/// Every match of `pattern` within `range` of `text`, as byte ranges.
pub fn find_all(
    text: &Rope,
    pattern: &str,
    range: Range<usize>,
) -> Result<Vec<Range<usize>>, BadPattern> {
    let regex = compile(pattern)?;
    let end = range.end.min(text.len_bytes());
    let input = Input::new(text.slice(..)).range(range.start.min(end)..end);
    Ok(regex.find_iter(input).map(|m| m.start()..m.end()).collect())
}

/// Every match of `pattern` within `range` of `text` with its groups: the
/// whole match first, then each group, `None` where one took no part.
pub fn find_all_groups(
    text: &Rope,
    pattern: &str,
    range: Range<usize>,
) -> Result<Vec<Vec<Option<Range<usize>>>>, BadPattern> {
    let regex = compile(pattern)?;
    let end = range.end.min(text.len_bytes());
    let input = Input::new(text.slice(..)).range(range.start.min(end)..end);
    Ok(regex
        .captures_iter(input)
        .map(|caps| {
            (0..caps.group_len())
                .map(|i| caps.get_group(i).map(|span| span.start..span.end))
                .collect()
        })
        .collect())
}

/// The first match starting at or after `from`, or the last one starting
/// before it, going round the other end of the text with `wrap`.
pub fn find(
    text: &Rope,
    pattern: &str,
    from: usize,
    direction: Direction,
    wrap: bool,
) -> Result<Option<Range<usize>>, BadPattern> {
    let all = find_all(text, pattern, 0..text.len_bytes())?;
    let found = match direction {
        Direction::Forward => all
            .iter()
            .find(|m| m.start >= from)
            .or(all.first().filter(|_| wrap)),
        Direction::Backward => all
            .iter()
            .rev()
            .find(|m| m.start < from)
            .or(all.last().filter(|_| wrap)),
    };
    Ok(found.cloned())
}

/// A line of a file with matches on it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LineMatch {
    /// Relative to the directory searched.
    pub path: String,
    /// 0-based.
    pub line: usize,
    /// The line, without its line break.
    pub text: String,
    /// Byte ranges in `text`.
    pub matches: Vec<Range<usize>>,
}

/// What to search with [`grep`].
#[derive(Debug, Clone, Copy)]
pub struct GrepOptions {
    /// Search hidden files too.
    pub hidden: bool,
    /// Search files `.gitignore` and the like exclude too.
    pub ignored: bool,
    /// Stop after this many lines.
    pub limit: usize,
}

/// Files bigger than this aren't searched.
const MAX_GREP_FILE: u64 = 8 * 1024 * 1024;

/// The lines matching `pattern` in the text files under `dir`, sorted by
/// path and line. Binary files, ones that aren't UTF-8 and very big ones
/// are skipped. Files are searched in parallel.
pub fn grep(dir: &Path, pattern: &str, options: GrepOptions) -> Result<Vec<LineMatch>, BadPattern> {
    let regex = compile(pattern)?;
    let found = Mutex::new(Vec::new());
    let count = AtomicUsize::new(0);
    ignore::WalkBuilder::new(dir)
        .hidden(!options.hidden)
        .git_ignore(!options.ignored)
        .git_exclude(!options.ignored)
        .git_global(!options.ignored)
        .ignore(!options.ignored)
        .parents(!options.ignored)
        .require_git(false)
        .build_parallel()
        .run(|| {
            Box::new(|entry| {
                if count.load(Ordering::Relaxed) >= options.limit {
                    return WalkState::Quit;
                }
                let Ok(entry) = entry else {
                    return WalkState::Continue;
                };
                let is_small_file = entry.file_type().is_some_and(|t| t.is_file())
                    && entry.metadata().is_ok_and(|m| m.len() <= MAX_GREP_FILE);
                if !is_small_file {
                    return WalkState::Continue;
                }
                let Some(text) = std::fs::read(entry.path())
                    .ok()
                    .filter(|bytes| !bytes.contains(&0))
                    .and_then(|bytes| String::from_utf8(bytes).ok())
                else {
                    return WalkState::Continue;
                };
                let path = entry.path().strip_prefix(dir).unwrap_or(entry.path());
                let lines = grep_text(&regex, &path.to_string_lossy(), &text);
                if !lines.is_empty() {
                    count.fetch_add(lines.len(), Ordering::Relaxed);
                    found.lock().expect("no panics while held").extend(lines);
                }
                WalkState::Continue
            })
        });
    let mut found = found.into_inner().expect("no panics while held");
    found.sort_by(|a, b| (&a.path, a.line).cmp(&(&b.path, b.line)));
    found.truncate(options.limit);
    Ok(found)
}

/// The lines of `text` that `regex` matches.
fn grep_text(regex: &Regex, path: &str, text: &str) -> Vec<LineMatch> {
    text.lines()
        .enumerate()
        .filter_map(|(line, content)| {
            let matches: Vec<_> = regex
                .find_iter(Input::new(content))
                .filter(|m| !m.is_empty())
                .map(|m| m.start()..m.end())
                .collect();
            (!matches.is_empty()).then(|| LineMatch {
                path: path.to_owned(),
                line,
                text: content.to_owned(),
                matches,
            })
        })
        .collect()
}
