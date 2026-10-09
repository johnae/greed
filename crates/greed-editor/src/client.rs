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

/// What sort of client this is, as it tells the session when attaching:
/// "gui" for a window, "tui" otherwise.
pub fn kind() -> &'static str {
    if GUI.load(Ordering::Relaxed) {
        "gui"
    } else {
        "tui"
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
        // The window opens at the size it last had.
        let size_file = crate::runtime::cache_dir().and_then(|dir| {
            std::fs::create_dir_all(&dir).ok()?;
            Some(dir.join("window-size"))
        });
        return greed_gui::run(input, output, size_file.as_deref());
    }
    tui::run(input, output)
}
