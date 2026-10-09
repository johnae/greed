use std::collections::HashMap;

/// Settings from `key = value` lines; blank lines and `#` comments are skipped.
pub fn settings(text: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some((key, value)) = line.split_once('=') {
            out.insert(key.trim().to_string(), value.trim().to_string());
        }
    }
    out
}

/// Like `settings`, but only the keys that start with `prefix`, without it.
pub fn section(text: &str, prefix: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some((key, value)) = line.split_once('=') {
            if let Some(rest) = key.trim().strip_prefix(prefix) {
                out.insert(rest.to_string(), value.trim().to_string());
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEXT: &str = "# comment\nname = greed\n\nui.theme = nord\nui.font = mono\n";

    #[test]
    fn reads_every_setting() {
        let all = settings(TEXT);
        assert_eq!(all.len(), 3);
        assert_eq!(all["name"], "greed");
    }

    #[test]
    fn reads_a_section() {
        let ui = section(TEXT, "ui.");
        assert_eq!(ui.len(), 2);
        assert_eq!(ui["theme"], "nord");
    }
}
