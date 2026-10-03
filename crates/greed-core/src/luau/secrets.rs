//! `kern.secrets`: API keys and the like, kept out of config files and
//! plugin source. A secret is found in, in order:
//!
//! 1. the environment, as `GREED_SECRET_NAME`, or the variable such a key
//!    usually has (`ANTHROPIC_API_KEY` for "anthropic"),
//! 2. the system keyring (`secret-tool` on Linux, `security` on macOS),
//! 3. Kern's own secrets file, readable only by you, for machines without a
//!    keyring, like many reached over ssh.
//!
//! A plugin reads only the secrets it declares as `secrets:NAME`, or all of
//! them with `secrets`. Lookups run a program, so they happen on a thread
//! and wait like `kern.sleep`.

use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use mlua::{Lua, Table, Value};

use super::jobs::{self, Output};
use super::state;
use crate::registry::PluginId;

type LuaResult<T> = mlua::Result<T>;

/// The variables well-known keys usually live in.
const USUAL: &[(&str, &str)] = &[
    ("anthropic", "ANTHROPIC_API_KEY"),
    ("openai", "OPENAI_API_KEY"),
];

/// The keyring's service name for Kern's secrets.
const SERVICE: &str = "kern";

/// Where secrets are looked for and kept, worked out on the editor's
/// thread and handed to the job.
#[derive(Clone)]
pub(super) struct Places {
    /// Kern's own secrets file.
    file: PathBuf,
    /// Whether to use the system keyring; tests don't.
    keyring: bool,
}

fn places(lua: &Lua) -> Option<Places> {
    if let Some(root) = state(lua).dirs.clone() {
        return Some(Places {
            file: root.join("state/secrets.json"),
            keyring: false,
        });
    }
    let base = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| Path::new(&home).join(".local/state")))?;
    Some(Places {
        file: base.join("kern/secrets.json"),
        keyring: true,
    })
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

fn from_env(name: &str) -> Option<String> {
    let own = format!(
        "GREED_SECRET_{}",
        name.to_ascii_uppercase().replace('-', "_")
    );
    let usual = USUAL.iter().find(|(n, _)| *n == name).map(|(_, var)| *var);
    std::iter::once(own.as_str())
        .chain(usual)
        .find_map(|var| std::env::var(var).ok().filter(|v| !v.is_empty()))
}

/// Runs `program` with `args`, giving it `input`, and returns what it printed
/// if it succeeded.
fn run(program: &str, args: &[&str], input: Option<&str>) -> Option<String> {
    let mut child = Command::new(program)
        .args(args)
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    if let (Some(input), Some(mut stdin)) = (input, child.stdin.take()) {
        stdin.write_all(input.as_bytes()).ok()?;
    }
    let output = child.wait_with_output().ok()?;
    output.status.success().then(|| {
        String::from_utf8_lossy(&output.stdout)
            .trim_end_matches('\n')
            .to_owned()
    })
}

fn from_keyring(name: &str) -> Option<String> {
    if cfg!(target_os = "macos") {
        run(
            "security",
            &["find-generic-password", "-s", SERVICE, "-a", name, "-w"],
            None,
        )
    } else {
        run(
            "secret-tool",
            &["lookup", "service", SERVICE, "account", name],
            None,
        )
    }
    .filter(|v| !v.is_empty())
}

