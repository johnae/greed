//! Finding the runtime: the default plugins and the Luau types.

use std::io;
use std::path::{Path, PathBuf};

mod embedded {
    include!(concat!(env!("OUT_DIR"), "/runtime.rs"));
}

/// Where the runtime is, in the first of these places that has one:
/// `$GREED_RUNTIME`, a folder chosen at build time (`GREED_RUNTIME_DIR`, for
/// packagers), `share/greed/runtime` beside the binary's folder, the source
/// tree it was built from, and last the copy built into the binary,
/// unpacked into the cache.
pub fn dir() -> io::Result<PathBuf> {
    if let Some(dir) = std::env::var_os("GREED_RUNTIME") {
        return Ok(PathBuf::from(dir));
    }
    let installed = std::env::current_exe()
        .ok()
        .and_then(|exe| Some(exe.parent()?.parent()?.join("share/greed/runtime")));
    let candidates = option_env!("GREED_RUNTIME_DIR")
        .map(PathBuf::from)
        .into_iter()
        .chain(installed)
        .chain([Path::new(env!("CARGO_MANIFEST_DIR")).join("../../runtime")]);
    for dir in candidates {
        if dir.join("plugins/core").is_dir() {
            return Ok(dir);
        }
    }
    let cache = cache_dir()
        .ok_or_else(|| io::Error::other("no cache folder to unpack the runtime into"))?;
    unpack(&cache)
}

/// Greed's cache folder (see [`greed_core::dirs`]).
pub(crate) fn cache_dir() -> Option<PathBuf> {
    greed_core::dirs::dir(greed_core::dirs::Kind::Cache)
}

/// Unpacks the built-in runtime into `cache` once per version of it, and
/// returns its folder. It's written beside and renamed into place, so a
/// second greed starting at the same time never sees half of it.
fn unpack(cache: &Path) -> io::Result<PathBuf> {
    let dir = cache.join(format!("runtime-{}", embedded::HASH));
    if dir.is_dir() {
        return Ok(dir);
    }
    let partial = cache.join(format!("runtime-{}.{}", embedded::HASH, std::process::id()));
    let written = embedded::FILES.iter().try_for_each(|(path, bytes)| {
        let path = partial.join(path);
        std::fs::create_dir_all(path.parent().unwrap_or(&partial))?;
        std::fs::write(path, bytes)
    });
    if let Err(err) = written.and_then(|()| std::fs::rename(&partial, &dir)) {
        let _ = std::fs::remove_dir_all(&partial);
        // Another greed may have got there first.
        if !dir.is_dir() {
            return Err(err);
        }
    }
    Ok(dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unpacks_the_built_in_runtime_once() {
        let cache = std::env::temp_dir().join(format!("greed-runtime-test-{}", std::process::id()));
        let dir = unpack(&cache).unwrap();
        assert!(dir.join("plugins/core/plugin.toml").is_file());
        assert!(dir.join("types/greed/init.luau").is_file());
        let source =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../runtime/plugins/core/init.luau");
        assert_eq!(
            std::fs::read(dir.join("plugins/core/init.luau")).unwrap(),
            std::fs::read(source).unwrap()
        );

        std::fs::write(dir.join("marker"), "").unwrap();
        assert_eq!(unpack(&cache).unwrap(), dir);
        assert!(dir.join("marker").exists(), "an unpacked runtime is reused");
        let entries = std::fs::read_dir(&cache).unwrap().count();
        assert_eq!(entries, 1, "nothing partial is left behind");
        std::fs::remove_dir_all(cache).unwrap();
    }
}
