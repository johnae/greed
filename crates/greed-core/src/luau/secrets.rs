//! `greed.secrets`: API keys and the like, kept out of config files and
//! plugin source. A secret is found in, in order:
//!
//! 1. the environment, as `GREED_SECRET_NAME`, or the variable such a key
//!    usually has (`ANTHROPIC_API_KEY` for "anthropic"),
//! 2. the system keyring (`secret-tool` on Linux, `security` on macOS),
//! 3. Greed's own secrets file, readable only by you, for machines without a
//!    keyring, like many reached over ssh.
//!
//! When the keyring can't be reached (its program isn't installed, there's
//! no D-Bus session, it fails), a secret found nowhere comes with why, since
//! the keyring may have it, and a secret kept goes to the file instead.
//!
//! A plugin reads only the secrets it declares as `secrets:NAME`, or all of
//! them with `secrets`. Lookups run a program, so they happen on a thread
//! and wait like `greed.sleep`.

use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Stdio;

use mlua::{Lua, Table, Value};

use super::jobs::{self, Output};
use super::state;
use crate::registry::PluginId;

type LuaResult<T> = mlua::Result<T>;

/// The variables well-known keys usually live in.
const USUAL: &[(&str, &str)] = &[
    ("anthropic", "ANTHROPIC_API_KEY"),
    ("openai", "OPENAI_API_KEY"),
    ("mistral", "MISTRAL_API_KEY"),
];

/// The keyring's service name for Greed's secrets.
const SERVICE: &str = "greed";

/// The program that reaches the system keyring.
const KEYRING: &str = if cfg!(target_os = "macos") {
    "security"
} else {
    "secret-tool"
};

/// Where secrets are looked for and kept, worked out on the editor's
/// thread and handed to the job.
#[derive(Clone)]
pub(super) struct Places {
    /// Greed's own secrets file.
    file: PathBuf,
    /// The program that reaches the system keyring, if one is used: tests
    /// use none unless they set one with `t:keyring`.
    keyring: Option<String>,
}

fn places(lua: &Lua) -> Option<Places> {
    let state = state(lua);
    if let Some(root) = &state.dirs {
        return Some(Places {
            file: root.join("state/secrets.json"),
            keyring: state.keyring.clone(),
        });
    }
    let dir = crate::dirs::dir(crate::dirs::Kind::State)?;
    Some(Places {
        file: dir.join("secrets.json"),
        keyring: Some(KEYRING.to_owned()),
    })
}

/// Greed's secrets file, if it has a place.
pub(super) fn file(lua: &Lua) -> Option<PathBuf> {
    places(lua).map(|places| places.file)
}

/// A secret's name: lowercase letters, digits and dashes.
fn check_name(name: &str) -> LuaResult<()> {
    let fine = !name.is_empty()
        && name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-');
    if fine {
        Ok(())
    } else {
        Err(mlua::Error::runtime(format!(
            "{name:?} isn't a secret's name: use lowercase letters, digits and dashes"
        )))
    }
}

/// Greed's own variable for the secret `name`: `GREED_SECRET_NAME`.
fn own_variable(name: &str) -> String {
    format!(
        "GREED_SECRET_{}",
        name.to_ascii_uppercase().replace('-', "_")
    )
}

/// The variable such a key usually has, like `ANTHROPIC_API_KEY`.
fn usual_variable(name: &str) -> Option<&'static str> {
    USUAL.iter().find(|(n, _)| *n == name).map(|(_, var)| *var)
}

/// The environment variable to set for the secret `name`: the usual one
/// when it has one, else Greed's own.
fn variable(name: &str) -> String {
    usual_variable(name).map_or_else(|| own_variable(name), str::to_owned)
}

fn from_env(name: &str) -> Option<String> {
    let own = own_variable(name);
    std::iter::once(own.as_str())
        .chain(usual_variable(name))
        .find_map(|var| std::env::var(var).ok().filter(|v| !v.is_empty()))
}

