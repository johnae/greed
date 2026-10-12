//! Debug lines: what the editor, its clients and plugins say about what
//! they're doing, kept while their topic is on, for `:debug-log`, `greed
//! ctl debug_log` and agents to read. A topic that's off costs one atomic
//! load where its lines would be said; nothing is formatted.
//!
//! Topics: `keys` (each key, what it ran, how long it waited), `runs`
//! (every run of plugin code, with its plugin and time), `frames` (each
//! frame built for a client, how long it took), `rpc` (messages with
//! language servers and other JSON-RPC programs), `jobs` (programs run),
//! `client` (the terminal's or window's side: keys as they came and how
//! long drawing took) and `plugins` (`greed.debug.log` from every plugin,
//! or `plugin:NAME` for one).

use std::collections::{BTreeSet, VecDeque};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::Instant;

/// What a line is about. Each is a bit in [`ON`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Topic {
    Keys,
    Runs,
    Frames,
    Rpc,
    Jobs,
    Client,
    Plugins,
}

impl Topic {
    pub const ALL: [Topic; 7] = [
        Topic::Keys,
        Topic::Runs,
        Topic::Frames,
        Topic::Rpc,
        Topic::Jobs,
        Topic::Client,
        Topic::Plugins,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Topic::Keys => "keys",
            Topic::Runs => "runs",
            Topic::Frames => "frames",
            Topic::Rpc => "rpc",
            Topic::Jobs => "jobs",
            Topic::Client => "client",
            Topic::Plugins => "plugins",
        }
    }

    fn bit(self) -> u32 {
        1 << self as u32
    }

    fn named(name: &str) -> Option<Topic> {
        Topic::ALL.into_iter().find(|t| t.name() == name)
    }
}

/// The topics on, a bit each. Plugins named on their own (`plugin:NAME`)
/// turn on [`NAMED`] instead.
static ON: AtomicU32 = AtomicU32::new(0);

/// A bit standing for "some plugin is on by name", so plugins' lines cost
/// one load when none is.
const NAMED: u32 = 1 << 31;

/// Set in the options a frame carries for its client while the `client`
/// topic is on: the client then sends what happens on its side as
/// `Input::Log`.
pub const CLIENT: &str = "gui-debug-client";

/// How many lines are kept: the oldest go first.
const KEEP: usize = 10_000;

/// One thing said.
#[derive(Debug, Clone)]
pub struct Line {
    /// Counts up from 1, so a reader can ask for what came after.
    pub id: u64,
    /// Milliseconds since the editor started.
    pub at: f64,
    pub topic: Topic,
    /// The plugin that said it, for `plugins` lines.
    pub plugin: Option<String>,
    pub text: String,
}

#[derive(Default)]
struct Kept {
    lines: VecDeque<Line>,
    next: u64,
    /// Plugins on by name.
    plugins: BTreeSet<String>,
}

fn kept() -> MutexGuard<'static, Kept> {
    static KEPT: OnceLock<Mutex<Kept>> = OnceLock::new();
    KEPT.get_or_init(Mutex::default)
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
}

fn started() -> Instant {
    static STARTED: OnceLock<Instant> = OnceLock::new();
    *STARTED.get_or_init(Instant::now)
}

/// Whether `topic`'s lines are kept.
#[inline]
pub fn on(topic: Topic) -> bool {
    ON.load(Ordering::Relaxed) & topic.bit() != 0
}

/// Whether lines from plugin `name` are kept.
pub fn plugin_on(name: &str) -> bool {
    let bits = ON.load(Ordering::Relaxed);
    if bits & Topic::Plugins.bit() != 0 {
        return true;
    }
    bits & NAMED != 0 && kept().plugins.contains(name)
}

/// Keeps `text` under `topic`. Callers check [`on`] first, through
/// [`debug!`](crate::debug!), so nothing is formatted while it's off.
pub fn say(topic: Topic, text: String) {
    keep(topic, None, text);
}

/// Keeps `text` from plugin `plugin`.
pub fn say_for(plugin: &str, text: String) {
    keep(Topic::Plugins, Some(plugin.to_owned()), text);
}

fn keep(topic: Topic, plugin: Option<String>, text: String) {
    let at = started().elapsed().as_secs_f64() * 1000.0;
    let mut kept = kept();
    kept.next += 1;
    let id = kept.next;
    if kept.lines.len() == KEEP {
        kept.lines.pop_front();
    }
    kept.lines.push_back(Line {
        id,
        at,
        topic,
        plugin,
        text,
    });
}

