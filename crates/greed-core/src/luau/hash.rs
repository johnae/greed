//! `greed.hash`: SHA-256 digests, for checking a download or telling
//! whether some text changed, and random bytes for one-time codes.

use std::fmt::Write;
use std::io::Read;
use std::path::Path;

use mlua::{IntoLuaMulti, Lua, Table};
use sha2::{Digest, Sha256};

type LuaResult<T> = mlua::Result<T>;

pub(crate) fn hex(digest: &[u8]) -> String {
    digest.iter().fold(String::new(), |mut out, byte| {
        let _ = write!(out, "{byte:02x}");
        out
    })
}

/// The file's digest, read in pieces so a big one isn't held whole.
fn file_digest(path: &Path) -> std::io::Result<String> {
    let mut hasher = Sha256::new();
    std::io::copy(&mut std::fs::File::open(path)?, &mut hasher)?;
    Ok(hex(&hasher.finalize()))
}

/// `count` bytes from the system's random source, as lowercase hex.
pub(crate) fn random_hex(count: usize) -> std::io::Result<String> {
    let mut bytes = vec![0u8; count];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    Ok(hex(&bytes))
}

pub(super) fn module(lua: &Lua) -> LuaResult<Table> {
    let hash = lua.create_table()?;
    hash.set(
        "sha256",
        lua.create_function(|_, data: mlua::LuaString| Ok(hex(&Sha256::digest(data.as_bytes()))))?,
    )?;
    hash.set(
        "random",
        lua.create_function(|_, count: usize| {
            if !(1..=1024).contains(&count) {
                return Err(mlua::Error::runtime(format!(
                    "hash.random takes 1 to 1024 bytes, not {count}"
                )));
            }
            random_hex(count).map_err(|err| mlua::Error::runtime(format!("no random bytes: {err}")))
        })?,
    )?;
    hash.set(
        "sha256_file",
        lua.create_function(|lua, path: String| {
            super::secrets::guard(lua, Path::new(&path))?;
            match file_digest(Path::new(&path)) {
                Ok(digest) => digest.into_lua_multi(lua),
                Err(err) => super::fs::failure(lua, format!("can't read {path}: {err}")),
            }
        })?,
    )?;
    Ok(hash)
}

#[cfg(test)]
mod tests {
    use super::{Digest, Sha256, hex};

    #[test]
    fn digests_are_lowercase_hex() {
        assert_eq!(
            hex(&Sha256::digest(b"abc")),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
