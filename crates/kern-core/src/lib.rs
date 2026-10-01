//! Kern's editor core: buffers, history, registry, keymaps and the Luau host.

mod buffer;
pub mod control;
pub mod delta;
pub mod diff;
mod editor;
mod filetypes;
mod history;
pub mod ide;
pub mod keymap;
pub mod lsp;
pub mod luau;
pub mod project;
pub mod registry;
pub mod render;
pub mod search;
pub mod server;
pub mod syntax;
pub mod theme;

use std::fmt;

use kern_text::TxId;

pub use buffer::{Buffer, BufferId, Mark};
pub use editor::{
    Anchor, CursorShape, Editor, Extent, Float, FloatOptions, KeyOutcome, Panel, PanelOptions,
    Project, ProjectId, Scroll, Side, SwitchTo, View, ViewId, parse_marked,
};
pub use history::History;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Text(kern_text::Error),
    /// A transaction was made against a version the buffer has moved past.
    StaleVersion {
        expected: Vec<TxId>,
        actual: Vec<TxId>,
    },
    /// Only plugins can change a read-only buffer.
    ReadOnly,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Text(err) => err.fmt(f),
            Error::StaleVersion { expected, actual } => write!(
                f,
                "edit was made against version {actual:?}, but the buffer is at {expected:?}"
            ),
            Error::ReadOnly => f.write_str("this buffer is read-only"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Text(err) => Some(err),
            Error::StaleVersion { .. } | Error::ReadOnly => None,
        }
    }
}

impl From<kern_text::Error> for Error {
    fn from(err: kern_text::Error) -> Self {
        Error::Text(err)
    }
}