/// How running the keyring's program went wrong.
enum Failed {
    /// It isn't there or couldn't start.
    Start(std::io::Error),
    /// It ran and failed: its exit code, if it exited, and the first line
    /// it printed to stderr.
    Exit(Option<i32>, String),
}

/// Runs `program` with `args`, giving it `input`, and returns what it printed.
fn run(program: &str, args: &[&str], input: Option<&str>) -> Result<String, Failed> {
    let command: Vec<&str> = std::iter::once(program)
        .chain(args.iter().copied())
        .collect();
    let mut child = crate::child::command(&command, None, &[], false)
        .map_err(Failed::Start)?
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(Failed::Start)?;
    // Waited for even when the input can't all be written, so it's reaped.
    let wrote = match (input, child.stdin.take()) {
        (Some(input), Some(mut stdin)) => stdin.write_all(input.as_bytes()).is_ok(),
        _ => true,
    };
    let output = child.wait_with_output().map_err(Failed::Start)?;
    if !output.status.success() {
        let said = String::from_utf8_lossy(&output.stderr);
        let said = said.lines().map(str::trim).find(|line| !line.is_empty());
        return Err(Failed::Exit(
            output.status.code(),
            said.unwrap_or_default().to_owned(),
        ));
    }
    if !wrote {
        return Err(Failed::Exit(
            None,
            format!("{program} didn't take the secret"),
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .trim_end_matches('\n')
        .to_owned())
}

/// Why the keyring couldn't be reached through `program`.
fn unreachable(program: &str, failed: Failed) -> String {
    let why = match failed {
        Failed::Start(err) if err.kind() == std::io::ErrorKind::NotFound => {
            format!("{program} isn't installed here")
        }
        Failed::Start(err) => format!("can't run {program}: {err}"),
        Failed::Exit(_, said) if !said.is_empty() => said,
        Failed::Exit(Some(code), _) => format!("{program} failed with code {code}"),
        Failed::Exit(None, _) => format!("{program} was stopped"),
    };
    format!("the system keyring couldn't be reached ({why})")
}

/// The secret `name` in the keyring, none if it has no such secret, or why
/// it couldn't be asked. With no such secret, `secret-tool` fails with 1
/// and says nothing, `security` fails with 44.
fn from_keyring(program: &str, name: &str) -> Result<Option<String>, String> {
    let args: &[&str] = if cfg!(target_os = "macos") {
        &["find-generic-password", "-s", SERVICE, "-a", name, "-w"]
    } else {
        &["lookup", "service", SERVICE, "account", name]
    };
    match run(program, args, None) {
        Ok(value) => Ok(Some(value).filter(|v| !v.is_empty())),
        Err(Failed::Exit(Some(1), said)) if said.is_empty() => Ok(None),
        Err(Failed::Exit(Some(44), _)) => Ok(None),
        Err(failed) => Err(unreachable(program, failed)),
    }
}

/// Keeps `value` as the secret `name` in the keyring, or says why it can't.
fn to_keyring(program: &str, name: &str, value: &str) -> Result<(), String> {
    let kept = if cfg!(target_os = "macos") {
        // `security` takes the value on its command line; -U updates.
        run(
            program,
            &[
                "add-generic-password",
                "-U",
                "-s",
                SERVICE,
                "-a",
                name,
                "-w",
                value,
            ],
            None,
        )
    } else {
        let label = format!("Greed: {name}");
        run(
            program,
            &[
                "store", "--label", &label, "service", SERVICE, "account", name,
            ],
            Some(value),
        )
    };
    kept.map(drop)
        .map_err(|failed| unreachable(program, failed))
}

fn read_file(file: &Path) -> BTreeMap<String, String> {
    std::fs::read_to_string(file)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

fn write_file(file: &Path, secrets: &BTreeMap<String, String>) -> Result<(), String> {
    use std::os::unix::fs::OpenOptionsExt;
    let write = || -> std::io::Result<()> {
        if let Some(dir) = file.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let text = serde_json::to_string_pretty(secrets).map_err(std::io::Error::other)?;
        let partial = file.with_extension("json.partial");
        std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&partial)?
            .write_all(text.as_bytes())?;
        std::fs::rename(&partial, file)
    };
    write().map_err(|err| err.to_string())
}

/// The secret `name`, from wherever it's found first; none if it's
/// nowhere, or why not when the keyring couldn't be asked and may have it.
pub(super) fn find(places: &Places, name: &str) -> Result<Option<String>, String> {
    if let Some(value) = from_env(name) {
        return Ok(Some(value));
    }
    let asked = places
        .keyring
        .as_deref()
        .map_or(Ok(None), |program| from_keyring(program, name));
    if let Ok(Some(value)) = asked {
        return Ok(Some(value));
    }
    match read_file(&places.file).remove(name) {
        Some(value) => Ok(Some(value)),
        None => asked,
    }
}

/// Keeps `value` as the secret `name`: in the keyring if it can be
/// reached, otherwise in Greed's secrets file. Says where it went, and why
/// not the keyring when it couldn't be reached.
pub(super) fn keep(places: &Places, name: &str, value: &str) -> Result<String, String> {
    let mut secrets = read_file(&places.file);
    let unreachable = match places.keyring.as_deref() {
        Some(program) => match to_keyring(program, name, value) {
            Ok(()) => {
                // A copy kept while the keyring couldn't be reached would
                // come back once the keyring's is emptied.
                if secrets.remove(name).is_some() {
                    write_file(&places.file, &secrets)?;
                }
                return Ok("the system keyring".to_owned());
            }
            Err(why) => Some(why),
        },
        None => None,
    };
    secrets.insert(name.to_owned(), value.to_owned());
    write_file(&places.file, &secrets)?;
    let file = places.file.display();
    Ok(match unreachable {
        Some(why) => format!("{file}, since {why}"),
        None => file.to_string(),
    })
}

/// Fails unless `owner` declared the secret `name`, and what started the
/// code running now may read it too.
fn check(lua: &Lua, owner: &PluginId, name: &str) -> LuaResult<()> {
    let capability = format!("secrets:{name}");
    super::capabilities::allowed(lua, owner, &capability, |g| {
        g.allows("secrets") || g.allows(&capability)
    })
}

/// Where to look for the secret `name`, once it's a valid name that `owner`
/// may read.
fn places_for(lua: &Lua, owner: &PluginId, name: &str) -> LuaResult<Places> {
    check_name(name)?;
    check(lua, owner, name)?;
    places(lua).ok_or_else(|| mlua::Error::runtime("there's no home folder"))
}

/// `greed.secrets` for `owner`.
pub(super) fn module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let secrets = lua.create_table()?;
    let o = owner.clone();
    let start_get = lua.create_function(move |lua, name: String| {
        let places = places_for(lua, &o, &name)?;
        Ok(jobs::start(
            lua,
            format!("greed.secrets.get {name:?}"),
            move || Output::Secret(find(&places, &name)),
        ))
    })?;
    let o = owner.clone();
    let start_set = lua.create_function(move |lua, (name, value): (String, String)| {
        let places = places_for(lua, &o, &name)?;
        Ok(jobs::start(
            lua,
            format!("greed.secrets.set {name:?}"),
            move || Output::Secret(keep(&places, &name, &value).map(Some)),
        ))
    })?;
    secrets.set("get", jobs::waiting(lua, "greed.secrets.get", start_get)?)?;
    secrets.set("set", jobs::waiting(lua, "greed.secrets.set", start_set)?)?;
    secrets.set(
        "variable",
        lua.create_function(|_, name: String| {
            check_name(&name)?;
            Ok(variable(&name))
        })?,
    )?;
    Ok(secrets)
}

/// What a command waiting on a secret wakes with: the value (or where it
/// was kept), nil if there's none, or nil and why.
pub(super) fn to_lua(
    lua: &Lua,
    result: Result<Option<String>, String>,
) -> LuaResult<mlua::MultiValue> {
    use mlua::IntoLuaMulti;
    match result {
        Ok(Some(value)) => value.into_lua_multi(lua),
        Ok(None) => Value::Nil.into_lua_multi(lua),
        Err(err) => (Value::Nil, err).into_lua_multi(lua),
    }
}

/// Whether `capability` names a secret, and which.
pub(super) fn named(capability: &str) -> Option<&str> {
    capability
        .strip_prefix("secrets:")
        .filter(|name| check_name(name).is_ok())
}

/// Fails if `path` is Greed's secrets file, which plugins may neither read
/// nor write through Greed's API, only ask for a secret by name.
pub(super) fn guard(lua: &Lua, path: &Path) -> LuaResult<()> {
    match places(lua) {
        Some(places) if super::approvals::same_file(path, &places.file) => Err(
            mlua::Error::runtime("Greed's secrets file is only read through greed.secrets"),
        ),
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};

    use super::{Places, find, keep};

    fn folder(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("greed-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A stand-in for the keyring's program, running `script`.
    fn fake_keyring(dir: &Path, script: &str) -> String {
        let program = dir.join("keyring");
        std::fs::write(&program, format!("#!/bin/sh\n{script}\n")).unwrap();
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
        program.display().to_string()
    }

    #[test]
    fn secrets_kept_in_the_file_come_back_and_stay_private() {
        let dir = folder("secrets");
        let places = Places {
            file: dir.join("secrets.json"),
            keyring: None,
        };
        assert_eq!(find(&places, "greed-test-nothing"), Ok(None));
        let kept = keep(&places, "greed-test-key", "s3cret").unwrap();
        assert!(kept.ends_with("secrets.json"), "{kept}");
        assert_eq!(
            find(&places, "greed-test-key"),
            Ok(Some("s3cret".to_owned()))
        );
        let mode = std::fs::metadata(&places.file)
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600, "only you can read it");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_keyring_that_cant_be_reached_says_why_and_secrets_go_to_the_file() {
        let dir = folder("secrets-unreachable");
        let places = Places {
            file: dir.join("secrets.json"),
            keyring: Some("greed-test-no-such-keyring".to_owned()),
        };
        let why = find(&places, "greed-test-key").unwrap_err();
        assert_eq!(
            why,
            "the system keyring couldn't be reached \
             (greed-test-no-such-keyring isn't installed here)"
        );
        let kept = keep(&places, "greed-test-key", "s3cret").unwrap();
        assert!(
            kept.starts_with(&places.file.display().to_string()),
            "{kept}"
        );
        assert!(kept.ends_with(&format!(", since {why}")), "{kept}");
        assert_eq!(
            find(&places, "greed-test-key"),
            Ok(Some("s3cret".to_owned())),
            "found in the file even though the keyring can't be asked"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_keyring_failing_says_what_it_said() {
        let dir = folder("secrets-failing");
        let places = Places {
            file: dir.join("secrets.json"),
            keyring: Some(fake_keyring(
                &dir,
                "echo 'Cannot autolaunch D-Bus without X11 $DISPLAY' >&2; exit 1",
            )),
        };
        assert_eq!(
            find(&places, "greed-test-key"),
            Err("the system keyring couldn't be reached \
                 (Cannot autolaunch D-Bus without X11 $DISPLAY)"
                .to_owned())
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_keyring_without_the_secret_is_just_missing() {
        let dir = folder("secrets-missing");
        let places = Places {
            file: dir.join("secrets.json"),
            keyring: Some(fake_keyring(&dir, "exit 1")),
        };
        assert_eq!(find(&places, "greed-test-key"), Ok(None));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn keeping_in_the_keyring_drops_the_files_copy() {
        let dir = folder("secrets-reached");
        let mut places = Places {
            file: dir.join("secrets.json"),
            keyring: None,
        };
        keep(&places, "greed-test-key", "old").unwrap();
        // A keyring that takes anything and has nothing.
        places.keyring = Some(fake_keyring(&dir, "cat >/dev/null; exit 0"));
        assert_eq!(
            keep(&places, "greed-test-key", "new").as_deref(),
            Ok("the system keyring")
        );
        assert_eq!(find(&places, "greed-test-key"), Ok(None));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
