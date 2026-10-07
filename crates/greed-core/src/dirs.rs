//! Where Greed keeps what it keeps: your config, data like saved agent
//! sessions, a cache, and state like the plugins you approved. For each,
//! in order: its own variable (`GREED_CONFIG_DIR`, `GREED_DATA_DIR`,
//! `GREED_CACHE_DIR`, `GREED_STATE_DIR`), then a folder in the profile
//! (`GREED_PROFILE`, which `greed --profile DIR` sets), then `greed` in the
//! XDG folder (`XDG_CONFIG_HOME` and the rest), then the usual folder in
//! your home. Sessions' sockets go in `GREED_RUN_DIR`, else the profile's `run`
//! folder, else the user's runtime folder.

use std::ffi::OsString;
use std::path::PathBuf;

/// What a folder is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Config,
    Data,
    Cache,
    State,
}

impl Kind {
    /// The variable naming this folder itself.
    pub fn variable(self) -> &'static str {
        match self {
            Self::Config => "GREED_CONFIG_DIR",
            Self::Data => "GREED_DATA_DIR",
            Self::Cache => "GREED_CACHE_DIR",
            Self::State => "GREED_STATE_DIR",
        }
    }

    /// Its folder's name in a profile.
    fn name(self) -> &'static str {
        match self {
            Self::Config => "config",
            Self::Data => "data",
            Self::Cache => "cache",
            Self::State => "state",
        }
    }

    fn xdg(self) -> (&'static str, &'static str) {
        match self {
            Self::Config => ("XDG_CONFIG_HOME", ".config"),
            Self::Data => ("XDG_DATA_HOME", ".local/share"),
            Self::Cache => ("XDG_CACHE_HOME", ".cache"),
            Self::State => ("XDG_STATE_HOME", ".local/state"),
        }
    }
}

/// The variable naming the profile folder.
pub const PROFILE: &str = "GREED_PROFILE";

/// Greed's folder for `kind`, from this process's environment.
pub fn dir(kind: Kind) -> Option<PathBuf> {
    dir_in(kind, |name| std::env::var_os(name))
}

/// The profile folder, if one is set.
pub fn profile() -> Option<PathBuf> {
    set(|name| std::env::var_os(name), PROFILE)
}

/// Where sessions keep their sockets when it isn't the user's runtime
/// folder: `GREED_RUN_DIR`, or the profile's `run` folder.
pub fn sessions() -> Option<PathBuf> {
    sessions_in(|name| std::env::var_os(name))
}

/// [`sessions`], with `env` for the environment.
pub fn sessions_in(env: impl Fn(&str) -> Option<OsString>) -> Option<PathBuf> {
    set(&env, "GREED_RUN_DIR").or_else(|| set(&env, PROFILE).map(|profile| profile.join("run")))
}

/// [`dir`], with `env` for the environment.
pub fn dir_in(kind: Kind, env: impl Fn(&str) -> Option<OsString>) -> Option<PathBuf> {
    if let Some(dir) = set(&env, kind.variable()) {
        return Some(dir);
    }
    if let Some(profile) = set(&env, PROFILE) {
        return Some(profile.join(kind.name()));
    }
    let (variable, fallback) = kind.xdg();
    let base = set(&env, variable).or_else(|| set(&env, "HOME").map(|home| home.join(fallback)))?;
    Some(base.join("greed"))
}

/// The folder variable `name` names, if it's set and not empty.
fn set(env: impl Fn(&str) -> Option<OsString>, name: &str) -> Option<PathBuf> {
    env(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<OsString> + 'a {
        move |name| {
            pairs
                .iter()
                .find(|(key, _)| *key == name)
                .map(|(_, value)| OsString::from(value))
        }
    }

    #[test]
    fn a_folders_own_variable_wins_then_the_profile_then_xdg_then_home() {
        let all = [
            ("GREED_CACHE_DIR", "/own"),
            ("GREED_PROFILE", "/profile"),
            ("XDG_CACHE_HOME", "/xdg"),
            ("HOME", "/home/me"),
        ];
        assert_eq!(dir_in(Kind::Cache, env(&all)), Some("/own".into()));
        assert_eq!(
            dir_in(Kind::Cache, env(&all[1..])),
            Some("/profile/cache".into())
        );
        assert_eq!(
            dir_in(Kind::Cache, env(&all[2..])),
            Some("/xdg/greed".into())
        );
        assert_eq!(
            dir_in(Kind::Cache, env(&all[3..])),
            Some("/home/me/.cache/greed".into())
        );
        assert_eq!(dir_in(Kind::Cache, env(&[])), None);
    }

    #[test]
    fn each_kind_has_its_place_and_empty_variables_count_as_unset() {
        let home = [("HOME", "/h"), ("GREED_PROFILE", "")];
        assert_eq!(
            dir_in(Kind::Config, env(&home)),
            Some("/h/.config/greed".into())
        );
        assert_eq!(
            dir_in(Kind::Data, env(&home)),
            Some("/h/.local/share/greed".into())
        );
        assert_eq!(
            dir_in(Kind::State, env(&home)),
            Some("/h/.local/state/greed".into())
        );
        let profile = [("GREED_PROFILE", "/p"), ("GREED_CONFIG_DIR", "/c")];
        assert_eq!(dir_in(Kind::Config, env(&profile)), Some("/c".into()));
        assert_eq!(dir_in(Kind::Data, env(&profile)), Some("/p/data".into()));
        assert_eq!(dir_in(Kind::State, env(&profile)), Some("/p/state".into()));
    }

    #[test]
    fn sessions_go_in_greed_run_dir_then_the_profile() {
        let both = [("GREED_RUN_DIR", "/r"), ("GREED_PROFILE", "/p")];
        assert_eq!(sessions_in(env(&both)), Some("/r".into()));
        assert_eq!(sessions_in(env(&both[1..])), Some("/p/run".into()));
        assert_eq!(sessions_in(env(&[("GREED_RUN_DIR", "")])), None);
    }
}
