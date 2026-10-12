//! Session sockets for tests, in a folder of the test binary's own.

use std::hash::{DefaultHasher, Hash, Hasher};
use std::path::{Path, PathBuf};

/// Keeps this test binary's sessions in a temporary folder of its own, so
/// tests never touch the user's running sessions or another checkout's
/// tests. Call it before anything that starts or looks for a session.
pub fn private() {
    // Named after the binary, so runs of it share one folder (session names
    // carry the process id) instead of leaving a folder each.
    let mut hasher = DefaultHasher::new();
    std::env::current_exe().unwrap().hash(&mut hasher);
    greed_core::control::use_sessions_dir(
        greed_core::control::socket_temp_dir()
            .join(format!("greed-sessions-{:x}", hasher.finish())),
    );
}

/// The default plugins, core first, as `greed` loads them.
#[allow(dead_code, reason = "not every test binary loads plugins")]
pub fn default_plugins() -> Vec<PathBuf> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../runtime/plugins");
    let mut dirs: Vec<PathBuf> = std::fs::read_dir(root)
        .unwrap()
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .filter(|path| path.join("plugin.toml").is_file())
        .collect();
    dirs.sort_by_key(|path| (path.file_name() != Some("core".as_ref()), path.clone()));
    dirs
}
