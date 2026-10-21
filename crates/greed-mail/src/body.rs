//! A message's body as the client reads it: its text, its HTML and what's
//! attached, decoded (MIME, base64, quoted-printable, charsets) from the
//! start of the raw message, at most `CAP` bytes of it. That's all of most
//! messages; of a big one, the parts before its attachments, where the
//! text nearly always is. Attachments themselves come when opened.

use mail_parser::{MessageParser, MessagePart, MimeHeaders, PartType};
use serde::{Deserialize, Serialize};

/// How much of a message is fetched for its body.
pub const CAP: u32 = 256 * 1024;

/// Something attached, as the message lists it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Attachment {
    pub name: String,
    pub mime: String,
    pub size: usize,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Body {
    /// What it says, as text: its plain part, or its HTML made text.
    pub text: Option<String>,
    pub html: Option<String>,
    pub attachments: Vec<Attachment>,
    /// Its iCalendar part, an invite or an answer to one.
    pub calendar: Option<String>,
    /// Whether nothing of its text is missing: the whole message was read,
    /// or what wasn't comes after its text and HTML, in what's attached.
    pub complete: bool,
}

impl Body {
    /// The body of `raw`, the start of a message `size` bytes long.
    pub fn of(raw: &[u8], size: usize) -> Body {
        let whole = raw.len() >= size;
        let Some(message) = MessageParser::default().parse(raw) else {
            return Body {
                complete: whole,
                ..Body::default()
            };
        };
        // The parts cut off run to where the read stopped; when none is
        // text or HTML, the text is all in, only what's attached was cut.
        let read = u32::try_from(raw.len()).unwrap_or(u32::MAX);
        let complete = whole
            || !message.parts.iter().any(|part| {
                part.offset_end >= read
                    && !matches!(part.body, PartType::Multipart(_))
                    && is_text(part)
            });
        // Its plain text, or its HTML as text when that's all it has, as
        // most mail is.
        let text = message.body_text(0).map(std::borrow::Cow::into_owned);
        let html = message
            .html_bodies()
            .find(|part| part.is_text_html())
            .and_then(|part| part.text_contents())
            .map(str::to_string);
        let attachments = message
            .attachments()
            .map(|part| Attachment {
                name: part.attachment_name().unwrap_or_default().to_string(),
                mime: part
                    .content_type()
                    .map_or_else(String::new, |t| match t.subtype() {
                        Some(sub) => format!("{}/{sub}", t.ctype()),
                        None => t.ctype().to_string(),
                    }),
                size: part.len(),
            })
            .collect();
        let calendar = message
            .parts
            .iter()
            .find(|part| {
                part.content_type().is_some_and(|t| {
                    t.ctype().eq_ignore_ascii_case("text")
                        && t.subtype()
                            .is_some_and(|s| s.eq_ignore_ascii_case("calendar"))
                })
            })
            .map(|part| String::from_utf8_lossy(part.contents()).into_owned());
        Body {
            text,
            html,
            attachments,
            calendar,
            complete,
        }
    }
}

/// Whether `part` is text to read: plain or HTML (plain when it doesn't
/// say), and not attached as a file.
fn is_text(part: &MessagePart<'_>) -> bool {
    let attached = part
        .content_disposition()
        .is_some_and(|d| d.ctype().eq_ignore_ascii_case("attachment"));
    let readable = part.content_type().is_none_or(|t| {
        t.ctype().eq_ignore_ascii_case("text")
            && t.subtype()
                .is_none_or(|s| s.eq_ignore_ascii_case("plain") || s.eq_ignore_ascii_case("html"))
    });
    readable && !attached
}

/// Thing number `index` attached to the whole message `raw`, counted as
/// `Body::of` lists them: its name and what it holds, decoded.
pub fn attached(raw: &[u8], index: usize) -> Option<(String, Vec<u8>)> {
    all_attached(raw).into_iter().nth(index)
}

