//! The client that shows a session: the TUI in this terminal, or with
//! `--gui` (in builds with the `gui` feature) a window.

use std::path::Path;
#[cfg(feature = "gui")]
use std::path::PathBuf;
#[cfg(feature = "gui")]
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};

use crossbeam_channel::{Receiver, Sender};
use greed_core::server::{Input, Output};

use crate::tui;

static GUI: AtomicBool = AtomicBool::new(false);

/// A recording's script and where it goes, when this client records.
#[cfg(feature = "gui")]
static RECORD: OnceLock<(greed_gui::record::Script, PathBuf)> = OnceLock::new();

/// Shows sessions in a window from now on, where this build can.
pub fn use_gui() -> Result<(), &'static str> {
    if cfg!(feature = "gui") {
        GUI.store(true, Ordering::Relaxed);
        Ok(())
    } else {
        Err("this greed was built without the GUI (the gui feature)")
    }
}

/// Records sessions from now on as the script at `path` says, drawn as
/// the window would draw them, into pictures.
pub fn use_record(path: &Path) -> Result<(), String> {
    #[cfg(feature = "gui")]
    {
        use greed_gui::record::{Script, output_of};
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("can't read {}: {e}", path.display()))?;
        let script = Script::parse(&text).map_err(|e| format!("{}: {e}", path.display()))?;
        let out = output_of(&script, path);
        record_as(script, out);
        Ok(())
    }
    #[cfg(not(feature = "gui"))]
    {
        let _ = path;
        Err("this greed was built without the GUI (the gui feature), which records".into())
    }
}

/// Records sessions from now on as `script` says, into `out`.
#[cfg(feature = "gui")]
pub fn record_as(script: greed_gui::record::Script, out: PathBuf) {
    // The session draws for a window: prose fonts, scenes as images.
    GUI.store(true, Ordering::Relaxed);
    let _ = RECORD.set((script, out));
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
    if let Some((script, out)) = RECORD.get() {
        return greed_gui::record::record(input, output, script, out);
    }
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
