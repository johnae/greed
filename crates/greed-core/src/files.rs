//! Writing users' files.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

/// Writes a file whole: to a temporary file beside it, then moved over it,
/// so a crash or a full disk never leaves it half written. A symlink is
/// followed and its target written; the file keeps its permissions. Where
/// the folder can't take a new file, the file is written in place.
pub fn write(
    path: &Path,
    contents: impl FnOnce(&mut dyn Write) -> std::io::Result<()>,
) -> std::io::Result<()> {
    let path = resolve(path)?;
    let permissions = std::fs::metadata(&path).ok().map(|m| m.permissions());
    let (temp, file) = match create_temp(&path) {
        Ok(created) => created,
        Err(err) if err.kind() == std::io::ErrorKind::PermissionDenied => {
            return write_in_place(&path, contents);
        }
        Err(err) => return Err(err),
    };
    let written = (|| {
        let mut out = std::io::BufWriter::new(file);
        contents(&mut out)?;
        let file = out
            .into_inner()
            .map_err(std::io::IntoInnerError::into_error)?;
        file.sync_all()?;
        if let Some(permissions) = permissions {
            std::fs::set_permissions(&temp, permissions)?;
        }
        std::fs::rename(&temp, &path)
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    written
}

fn write_in_place(
    path: &Path,
    contents: impl FnOnce(&mut dyn Write) -> std::io::Result<()>,
) -> std::io::Result<()> {
    let mut out = std::io::BufWriter::new(std::fs::File::create(path)?);
    contents(&mut out)?;
    out.flush()
}

/// The file a write to `path` lands in: `path` with symlinks followed, the
/// last one even if what it points to doesn't exist yet.
fn resolve(path: &Path) -> std::io::Result<PathBuf> {
    let mut path = path.to_path_buf();
    for _ in 0..40 {
        match std::fs::symlink_metadata(&path) {
            Ok(meta) if meta.file_type().is_symlink() => {
                let target = std::fs::read_link(&path)?;
                path = match path.parent() {
                    Some(parent) => parent.join(target),
                    None => target,
                };
            }
            _ => return Ok(path),
        }
    }
    Err(std::io::Error::other(format!(
        "too many symlinks at {}",
        path.display()
    )))
}

fn create_temp(path: &Path) -> std::io::Result<(PathBuf, std::fs::File)> {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let name = path
        .file_name()
        .ok_or_else(|| std::io::Error::other(format!("{} isn't a file", path.display())))?;
    let dir = path.parent().unwrap_or(Path::new("."));
    loop {
        let n = NEXT.fetch_add(1, Ordering::Relaxed);
        let mut temp_name = std::ffi::OsString::from(".");
        temp_name.push(name);
        temp_name.push(format!(".greed-{}-{n}.tmp", std::process::id()));
        let temp = dir.join(temp_name);
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)
        {
            Ok(file) => return Ok((temp, file)),
            Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(err) => return Err(err),
        }
    }
}
