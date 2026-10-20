//! Reading the store while a sync writes it: what the client asks for, by
//! the keys the index gives (`indexing::message_key`, `thread_key`). It
//! opens the store's files read-only, so it never waits on the lock and
//! never changes anything.

use std::path::Path;

use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use serde::Serialize;

use crate::body::Attachment;
use crate::header::{Fetched, Header};
use crate::send::Original;
use crate::store::Trouble;

/// A message as a list shows it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Summary {
    pub key: String,
    pub thread: Option<String>,
    pub from: String,
    pub subject: String,
    pub date: Option<String>,
    pub unread: bool,
    pub flagged: bool,
}

/// A message as it's read: its summary, who else it went to, and its body
/// once that's in (`text` nil until then).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Message {
    #[serde(flatten)]
    pub summary: Summary,
    pub to: String,
    pub cc: String,
    pub text: Option<String>,
    pub attachments: Vec<Attachment>,
    /// Whether all of it was read; a big message's text can stop short.
    pub complete: bool,
}

/// A thread: what it's called and its messages, oldest first.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Thread {
    pub key: String,
    pub subject: String,
    pub messages: Vec<Message>,
}

impl Thread {
    /// The keys of its messages whose bodies aren't in yet.
    pub fn bodiless(&self) -> Vec<String> {
        self.messages
            .iter()
            .filter(|m| m.text.is_none())
            .map(|m| m.summary.key.clone())
            .collect()
    }
}

/// The store, open to read.
pub struct Reader {
    db: Connection,
}

/// What a key names: `m:ACCOUNT:IDENTITY` or `t:ACCOUNT:THREAD`.
fn split_key(key: &str) -> Option<(char, i64, &str)> {
    let mut parts = key.splitn(3, ':');
    let kind = parts.next()?.chars().next()?;
    let account = parts.next()?.parse().ok()?;
    Some((kind, account, parts.next()?))
}

const SUMMARY: &str = "SELECT 'm:' || messages.account || ':' || messages.identity,
        CASE WHEN messages.thread IS NULL THEN NULL
             ELSE 't:' || messages.account || ':' || messages.thread END,
        messages.sender, messages.subject, messages.date, messages.flags,
        messages.recipients, messages.cc, bodies.text, bodies.attachments, bodies.complete
     FROM messages LEFT JOIN bodies.bodies ON bodies.message = messages.id";

fn message(r: &rusqlite::Row<'_>) -> rusqlite::Result<Message> {
    let flags: String = r.get(5)?;
    let has = |flag: &str| flags.split(' ').any(|f| f.eq_ignore_ascii_case(flag));
    let attachments: Option<String> = r.get(9)?;
    Ok(Message {
        summary: Summary {
            key: r.get(0)?,
            thread: r.get(1)?,
            from: r.get(2)?,
            subject: r.get(3)?,
            date: r.get(4)?,
            unread: !has("\\Seen"),
            flagged: has("\\Flagged"),
        },
        to: r.get(6)?,
        cc: r.get(7)?,
        text: r.get(8)?,
        attachments: attachments
            .and_then(|a| serde_json::from_str(&a).ok())
            .unwrap_or_default(),
        complete: r.get::<_, Option<bool>>(10)?.unwrap_or(false),
    })
}

impl Reader {
    /// The store in `dir`, to read.
    pub fn open(dir: &Path) -> Result<Reader, Trouble> {
        let db = Connection::open_with_flags(
            dir.join("mail.db"),
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
        )?;
        let bodies = format!("file:{}?mode=ro", dir.join("bodies.db").display());
        db.execute("ATTACH DATABASE ?1 AS bodies", [bodies])?;
        Ok(Reader { db })
    }

    /// What lists show of the messages with `keys`, in that order; keys of
    /// messages that went are left out.
    pub fn summaries(&self, keys: &[String]) -> Result<Vec<Summary>, Trouble> {
        let mut statement = self.db.prepare(&format!(
            "{SUMMARY} WHERE messages.account = ?1 AND messages.identity = ?2"
        ))?;
        let mut out = Vec::new();
        for key in keys {
            let Some(('m', account, identity)) = split_key(key) else {
                continue;
            };
            if let Some(found) = statement
                .query_row(params![account, identity], message)
                .optional()?
            {
                out.push(found.summary);
            }
        }
        Ok(out)
    }

    /// The thread `key` names, or the one the message `key` is in.
    pub fn thread(&self, key: &str) -> Result<Option<Thread>, Trouble> {
        let Some((kind, account, rest)) = split_key(key) else {
            return Ok(None);
        };
        let thread: Option<String> = match kind {
            't' => Some(rest.to_string()),
            'm' => self
                .db
                .query_row(
                    "SELECT thread FROM messages WHERE account = ?1 AND identity = ?2",
                    params![account, rest],
                    |r| r.get(0),
                )
                .optional()?
                .flatten(),
            _ => None,
        };
        let Some(thread) = thread else {
            return Ok(None);
        };
        let mut statement = self.db.prepare(&format!(
            "{SUMMARY} WHERE messages.account = ?1 AND messages.thread = ?2 ORDER BY messages.date"
        ))?;
        let messages: Vec<Message> = statement
            .query_map(params![account, thread], message)?
            .collect::<Result<_, _>>()?;
        let Some(first) = messages.first() else {
            return Ok(None);
        };
        Ok(Some(Thread {
            key: format!("t:{account}:{thread}"),
            subject: first.summary.subject.clone(),
            messages,
        }))
    }

