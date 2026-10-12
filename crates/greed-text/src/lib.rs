//! Greed's text model: change sets, selections and transactions over a rope.
//!
//! Positions throughout are byte offsets into UTF-8 text.

// Nothing a plugin, client, agent, language server or file does may panic
// the editor: real invariants say why they hold with `expect`, the rest
// return errors. Tests may unwrap.
#![cfg_attr(
    not(test),
    warn(
        clippy::unwrap_used,
        clippy::panic,
        clippy::todo,
        clippy::unimplemented
    )
)]

mod changeset;
mod selection;
mod transaction;

use std::fmt;

pub use changeset::{Assoc, ChangeSet, Operation};
pub use ropey::{Rope, RopeSlice};
pub use selection::{Range, Selection};
pub use transaction::{AgentId, Author, ClientId, Replica, Transaction, TxId, TxMeta};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// A change set was used with a document of the wrong length.
    LengthMismatch { expected: usize, actual: usize },
    /// A position would split a UTF-8 character.
    NotCharBoundary { pos: usize },
    /// Changes were out of order or overlapped.
    OverlappingChanges { at: usize },
    /// A position was past the end of the document.
    OutOfBounds { pos: usize, len: usize },
    /// A selection must have at least one range.
    EmptySelection,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::LengthMismatch { expected, actual } => {
                write!(f, "expected a document of {expected} bytes, got {actual}")
            }
            Error::NotCharBoundary { pos } => {
                write!(f, "byte {pos} is inside a character")
            }
            Error::OverlappingChanges { at } => {
                write!(f, "changes overlap or are out of order at byte {at}")
            }
            Error::OutOfBounds { pos, len } => {
                write!(f, "byte {pos} is past the end of a {len} byte document")
            }
            Error::EmptySelection => write!(f, "a selection needs at least one range"),
        }
    }
}

impl std::error::Error for Error {}

/// The byte where `line` of `text` ends, before its line break. Lines break
/// at `\n`, `\r\n` and a lone `\r`, as compilers and language servers count
/// them.
#[must_use]
pub fn line_end(text: &Rope, line: usize) -> usize {
    let slice = text.line(line);
    let len = slice.len_bytes();
    let last = |back: usize| len.checked_sub(back).map(|i| slice.byte(i));
    let newline = match (last(2), last(1)) {
        (Some(b'\r'), Some(b'\n')) => 2,
        (_, Some(b'\n' | b'\r')) => 1,
        _ => 0,
    };
    text.line_to_byte(line) + len - newline
}

/// `line` of `text` without its line break.
#[must_use]
pub fn line_content(text: &Rope, line: usize) -> RopeSlice<'_> {
    text.byte_slice(text.line_to_byte(line)..line_end(text, line))
}
