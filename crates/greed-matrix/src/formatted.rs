//! A message's text as Greed shows it: its plain body, with the code its
//! HTML has in `<pre>` fenced. Bots often send output (a scanner's
//! box-drawn table, a log) as `<pre>` in the HTML and as bare lines in the
//! body, which would otherwise read as prose and lose their columns.

use matrix_sdk::ruma::events::room::message::{MessageFormat, MessageType};

/// The text of `message`, its `<pre>` blocks fenced.
pub(crate) fn text_of(message: &MessageType) -> String {
    let formatted = match message {
        MessageType::Text(content) => content.formatted.as_ref(),
        MessageType::Notice(content) => content.formatted.as_ref(),
        MessageType::Emote(content) => content.formatted.as_ref(),
        _ => None,
    };
    let body = message.body();
    match formatted {
        Some(f) if f.format == MessageFormat::Html => fence(body, &f.body),
        _ => body.to_string(),
    }
}

/// `body` with each `<pre>` block of `html` fenced where `body` has its
/// text on lines of its own, and not fenced already.
fn fence(body: &str, html: &str) -> String {
    let mut out = body.to_string();
    for code in pre_blocks(html) {
        let code = code.trim_end_matches('\n');
        if code.trim().is_empty() {
            continue;
        }
        let Some(at) = out.find(code) else { continue };
        let starts_line = at == 0 || out[..at].ends_with('\n');
        let end = at + code.len();
        let ends_line = end == out.len() || out[end..].starts_with('\n');
        if !starts_line || !ends_line || out[..at].ends_with("```\n") {
            continue;
        }
        out.replace_range(at..end, &format!("```\n{code}\n```"));
    }
    out
}

/// The text inside each `<pre>` of `html`, its tags gone and its entities
/// read.
fn pre_blocks(html: &str) -> Vec<String> {
    let lower = html.to_ascii_lowercase();
    let mut blocks = Vec::new();
    let mut from = 0;
    while let Some(open) = lower[from..].find("<pre").map(|i| i + from) {
        let Some(start) = lower[open..].find('>').map(|i| i + open + 1) else {
            break;
        };
        let Some(close) = lower[start..].find("</pre>").map(|i| i + start) else {
            break;
        };
        blocks.push(unescape(&strip_tags(&html[start..close])));
        from = close + "</pre>".len();
    }
    blocks
}

fn strip_tags(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut in_tag = false;
    for c in html.chars() {
        match c {
            '<' => in_tag = true,
            '>' if in_tag => in_tag = false,
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out
}

fn unescape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(amp) = rest.find('&') {
        out.push_str(&rest[..amp]);
        rest = &rest[amp..];
        let read = rest.find(';').filter(|&end| end <= 10).and_then(|end| {
            let name = &rest[1..end];
            let c = match name {
                "lt" => Some('<'),
                "gt" => Some('>'),
                "amp" => Some('&'),
                "quot" => Some('"'),
                "apos" => Some('\''),
                "nbsp" => Some('\u{a0}'),
                _ => name
                    .strip_prefix("#x")
                    .or_else(|| name.strip_prefix("#X"))
                    .and_then(|hex| u32::from_str_radix(hex, 16).ok())
                    .or_else(|| name.strip_prefix('#').and_then(|n| n.parse().ok()))
                    .and_then(char::from_u32),
            };
            c.map(|c| (c, end + 1))
        });
        if let Some((c, len)) = read {
            out.push(c);
            rest = &rest[len..];
        } else {
            out.push('&');
            rest = &rest[1..];
        }
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn code_the_html_has_in_pre_is_fenced_in_the_body() {
        let body = "❌ Run failed\n\noutput:\n│ a │ b │\n│ 1 │ 2 │\n\nNotices";
        let html = "<p>❌ Run failed</p><pre><code>output:\n│ a │ b │\n│ 1 │ 2 │\n</code></pre><p>Notices</p>";
        assert_eq!(
            fence(body, html),
            "❌ Run failed\n\n```\noutput:\n│ a │ b │\n│ 1 │ 2 │\n```\n\nNotices"
        );
    }

    #[test]
    fn entities_in_the_code_are_read_before_its_found() {
        let body = "if a < b && c > \"d\" {}";
        let html = "<pre>if a &lt; b &amp;&amp; c &gt; &quot;d&quot; {}</pre>";
        assert_eq!(fence(body, html), format!("```\n{body}\n```"));
    }

    #[test]
    fn a_body_fenced_already_or_without_the_code_stays_as_it_is() {
        let fenced = "```\nls -la\n```";
        assert_eq!(fence(fenced, "<pre><code>ls -la</code></pre>"), fenced);
        assert_eq!(fence("something else", "<pre>ls</pre>"), "something else");
        // Code in the middle of a line isn't a block of its own there.
        assert_eq!(fence("run ls now", "<pre>ls</pre>"), "run ls now");
    }
}