    /// What a reply to the message `key` needs of it, and the name of the
    /// account it's in.
    pub fn original(&self, key: &str) -> Result<Option<(String, Original)>, Trouble> {
        let Some(('m', account, identity)) = split_key(key) else {
            return Ok(None);
        };
        Ok(self
            .db
            .query_row(
                "SELECT accounts.name, accounts.address, messages.message_id, messages.refs,
                     messages.sender, messages.recipients, messages.cc, messages.subject,
                     messages.date, messages.headers, bodies.text
                 FROM messages JOIN accounts ON accounts.id = messages.account
                 LEFT JOIN bodies.bodies ON bodies.message = messages.id
                 WHERE messages.account = ?1 AND messages.identity = ?2",
                params![account, identity],
                |r| {
                    let refs: String = r.get(3)?;
                    let headers: Option<Vec<u8>> = r.get(9)?;
                    let header = Header::of(&Fetched {
                        raw: headers.unwrap_or_default(),
                        ..Fetched::default()
                    });
                    Ok((
                        r.get(0)?,
                        Original {
                            address: r.get(1)?,
                            message_id: r.get(2)?,
                            references: refs.split_whitespace().map(str::to_string).collect(),
                            from: r.get(4)?,
                            reply_to: header.reply_to,
                            to: r.get(5)?,
                            cc: r.get(6)?,
                            subject: r.get(7)?,
                            date: r.get(8)?,
                            text: r.get(10)?,
                        },
                    ))
                },
            )
            .optional()?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::body::Body;
    use crate::header::Fetched;
    use crate::store::Store;

    fn mail(uid: u32, id: &str, subject: &str, reply_to: Option<&str>, flags: &[&str]) -> Fetched {
        let reply = reply_to.map_or(String::new(), |p| format!("In-Reply-To: <{p}@x>\r\n"));
        let raw = format!(
            "From: Bob <bob@x>\r\nTo: anna@x\r\nSubject: {subject}\r\nMessage-ID: <{id}@x>\r\n\
             X-Pm-Internal-Id: {id}\r\nDate: Sun, 19 Oct 2026 10:0{uid}:00 +0200\r\n{reply}\r\n"
        );
        Fetched {
            uid,
            raw: raw.into_bytes(),
            flags: flags.iter().map(ToString::to_string).collect(),
            ..Fetched::default()
        }
    }

    #[test]
    fn a_thread_reads_oldest_first_with_its_bodies_once_theyre_in() {
        let dir = std::env::temp_dir().join(format!("gm-reader-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut store = Store::open(&dir).unwrap();
        let account = store.account("a", "anna@x").unwrap();
        let inbox = store.mailbox(account, "INBOX", Some("inbox")).unwrap();
        store
            .put(
                account,
                inbox.id,
                &[
                    mail(2, "b", "Re: plans", Some("a"), &[]),
                    mail(1, "a", "plans", None, &["\\Seen"]),
                ],
                2,
                1,
            )
            .unwrap();
        let first = store.wanting(inbox.id, 10).unwrap();
        let a = first.iter().find(|w| w.uid == 1).unwrap().message;
        let body = Body {
            text: Some("seeds?".into()),
            complete: true,
            ..Body::default()
        };
        store.put_bodies(&[(a, body)]).unwrap();
        let reader = Reader::open(&dir).unwrap();
        let summaries = reader
            .summaries(&["m:1:pm:b".into(), "m:1:pm:gone".into(), "m:1:pm:a".into()])
            .unwrap();
        let keys: Vec<&str> = summaries.iter().map(|s| s.key.as_str()).collect();
        assert_eq!(
            keys,
            ["m:1:pm:b", "m:1:pm:a"],
            "in the order asked, gone ones left out"
        );
        assert!(summaries[0].unread && !summaries[1].unread);
        assert_eq!(summaries[0].thread, summaries[1].thread);
        let thread = reader.thread("m:1:pm:b").unwrap().unwrap();
        assert_eq!(thread.subject, "plans");
        let subjects: Vec<&str> = thread
            .messages
            .iter()
            .map(|m| m.summary.subject.as_str())
            .collect();
        assert_eq!(subjects, ["plans", "Re: plans"]);
        assert_eq!(thread.messages[0].text.as_deref(), Some("seeds?"));
        assert_eq!(thread.bodiless(), ["m:1:pm:b"]);
        assert_eq!(
            reader.thread(&thread.key).unwrap().unwrap().messages.len(),
            2
        );
        assert_eq!(reader.thread("m:1:pm:nothing").unwrap(), None);
    }
}
