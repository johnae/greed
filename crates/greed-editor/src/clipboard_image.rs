//! The image on the system clipboard, for a terminal client, which reads it
//! on its own machine, so that with `greed ssh` it's your laptop's clipboard
//! that's read: `wl-paste` on Wayland, `xclip` on X11 and the pasteboard
//! through `osascript` on macOS. A terminal's paste only ever carries text.

use std::process::{Command, Stdio};

/// The PNG on the clipboard, if there's one and a way to read it here.
pub fn read() -> Option<Vec<u8>> {
    let png = if cfg!(target_os = "macos") {
        macos()
    } else if std::env::var_os("WAYLAND_DISPLAY").is_some() {
        wayland().or_else(x11)
    } else {
        x11()
    };
    png.filter(|bytes| is_png(bytes))
}

/// Whether `bytes` start as a PNG does.
fn is_png(bytes: &[u8]) -> bool {
    bytes.starts_with(b"\x89PNG\r\n\x1a\n")
}

/// What `program` with `args` printed, when it ran, worked and printed
/// something.
fn output(program: &str, args: &[&str]) -> Option<Vec<u8>> {
    let out = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    (out.status.success() && !out.stdout.is_empty()).then_some(out.stdout)
}

/// Whether a list of types, one a line, offers PNG.
fn offers_png(types: &[u8]) -> bool {
    String::from_utf8_lossy(types)
        .lines()
        .any(|kind| kind.trim() == "image/png")
}

fn wayland() -> Option<Vec<u8>> {
    if !offers_png(&output("wl-paste", &["--list-types"])?) {
        return None;
    }
    output("wl-paste", &["--no-newline", "--type", "image/png"])
}

fn x11() -> Option<Vec<u8>> {
    let types = output("xclip", &["-selection", "clipboard", "-t", "TARGETS", "-o"])?;
    if !offers_png(&types) {
        return None;
    }
    output(
        "xclip",
        &["-selection", "clipboard", "-t", "image/png", "-o"],
    )
}

fn macos() -> Option<Vec<u8>> {
    let said = output("osascript", &["-e", "the clipboard as «class PNGf»"])?;
    from_applescript(&String::from_utf8_lossy(&said))
}

/// The bytes in the way `AppleScript` prints data, `«data PNGf89504E47…»`.
fn from_applescript(said: &str) -> Option<Vec<u8>> {
    let hex = said.trim().strip_prefix("«data PNGf")?.strip_suffix('»')?;
    if hex.len() % 2 != 0 {
        return None;
    }
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(hex.get(i..i + 2)?, 16).ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn applescript_data_is_read_as_its_bytes() {
        assert_eq!(
            from_applescript("«data PNGf89504E470D0A1A0A»\n"),
            Some(b"\x89PNG\r\n\x1a\n".to_vec())
        );
        assert_eq!(from_applescript("«data PNGf8950»"), Some(vec![0x89, 0x50]));
        assert_eq!(from_applescript("«data TIFF0000»"), None, "another type");
        assert_eq!(from_applescript("«data PNGf895»"), None, "half a byte");
        assert_eq!(from_applescript("«data PNGfZZ»"), None, "not hex");
    }

    #[test]
    fn only_a_png_on_offer_is_read() {
        assert!(offers_png(b"text/plain\nimage/png\n"));
        assert!(!offers_png(b"text/plain\nimage/png+xml\n"));
        assert!(is_png(b"\x89PNG\r\n\x1a\nrest"));
        assert!(!is_png(b"GIF89a"));
    }
}
