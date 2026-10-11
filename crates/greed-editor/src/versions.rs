//! When the session greed would show runs another version of greed, the two
//! can't work together. A page says so and asks what to do (the versions
//! plugin), in a greed of its own in this terminal or window, and the
//! caller does what's picked: end the session and start one of this
//! version, open it with the version it runs, or start one beside it.

use std::path::{Path, PathBuf};

use greed_core::control::{self, Refused};
use greed_core::server::{self, Input, Output};
use serde_json::json;

use crate::ctl::State;
use crate::{client, host};

type Error = Box<dyn std::error::Error>;

/// What was picked on the page.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Choice {
    /// End the session (losing unsaved changes, if it had any) and start
    /// one of this version in its place.
    End,
    /// Open it with the greed it runs, to save work first.
    Old,
    /// Start a session of this version beside it.
    Beside,
    Cancel,
}

/// A session of another version, and what's at stake in it.
#[derive(Debug, Clone, Default)]
pub struct Stale {
    pub session: String,
    /// The machine it runs on, if not this one.
    pub host: Option<String>,
    /// The version it runs, if it said.
    pub version: Option<String>,
    pub state: State,
    /// Its project.
    pub root: Option<PathBuf>,
    /// The greed it runs, when that's here to open it with.
    pub greed: Option<PathBuf>,
}

/// The refusal in `err`, if attaching failed because the session runs
/// another version of greed.
pub fn other_version(err: &Error) -> Option<Refused> {
    let refused = err.downcast_ref::<Refused>().or_else(|| {
        err.downcast_ref::<std::io::Error>()?
            .get_ref()?
            .downcast_ref::<Refused>()
    })?;
    refused.other_version.then(|| refused.clone())
}

/// The session `name` on this machine that refused with `refused`: what's
/// unsaved and running in it, its project, and the greed it runs.
pub fn here(name: &str, refused: &Refused) -> Stale {
    let info = control::sessions()
        .unwrap_or_default()
        .into_iter()
        .find(|session| session.name == name);
    let greed = info
        .as_ref()
        .and_then(|info| info.greed.clone().or_else(|| info.pid.and_then(program_of)));
    let mine = std::env::current_exe().ok();
    Stale {
        session: name.to_owned(),
        host: None,
        version: refused.version.clone(),
        state: crate::ctl::state(name).unwrap_or_default(),
        root: info.and_then(|info| info.root),
        greed: greed.filter(|path| path.is_file() && Some(path) != mine.as_ref()),
    }
}

/// The program process `pid` runs, from `ps`, which says so on Linux and
/// macOS alike.
fn program_of(pid: u32) -> Option<PathBuf> {
    let out = std::process::Command::new("ps")
        .args(["-o", "args=", "-p", &pid.to_string()])
        .output()
        .ok()?;
    let args = String::from_utf8_lossy(&out.stdout);
    let program = args.split_whitespace().next()?;
    Path::new(program)
        .is_absolute()
        .then(|| PathBuf::from(program))
}

/// Shows the page for `stale` and gives back what was picked; cancelled if
/// the page was closed some other way.
pub fn ask(stale: &Stale) -> Result<Choice, Error> {
    let dir = std::env::temp_dir().join(format!("greed-versions-{}", std::process::id()));
    std::fs::create_dir_all(&dir)?;
    let answer = dir.join("answer");
    let info = json!({
        "session": stale.session,
        "host": stale.host,
        "theirs": stale.version,
        "ours": env!("CARGO_PKG_VERSION"),
        "unsaved": stale.state.unsaved,
        "busy": stale.state.busy,
        "old": stale.greed.is_some(),
        "answer": answer,
    });
    let code = format!("require('@versions').ask(require('@greed').json.decode([==[{info}]==]))");
    run_page("versions-page", code)?;
    let picked = std::fs::read_to_string(&answer).unwrap_or_default();
    let _ = std::fs::remove_dir_all(&dir);
    Ok(match picked.trim() {
        "end" => Choice::End,
        "old" => Choice::Old,
        "beside" => Choice::Beside,
        _ => Choice::Cancel,
    })
}

/// Shows `message`, why greed can't go on, on a page in a greed of its own:
/// the window has no terminal to say it in. Returns once it's closed.
pub fn tell(message: &str) -> Result<(), Error> {
    let quoted = serde_json::to_string(message)?;
    let code =
        format!("require('@versions').tell(require('@greed').json.decode([==[{quoted}]==]))");
    run_page("versions-error", code)
}

/// Runs `code` as the plugin `name` in a greed of its own here, until its
/// page is closed.
fn run_page(name: &'static str, code: String) -> Result<(), Error> {
    let conn = server::spawn(move || {
        let host = host("", None, None)?;
        host.load_str(name, &code)?;
        Ok(host)
    });
    // Closing the window lets the editor go, as for any other.
    if matches!(client::run(&conn.input, &conn.output)?, Output::Detached) {
        let _ = conn.input.send(Input::Quit);
    }
    conn.server.join().map_err(|_| "the editor crashed")??;
    Ok(())
}
