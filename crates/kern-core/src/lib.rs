//! Kern's editor core: buffers, history, registry, keymaps and the Luau host.

mod buffer;
mod history;

use std::fmt;

use kern_text::TxId;

pub use buffer::{Buffer, BufferId};
pub use history::History;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Text(kern_text::Error),
    /// A transaction was made against a version the buffer has moved past.
    StaleVersion {
        expected: Vec<TxId>,
        actual: Vec<TxId>,
    },
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Text(err) => err.fmt(f),
            Error::StaleVersion { expected, actual } => write!(
                f,
                "edit was made against version {actual:?}, but the buffer is at {expected:?}"
            ),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Text(err) => Some(err),
            Error::StaleVersion { .. } => None,
        }
    }
}

impl From<kern_text::Error> for Error {
    fn from(err: kern_text::Error) -> Self {
        Error::Text(err)
    }
}
