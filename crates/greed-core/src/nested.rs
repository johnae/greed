//! Reading text that nests by indent: YAML, indented JSON, what `kubectl
//! describe` prints. One reader for what keeps a filter's section, what
//! folds, and what completes a section's path.

/// How far `line` is indented and the key it starts with, if any; `None`
/// for a blank line. With `items`, a list item's `- ` counts as indent, as
/// YAML nests a list under its key, so `- name: x` is a key `name` two
/// further in.
pub fn shape(line: &str, items: bool) -> Option<(usize, Option<&str>)> {
    let mut rest = line.trim_start();
    if rest.is_empty() {
        return None;
    }
    let mut indent = line.len() - rest.len();
    while items && let Some(item) = rest.strip_prefix("- ") {
        let after = item.trim_start();
        indent += rest.len() - after.len();
        rest = after;
    }
    Some((indent, key(rest)))
}

/// The key `text` starts with: `name:` or `"name":`, before a colon that
/// ends the line or has a space after it.
fn key(text: &str) -> Option<&str> {
    if let Some(quoted) = text.strip_prefix('"') {
        let (key, after) = quoted.split_once('"')?;
        return (!key.is_empty() && after.trim_start().starts_with(':')).then_some(key);
    }
    let colon = text.match_indices(':').find_map(|(at, _)| {
        let after = &text[at + 1..];
        (after.is_empty() || after.starts_with(' ')).then_some(at)
    })?;
    let key = &text[..colon];
    let fits = !key.is_empty() && key.len() <= 64 && !key.starts_with("- ");
    (fits && !key.contains(['{', '[', '"'])).then_some(key)
}

#[cfg(test)]
mod tests {
    use super::shape;

    #[test]
    fn a_line_has_an_indent_and_maybe_a_key() {
        assert_eq!(shape("status:", true), Some((0, Some("status"))));
        assert_eq!(shape("  phase: Running", true), Some((2, Some("phase"))));
        assert_eq!(
            shape(r#"    "name": "web","#, true),
            Some((4, Some("name")))
        );
        assert_eq!(shape("  - name: x", true), Some((4, Some("name"))));
        assert_eq!(shape("  - name: x", false), Some((2, None)));
        assert_eq!(
            shape("  - -1", true),
            Some((4, None)),
            "a dash before a space only"
        );
        assert_eq!(shape("url: http://x", true), Some((0, Some("url"))));
        assert_eq!(shape("time 12:30 here", true), Some((0, None)));
        assert_eq!(shape(r#"{"a": 1}"#, true), Some((0, None)));
        assert_eq!(shape("   ", true), None);
    }
}
