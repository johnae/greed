//! Greed's editor core: buffers, history, registry, keymaps and the Luau host.

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

mod buffer;
pub mod control;
pub mod debug;
pub mod delta;
pub mod diff;
pub mod dirs;
pub mod dropped;
mod editor;
pub mod files;
mod filetypes;
mod history;
pub mod ide;
pub mod image;
pub mod keymap;
pub mod layout;
pub mod lsp;
pub mod luau;
pub mod mouse;
pub mod panics;
pub mod pdf;
pub mod project;
pub mod registry;
pub mod render;
pub mod rpc;
pub mod scene;
pub mod scene_image;
pub mod search;
pub mod server;
pub mod syntax;
pub mod terminal;
pub mod theme;

use std::fmt;

use greed_text::TxId;

pub use buffer::{
    Buffer, BufferId, Mark, MarkImage, MarkScene, Reveal, ScreenSize, TrackId, Tracked, VirtualLine,
};
pub use editor::{
    Anchor, ClientInfo, ClientLayout, ClientState, CurrentProject, CursorShape, Editor, Extent,
    FIRST_CLIENT, Float, FloatOptions, KeyOutcome, LayoutChange, LineNumbers, Notice, PEER_COLORS,
    Panel, PanelOptions, Project, ProjectId, Scroll, Side, SwitchTo, Tab, TabId, TabView, View,
    ViewId, file_path, parse_marked,
};
pub use history::{GroupState, History};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Text(greed_text::Error),
    /// A transaction was made against a version the buffer has moved past.
    StaleVersion {
        expected: Vec<TxId>,
        actual: Vec<TxId>,
    },
    /// Only plugins can change a read-only buffer.
    ReadOnly,
    /// A buffer can't close while a view shows it.
    Shown,
    /// A group can't be undone: something was done on top of it since.
    GroupChanged,
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
            Error::Shown => f.write_str("a view still shows this buffer"),
            Error::GroupChanged => {
                f.write_str("it was changed since; undo what came after it first")
            }
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Text(err) => Some(err),
            Error::StaleVersion { .. } | Error::ReadOnly | Error::Shown | Error::GroupChanged => {
                None
            }
        }
    }
}

impl From<greed_text::Error> for Error {
    fn from(err: greed_text::Error) -> Self {
        Error::Text(err)
    }
}
