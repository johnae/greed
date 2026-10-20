//! A message as the first fetch knows it: where it is (its UID), its flags,
//! size and dates, the header fields a client lists and threads by, decoded,
//! and on Gmail its id and labels. Bodies come later.

use mail_parser::{Address, HeaderValue, MessageParser};

/// The header fields fetched for every message: what lists, threads and
/// search need, and Bridge's id for a message.
pub const FIELDS: &str =
    "From Reply-To To Cc Subject Date Message-ID In-Reply-To References List-Id X-Pm-Internal-Id";

/// One message's fetch.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Fetched {
    pub uid: u32,
    pub flags: Vec<String>,
    /// When the server got it, RFC 3339.
    pub arrived: Option<String>,
    pub size: u32,
    /// The header fields in `FIELDS`, as the server sent them.
    pub raw: Vec<u8>,
    /// Gmail's id for the message, the same in every label.
    pub gmail_id: Option<u64>,
    pub labels: Vec<String>,
}

/// The header fields of a message, decoded.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Header {
    pub message_id: Option<String>,
    /// When it was written (its Date), else when it arrived, RFC 3339.
    pub date: Option<String>,
    pub from: String,
    /// Where replies go, when not to `from`.
    pub reply_to: String,
    pub to: String,
    pub cc: String,
    pub subject: String,
    pub in_reply_to: Vec<String>,
    pub references: Vec<String>,
    pub list_id: Option<String>,
    /// Bridge's id for the message.
    pub proton_id: Option<String>,
}

impl Header {
    /// `fetched`'s header fields, decoded (encoded words, charsets, folded
    /// lines).
    pub fn of(fetched: &Fetched) -> Header {
        let Some(message) = MessageParser::default().parse_headers(&fetched.raw) else {
            return Header {
                date: fetched.arrived.clone(),
                ..Header::default()
            };
        };
        Header {
            message_id: message.message_id().map(str::to_string),
            date: message
                .date()
                .map(mail_parser::DateTime::to_rfc3339)
                .or_else(|| fetched.arrived.clone()),
            from: addresses(message.from()),
            reply_to: addresses(message.reply_to()),
            to: addresses(message.to()),
            cc: addresses(message.cc()),
            subject: message.subject().unwrap_or_default().to_string(),
            in_reply_to: ids(message.in_reply_to()),
            references: ids(message.references()),
            list_id: list_id(message.list_id()),
            proton_id: message
                .header_raw("X-Pm-Internal-Id")
                .map(|id| id.trim().to_string())
                .filter(|id| !id.is_empty()),
        }
    }

    /// What the message is known by in its account, the same in every
    /// mailbox it's in: Gmail's id, Bridge's, or else its Message-ID with
    /// what it was sent with, as a Message-ID alone isn't always unique.
    pub fn identity(&self, fetched: &Fetched) -> String {
        if let Some(id) = fetched.gmail_id {
            return format!("gm:{id}");
        }
        if let Some(id) = &self.proton_id {
            return format!("pm:{id}");
        }
        let id = self.message_id.as_deref().unwrap_or("");
        let date = self.date.as_deref().unwrap_or("");
        format!("id:{id} {date} {} {}", fetched.size, self.from)
    }
}

/// The addresses in a header, as "Name <address>", comma-separated.
fn addresses(address: Option<&Address<'_>>) -> String {
    let Some(address) = address else {
        return String::new();
    };
    address
        .iter()
        .map(|a| match (&a.name, &a.address) {
            (Some(name), Some(at)) => format!("{name} <{at}>"),
            (None, Some(at)) => at.to_string(),
            (Some(name), None) => name.to_string(),
            (None, None) => String::new(),
        })
        .filter(|a| !a.is_empty())
        .collect::<Vec<_>>()
        .join(", ")
}

/// A List-Id's id, the part in angle brackets after its description.
fn list_id(value: &HeaderValue<'_>) -> Option<String> {
    match value {
        HeaderValue::Text(id) => Some(id.to_string()),
        HeaderValue::Address(address) => address.first()?.address.as_deref().map(str::to_string),
        _ => None,
    }
}

/// The message ids in a header (In-Reply-To, References).
fn ids(value: &HeaderValue<'_>) -> Vec<String> {
    match value {
        HeaderValue::Text(id) => vec![id.to_string()],
        HeaderValue::TextList(list) => list.iter().map(ToString::to_string).collect(),
        _ => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fetched(raw: &str) -> Fetched {
        Fetched {
            uid: 7,
            size: 1200,
            arrived: Some("2026-10-19T08:00:00+00:00".into()),
            raw: raw.replace('\n', "\r\n").into_bytes(),
            ..Fetched::default()
        }
    }

    #[test]
    fn header_fields_are_decoded() {
        let f = fetched(
            "From: =?utf-8?q?Zo=C3=AB_=C3=85ngstr=C3=B6m?= <zoe@example.com>\n\
             To: anna@example.com, Bob <bob@example.com>\n\
             Subject: =?utf-8?b?RmlrYSBww6UgY2Fmw6k=?=\n\
             Date: Sun, 19 Oct 2026 10:15:00 +0200\n\
             Message-ID: <abc@example.com>\n\
             In-Reply-To: <parent@example.com>\n\
             References: <root@example.com>\n <parent@example.com>\n\
             List-Id: Garden club <garden.example.com>\n\n",
        );
        let h = Header::of(&f);
        assert_eq!(h.from, "Zoë Ångström <zoe@example.com>");
        assert_eq!(h.to, "anna@example.com, Bob <bob@example.com>");
        assert_eq!(h.subject, "Fika på café");
        assert_eq!(h.date.as_deref(), Some("2026-10-19T10:15:00+02:00"));
        assert_eq!(h.message_id.as_deref(), Some("abc@example.com"));
        assert_eq!(h.in_reply_to, ["parent@example.com"]);
        assert_eq!(h.references, ["root@example.com", "parent@example.com"]);
        assert_eq!(h.list_id.as_deref(), Some("garden.example.com"));
    }

    #[test]
    fn without_a_date_it_dates_from_arriving() {
        let h = Header::of(&fetched("Subject: hi\n\n"));
        assert_eq!(h.date.as_deref(), Some("2026-10-19T08:00:00+00:00"));
    }

    #[test]
    fn the_identity_is_the_providers_id_when_there_is_one() {
        let mut f = fetched("Message-ID: <abc@example.com>\nX-Pm-Internal-Id: pm-42\n\n");
        let h = Header::of(&f);
        assert_eq!(h.identity(&f), "pm:pm-42");
        f.gmail_id = Some(1_234);
        assert_eq!(h.identity(&f), "gm:1234");
        let plain = fetched("Message-ID: <abc@example.com>\nFrom: a@b\n\n");
        let h = Header::of(&plain);
        assert!(h.identity(&plain).starts_with("id:abc@example.com "));
    }
}
