//! Alacritty - The GPU Enhanced Terminal.
//!
//! Vendored into Kern from alacritty_terminal 0.26.0 (Apache-2.0). Kern's
//! changes: no PTY, event loop or lock of its own (Kern runs programs with
//! portable-pty).

#![warn(rust_2018_idioms, future_incompatible)]
#![deny(clippy::all, clippy::if_not_else, clippy::enum_glob_use)]
#![cfg_attr(clippy, deny(warnings))]

pub mod event;
pub mod grid;
pub mod index;
pub mod selection;
pub mod term;
pub mod vi_mode;

pub use crate::grid::Grid;
pub use crate::term::Term;
pub use vte;
