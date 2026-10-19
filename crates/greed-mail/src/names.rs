//! Names as IMAP writes them, made readable: mailbox names and Gmail
//! labels in modified UTF-7 (RFC 3501 5.1.3: `Skr&AOQ-p` is "Skräp"), and
//! labels still escaped as the server quoted them (`\\Inbox`).

/// `name` decoded from modified UTF-7; as it was where it isn't valid.
pub fn decode(name: &str) -> String {
    let mut out = String::new();
    let mut rest = name;
    while let Some(at) = rest.find('&') {
        out.push_str(&rest[..at]);
        let after = &rest[at + 1..];
        let Some(end) = after.find('-') else {
            out.push_str(&rest[at..]);
            return out;
        };
        let encoded = &after[..end];
        if encoded.is_empty() {
            out.push('&');
        } else if let Some(text) = utf16_of(encoded) {
            out.push_str(&text);
        } else {
            out.push_str(&rest[at..=at + end + 1]);
        }
        rest = &after[end + 1..];
    }
    out.push_str(rest);
    out
}

/// A Gmail label from X-GM-LABELS: unescaped (`\\Inbox` is `\Inbox`,
/// `\"` a quote) and decoded.
pub fn label(raw: &str) -> String {
    let mut unescaped = String::with_capacity(raw.len());
    let mut chars = raw.chars();
    while let Some(c) = chars.next() {
        if c == '\\'
            && let Some(next) = chars.clone().next()
            && (next == '\\' || next == '"')
        {
            unescaped.push(next);
            chars.next();
        } else {
            unescaped.push(c);
        }
    }
    decode(&unescaped)
}

/// The text a modified base64 run (`,` for `/`, no padding) of UTF-16
/// stands for.
fn utf16_of(encoded: &str) -> Option<String> {
    let mut bits: u32 = 0;
    let mut count = 0;
    let mut bytes = Vec::new();
    for c in encoded.bytes() {
        let value = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b',' => 63,
            _ => return None,
        };
        bits = (bits << 6) | u32::from(value);
        count += 6;
        if count >= 8 {
            count -= 8;
            bytes.push(u8::try_from((bits >> count) & 0xff).ok()?);
        }
    }
    let units: Vec<u16> = bytes
        .chunks(2)
        .map(|pair| match pair {
            [high, low] => Some(u16::from_be_bytes([*high, *low])),
            _ => None,
        })
        .collect::<Option<_>>()?;
    String::from_utf16(&units).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modified_utf7_names_read_as_text() {
        assert_eq!(decode("INBOX"), "INBOX");
        assert_eq!(decode("Skr&AOQ-p"), "Skräp");
        assert_eq!(decode("Labels/&AMU-terbes&APY-k"), "Labels/Återbesök");
        assert_eq!(decode("Fika &- kaka"), "Fika & kaka");
        assert_eq!(decode("&ZeVnLIqe-"), "日本語");
        assert_eq!(decode("broken &!!-"), "broken &!!-", "left as it was");
        assert_eq!(decode("open &AOQ"), "open &AOQ");
    }

    #[test]
    fn gmail_labels_are_unescaped_and_decoded() {
        assert_eq!(label("\\\\Inbox"), "\\Inbox");
        assert_eq!(label("\\\\Important"), "\\Important");
        assert_eq!(label("Work"), "Work");
        assert_eq!(label("say \\\"hi\\\""), "say \"hi\"");
        assert_eq!(label("Resor/G&APY-teborg"), "Resor/Göteborg");
    }
}
