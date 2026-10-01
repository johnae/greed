//! Embeds the runtime (the default plugins and the Luau types) in the
//! binary, so an installed `kern` works without the source tree next to it.

use std::fmt::Write as _;
use std::path::{Path, PathBuf};

fn main() {
    let manifest = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").expect("set by cargo"));
    let runtime = manifest.join("../../runtime");
    println!("cargo::rerun-if-changed={}", runtime.display());

    let mut files = Vec::new();
    collect(&runtime, &runtime, &mut files);
    files.sort();

    // FNV-1a over every path and its contents, so a changed runtime gets a
    // folder of its own when it's unpacked.
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    let mut entries = String::new();
    for (relative, path) in &files {
        let bytes = std::fs::read(path).expect("runtime file is readable");
        for byte in relative.bytes().chain(bytes) {
            hash ^= u64::from(byte);
            hash = hash.wrapping_mul(0x0100_0000_01b3);
        }
        let _ = writeln!(
            entries,
            "    ({relative:?}, include_bytes!({:?})),",
            path.display().to_string()
        );
    }
    let source = format!(
        "/// Every runtime file, by its path in the runtime folder.\n\
         pub const FILES: &[(&str, &[u8])] = &[\n{entries}];\n\n\
         /// Changes whenever any runtime file does.\n\
         pub const HASH: &str = \"{hash:016x}\";\n"
    );
    let out = PathBuf::from(std::env::var_os("OUT_DIR").expect("set by cargo")).join("runtime.rs");
    std::fs::write(out, source).expect("OUT_DIR is writable");
}

fn collect(root: &Path, dir: &Path, files: &mut Vec<(String, PathBuf)>) {
    for entry in std::fs::read_dir(dir).expect("runtime folder is readable") {
        let path = entry.expect("runtime entry is readable").path();
        if path.is_dir() {
            collect(root, &path, files);
        } else {
            let relative = path
                .strip_prefix(root)
                .expect("under the runtime folder")
                .to_string_lossy()
                .into_owned();
            let path = path.canonicalize().expect("runtime file exists");
            files.push((relative, path));
        }
    }
}