/// Turns `name` on or off: a topic, `plugin:NAME`, or `all`.
pub fn set(name: &str, on: bool) -> Result<(), String> {
    let bits = if name == "all" {
        Topic::ALL.iter().fold(0, |bits, t| bits | t.bit())
    } else if let Some(plugin) = name.strip_prefix("plugin:") {
        let mut kept = kept();
        if on {
            kept.plugins.insert(plugin.to_owned());
        } else {
            kept.plugins.remove(plugin);
        }
        if kept.plugins.is_empty() {
            ON.fetch_and(!NAMED, Ordering::Relaxed);
        } else {
            ON.fetch_or(NAMED, Ordering::Relaxed);
        }
        return Ok(());
    } else {
        Topic::named(name)
            .ok_or_else(|| {
                let names: Vec<&str> = Topic::ALL.iter().map(|t| t.name()).collect();
                format!(
                    "no debug topic called {name:?}; there's {}, plugin:NAME and all",
                    names.join(", ")
                )
            })?
            .bit()
    };
    if on {
        ON.fetch_or(bits, Ordering::Relaxed);
    } else {
        ON.fetch_and(!bits, Ordering::Relaxed);
    }
    Ok(())
}

/// Whether `name` is on: a topic or `plugin:NAME`. None for neither.
pub fn named_on(name: &str) -> Option<bool> {
    match name.strip_prefix("plugin:") {
        Some(plugin) => Some(plugin_on(plugin)),
        None => Topic::named(name).map(on),
    }
}

/// Turns everything off, plugins named on their own too.
pub fn off() {
    ON.store(0, Ordering::Relaxed);
    kept().plugins.clear();
}

/// What's on: topics, then `plugin:NAME` for each plugin on by name.
pub fn enabled() -> Vec<String> {
    let mut names: Vec<String> = Topic::ALL
        .into_iter()
        .filter(|t| on(*t))
        .map(|t| t.name().to_owned())
        .collect();
    names.extend(kept().plugins.iter().map(|p| format!("plugin:{p}")));
    names
}

/// Switches topics as `words` say, separated by spaces or commas: a name
/// turns it on, `-name` off, and `off` everything. Stops at the first name
/// that isn't one.
pub fn switch(words: &str) -> Result<(), String> {
    for word in words.split([' ', ',']).filter(|w| !w.is_empty()) {
        if word == "off" {
            off();
        } else if let Some(name) = word.strip_prefix('-') {
            set(name, false)?;
        } else {
            set(word, true)?;
        }
    }
    Ok(())
}

/// Turns on the topics `$GREED_DEBUG` names, e.g. `keys,frames`.
pub fn from_env() {
    if let Ok(words) = std::env::var("GREED_DEBUG") {
        let _ = switch(&words);
    }
}

/// The lines kept after `after` (an id; 0 for all), at most the last
/// `limit` of them.
pub fn lines(after: u64, limit: usize) -> Vec<Line> {
    let kept = kept();
    let newer = kept.lines.iter().filter(|l| l.id > after);
    let count = newer.clone().count();
    newer.skip(count.saturating_sub(limit)).cloned().collect()
}

/// Forgets the lines kept so far.
pub fn clear() {
    kept().lines.clear();
}

/// Says a line under a topic, formatting it only when the topic is on:
/// `debug!(Keys, "{key} ran {name}")`.
#[macro_export]
macro_rules! debug {
    ($topic:ident, $($arg:tt)*) => {
        if $crate::debug::on($crate::debug::Topic::$topic) {
            $crate::debug::say($crate::debug::Topic::$topic, format!($($arg)*));
        }
    };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_topic_off_keeps_nothing_and_on_keeps_its_lines_in_order() {
        // Other tests share these, so this one looks only for its own lines.
        set("jobs", false).unwrap();
        crate::debug!(Jobs, "not kept {}", 1);
        set("jobs", true).unwrap();
        crate::debug!(Jobs, "kept {}", "first");
        crate::debug!(Jobs, "kept {}", "second");
        set("jobs", false).unwrap();
        let mine: Vec<String> = lines(0, KEEP)
            .into_iter()
            .filter(|l| l.text.starts_with("kept ") || l.text.starts_with("not kept"))
            .map(|l| l.text)
            .collect();
        assert_eq!(mine, ["kept first", "kept second"]);
    }

    #[test]
    fn plugins_are_on_all_together_or_by_name() {
        assert!(!plugin_on("debug-test-a"));
        set("plugin:debug-test-a", true).unwrap();
        assert!(plugin_on("debug-test-a"));
        assert!(!plugin_on("debug-test-b"));
        assert!(enabled().contains(&"plugin:debug-test-a".to_owned()));
        set("plugin:debug-test-a", false).unwrap();
        assert!(!plugin_on("debug-test-a"));
    }

    #[test]
    fn unknown_topics_say_which_there_are() {
        let err = set("keyz", true).unwrap_err();
        assert!(err.contains("keys, runs, frames"), "{err}");
    }

    #[test]
    fn lines_after_an_id_and_at_most_a_limit() {
        set("frames", true).unwrap();
        crate::debug!(Frames, "limit one");
        crate::debug!(Frames, "limit two");
        set("frames", false).unwrap();
        let all = lines(0, KEEP);
        let one = all.iter().find(|l| l.text == "limit one").unwrap().id;
        let after: Vec<String> = lines(one, KEEP).into_iter().map(|l| l.text).collect();
        assert!(after.contains(&"limit two".to_owned()));
        assert!(!after.contains(&"limit one".to_owned()));
        assert_eq!(lines(0, 1).len(), 1);
    }
}
