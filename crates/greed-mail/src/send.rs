//! Writing and sending mail: a reply made ready from the message it
//! answers (`reply`), the message made from what was written (`compose`),
//! and handing it to the account's SMTP server (`deliver`). Mail waits in
//! the store's outbox until its server takes it.

use std::str::FromStr;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use lettre::address::Envelope;
use lettre::message::header::ContentType;
use lettre::message::{Attachment, Mailbox, Mailboxes, MultiPart, SinglePart};
use lettre::transport::smtp::authentication::Credentials;
use lettre::{Address, AsyncSmtpTransport, AsyncTransport, Message, Tokio1Executor};
use serde::{Deserialize, Serialize};

use crate::addresses::{bare, name, split};
use crate::config::{Account, Tls};
use crate::files;

/// How long a server may take to answer while mail is handed to it.
const ANSWERING: Duration = Duration::from_secs(60);

/// Mail as it's written: addresses as headers have them, apart by commas.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Draft {
    /// Who it's from: an account's address or one of its aliases, with a
    /// name or not; empty for the account's own.
    pub from: String,
    pub to: String,
    pub cc: String,
    pub bcc: String,
    pub subject: String,
    pub text: String,
    /// The key of the message it answers.
    pub replying: Option<String>,
    /// The files it carries, by path (`~` for your home folder).
    #[serde(deserialize_with = "crate::json::list")]
    pub attach: Vec<String>,
    /// An answer to an invite it carries (`invite::reply`), sent beside the
    /// text. Only greed-mail sets it, never a draft from the client.
    #[serde(skip)]
    pub calendar: Option<String>,
}

/// What a reply needs of the message it answers.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Original {
    /// The address of the account it's in.
    pub address: String,
    pub message_id: Option<String>,
    pub references: Vec<String>,
    pub from: String,
    pub reply_to: String,
    pub to: String,
    pub cc: String,
    pub subject: String,
    /// RFC 3339.
    pub date: Option<String>,
    pub text: Option<String>,
}

/// Mail on its way: the message as it's sent and who it goes to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Outgoing {
    pub sender: String,
    pub recipients: Vec<String>,
    pub message: Vec<u8>,
}

/// Why mail didn't go: the server won't take it as it is, or couldn't be
/// reached and it's tried again later.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Failure {
    Refused(String),
    Later(String),
}

/// A reply to `original`: to who sent it (its Reply-To when it has one),
/// and with `all` to everyone else it went to as well, but you; from the
/// address of yours it went to (the account's or one of its `aliases`);
/// its subject with "Re:", its text quoted under who wrote it.
pub fn reply(original: &Original, key: &str, all: bool, aliases: &[String]) -> Draft {
    let own = crate::addresses::own(&original.address, aliases);
    let mine = own.contains(&bare(&original.from));
    let went_to: Vec<String> = split(&original.to)
        .into_iter()
        .chain(split(&original.cc))
        .collect();
    let from = went_to
        .iter()
        .map(|a| bare(a))
        .find(|a| own.contains(a))
        .unwrap_or_else(|| original.address.clone());
    // A reply to one's own mail goes on to whom it went.
    let to = if mine {
        original.to.clone()
    } else if original.reply_to.is_empty() {
        original.from.clone()
    } else {
        original.reply_to.clone()
    };
    let cc = if all {
        let taken: Vec<String> = split(&to).iter().map(|a| bare(a)).collect();
        let others: Vec<&str> = went_to
            .iter()
            .map(String::as_str)
            .filter(|a| !own.contains(&bare(a)) && !taken.contains(&bare(a)))
            .collect();
        others.join(", ")
    } else {
        String::new()
    };
    let subject = if original.subject.to_lowercase().starts_with("re:") {
        original.subject.clone()
    } else {
        format!("Re: {}", original.subject)
    };
    Draft {
        from,
        to,
        cc,
        subject,
        text: format!(
            "\n\n{}\n{}",
            wrote(original),
            quoted(original.text.as_deref())
        ),
        replying: Some(key.to_string()),
        ..Draft::default()
    }
}

/// "On 2026-10-19 08:00, Anna Berg wrote:"
fn wrote(original: &Original) -> String {
    let date = original.date.as_deref().unwrap_or("");
    let when = match (date.get(..10), date.get(11..16)) {
        (Some(day), Some(time)) => format!("On {day} {time}, "),
        _ => String::new(),
    };
    let who = name(&original.from).unwrap_or_else(|| original.from.clone());
    format!("{when}{who} wrote:")
}

