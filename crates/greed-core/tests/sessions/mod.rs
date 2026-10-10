//! Session sockets for tests, in a folder of the test binary's own.

use std::hash::{DefaultHasher, Hash, Hasher};

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
