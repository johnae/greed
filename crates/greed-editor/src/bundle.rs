//! Started as Greed.app on macOS: Finder runs the binary with no arguments
//! (or a `-psn_` one), from `/`, and without what the login shell sets up,
//! so language servers and tools on its PATH would be missing. Greed runs
//! again as `greed --gui` from home, with the login shell's environment.

use std::ffi::{OsStr, OsString};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::process::{Command, Stdio};

/// Runs Greed again as the app if this is the binary in an app bundle,
/// started with `args` as Finder starts it; returns only if it isn't, or
/// running it failed.
#[cfg(target_os = "macos")]
pub fn reopen_as_app(args: &[String]) -> Option<std::io::Error> {
    use std::io::IsTerminal;
    use std::os::unix::process::CommandExt;
    let me = std::env::current_exe().ok()?;
    let in_bundle = me
        .parent()
        .is_some_and(|dir| dir.ends_with("Contents/MacOS"));
    // From a terminal, as when the binary is linked onto the PATH, it's the
    // usual command line.
    let from_finder = !std::io::stdin().is_terminal();
    if !in_bundle || !from_finder || !args.iter().all(|arg| arg.starts_with("-psn_")) {
        return None;
    }
    let mut command = Command::new(&me);
    command.arg("--gui");
    if shift_held() {
        command.arg("--fresh");
    }
    if let Some(home) = std::env::var_os("HOME") {
        command.current_dir(home);
    }
    if let Some(environment) = login_environment(&me) {
        command.env_clear().envs(environment);
    }
    Some(command.exec())
}

/// Whether Shift is held now: opening an app with it held starts it without
/// what it had open, as Mac apps leave their windows closed.
#[cfg(target_os = "macos")]
fn shift_held() -> bool {
    use objc2_core_graphics::{CGEventFlags, CGEventSource, CGEventSourceStateID};
    CGEventSource::flags_state(CGEventSourceStateID::CombinedSessionState)
        .contains(CGEventFlags::MaskShift)
}

/// The environment the user's login shell sets up, read back through
/// `greed --env0` run from it; None if the shell fails. The command is
/// single-quoted, which zsh, bash, fish and nushell all read the same way.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn login_environment(me: &Path) -> Option<Vec<(OsString, OsString)>> {
    let me = me.to_str().filter(|path| !path.contains('\''))?;
    let shell = std::env::var_os("SHELL").unwrap_or_else(|| "/bin/sh".into());
    let output = Command::new(shell)
        .args(["-l", "-c", &format!("exec '{me}' --env0")])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    output.status.success().then(|| parse_env0(&output.stdout))
}

/// `NAME=value` entries, each ended by a NUL byte.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn parse_env0(bytes: &[u8]) -> Vec<(OsString, OsString)> {
    bytes
        .split(|&b| b == 0)
        .filter_map(|entry| {
            let eq = entry.iter().position(|&b| b == b'=')?;
            Some((
                OsStr::from_bytes(&entry[..eq]).to_owned(),
                OsStr::from_bytes(&entry[eq + 1..]).to_owned(),
            ))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entries_keep_newlines_and_equals_signs_in_values() {
        let parsed = parse_env0(b"A=1\0B=x=y\nz\0\0");
        assert_eq!(
            parsed,
            [("A".into(), "1".into()), ("B".into(), "x=y\nz".into())]
        );
    }
}
