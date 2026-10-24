//! Putting greed on the other machine for `greed ssh`, so nothing has to be
//! installed there first. Each version goes in a folder of its own,
//! `~/.local/share/greed/server/VERSION-pPROTOCOL`, and the first `greed
//! ssh` to a machine without it copies one there over the same ssh. The
//! binary comes from, in order:
//!
//! 1. `$GREED_REMOTE_BINARY`, a greed built for that machine;
//! 2. this greed itself, when the other machine runs the same system and
//!    it runs there (a static build always does);
//! 3. the release's static build for that machine, from the cache or
//!    downloaded into it, checked against the release's checksums.
//!
//! This greed itself goes in a folder of its own build,
//! `VERSION-pPROTOCOL-BUILD`, so a rebuild of the same version (while working
//! on greed) gets there too, rather than the first copy staying; only the
//! last few builds are kept. A greed on the other machine's PATH of the
//! same version is used when this one can't be put there, and of the same
//! build always.
//!
//! The programs Greed runs beside itself ([`HELPERS`], like `greed-mail`)
//! go along into the same folder, from beside whichever greed is put there,
//! where Greed finds them.

use std::io::{BufRead, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use greed_core::control::PROTOCOL;
use sha2::{Digest, Sha256};

use crate::runtime::BUILD;
use crate::session::remote;

type Error = Box<dyn std::error::Error>;

const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Where releases are downloaded from.
const RELEASES: &str = "https://github.com/johnae/greed/releases/download";

/// The greed to run on `host`: this build, there already or put there now
/// when the other machine runs the same system; else a greed of this
/// version, there already or the release's put there now.
pub fn ensure(host: &str) -> Result<String, Error> {
    let found = probe(host)?;
    if let Some(path) = found.build {
        // Put there before helpers went along: this build has them beside it.
        if !found.build_missing.is_empty()
            && let Ok(me) = std::env::current_exe()
        {
            upload_helpers(host, &me, folder_of(&path), &found.build_missing);
        }
        return Ok(path);
    }
    let system = found.system;
    let server = format!("{}/.local/share/greed/server", found.home);
    let given = std::env::var_os("GREED_REMOTE_BINARY");
    if given.is_none() && this_system().as_deref() == Some(system.as_str()) {
        let folder = format!("{server}/{}", build_folder());
        eprintln!("greed: putting this greed (build {BUILD}) on {host} ({system})");
        if upload_this(host, &system, &folder) {
            prune(host, &server);
            return Ok(format!("{folder}/greed"));
        }
    }
    if let Some(path) = found.version {
        if !found.version_missing.is_empty() {
            let source = match &given {
                Some(given) => Ok(PathBuf::from(given)),
                None => fetched(host, &system),
            };
            match source {
                Ok(greed) => upload_helpers(host, &greed, folder_of(&path), &found.version_missing),
                Err(err) => {
                    eprintln!("greed: couldn't get what goes beside greed on {host}: {err}");
                }
            }
        }
        return Ok(path);
    }
    let folder = format!("{server}/{}", folder_name());
    eprintln!("greed: putting greed {VERSION} on {host} ({system}), once for this version");
    if let Some(given) = given {
        upload(host, Path::new(&given), &folder)?;
    } else {
        upload(host, &fetched(host, &system)?, &folder)?;
    }
    Ok(format!("{folder}/greed"))
}

/// The folder this version goes in on the other machine. The protocol is
/// in it too, so builds between releases that speak another one don't
/// share a folder.
fn folder_name() -> String {
    format!("{VERSION}-p{PROTOCOL}")
}

/// The folder this very build goes in on the other machine, when it's put
/// there itself: a rebuild of the same version gets a folder of its own.
fn build_folder() -> String {
    format!("{}-{BUILD}", folder_name())
}

/// How many builds of this version are kept on the other machine, the
/// newest; each rebuild put there would otherwise stay.
const BUILDS_KEPT: usize = 3;

/// Removes all but the newest few builds of this version from `server` on
/// `host`. A session running an older one goes on: the program it runs
/// stays until it ends.
fn prune(host: &str, server: &str) {
    let line = format!(
        "cd \"{server}\" && ls -1dt {}-*/ 2>/dev/null | tail -n +{} | while read -r d; do rm -rf \"$d\"; done",
        folder_name(),
        BUILDS_KEPT + 1
    );
    if let Ok((mut child, input, _)) = remote(host, &line) {
        drop(input);
        let _ = child.wait();
    }
}

/// What `probe` found on the other machine.
struct Found {
    /// Its system as releases name it, e.g. "linux-x86_64".
    system: String,
    home: String,
    /// This very build of greed there, if it is.
    build: Option<String>,
    /// A greed of this version there, if there is one.
    version: Option<String>,
    /// The helpers missing beside each, when it's one Greed put there: one
    /// put there before they went along. One on the PATH has what its
    /// install gave it.
    build_missing: Vec<String>,
    version_missing: Vec<String>,
}

/// The folder of the program at `path`.
fn folder_of(path: &str) -> &str {
    path.rsplit_once('/').map_or(".", |(folder, _)| folder)
}

/// Asks `host` for its system, its home, this build of greed and a greed of
/// this version: in the folders they're put in, or on its PATH.
fn probe(host: &str) -> Result<Found, Error> {
    let folder = folder_name();
    let built = build_folder();
    let helpers = HELPERS.join(" ");
    // The helpers missing in the server folder `dir`, if Greed put a greed there.
    let missing = |dir: &str| {
        format!(
            "if [ -x \"$s/{dir}/greed\" ]; then for h in {helpers}; do \
             [ -x \"$s/{dir}/$h\" ] || printf '%s ' \"$h\"; done; fi; echo"
        )
    };
    let line = format!(
        "uname -s; uname -m; echo \"$HOME\"; \
         s=\"$HOME/.local/share/greed/server\"; v=$(greed --version 2>/dev/null); \
         if [ -x \"$s/{built}/greed\" ]; then echo \"$s/{built}/greed\"; \
         elif [ \"${{v%%)*}})\" = 'greed {VERSION} (build {BUILD})' ]; then command -v greed; \
         else echo; fi; \
         if [ -x \"$s/{folder}/greed\" ]; then echo \"$s/{folder}/greed\"; \
         elif [ \"${{v%% (*}}\" = 'greed {VERSION}' ]; then command -v greed; \
         else echo; fi; {}; {}",
        missing(&built),
        missing(&folder)
    );
    let (mut child, input, mut output) = remote(host, &line)?;
    drop(input);
    let mut lines = Vec::new();
    for _ in 0..7 {
        let mut line = String::new();
        output.read_line(&mut line)?;
        lines.push(line.trim().to_owned());
    }
    let _ = child.wait();
    let [
        os,
        arch,
        home,
        exact,
        version,
        build_missing,
        version_missing,
    ] = <[String; 7]>::try_from(lines).map_err(|_| "no answer")?;
    let names =
        |line: String| -> Vec<String> { line.split_whitespace().map(str::to_owned).collect() };
    if home.is_empty() {
        return Err(format!("{host} didn't say where its home is").into());
    }
    Ok(Found {
        system: system_name(&os, &arch).ok_or_else(|| {
            format!("there's no greed for {host}'s system ({os} {arch}); set GREED_REMOTE to one")
        })?,
        home,
        build: Some(exact).filter(|g| !g.is_empty()),
        version: Some(version).filter(|g| !g.is_empty()),
        build_missing: names(build_missing),
        version_missing: names(version_missing),
    })
}

/// A system as `uname -s` and `uname -m` say it, as releases name it.
fn system_name(os: &str, arch: &str) -> Option<String> {
    let arch = match arch {
        "x86_64" | "amd64" => "x86_64",
        "aarch64" | "arm64" => "aarch64",
        _ => return None,
    };
    match os {
        "Linux" => Some(format!("linux-{arch}")),
        "Darwin" => Some("macos-universal".to_owned()),
        _ => None,
    }
}

/// This machine's system, as releases name it.
fn this_system() -> Option<String> {
    let os = match std::env::consts::OS {
        "linux" => "Linux",
        "macos" => "Darwin",
        _ => return None,
    };
    system_name(os, std::env::consts::ARCH)
}

/// Puts this greed on `host` as `folder/greed`, if the other machine runs
/// the same system and it runs there: a static build always does, one
/// linked against glibc where the glibc is new enough.
fn upload_this(host: &str, system: &str, folder: &str) -> bool {
    let Ok(me) = std::env::current_exe() else {
        return false;
    };
    if this_system().as_deref() != Some(system) {
        return false;
    }
    if upload(host, &me, folder).is_ok() {
        return true;
    }
    eprintln!("greed: this greed doesn't run on {host}; getting the static build");
    false
}

/// The release's static build for `system`: the one downloaded before, or
/// downloaded now into the cache.
fn fetched(host: &str, system: &str) -> Result<PathBuf, Error> {
    let cached = crate::runtime::cache_dir()
        .ok_or("there's no cache folder to download greed into")?
        .join("remote")
        .join(folder_name())
        .join(system)
        .join("greed");
    if !cached.is_file() {
        download(system, &cached).map_err(|err| {
            format!(
                "couldn't get greed {VERSION} for {host} ({system}): {err}. \
                 Set GREED_REMOTE_BINARY to a greed built for it (nix build .#static), \
                 or install one there and set GREED_REMOTE"
            )
        })?;
    }
    Ok(cached)
}

/// The programs that ship beside `greed` and that Greed runs from beside
/// itself: they go wherever a greed is put.
pub const HELPERS: &[&str] = &["greed-mail"];

/// The helpers there are beside `greed`, with their names.
fn helpers_beside(greed: &Path) -> Vec<(&'static str, PathBuf)> {
    HELPERS
        .iter()
        .map(|name| (*name, greed.with_file_name(name)))
        .filter(|(_, path)| path.is_file())
        .collect()
}

/// Copies `binary` to `folder` on `host` as `greed`, and checks it runs
/// there, then the helpers beside it. Each is written beside and renamed
/// into place, so a greed starting there at the same time never runs half
/// of one. A helper that doesn't go only means its part of Greed doesn't
/// work there, which it says when it's used.
fn upload(host: &str, binary: &Path, folder: &str) -> Result<(), Error> {
    copy(host, binary, folder, "greed", true)?;
    upload_helpers(host, binary, folder, HELPERS);
    Ok(())
}

/// Copies the helpers named in `wanted` from beside `greed` to `folder` on
/// `host`, those there are.
fn upload_helpers(host: &str, greed: &Path, folder: &str, wanted: &[impl AsRef<str>]) {
    for (name, helper) in helpers_beside(greed) {
        if !wanted.iter().any(|w| w.as_ref() == name) {
            continue;
        }
        if let Err(err) = copy(host, &helper, folder, name, false) {
            eprintln!("greed: couldn't put {name} on {host}: {err}");
        }
    }
}

/// Copies `binary` to `folder/name` on `host`; with `check`, only once it
/// says its version there.
fn copy(host: &str, binary: &Path, folder: &str, name: &str, check: bool) -> Result<(), Error> {
    let part = format!("{folder}/{name}.part");
    let check = if check {
        format!("&& \"{part}\" --version >/dev/null ")
    } else {
        String::new()
    };
    let line = format!(
        "mkdir -p \"{folder}\" && cat > \"{part}\" && chmod +x \"{part}\" \
         {check}&& mv \"{part}\" \"{folder}/{name}\" && echo copied"
    );
    let (mut child, mut input, mut output) = remote(host, &line)?;
    std::io::copy(&mut std::fs::File::open(binary)?, &mut input)?;
    drop(input);
    let mut said = String::new();
    output.read_to_string(&mut said)?;
    let status = child.wait()?;
    if status.success() && said.trim() == "copied" {
        Ok(())
    } else {
        Err(format!("it didn't run there ({status})").into())
    }
}

/// Downloads the release's static build for `system` to `to`, checked
/// against the release's checksums.
fn download(system: &str, to: &Path) -> Result<(), Error> {
    let name = if system.starts_with("linux") {
        format!("greed-{VERSION}-{system}-tui-only-static")
    } else {
        format!("greed-{VERSION}-{system}")
    };
    let base = format!("{RELEASES}/v{VERSION}");
    let sums = String::from_utf8(get(&format!("{base}/SHA256SUMS"))?)?;
    let archive = format!("{name}.tar.gz");
    let want = sums
        .lines()
        .find_map(|line| {
            let (sum, file) = line.split_once(char::is_whitespace)?;
            (file.trim() == archive).then(|| sum.to_owned())
        })
        .ok_or_else(|| format!("the release has no {archive}"))?;
    let bytes = get(&format!("{base}/{archive}"))?;
    if format!("{:x}", Sha256::digest(&bytes)) != want {
        return Err(format!("{archive} doesn't match its checksum").into());
    }
    let folder = to.parent().ok_or("no folder to unpack into")?;
    let unpacking = folder.with_extension("part");
    let _ = std::fs::remove_dir_all(&unpacking);
    std::fs::create_dir_all(&unpacking)?;
    let mut tar = Command::new("tar")
        .arg("-C")
        .arg(&unpacking)
        .args([
            "-xzf",
            "-",
            "--strip-components=2",
            // greed, and the helpers beside it in releases that have them.
            &format!("{name}/bin"),
        ])
        .stdin(Stdio::piped())
        .spawn()?;
    std::io::Write::write_all(tar.stdin.as_mut().ok_or("tar has no input")?, &bytes)?;
    drop(tar.stdin.take());
    if !tar.wait()?.success() {
        return Err(format!("couldn't unpack {archive}").into());
    }
    let _ = std::fs::remove_dir_all(folder);
    std::fs::rename(&unpacking, folder)?;
    Ok(())
}

/// The body of a GET of `url`, following GitHub's redirect to its storage.
fn get(url: &str) -> Result<Vec<u8>, Error> {
    let mut response = ureq::get(url).call()?;
    Ok(response
        .body_mut()
        .with_config()
        .limit(200 * 1024 * 1024)
        .read_to_vec()?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_helpers_beside_a_greed_go_with_it_those_there_are() {
        let dir = std::env::temp_dir().join(format!("greed-helpers-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let greed = dir.join("greed");
        std::fs::write(&greed, "").unwrap();
        assert!(helpers_beside(&greed).is_empty(), "none there yet");
        std::fs::write(dir.join("greed-mail"), "").unwrap();
        std::fs::write(dir.join("something-else"), "").unwrap();
        assert_eq!(
            helpers_beside(&greed),
            [("greed-mail", dir.join("greed-mail"))]
        );
        std::fs::remove_dir_all(dir).unwrap();
        assert_eq!(
            folder_of("/home/me/.local/share/greed/server/0.3/greed"),
            "/home/me/.local/share/greed/server/0.3"
        );
    }

    #[test]
    fn systems_are_named_as_releases_name_them() {
        assert_eq!(
            system_name("Linux", "x86_64").as_deref(),
            Some("linux-x86_64")
        );
        assert_eq!(
            system_name("Linux", "arm64").as_deref(),
            Some("linux-aarch64")
        );
        assert_eq!(
            system_name("Darwin", "arm64").as_deref(),
            Some("macos-universal")
        );
        assert_eq!(system_name("FreeBSD", "amd64"), None);
        assert_eq!(system_name("Linux", "riscv64"), None);
    }
}
