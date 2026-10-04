//! The client that shows a session: the TUI in this terminal, or with
//! `--gui` (in builds with the `gui` feature) a window.

use std::sync::atomic::{AtomicBool, Ordering};

use crossbeam_channel::{Receiver, Sender};
use greed_core::server::{Input, Output};

use crate::tui;

static GUI: AtomicBool = AtomicBool::new(false);

/// Shows sessions in a window from now on, where this build can.
pub fn use_gui() -> Result<(), &'static str> {
    if cfg!(feature = "gui") {
        GUI.store(true, Ordering::Relaxed);
        Ok(())
    } else {
        Err("this greed was built without the GUI (the gui feature)")
    }
}

/// Runs the client until the session exits or lets it go, and returns how
/// it ended. Closing the window lets the session go, as `:detach` does.
pub fn run(
    input: &Sender<Input>,
    output: &Receiver<Output>,
) -> Result<Output, Box<dyn std::error::Error>> {
    #[cfg(feature = "gui")]
    if GUI.load(Ordering::Relaxed) {
        return greed_gui::run(input, output);
    }
    tui::run(input, output)
}