/// Everything attached to the whole message `raw`, in `Body::of`'s order:
/// each one's name and what it holds, decoded.
pub fn all_attached(raw: &[u8]) -> Vec<(String, Vec<u8>)> {
    let Some(message) = MessageParser::default().parse(raw) else {
        return Vec::new();
    };
    message
        .attachments()
        .map(|part| {
            (
                part.attachment_name().unwrap_or_default().to_string(),
                part.contents().to_vec(),
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn message(text: &str) -> Vec<u8> {
        text.replace('\n', "\r\n").into_bytes()
    }

    #[test]
    fn a_plain_message_is_its_text() {
        let raw = message(
            "Subject: hi\nContent-Type: text/plain; charset=utf-8\n\
             Content-Transfer-Encoding: quoted-printable\n\nFika p=C3=A5 caf=C3=A9?\n",
        );
        let body = Body::of(&raw, raw.len());
        assert_eq!(body.text.as_deref(), Some("Fika på café?\r\n"));
        assert_eq!(body.html, None);
        assert!(body.complete);
    }

    #[test]
    fn cut_in_an_attachment_its_text_is_all_in_but_cut_in_its_text_it_isnt() {
        let raw = message(&format!(
            "Subject: invoice\nMIME-Version: 1.0\n\
             Content-Type: multipart/mixed; boundary=\"b1\"\n\n\
             --b1\nContent-Type: text/plain\n\nthe invoice, attached\n\
             --b1\nContent-Type: application/pdf; name=\"invoice.pdf\"\n\
             Content-Disposition: attachment; filename=\"invoice.pdf\"\n\
             Content-Transfer-Encoding: base64\n\n{}\n\
             --b1--\n",
            "JVBERi0xLjQK".repeat(500)
        ));
        let in_attachment = raw.len() - 1000;
        let body = Body::of(&raw[..in_attachment], raw.len());
        assert_eq!(
            body.text.as_deref().map(str::trim),
            Some("the invoice, attached")
        );
        assert!(body.complete, "only the attachment was cut");
        let at = raw.windows(7).position(|w| w == b"invoice").unwrap();
        let text_start = raw.windows(4).position(|w| w == b"the ").unwrap();
        assert!(text_start > at);
        let body = Body::of(&raw[..text_start + 5], raw.len());
        assert!(!body.complete, "the text was cut");
    }

    #[test]
    fn text_html_and_attachments_come_apart() {
        let raw = message(
            "Subject: plans\nMIME-Version: 1.0\n\
             Content-Type: multipart/mixed; boundary=\"b1\"\n\n\
             --b1\nContent-Type: multipart/alternative; boundary=\"b2\"\n\n\
             --b2\nContent-Type: text/plain\n\nthe plan\n\
             --b2\nContent-Type: text/html\n\n<p>the plan</p>\n\
             --b2--\n\
             --b1\nContent-Type: application/pdf; name=\"plan.pdf\"\n\
             Content-Disposition: attachment; filename=\"plan.pdf\"\n\
             Content-Transfer-Encoding: base64\n\nJVBERi0xLjQK\n\
             --b1--\n",
        );
        let body = Body::of(&raw, raw.len());
        assert_eq!(body.text.as_deref().map(str::trim), Some("the plan"));
        assert_eq!(body.html.as_deref().map(str::trim), Some("<p>the plan</p>"));
        assert_eq!(
            body.attachments,
            [Attachment {
                name: "plan.pdf".into(),
                mime: "application/pdf".into(),
                size: 9,
            }]
        );
        assert_eq!(
            attached(&raw, 0),
            Some(("plan.pdf".into(), b"%PDF-1.4\n".to_vec())),
            "decoded"
        );
        assert_eq!(attached(&raw, 1), None);
    }

    #[test]
    fn an_invite_keeps_its_calendar() {
        let raw = message(
            "Subject: Invitation: plans\nMIME-Version: 1.0\n\
             Content-Type: multipart/alternative; boundary=\"b\"\n\n\
             --b\nContent-Type: text/plain\n\nyou're invited\n\
             --b\nContent-Type: text/calendar; charset=utf-8; method=REQUEST\n\
             Content-Transfer-Encoding: base64\n\n\
             QkVHSU46VkNBTEVOREFSDQpFTkQ6VkNBTEVOREFSDQo=\n\
             --b--\n",
        );
        let body = Body::of(&raw, raw.len());
        assert_eq!(body.text.as_deref().map(str::trim), Some("you're invited"));
        assert_eq!(
            body.calendar.as_deref(),
            Some("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")
        );
    }

    #[test]
    fn html_alone_is_read_as_text_too() {
        let raw = message(
            "Subject: news\nContent-Type: text/html; charset=utf-8\n\n\
             <html><body><h1>News</h1><p>Seeds are <b>in</b>.</p></body></html>\n",
        );
        let body = Body::of(&raw, raw.len());
        let text = body.text.unwrap();
        assert!(
            text.contains("News") && text.contains("Seeds are in."),
            "{text}"
        );
        assert!(body.html.unwrap().contains("<b>in</b>"));
    }

    #[test]
    fn the_start_of_a_big_message_still_gives_its_text() {
        let mut raw = message(
            "Subject: photos\nContent-Type: multipart/mixed; boundary=\"b\"\n\n\
             --b\nContent-Type: text/plain\n\nlook at these\n\
             --b\nContent-Type: image/jpeg; name=\"a.jpg\"\n\
             Content-Transfer-Encoding: base64\n\n",
        );
        let cut = raw.len() + 100;
        raw.extend(std::iter::repeat_n(b'A', 100));
        let body = Body::of(&raw, cut + 5_000_000);
        assert_eq!(body.text.as_deref().map(str::trim), Some("look at these"));
        assert!(
            body.complete,
            "only the photo is cut off: its text is all in"
        );
    }
}
