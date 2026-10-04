//! Greed's GUI client: a window that attaches to a session like the TUI,
//! draws its frames on the GPU and sends keys and the mouse back.

// Drawing converts between cell counts, pixels and GPU floats all the time,
// and compares colors that were copied, never computed; these casts and
// comparisons, within the size of a screen, lose nothing that matters.
#![allow(
    clippy::cast_precision_loss,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    clippy::cast_possible_wrap,
    clippy::float_cmp
)]

mod boxdraw;
mod color;
pub mod draw;
pub mod gpu;
#[cfg(target_os = "macos")]
mod menubar;
pub mod text;
mod window;

pub use color::Palette;
pub use window::run;
