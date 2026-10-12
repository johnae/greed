//! Drives a host's jobs and timers, for tests with no event loop around it.

use std::time::{Duration, Instant};

use greed_core::Editor;
use greed_core::luau::Host;

/// Finishes jobs and fires timers as they come due until `done` says so.
/// Fails when neither a job finished nor a timer fired for 5 seconds.
pub fn until(host: &Host, mut done: impl FnMut(&Host) -> bool) {
    const QUIET: Duration = Duration::from_secs(5);
    let jobs = host.finished_jobs();
    let mut heard = Instant::now();
    loop {
        let now = Instant::now();
        if host.next_timer().is_some_and(|at| at <= now) {
            heard = now;
        }
        host.fire_timers(now).unwrap();
        if done(host) {
            return;
        }
        let wait = host
            .next_timer()
            .map_or(QUIET, |at| at.saturating_duration_since(Instant::now()))
            .min(QUIET);
        if let Ok(job) = jobs.recv_timeout(wait) {
            host.finish_job(job).unwrap();
            heard = Instant::now();
        }
        assert!(heard.elapsed() < QUIET, "a job finished or a timer fired");
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
