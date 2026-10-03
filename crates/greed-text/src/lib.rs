//! Greed's text model: change sets, selections and transactions over a rope.
//!
//! Positions throughout are byte offsets into UTF-8 text.

mod changeset;
mod selection;
mod transaction;

use std::fmt;

pub use changeset::{Assoc, ChangeSet, Operation};
pub use ropey::Rope;
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
