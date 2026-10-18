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

/// A walk over the files under `dir`, in parallel, leaving out hidden ones
/// and those `.gitignore` and the like exclude unless told to keep them.
fn walker(dir: &Path, hidden: bool, ignored: bool) -> ignore::WalkParallel {
    ignore::WalkBuilder::new(dir)
        .hidden(!hidden)
        .git_ignore(!ignored)
        .git_exclude(!ignored)
        .git_global(!ignored)
        .ignore(!ignored)
        .parents(!ignored)
        .require_git(false)
        .build_parallel()
}

/// The file at `path` as text, unless it's binary or isn't UTF-8.
fn text_of(path: &Path) -> Option<String> {
    std::fs::read(path)
        .ok()
        .filter(|bytes| !bytes.contains(&0))
        .and_then(|bytes| String::from_utf8(bytes).ok())
}

/// A file [`scan`] found: its path from the folder scanned, its size, when
/// it was last written (seconds since 1970) and, when asked for, its text.
#[derive(Debug, Clone, PartialEq)]
pub struct Scanned {
    pub path: String,
    pub size: u64,
    pub modified: f64,
    pub text: Option<String>,
}

/// What [`scan`] looks at and reads.
#[derive(Debug, Clone, Default)]
pub struct ScanOptions {
    /// Look at hidden files too.
    pub hidden: bool,
    /// Look at files `.gitignore` and the like exclude too.
    pub ignored: bool,
    /// Only files with this extension, like "md".
    pub ext: Option<String>,
    /// Read each file's text too (not binary or very big ones).
    pub read: bool,
}

/// The files under `dir`, sorted by path, with their sizes and when they
/// were last written, and their text with `read`. Folders are walked in
/// parallel.
pub fn scan(dir: &Path, options: &ScanOptions) -> Vec<Scanned> {
    let found = Mutex::new(Vec::new());
    walker(dir, options.hidden, options.ignored).run(|| {
        Box::new(|entry| {
            let Ok(entry) = entry else {
                return WalkState::Continue;
            };
            let wanted = entry.file_type().is_some_and(|t| t.is_file())
                && options
                    .ext
                    .as_deref()
                    .is_none_or(|ext| entry.path().extension().is_some_and(|e| e == ext));
            let Some(meta) = entry.metadata().ok().filter(|_| wanted) else {
                return WalkState::Continue;
            };
            let modified = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map_or(0.0, |d| d.as_secs_f64());
            let text = (options.read && meta.len() <= MAX_GREP_FILE)
                .then(|| text_of(entry.path()))
                .flatten();
            let path = entry.path().strip_prefix(dir).unwrap_or(entry.path());
            found.lock().expect("no panics while held").push(Scanned {
                path: path.to_string_lossy().into_owned(),
                size: meta.len(),
                modified,
                text,
            });
            WalkState::Continue
        })
    });
    let mut found = found.into_inner().expect("no panics while held");
    found.sort_by(|a, b| a.path.cmp(&b.path));
    found
}

/// The lines matching `pattern` in the text files under `dir`, sorted by
/// path and line. Binary files, ones that aren't UTF-8 and very big ones
/// are skipped. Files are searched in parallel.
pub fn grep(dir: &Path, pattern: &str, options: GrepOptions) -> Result<Vec<LineMatch>, BadPattern> {
    let regex = compile(pattern)?;
    let found = Mutex::new(Vec::new());
    let count = AtomicUsize::new(0);
    walker(dir, options.hidden, options.ignored).run(|| {
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
            let Some(text) = text_of(entry.path()) else {
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