fn quoted(text: Option<&str>) -> String {
    let text = text.unwrap_or("").replace("\r\n", "\n");
    text.trim_end()
        .lines()
        .map(|line| {
            if line.is_empty() {
                ">".to_string()
            } else {
                format!("> {line}")
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
        + "\n"
}

/// The most the files mail carries may weigh together; most servers take
/// no more.
const ATTACHED: u64 = 25 * 1024 * 1024;

/// The files `paths` name, read: each one's name, what's in it and its
/// kind; or why one can't go.
fn attached(paths: &[String]) -> Result<Vec<(String, Vec<u8>, ContentType)>, String> {
    let mut out = Vec::new();
    let mut weight = 0;
    for path in paths {
        let at = files::expand_home(path.trim());
        let bytes = std::fs::read(&at).map_err(|e| format!("can't attach {path}: {e}"))?;
        weight += bytes.len() as u64;
        if weight > ATTACHED {
            return Err(format!(
                "what's attached weighs more than {} MB, more than mail takes",
                ATTACHED / 1024 / 1024
            ));
        }
        let name = at
            .file_name()
            .map_or_else(|| path.clone(), |n| n.to_string_lossy().into_owned());
        let kind = ContentType::parse(files::kind_of(&name)).map_err(|e| e.to_string())?;
        out.push((name, bytes, kind));
    }
    Ok(out)
}

/// The message `draft` makes, from its `from` or else `address`,
/// answering `original` (its Message-ID and References) when it's a
/// reply, with the files it attaches.
pub fn compose(
    address: &str,
    draft: &Draft,
    original: Option<&Original>,
) -> Result<Outgoing, String> {
    let sender = if draft.from.trim().is_empty() {
        address
    } else {
        draft.from.trim()
    };
    let from: Mailbox = sender
        .parse()
        .map_err(|e| format!("{sender} isn't an address: {e}"))?;
    let own = bare(sender);
    let domain = own.rsplit_once('@').map_or("localhost", |(_, d)| d);
    let mut builder = Message::builder()
        .from(from)
        .subject(draft.subject.clone())
        .message_id(Some(new_id(domain)));
    for (field, list) in [("To", &draft.to), ("Cc", &draft.cc), ("Bcc", &draft.bcc)] {
        if list.trim().is_empty() {
            continue;
        }
        let mailboxes =
            Mailboxes::from_str(list).map_err(|e| format!("{field}: {list} won't do: {e}"))?;
        for mailbox in mailboxes {
            builder = match field {
                "To" => builder.to(mailbox),
                "Cc" => builder.cc(mailbox),
                _ => builder.bcc(mailbox),
            };
        }
    }
    if let Some(original) = original
        && let Some(id) = &original.message_id
    {
        let mut references: Vec<String> = original
            .references
            .iter()
            .map(|r| format!("<{r}>"))
            .collect();
        references.push(format!("<{id}>"));
        builder = builder
            .in_reply_to(format!("<{id}>"))
            .references(references.join(" "));
    }
    let files = attached(&draft.attach)?;
    let built = match &draft.calendar {
        Some(calendar) => {
            let kind = ContentType::parse("text/calendar; charset=utf-8; method=REPLY")
                .map_err(|e| e.to_string())?;
            builder.multipart(
                MultiPart::alternative()
                    .singlepart(SinglePart::plain(draft.text.clone()))
                    .singlepart(SinglePart::builder().header(kind).body(calendar.clone())),
            )
        }
        None if !files.is_empty() => {
            let mut parts = MultiPart::mixed().singlepart(SinglePart::plain(draft.text.clone()));
            for (name, bytes, kind) in files {
                parts = parts.singlepart(Attachment::new(name).body(bytes, kind));
            }
            builder.multipart(parts)
        }
        None => builder
            .header(ContentType::TEXT_PLAIN)
            .body(draft.text.clone()),
    };
    let message = built.map_err(|e| match e {
        lettre::error::Error::MissingTo => "it goes to no one: To is empty".to_string(),
        other => other.to_string(),
    })?;
    let envelope = message.envelope();
    Ok(Outgoing {
        sender: envelope.from().map(ToString::to_string).unwrap_or_default(),
        recipients: envelope.to().iter().map(ToString::to_string).collect(),
        message: message.formatted(),
    })
}

/// A Message-ID no other message has: the time and this process.
fn new_id(domain: &str) -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    format!("<{nanos:x}.{:x}@{domain}>", std::process::id())
}

/// Hands `outgoing` to `account`'s SMTP server.
pub async fn deliver(account: &Account, outgoing: &Outgoing) -> Result<(), Failure> {
    let at = account.smtp().ok_or_else(|| {
        Failure::Refused(format!("{} has no smtp server in mail.toml", account.name))
    })?;
    let unknown = |e: lettre::transport::smtp::Error| Failure::Refused(e.to_string());
    let builder = match at.tls {
        Tls::Implicit => AsyncSmtpTransport::<Tokio1Executor>::relay(&at.host).map_err(unknown)?,
        Tls::Starttls => {
            AsyncSmtpTransport::<Tokio1Executor>::starttls_relay(&at.host).map_err(unknown)?
        }
        Tls::None => AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous(&at.host),
    };
    let password = account.password().map_err(Failure::Later)?;
    let transport = builder
        .port(at.port)
        .credentials(Credentials::new(account.user().to_string(), password))
        .timeout(Some(ANSWERING))
        .build();
    let address = |a: &str| {
        Address::from_str(a).map_err(|e| Failure::Refused(format!("{a} isn't an address: {e}")))
    };
    let recipients = outgoing
        .recipients
        .iter()
        .map(|r| address(r))
        .collect::<Result<Vec<_>, _>>()?;
    let envelope = Envelope::new(Some(address(&outgoing.sender)?), recipients)
        .map_err(|e| Failure::Refused(e.to_string()))?;
    match transport.send_raw(&envelope, &outgoing.message).await {
        Ok(_) => Ok(()),
        Err(e) if e.is_permanent() => Err(Failure::Refused(e.to_string())),
        Err(e) => Err(Failure::Later(e.to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn original() -> Original {
        Original {
            address: "anna@example.com".into(),
            message_id: Some("41@example.com".into()),
            references: vec!["40@example.com".into()],
            from: "Bob Berg <bob@example.com>".into(),
            to: "Anna <ANNA@example.com>, carl@example.com".into(),
            cc: "dora@example.com".into(),
            subject: "Invoice 41".into(),
            date: Some("2026-10-19T08:00:00+02:00".into()),
            text: Some("Please pay.\r\n\r\nBob\r\n".into()),
            ..Original::default()
        }
    }

    #[test]
    fn a_reply_goes_to_the_sender_quoting_what_they_wrote() {
        let draft = reply(&original(), "m:1:x", false, &[]);
        assert_eq!(draft.to, "Bob Berg <bob@example.com>");
        assert_eq!(draft.cc, "");
        assert_eq!(draft.subject, "Re: Invoice 41");
        assert_eq!(
            draft.text,
            "\n\nOn 2026-10-19 08:00, Bob Berg wrote:\n> Please pay.\n>\n> Bob\n"
        );
        assert_eq!(draft.replying.as_deref(), Some("m:1:x"));
        let again = Original {
            subject: "RE: Invoice 41".into(),
            reply_to: "billing@example.com".into(),
            ..original()
        };
        let draft = reply(&again, "m:1:x", false, &[]);
        assert_eq!(draft.subject, "RE: Invoice 41", "one Re: is enough");
        assert_eq!(
            draft.to, "billing@example.com",
            "where it asks replies to go"
        );
    }

    #[test]
    fn a_reply_to_all_copies_everyone_else_but_this_account() {
        let draft = reply(&original(), "m:1:x", true, &[]);
        assert_eq!(draft.to, "Bob Berg <bob@example.com>");
        assert_eq!(draft.cc, "carl@example.com, dora@example.com");
        let own = Original {
            from: "Anna <anna@example.com>".into(),
            to: "bob@example.com".into(),
            cc: String::new(),
            ..original()
        };
        assert_eq!(
            reply(&own, "m:1:x", true, &[]).to,
            "bob@example.com",
            "on to whom it went"
        );
    }

    #[test]
    fn a_composed_reply_answers_its_original() {
        let draft = Draft {
            to: "Bob Berg <bob@example.com>".into(),
            bcc: "me@example.com".into(),
            subject: "Re: Invoice 41".into(),
            text: "Paid.\n".into(),
            ..Draft::default()
        };
        let out = compose("anna@example.com", &draft, Some(&original())).unwrap();
        assert_eq!(out.sender, "anna@example.com");
        assert_eq!(out.recipients, ["bob@example.com", "me@example.com"]);
        let text = String::from_utf8(out.message).unwrap();
        assert!(text.contains("In-Reply-To: <41@example.com>"), "{text}");
        assert!(
            text.contains("References: <40@example.com> <41@example.com>"),
            "{text}"
        );
        assert!(
            !text.contains("Bcc"),
            "Bcc stays out of the message: {text}"
        );
        assert!(
            text.contains("@example.com>\r\n"),
            "a Message-ID of its own: {text}"
        );
        assert!(
            text.ends_with("Paid.\r\n") || text.ends_with("Paid.\n"),
            "{text}"
        );
        let Err(why) = compose("anna@example.com", &Draft::default(), None) else {
            panic!("composed mail to no one");
        };
        assert_eq!(why, "it goes to no one: To is empty");
        let Err(why) = compose(
            "anna@example.com",
            &Draft {
                to: "bob@".into(),
                ..Draft::default()
            },
            None,
        ) else {
            panic!("took a broken address");
        };
        assert!(why.starts_with("To: bob@ won't do"), "{why}");
    }

    #[test]
    fn an_answer_to_an_invite_carries_its_calendar_beside_the_text() {
        let draft = Draft {
            to: "Bob <bob@example.com>".into(),
            subject: "Accepted: plans".into(),
            text: "anna@example.com has accepted.\n".into(),
            calendar: Some("BEGIN:VCALENDAR\r\nMETHOD:REPLY\r\nEND:VCALENDAR\r\n".into()),
            ..Draft::default()
        };
        let out = compose("anna@example.com", &draft, None).unwrap();
        let text = String::from_utf8_lossy(&out.message).into_owned();
        assert!(text.contains("multipart/alternative"), "{text}");
        assert!(text.contains("method=REPLY"), "{text}");
        let body = crate::body::Body::of(&out.message, out.message.len());
        assert_eq!(
            body.text.as_deref().map(str::trim),
            Some("anna@example.com has accepted.")
        );
        assert_eq!(
            body.calendar.as_deref().map(str::trim_end),
            Some("BEGIN:VCALENDAR\r\nMETHOD:REPLY\r\nEND:VCALENDAR")
        );
        let given: Draft = serde_json::from_value(serde_json::json!({
            "to": "x@example.com",
            "calendar": "BEGIN:VCALENDAR",
        }))
        .unwrap();
        assert_eq!(given.calendar, None, "a client can't make one");
        let unattached: Draft = serde_json::from_value(serde_json::json!({
            "to": "x@example.com",
            "attach": {},
        }))
        .unwrap();
        assert!(unattached.attach.is_empty(), "Luau's empty table");
    }

    #[test]
    fn a_reply_goes_from_the_address_of_yours_it_was_sent_to() {
        let mut sent = original();
        sent.to = "Anna <anna@alias.example>, carl@example.com".into();
        let aliases = ["anna@alias.example".to_string()];
        let draft = reply(&sent, "m:1:x", true, &aliases);
        assert_eq!(draft.from, "anna@alias.example");
        assert_eq!(
            draft.cc, "carl@example.com, dora@example.com",
            "not you, by any address"
        );
        assert_eq!(
            reply(&original(), "m:1:x", false, &aliases).from,
            "anna@example.com"
        );
    }

    #[test]
    fn mail_carries_the_files_it_attaches_from_who_it_says() {
        let dir = std::env::temp_dir().join(format!("gm-attach-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("plan.pdf");
        std::fs::write(&file, b"%PDF-1.4\n").unwrap();
        let draft = Draft {
            from: "Anna <anna@alias.example>".into(),
            to: "bob@example.com".into(),
            subject: "the plan".into(),
            text: "Here.\n".into(),
            attach: vec![file.display().to_string()],
            ..Draft::default()
        };
        let out = compose("anna@example.com", &draft, None).unwrap();
        assert_eq!(out.sender, "anna@alias.example");
        let body = crate::body::Body::of(&out.message, out.message.len());
        assert_eq!(body.text.as_deref().map(str::trim), Some("Here."));
        assert_eq!(body.attachments.len(), 1);
        assert_eq!(
            (
                body.attachments[0].name.as_str(),
                body.attachments[0].mime.as_str()
            ),
            ("plan.pdf", "application/pdf")
        );
        let missing = Draft {
            attach: vec![dir.join("gone.txt").display().to_string()],
            ..draft
        };
        let Err(why) = compose("anna@example.com", &missing, None) else {
            panic!("sent without its attachment");
        };
        assert!(why.starts_with("can't attach"), "{why}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
