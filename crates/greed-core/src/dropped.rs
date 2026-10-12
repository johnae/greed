//! Files dropped on a client's window, made into what's pasted: a path the
//! session can read. A client on the session's machine sends the path; a
//! remote one sends what's in the file too, which is kept in the session's
//! cache folder, and that path goes in its place.

use std::path::{Path, PathBuf};

use base64::Engine;

/// How big a dropped file a client sends along, for a session elsewhere.
pub const MOST: u64 = 50 * 1024 * 1024;

/// What's in the file at `path` as base64, for a session on another
/// machine to keep; None for a folder, or a file bigger than [`MOST`].
pub fn contents(path: &Path) -> Option<String> {
    let small = std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.len() <= MOST);
    if !small {
        return None;
    }
    let bytes = std::fs::read(path).ok()?;
    Some(base64::engine::general_purpose::STANDARD.encode(bytes))
}

/// What to paste for the file a client dropped at `path` (on its own
/// machine), with what's in it as base64 in `data`: the path itself for a
/// client on this machine, or else the file written into `dir` under its
/// own name. Spaces are escaped, as terminals paste a dropped file's path,
/// and a space follows, so several in a row stay apart.
pub fn paste_text(
    path: &str,
    data: Option<&str>,
    remote: bool,
    dir: &Path,
) -> Result<String, String> {
    let here = if remote {
        let data = data
            .ok_or_else(|| format!("{path} is too big to send to a session on another machine"))?;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(data)
            .map_err(|err| format!("{path} came garbled: {err}"))?;
        let name = Path::new(path).file_name().map_or_else(
            || "dropped".into(),
            |name| name.to_string_lossy().into_owned(),
        );
        std::fs::create_dir_all(dir).map_err(|err| format!("can't keep {name}: {err}"))?;
        let to = free(dir, &name);
        std::fs::write(&to, bytes).map_err(|err| format!("can't keep {name}: {err}"))?;
        to.to_string_lossy().into_owned()
    } else {
        path.to_owned()
    };
    Ok(format!("{} ", here.replace(' ', "\\ ")))
}

/// The files a paste names, when it's nothing but paths to files that
/// `exists` says are there, as a terminal pastes files dropped on it: each
/// with its spaces escaped (`My\ Shot.png`) or in quotes, separated by
/// spaces. None for anything else.
pub fn paths_in(text: &str, exists: impl Fn(&str) -> bool) -> Option<Vec<String>> {
    let mut paths = Vec::new();
    let mut current = String::new();
    let mut quote: Option<char> = None;
    let mut chars = text.trim().chars();
    while let Some(c) = chars.next() {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (None, '\\') => current.push(chars.next()?),
            (None, '"' | '\'') => quote = Some(c),
            (None, c) if c.is_whitespace() => {
                if !current.is_empty() {
                    paths.push(std::mem::take(&mut current));
                }
            }
            (_, c) => current.push(c),
        }
    }
    if quote.is_some() {
        return None;
    }
    if !current.is_empty() {
        paths.push(current);
    }
    let all = !paths.is_empty() && paths.iter().all(|p| p.starts_with('/') && exists(p));
    all.then_some(paths)
}

/// A path in `dir` for `name` that no file has: `name`, else with `-2`,
/// `-3`, ... before its extension (past ten thousand, `name` again).
fn free(dir: &Path, name: &str) -> PathBuf {
    let first = dir.join(name);
    if !first.exists() {
        return first;
    }
    let (stem, ext) = match name.rsplit_once('.') {
        Some((stem, ext)) if !stem.is_empty() => (stem, format!(".{ext}")),
        _ => (name, String::new()),
    };
    (2..10_000)
        .map(|n| dir.join(format!("{stem}-{n}{ext}")))
        .find(|path| !path.exists())
        .unwrap_or(first)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(label: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("greed-dropped-{label}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn a_file_dropped_on_this_machine_is_its_path_with_spaces_escaped() {
        let dir = temp("local");
        let text = paste_text("/home/me/My Shot.png", None, false, &dir).unwrap();
        assert_eq!(text, "/home/me/My\\ Shot.png ");
        assert!(!dir.exists(), "nothing written");
    }

    #[test]
    fn a_file_dropped_elsewhere_is_kept_here_under_its_name_and_another_beside_it() {
        let dir = temp("remote");
        let data = base64::engine::general_purpose::STANDARD.encode(b"png bytes");
        let first = paste_text("/Users/me/shot.png", Some(&data), true, &dir).unwrap();
        assert_eq!(first, format!("{} ", dir.join("shot.png").display()));
        assert_eq!(std::fs::read(dir.join("shot.png")).unwrap(), b"png bytes");
        let second = paste_text("/Users/me/shot.png", Some(&data), true, &dir).unwrap();
        assert_eq!(second, format!("{} ", dir.join("shot-2.png").display()));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_paste_of_paths_to_files_here_is_files_whatever_way_they_re_written() {
        let here = |p: &str| p.starts_with("/home/me/");
        assert_eq!(
            paths_in("/home/me/My\\ Shot.png ", here),
            Some(vec!["/home/me/My Shot.png".to_owned()])
        );
        assert_eq!(
            paths_in("'/home/me/a b.png' \"/home/me/c.png\"", here),
            Some(vec![
                "/home/me/a b.png".to_owned(),
                "/home/me/c.png".to_owned()
            ])
        );
        assert_eq!(paths_in("/elsewhere/x.png", here), None, "not a file here");
        assert_eq!(
            paths_in("echo /home/me/x.png", here),
            None,
            "more than paths"
        );
        assert_eq!(paths_in("relative.png", |_| true), None, "only whole paths");
        assert_eq!(paths_in("", here), None);
    }

    #[test]
    fn a_file_too_big_to_send_says_so() {
        let err = paste_text("/Users/me/movie.mov", None, true, &temp("big")).unwrap_err();
        assert!(err.contains("too big"), "{err}");
    }
}
