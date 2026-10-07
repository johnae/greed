//! Drives a host's jobs and timers, for tests with no event loop around it.

use std::time::{Duration, Instant};

use greed_core::Editor;
use greed_core::luau::Host;

/// Finishes jobs and fires due timers until `done` says so. Fails when no
/// job has finished for 5 seconds.
pub fn until(host: &Host, mut done: impl FnMut(&Host) -> bool) {
    let jobs = host.finished_jobs();
    loop {
        host.fire_timers(Instant::now()).unwrap();
        if done(host) {
            return;
        }
        let job = jobs
            .recv_timeout(Duration::from_secs(5))
            .expect("a job finished");
        host.finish_job(job).unwrap();
    }
}

/// Finishes jobs until `count` messages were echoed, and returns them.
pub fn messages(host: &Host, count: usize) -> Vec<String> {
    let mut got = Vec::new();
    until(host, |host| {
        got.extend(host.with_editor_mut(Editor::take_messages));
        got.len() >= count
    });
    got
}
