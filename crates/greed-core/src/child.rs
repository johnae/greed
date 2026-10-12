//! Signals Greed passes on to the programs it starts.

use nix::sys::signal::{SaFlags, SigAction, SigHandler, SigSet, Signal, sigaction};

/// Lets the programs Greed starts take SIGINT and SIGQUIT as programs
/// usually do, even when Greed was started ignoring them, as a shell's
/// background job (`greed &`) is: a program inherits the signals its parent
/// ignores, so ctrl-c couldn't stop what Greed runs. An ignored one is
/// caught instead, by a handler that does nothing, so Greed goes on as if it
/// were ignored while the programs it starts get it back, since starting a
/// program resets caught signals. Call once, before starting threads.
#[allow(unsafe_code)]
pub fn pass_on_signals() {
    extern "C" fn nothing(_: nix::libc::c_int) {}
    let caught = SigAction::new(
        SigHandler::Handler(nothing),
        SaFlags::SA_RESTART,
        SigSet::empty(),
    );
    for which in [Signal::SIGINT, Signal::SIGQUIT] {
        // SAFETY: the handler does nothing, so it's async-signal-safe, and
        // this runs once at startup, before other threads could be handling
        // the signal. It's only kept where the signal was ignored.
        unsafe {
            if let Ok(old) = sigaction(which, &caught)
                && old.handler() != SigHandler::SigIgn
            {
                let _ = sigaction(which, &old);
            }
        }
    }
}
