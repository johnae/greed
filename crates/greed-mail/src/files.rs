//! Files greed-mail writes beside the store for the reader to open: a
//! message's HTML as a page, an attachment. Named after what they're of,
//! so the same one lands in the same place each time, and safely, as a
//! name from a message can say anything.

use std::path::{Path, PathBuf};

/// A name for `key` that's the same each time (FNV-1a), for a file or
/// folder of what it names.
pub fn hashed(key: &str) -> String {
    let hash = key.bytes().fold(0xcbf2_9ce4_8422_2325_u64, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
    });
    format!("{hash:016x}")
}

/// `name`, as a message gives it, made a file name of its own: no folders
/// in it, nothing a terminal or a shell reads as more, never hidden, and
/// "attachment" when nothing is left.
pub fn safe_name(name: &str) -> String {
    let last = name.rsplit(['/', '\\']).next().unwrap_or("");
    let clean: String = last
        .chars()
        .map(|c| if c.is_control() { '_' } else { c })
        .collect();
    let clean = clean.trim().trim_start_matches('.').trim();
    if clean.is_empty() {
        "attachment".into()
    } else {
        clean.chars().take(200).collect()
    }
}

/// The kind of file `name` is by its extension, as mail says it:
/// `application/octet-stream` for what isn't known.
pub fn kind_of(name: &str) -> &'static str {
    let extension = name
        .rsplit_once('.')
        .map(|(_, e)| e.to_ascii_lowercase())
        .unwrap_or_default();
    match extension.as_str() {
        "pdf" => "application/pdf",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        "txt" | "md" | "log" => "text/plain; charset=utf-8",
        "csv" => "text/csv; charset=utf-8",
        "html" | "htm" => "text/html; charset=utf-8",
        "ics" => "text/calendar; charset=utf-8",
        "json" => "application/json",
        "zip" => "application/zip",
        "gz" | "tgz" => "application/gzip",
        "doc" => "application/msword",
        "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls" => "application/vnd.ms-excel",
        "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "odt" => "application/vnd.oasis.opendocument.text",
        "mp3" => "audio/mpeg",
        "mp4" => "video/mp4",
        _ => "application/octet-stream",
    }
}

/// `path` as the reader writes it, `~/` for their home folder.
pub fn expand_home(path: &str) -> PathBuf {
    match (path.strip_prefix("~/"), std::env::var_os("HOME")) {
        (Some(rest), Some(home)) => PathBuf::from(home).join(rest),
        _ => PathBuf::from(path),
    }
}

/// Writes `bytes` to `path`, making its folder; refused when something is
/// there already, so nothing of the reader's is written over.
pub fn write_new(path: &Path, bytes: &[u8]) -> Result<PathBuf, String> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)
            .map_err(|e| format!("couldn't make {}: {e}", dir.display()))?;
    }
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|e| match e.kind() {
            std::io::ErrorKind::AlreadyExists => format!("{} is there already", path.display()),
            _ => format!("couldn't write {}: {e}", path.display()),
        })?;
    std::io::Write::write_all(&mut file, bytes)
        .map_err(|e| format!("couldn't write {}: {e}", path.display()))?;
    Ok(path.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_from_mail_are_made_safe() {
        assert_eq!(safe_name("plan.pdf"), "plan.pdf");
        assert_eq!(safe_name("../../.ssh/authorized_keys"), "authorized_keys");
        assert_eq!(safe_name("C:\\Users\\x\\evil.exe"), "evil.exe");
        assert_eq!(safe_name(".bashrc"), "bashrc", "never hidden");
        assert_eq!(safe_name("a\u{1b}[31mred"), "a_[31mred");
        assert_eq!(safe_name("  "), "attachment");
        assert_eq!(safe_name("../"), "attachment");
        assert_eq!(hashed("m:1:a"), hashed("m:1:a"));
        assert_ne!(hashed("m:1:a"), hashed("m:1:b"));
    }

    #[test]
    fn a_file_is_never_written_over() {
        let dir = std::env::temp_dir().join(format!("gm-files-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("deep/plan.pdf");
        assert_eq!(write_new(&path, b"one").unwrap(), path);
        let Err(why) = write_new(&path, b"two") else {
            panic!("wrote over it");
        };
        assert!(why.ends_with("is there already"), "{why}");
        assert_eq!(std::fs::read(&path).unwrap(), b"one");
        let _ = std::fs::remove_dir_all(dir);
    }
}