fn to_keyring(name: &str, value: &str) -> bool {
    if cfg!(target_os = "macos") {
        // `security` takes the value on its command line; -U updates.
        run(
            "security",
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
        .is_some()
    } else {
        let label = format!("Kern: {name}");
        run(
            "secret-tool",
            &[
                "store", "--label", &label, "service", SERVICE, "account", name,
            ],
            Some(value),
        )
        .is_some()
    }
}

fn read_file(file: &Path) -> BTreeMap<String, String> {
    std::fs::read_to_string(file)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

fn write_file(file: &Path, secrets: &BTreeMap<String, String>) -> std::io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
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
}

/// The secret `name`, from wherever it's found first.
pub(super) fn find(places: &Places, name: &str) -> Option<String> {
    from_env(name)
        .or_else(|| places.keyring.then(|| from_keyring(name)).flatten())
        .or_else(|| read_file(&places.file).remove(name))
}

/// Keeps `value` as the secret `name`: in the keyring if there is one,
/// otherwise in Kern's secrets file. Says where it went.
pub(super) fn keep(places: &Places, name: &str, value: &str) -> Result<String, String> {
    if places.keyring && to_keyring(name, value) {
        return Ok("the system keyring".to_owned());
    }
    let mut secrets = read_file(&places.file);
    secrets.insert(name.to_owned(), value.to_owned());
    write_file(&places.file, &secrets).map_err(|err| err.to_string())?;
    Ok(places.file.display().to_string())
}

/// Fails unless `owner` declared the secret `name`.
fn check(lua: &Lua, owner: &PluginId, name: &str) -> LuaResult<()> {
    let capability = format!("secrets:{name}");
    let allowed = state(lua)
        .grants
        .get(owner)
        .is_none_or(|g| g.allows("secrets") || g.allows(&capability));
    if allowed {
        Ok(())
    } else {
        Err(mlua::Error::runtime(format!(
            "{owner} can't read the secret {name:?}: add \"{capability}\" to capabilities in its plugin.toml"
        )))
    }
}

/// Where to look for the secret `name`, once it's a valid name that `owner`
/// may read.
fn places_for(lua: &Lua, owner: &PluginId, name: &str) -> LuaResult<Places> {
    check_name(name)?;
    check(lua, owner, name)?;
    places(lua).ok_or_else(|| mlua::Error::runtime("there's no home folder"))
}

/// `kern.secrets` for `owner`.
pub(super) fn module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let secrets = lua.create_table()?;
    let o = owner.clone();
    let start_get = lua.create_function(move |lua, name: String| {
        let places = places_for(lua, &o, &name)?;
        Ok(jobs::start(lua, move || {
            Output::Secret(Ok(find(&places, &name)))
        }))
    })?;
    let o = owner.clone();
    let start_set = lua.create_function(move |lua, (name, value): (String, String)| {
        let places = places_for(lua, &o, &name)?;
        Ok(jobs::start(lua, move || {
            Output::Secret(keep(&places, &name, &value).map(Some))
        }))
    })?;
    secrets.set("get", jobs::waiting(lua, "kern.secrets.get", start_get)?)?;
    secrets.set("set", jobs::waiting(lua, "kern.secrets.set", start_set)?)?;
    Ok(secrets)
}

/// What a command waiting on a secret wakes with: the value (or where it
/// was kept), nil if there's none, or nil and why it failed.
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

/// Fails if `path` is Kern's secrets file, which plugins may neither read
/// nor write through Kern's API, only ask for a secret by name.
pub(super) fn guard(lua: &Lua, path: &Path) -> LuaResult<()> {
    match places(lua) {
        Some(places) if super::approvals::same_file(path, &places.file) => Err(
            mlua::Error::runtime("Kern's secrets file is only read through kern.secrets"),
        ),
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::{Places, find, keep};

    #[test]
    fn secrets_kept_in_the_file_come_back_and_stay_private() {
        let dir = std::env::temp_dir().join(format!("kern-secrets-{}", std::process::id()));
        let places = Places {
            file: dir.join("secrets.json"),
            keyring: false,
        };
        assert_eq!(find(&places, "kern-test-nothing"), None);
        let kept = keep(&places, "kern-test-key", "s3cret").unwrap();
        assert!(kept.ends_with("secrets.json"), "{kept}");
        assert_eq!(find(&places, "kern-test-key").as_deref(), Some("s3cret"));
        let mode = std::fs::metadata(&places.file)
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600, "only you can read it");
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
