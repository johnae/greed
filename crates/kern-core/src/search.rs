//! Regex search over a rope, without copying the text out of it.

use std::ops::Range;

use kern_text::Rope;
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

fn compile(pattern: &str) -> Result<Regex, BadPattern> {
    Regex::new(pattern).map_err(|err| BadPattern(err.to_string()))
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
