//! Finding a project from a path, for the binary to decide which session a
//! folder belongs to. Plugins have their own, configurable version of this
//! in the core plugin; this one only needs to agree on the common case.

use std::path::{Path, PathBuf};

/// The longest session name made from a folder name, with room for a
/// number after it.
const MAX_NAME: usize = 32;

/// Files or folders that mark a project's root.
pub const MARKERS: [&str; 2] = [".jj", ".git"];

/// The root of the project `path` (a file or folder) is in: the nearest
/// folder up holding a marker, or the folder itself when none does.
pub fn root_of(path: &Path) -> PathBuf {
    let folder = if path.is_dir() {
        path
    } else {
        path.parent().unwrap_or(path)
    };
    folder
        .ancestors()
        .find(|dir| MARKERS.iter().any(|marker| dir.join(marker).exists()))
        .unwrap_or(folder)
        .to_owned()
}

/// A session name for a project at `root`: its folder's name in plain
/// letters, digits and dashes, with a number after it if `taken` already
/// has that name.
pub fn session_name(root: &Path, taken: &[String]) -> String {
    let base: String = root
        .file_name()
        .map(|name| name.to_string_lossy().to_lowercase())
        .unwrap_or_default()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    // Session names end up in socket paths, which are short on Unix.
    let base: String = base.trim_matches('-').chars().take(MAX_NAME - 3).collect();
    let base = base.trim_end_matches('-');
    let base = if base.is_empty() { "kern" } else { base };
    std::iter::once(base.to_owned())
        // One more name than are taken: at least one of them is free.
        .chain((2..=taken.len() + 2).map(|n| format!("{base}-{n}")))
        .find(|name| !taken.contains(name))
        .expect("one of these is free")
}
