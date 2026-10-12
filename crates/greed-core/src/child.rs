//! Starting programs: what every program Greed starts gets.

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

/// How Greed starts a program: `argv`'s first word, with the rest as its
/// arguments, in `cwd`, with `env` set (`None` leaves a variable out of
/// what it inherits), and with `group` in a process group of its own, so a
/// signal reaches what it starts too. Its input and output are the
/// caller's to set.
pub fn command<S: AsRef<std::ffi::OsStr>>(
    argv: &[S],
    cwd: Option<&std::path::Path>,
    env: &[(String, Option<String>)],
    group: bool,
) -> std::io::Result<std::process::Command> {
    use std::os::unix::process::CommandExt;
    let (program, rest) = argv
        .split_first()
        .ok_or_else(|| std::io::Error::other("an empty command line"))?;
    let mut command = std::process::Command::new(program);
    command.args(rest);
    for (name, value) in env {
        match value {
            Some(value) => command.env(name, value),
            None => command.env_remove(name),
        };
    }
    if let Some(cwd) = cwd {
        command.current_dir(cwd);
    }
    if group {
        command.process_group(0);
    }
    Ok(command)
}

/// Why `program` didn't start, naming it.
pub fn cant_run(program: impl std::fmt::Display, err: &std::io::Error) -> std::io::Error {
    std::io::Error::new(err.kind(), format!("can't run {program}: {err}"))
}
