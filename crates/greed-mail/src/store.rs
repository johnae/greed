//! The store: a folder holding `mail.db`, what's known about every message,
//! its mailboxes and where each sync got to. One greed-mail at a time uses
//! a store; the `lock` file in it says which.
//!
//! A message is kept once per account, by its identity (`Header::identity`);
//! the mailboxes it's in, and its UID in each, are its places. What a batch
//! fetched and how far the sync got are written in one transaction, the
//! state last, so a crash makes the next sync repeat a batch, never skip
//! one.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::Path;

use rusqlite::{Connection, OptionalExtension, Transaction, params};

use crate::body::Body;
use crate::header::{Fetched, Header};
use crate::imap::Change;

/// The version of the tables; a store from another is refused rather than
/// guessed at.
const VERSION: &str = "3";

const TABLES: &str = "
CREATE TABLE IF NOT EXISTS accounts (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    address TEXT NOT NULL
);
-- `high` and `low` say how far a sync got: every UID from `low` up to
-- `high` is in, new mail comes above `high` and the first sync goes on
-- below `low` until it's 1. Neither is set before the first sync starts.
CREATE TABLE IF NOT EXISTS mailboxes (
    id INTEGER PRIMARY KEY,
    account INTEGER NOT NULL REFERENCES accounts (id),
    name TEXT NOT NULL,
    role TEXT,
    uidvalidity INTEGER,
    uidnext INTEGER,
    highestmodseq INTEGER,
    high INTEGER,
    low INTEGER,
    synced_at TEXT,
    UNIQUE (account, name)
);
CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY,
    account INTEGER NOT NULL REFERENCES accounts (id),
    identity TEXT NOT NULL,
    message_id TEXT,
    date TEXT,
    sender TEXT NOT NULL DEFAULT '',
    recipients TEXT NOT NULL DEFAULT '',
    cc TEXT NOT NULL DEFAULT '',
    subject TEXT NOT NULL DEFAULT '',
    in_reply_to TEXT NOT NULL DEFAULT '',
    refs TEXT NOT NULL DEFAULT '',
    list_id TEXT,
    size INTEGER NOT NULL DEFAULT 0,
    headers BLOB,
    flags TEXT NOT NULL DEFAULT '',
    labels TEXT NOT NULL DEFAULT '',
    -- What thread it's in: the Message-ID of the first message the
    -- thread knows of.
    thread TEXT,
    -- Whether the index has it as it is now: anything that changes it
    -- clears this, and the index catches up.
    indexed INTEGER NOT NULL DEFAULT 0,
    UNIQUE (account, identity)
);
CREATE INDEX IF NOT EXISTS messages_date ON messages (account, date);
CREATE INDEX IF NOT EXISTS messages_message_id ON messages (message_id);
CREATE INDEX IF NOT EXISTS messages_thread ON messages (account, thread);
CREATE TABLE IF NOT EXISTS places (
    message INTEGER NOT NULL REFERENCES messages (id),
    mailbox INTEGER NOT NULL REFERENCES mailboxes (id),
    uid INTEGER NOT NULL,
    PRIMARY KEY (mailbox, uid)
);
CREATE INDEX IF NOT EXISTS places_message ON places (message);
CREATE INDEX IF NOT EXISTS messages_unindexed ON messages (indexed) WHERE indexed = 0;
-- Keys the index still has of messages and threads that went.
CREATE TABLE IF NOT EXISTS unindexed (key TEXT PRIMARY KEY);
";

/// `bodies.db`: each message's text, its HTML packed with zstd and what's
/// attached, by its id in `mail.db`, apart so `mail.db` stays small.
/// `complete` says the whole message was read.
const BODIES: &str = "
CREATE TABLE IF NOT EXISTS bodies.bodies (
    message INTEGER PRIMARY KEY,
    text TEXT,
    html BLOB,
    attachments TEXT NOT NULL DEFAULT '',
    complete INTEGER NOT NULL
);
";

/// A body as `bodies.db` has it: text, packed HTML, attachments as JSON,
/// whether it's complete.
type StoredBody = (Option<String>, Option<Vec<u8>>, String, bool);

/// A message whose body isn't in yet: its id, and its UID and size in the
/// mailbox it's fetched from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Wanting {
    pub message: i64,
    pub uid: u32,
    pub size: u32,
}

/// A message as the index takes it, from what the store has of it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Indexable {
    pub id: i64,
    pub account: i64,
    pub account_name: String,
    /// The account's own address, so its mail can be told from others'.
    pub address: String,
    pub identity: String,
    pub thread: Option<String>,
    pub date: Option<String>,
    pub from: String,
    pub to: String,
    pub cc: String,
    pub subject: String,
    pub list_id: Option<String>,
    pub size: u32,
    pub flags: String,
    pub labels: String,
    /// The mailboxes it's in, by name, and their roles.
    pub places: Vec<(String, Option<String>)>,
    /// Its body's text, once that's in.
    pub text: Option<String>,
    /// Whether something's attached.
    pub attached: bool,
}

/// What went wrong with the store, in words.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Trouble(pub String);

impl std::fmt::Display for Trouble {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl From<rusqlite::Error> for Trouble {
    fn from(error: rusqlite::Error) -> Trouble {
        Trouble(error.to_string())
    }
}

/// Where a mailbox's sync is.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct State {
    pub id: i64,
    pub uid_validity: Option<u32>,
    pub high: Option<u32>,
    pub low: Option<u32>,
    /// The mailbox's HIGHESTMODSEQ when its flags were last known.
    pub modseq: Option<u64>,
}

/// An open store, held by this process until it's dropped.
pub struct Store {
    db: Connection,
    _lock: File,
}

impl Store {
    /// The store in `dir`, made if it isn't there. Refused while another
    /// greed-mail has it.
    pub fn open(dir: &Path) -> Result<Store, Trouble> {
        std::fs::create_dir_all(dir)
            .map_err(|e| Trouble(format!("couldn't make {}: {e}", dir.display())))?;
        let lock_path = dir.join("lock");
        let mut lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(&lock_path)
            .map_err(|e| Trouble(format!("couldn't open {}: {e}", lock_path.display())))?;
        if lock.try_lock().is_err() {
            let holder = std::fs::read_to_string(&lock_path).unwrap_or_default();
            return Err(Trouble(format!(
                "{} is in use by another greed-mail (pid {})",
                dir.display(),
                holder.trim()
            )));
        }
        lock.set_len(0)
            .and_then(|()| write!(lock, "{}", std::process::id()))
            .map_err(|e| Trouble(format!("couldn't write {}: {e}", lock_path.display())))?;
        let db = Connection::open(dir.join("mail.db"))?;
        db.pragma_update(None, "journal_mode", "WAL")?;
        db.pragma_update(None, "synchronous", "NORMAL")?;
        db.pragma_update(None, "foreign_keys", "ON")?;
        // The version first: another's tables may not take this one's.
        db.execute_batch(
            "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);",
        )?;
        let version: Option<String> = db
            .query_row("SELECT value FROM meta WHERE key = 'version'", [], |r| {
                r.get(0)
            })
            .optional()?;
        match version.as_deref() {
            None => {
                db.execute(
                    "INSERT INTO meta (key, value) VALUES ('version', ?1)",
                    [VERSION],
                )?;
            }
            Some(VERSION) => {}
            Some(other) => {
                return Err(Trouble(format!(
                    "{} is a store of another greed-mail (version {other})",
                    dir.display()
                )));
            }
        }
        db.execute_batch(TABLES)?;
        db.execute(
            "ATTACH DATABASE ?1 AS bodies",
            [dir.join("bodies.db").to_string_lossy()],
        )?;
        db.pragma_update(Some("bodies"), "journal_mode", "WAL")?;
        db.execute_batch(BODIES)?;
        Ok(Store { db, _lock: lock })
    }

    /// The id of the account `name`, added if it's new.
    pub fn account(&self, name: &str, address: &str) -> Result<i64, Trouble> {
        self.db.execute(
            "INSERT INTO accounts (name, address) VALUES (?1, ?2)
             ON CONFLICT (name) DO UPDATE SET address = ?2",
            params![name, address],
        )?;
        Ok(self
            .db
            .query_row("SELECT id FROM accounts WHERE name = ?1", [name], |r| {
                r.get(0)
            })?)
    }

    /// Where the sync of `account`'s mailbox `name` is, the mailbox added
    /// if it's new; its role kept as it was without one.
    pub fn mailbox(&self, account: i64, name: &str, role: Option<&str>) -> Result<State, Trouble> {
        self.db.execute(
            "INSERT INTO mailboxes (account, name, role) VALUES (?1, ?2, ?3)
             ON CONFLICT (account, name) DO UPDATE SET role = coalesce(?3, role)",
            params![account, name, role],
        )?;
        Ok(self.db.query_row(
            "SELECT id, uidvalidity, high, low, highestmodseq FROM mailboxes
             WHERE account = ?1 AND name = ?2",
            params![account, name],
            |r| {
                Ok(State {
                    id: r.get(0)?,
                    uid_validity: r.get(1)?,
                    high: r.get(2)?,
                    low: r.get(3)?,
                    modseq: r
                        .get::<_, Option<i64>>(4)?
                        .and_then(|m| u64::try_from(m).ok()),
                })
            },
        )?)
    }

    /// Keeps `modseq` as the HIGHESTMODSEQ `mailbox`'s flags are known at.
    pub fn set_modseq(&self, mailbox: i64, modseq: Option<u64>) -> Result<(), Trouble> {
        let modseq = modseq.and_then(|m| i64::try_from(m).ok());
        self.db.execute(
            "UPDATE mailboxes SET highestmodseq = ?2 WHERE id = ?1",
            params![mailbox, modseq],
        )?;
        Ok(())
    }

    /// Puts the flags (and labels, when given) of `changes` on the
    /// messages at those UIDs in `mailbox`; gives how many changed.
    pub fn set_flags(&mut self, mailbox: i64, changes: &[Change]) -> Result<usize, Trouble> {
        let tx = self.db.transaction()?;
        let mut updated = 0;
        for change in changes {
            updated += tx.execute(
                "UPDATE messages SET flags = ?3, labels = coalesce(?4, labels), indexed = 0
                 WHERE id = (SELECT message FROM places WHERE mailbox = ?1 AND uid = ?2)
                 AND (flags != ?3 OR labels != coalesce(?4, labels))",
                params![
                    mailbox,
                    change.uid,
                    change.flags.join(" "),
                    change.labels.as_ref().map(|labels| labels.join("\n")),
                ],
            )?;
        }
        tx.commit()?;
        Ok(updated)
    }

    /// Takes `uids`, gone from `mailbox` on the server, out of it; a
    /// message that's then in no mailbox goes.
    pub fn forget(&mut self, mailbox: i64, uids: &[u32]) -> Result<(), Trouble> {
        let tx = self.db.transaction()?;
        for uid in uids {
            tx.execute(
                "UPDATE messages SET indexed = 0
                 WHERE id = (SELECT message FROM places WHERE mailbox = ?1 AND uid = ?2)",
                params![mailbox, uid],
            )?;
            tx.execute(
                "DELETE FROM places WHERE mailbox = ?1 AND uid = ?2",
                params![mailbox, uid],
            )?;
        }
        // Those in no mailbox now go from the index too, and their threads
        // when nothing's left in them.
        let gone = "account = (SELECT account FROM mailboxes WHERE id = ?1)
             AND NOT EXISTS (SELECT 1 FROM places WHERE places.message = messages.id)";
        tx.execute(
            &format!(
                "INSERT OR IGNORE INTO unindexed (key)
                 SELECT 'm:' || account || ':' || identity FROM messages WHERE {gone}"
            ),
            [mailbox],
        )?;
        tx.execute(
            &format!(
                "INSERT OR IGNORE INTO unindexed (key)
                 SELECT DISTINCT 't:' || account || ':' || thread FROM messages WHERE {gone}
                 AND NOT EXISTS (SELECT 1 FROM messages AS other JOIN places
                     ON places.message = other.id
                     WHERE other.account = messages.account AND other.thread = messages.thread)"
            ),
            [mailbox],
        )?;
        tx.execute(&format!("DELETE FROM messages WHERE {gone}"), [mailbox])?;
        tx.execute(
            "DELETE FROM bodies.bodies WHERE message NOT IN (SELECT id FROM messages)",
            [],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Starts a mailbox's sync again under `uid_validity`: its UIDs from
    /// before mean nothing now, so its places go and the sync starts from
    /// the top. Messages stay: their headers come again under the new
    /// UIDs and match them by identity, so none is kept twice.
    pub fn restart(&mut self, mailbox: i64, uid_validity: u32) -> Result<(), Trouble> {
        let tx = self.db.transaction()?;
        tx.execute(
            "UPDATE messages SET indexed = 0
             WHERE id IN (SELECT message FROM places WHERE mailbox = ?1)",
            [mailbox],
        )?;
        tx.execute("DELETE FROM places WHERE mailbox = ?1", [mailbox])?;
        tx.execute(
            "UPDATE mailboxes SET uidvalidity = ?2, high = NULL, low = NULL, highestmodseq = NULL
             WHERE id = ?1",
            params![mailbox, uid_validity],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Puts what one fetch got in `mailbox`, then sets how far its sync
    /// got (`high`, `low`), in one transaction.
    pub fn put(
        &mut self,
        account: i64,
        mailbox: i64,
        fetched: &[Fetched],
        high: u32,
        low: u32,
    ) -> Result<(), Trouble> {
        let tx = self.db.transaction()?;
        for f in fetched {
            let id = put_message(&tx, account, f)?;
            tx.execute(
                "INSERT INTO places (message, mailbox, uid) VALUES (?1, ?2, ?3)
                 ON CONFLICT (mailbox, uid) DO UPDATE SET message = ?1",
                params![id, mailbox, f.uid],
            )?;
        }
        tx.execute(
            "UPDATE mailboxes SET high = ?2, low = ?3, synced_at = datetime('now') WHERE id = ?1",
            params![mailbox, high, low],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// How many messages `account` has, and how many places they're in.
    pub fn counts(&self, account: i64) -> Result<(i64, i64), Trouble> {
        Ok(self.db.query_row(
            "SELECT (SELECT count(*) FROM messages WHERE account = ?1),
                    (SELECT count(*) FROM places JOIN mailboxes ON mailboxes.id = places.mailbox
                     WHERE mailboxes.account = ?1)",
            [account],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?)
    }

    /// The flags and labels of `account`'s message `identity`, if it has
    /// one by that identity.
    pub fn flags(&self, account: i64, identity: &str) -> Result<Option<(String, String)>, Trouble> {
        Ok(self
            .db
            .query_row(
                "SELECT flags, labels FROM messages WHERE account = ?1 AND identity = ?2",
                params![account, identity],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?)
    }

    /// Where `account`'s message `identity` can be fetched from: a mailbox
    /// it's in, All Mail before others, and its UID and size there.
    pub fn place_of(
        &self,
        account: i64,
        identity: &str,
    ) -> Result<Option<(String, Wanting)>, Trouble> {
        Ok(self
            .db
            .query_row(
                "SELECT mailboxes.name, messages.id, places.uid, messages.size FROM messages
                 JOIN places ON places.message = messages.id
                 JOIN mailboxes ON mailboxes.id = places.mailbox
                 WHERE messages.account = ?1 AND messages.identity = ?2
                 ORDER BY mailboxes.role IS 'all' DESC LIMIT 1",
                params![account, identity],
                |r| {
                    Ok((
                        r.get(0)?,
                        Wanting {
                            message: r.get(1)?,
                            uid: r.get(2)?,
                            size: r.get(3)?,
                        },
                    ))
                },
            )
            .optional()?)
    }

    /// Up to `most` messages in `mailbox` whose bodies aren't in yet,
    /// unread first, then newest.
    pub fn wanting(&self, mailbox: i64, most: usize) -> Result<Vec<Wanting>, Trouble> {
        let mut statement = self.db.prepare(
            "SELECT messages.id, places.uid, messages.size FROM places
             JOIN messages ON messages.id = places.message
             LEFT JOIN bodies.bodies ON bodies.message = messages.id
             WHERE places.mailbox = ?1 AND bodies.message IS NULL
             ORDER BY instr(messages.flags, '\\Seen') > 0, messages.date DESC
             LIMIT ?2",
        )?;
        let most = i64::try_from(most).unwrap_or(i64::MAX);
        let wanting = statement
            .query_map(params![mailbox, most], |r| {
                Ok(Wanting {
                    message: r.get(0)?,
                    uid: r.get(1)?,
                    size: r.get(2)?,
                })
            })?
            .collect::<Result<_, _>>()?;
        Ok(wanting)
    }

    /// Puts each message's body in, by its id.
    pub fn put_bodies(&mut self, bodies: &[(i64, Body)]) -> Result<(), Trouble> {
        let tx = self.db.transaction()?;
        for (message, body) in bodies {
            let attachments =
                serde_json::to_string(&body.attachments).map_err(|e| Trouble(e.to_string()))?;
            // HTML is most of what a body weighs, and packs well.
            let html = body
                .html
                .as_ref()
                .map(|html| zstd::encode_all(html.as_bytes(), 3))
                .transpose()
                .map_err(|e| Trouble(format!("packing a body: {e}")))?;
            tx.execute(
                "INSERT OR REPLACE INTO bodies.bodies (message, text, html, attachments, complete)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![message, body.text, html, attachments, body.complete],
            )?;
            tx.execute("UPDATE messages SET indexed = 0 WHERE id = ?1", [message])?;
        }
        tx.commit()?;
        Ok(())
    }

    /// The body of `account`'s message `identity`, once it's in.
    pub fn body(&self, account: i64, identity: &str) -> Result<Option<Body>, Trouble> {
        let found: Option<StoredBody> = self
            .db
            .query_row(
                "SELECT text, html, attachments, complete FROM bodies.bodies
                 JOIN messages ON messages.id = bodies.message
                 WHERE messages.account = ?1 AND messages.identity = ?2",
                params![account, identity],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .optional()?;
        let Some((text, html, attachments, complete)) = found else {
            return Ok(None);
        };
        let html = html
            .map(|packed| zstd::decode_all(packed.as_slice()))
            .transpose()
            .map_err(|e| Trouble(format!("unpacking a body: {e}")))?
            .map(|html| String::from_utf8_lossy(&html).into_owned());
        Ok(Some(Body {
            text,
            html,
            attachments: serde_json::from_str(&attachments).unwrap_or_default(),
            complete,
        }))
    }

    /// Up to `most` messages the index doesn't have as they are now.
    pub fn unindexed(&self, most: usize) -> Result<Vec<Indexable>, Trouble> {
        let mut rows = self.db.prepare(
            "SELECT messages.id, messages.account, accounts.name, accounts.address,
                    messages.identity, messages.thread, messages.date, messages.sender,
                    messages.recipients, messages.cc, messages.subject, messages.list_id,
                    messages.size, messages.flags, messages.labels,
                    bodies.text, coalesce(bodies.attachments, '[]') != '[]'
             FROM messages JOIN accounts ON accounts.id = messages.account
             LEFT JOIN bodies.bodies ON bodies.message = messages.id
             WHERE messages.indexed = 0 LIMIT ?1",
        )?;
        let mut places = self.db.prepare(
            "SELECT mailboxes.name, mailboxes.role FROM places
             JOIN mailboxes ON mailboxes.id = places.mailbox WHERE places.message = ?1",
        )?;
        let most = i64::try_from(most).unwrap_or(i64::MAX);
        let mut found: Vec<Indexable> = rows
            .query_map([most], |r| {
                Ok(Indexable {
                    id: r.get(0)?,
                    account: r.get(1)?,
                    account_name: r.get(2)?,
                    address: r.get(3)?,
                    identity: r.get(4)?,
                    thread: r.get(5)?,
                    date: r.get(6)?,
                    from: r.get(7)?,
                    to: r.get(8)?,
                    cc: r.get(9)?,
                    subject: r.get(10)?,
                    list_id: r.get(11)?,
                    size: r.get(12)?,
                    flags: r.get(13)?,
                    labels: r.get(14)?,
                    text: r.get(15)?,
                    attached: r.get(16)?,
                    places: Vec::new(),
                })
            })?
            .collect::<Result<_, _>>()?;
        for message in &mut found {
            message.places = places
                .query_map([message.id], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<Result<_, _>>()?;
        }
        Ok(found)
    }

    /// Notes that the index has the messages `ids` as they are now.
    pub fn indexed(&mut self, ids: &[i64]) -> Result<(), Trouble> {
        let tx = self.db.transaction()?;
        for id in ids {
            tx.execute("UPDATE messages SET indexed = 1 WHERE id = ?1", [id])?;
        }
        tx.commit()?;
        Ok(())
    }

    /// Up to `most` keys of messages and threads that went, which the
    /// index still has.
    pub fn removed(&self, most: usize) -> Result<Vec<String>, Trouble> {
        let mut statement = self.db.prepare("SELECT key FROM unindexed LIMIT ?1")?;
        let most = i64::try_from(most).unwrap_or(i64::MAX);
        let keys = statement
            .query_map([most], |r| r.get(0))?
            .collect::<Result<_, _>>()?;
        Ok(keys)
    }

    /// Notes that the index no longer has `keys`.
    pub fn unlisted(&mut self, keys: &[String]) -> Result<(), Trouble> {
        let tx = self.db.transaction()?;
        for key in keys {
            tx.execute("DELETE FROM unindexed WHERE key = ?1", [key])?;
        }
        tx.commit()?;
        Ok(())
    }

    /// The subject a thread goes by: its first message's.
    pub fn thread_subject(&self, account: i64, thread: &str) -> Result<String, Trouble> {
        Ok(self
            .db
            .query_row(
                "SELECT subject FROM messages WHERE account = ?1 AND thread = ?2
                 ORDER BY date LIMIT 1",
                params![account, thread],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or_default())
    }

    /// The thread of `account`'s message `identity`.
    pub fn thread(&self, account: i64, identity: &str) -> Result<Option<String>, Trouble> {
        Ok(self
            .db
            .query_row(
                "SELECT thread FROM messages WHERE account = ?1 AND identity = ?2",
                params![account, identity],
                |r| r.get(0),
            )
            .optional()?
            .flatten())
    }

    /// The UIDs of `mailbox`'s places, lowest first.
    pub fn uids(&self, mailbox: i64) -> Result<Vec<u32>, Trouble> {
        let mut statement = self
            .db
            .prepare("SELECT uid FROM places WHERE mailbox = ?1 ORDER BY uid")?;
        let uids = statement
            .query_map([mailbox], |r| r.get(0))?
            .collect::<Result<_, _>>()?;
        Ok(uids)
    }
}

/// Puts one message in, or updates the one with its identity; gives its id.
fn put_message(tx: &Transaction<'_>, account: i64, f: &Fetched) -> Result<i64, Trouble> {
    let header = Header::of(f);
    let identity = header.identity(f);
    tx.execute(
        "INSERT INTO messages (account, identity, message_id, date, sender, recipients, cc,
             subject, in_reply_to, refs, list_id, size, headers, flags, labels)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
         ON CONFLICT (account, identity) DO UPDATE SET flags = ?14, labels = ?15, indexed = 0",
        params![
            account,
            identity,
            header.message_id,
            header.date,
            header.from,
            header.to,
            header.cc,
            header.subject,
            header.in_reply_to.join(" "),
            header.references.join(" "),
            header.list_id,
            f.size,
            f.raw,
            f.flags.join(" "),
            f.labels.join("\n"),
        ],
    )?;
    let (id, thread): (i64, Option<String>) = tx.query_row(
        "SELECT id, thread FROM messages WHERE account = ?1 AND identity = ?2",
        params![account, identity],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    if thread.is_none() {
        put_thread(tx, account, id, &header, &identity)?;
    }
    Ok(id)
}

/// Puts message `id`, new to the store, in its thread: that of the first
/// message it refers to (its References' first, which is the thread's
/// start, else what it replies to) when that's in, else one named by that
/// message, or by itself when it refers to none. Messages that came first
/// and named their thread by this one join its thread, as the first sync
/// brings replies before what they reply to.
fn put_thread(
    tx: &Transaction<'_>,
    account: i64,
    id: i64,
    header: &Header,
    identity: &str,
) -> Result<(), Trouble> {
    let refers = header.references.first().or(header.in_reply_to.first());
    let thread = match refers {
        Some(refers) => tx
            .query_row(
                "SELECT thread FROM messages WHERE account = ?1 AND message_id = ?2
                 AND thread IS NOT NULL LIMIT 1",
                params![account, refers],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or_else(|| refers.clone()),
        None => header
            .message_id
            .clone()
            .unwrap_or_else(|| identity.to_string()),
    };
    tx.execute(
        "UPDATE messages SET thread = ?2 WHERE id = ?1",
        params![id, thread],
    )?;
    if let Some(own) = &header.message_id
        && *own != thread
    {
        tx.execute(
            "UPDATE messages SET thread = ?3, indexed = 0 WHERE account = ?1 AND thread = ?2",
            params![account, own, thread],
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("gm-store-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn only_one_greed_mail_has_a_store() {
        let dir = temp("lock");
        let store = Store::open(&dir).unwrap();
        let Err(second) = Store::open(&dir) else {
            panic!("opened twice");
        };
        assert!(
            second.0.contains("in use by another greed-mail"),
            "{second}"
        );
        drop(store);
        assert!(Store::open(&dir).is_ok(), "free again once closed");
    }

    #[test]
    fn a_message_in_two_mailboxes_is_kept_once() {
        let dir = temp("once");
        let mut store = Store::open(&dir).unwrap();
        let account = store.account("a", "a@example.com").unwrap();
        let inbox = store.mailbox(account, "INBOX", Some("inbox")).unwrap();
        let all = store.mailbox(account, "All Mail", Some("all")).unwrap();
        let message = |uid: u32| Fetched {
            uid,
            raw: b"Message-ID: <x@example.com>\r\nX-Pm-Internal-Id: p1\r\n\r\n".to_vec(),
            ..Fetched::default()
        };
        store.put(account, inbox.id, &[message(5)], 5, 5).unwrap();
        store.put(account, all.id, &[message(90)], 90, 90).unwrap();
        assert_eq!(store.counts(account).unwrap(), (1, 2));
        assert_eq!(store.mailbox(account, "INBOX", None).unwrap().high, Some(5));
    }

    /// A message with Bridge id `id`, Message-ID `<id@x>`, referring to
    /// `references` and replying to `reply_to`.
    fn mail(uid: u32, id: &str, references: &[&str], reply_to: Option<&str>) -> Fetched {
        let mut lines = vec![
            format!("X-Pm-Internal-Id: {id}"),
            format!("Message-ID: <{id}@x>"),
        ];
        if !references.is_empty() {
            let refs: Vec<String> = references.iter().map(|r| format!("<{r}@x>")).collect();
            lines.push(format!("References: {}", refs.join(" ")));
        }
        if let Some(parent) = reply_to {
            lines.push(format!("In-Reply-To: <{parent}@x>"));
        }
        let raw = format!("{}\r\n\r\n", lines.join("\r\n"));
        Fetched {
            uid,
            raw: raw.into_bytes(),
            ..Fetched::default()
        }
    }

    #[test]
    fn replies_are_in_the_thread_of_what_they_reply_to_whichever_came_first() {
        let dir = temp("threads");
        let mut store = Store::open(&dir).unwrap();
        let account = store.account("a", "a@example.com").unwrap();
        let inbox = store.mailbox(account, "INBOX", None).unwrap();
        let thread = |store: &Store, id: &str| store.thread(account, &format!("pm:{id}")).unwrap();
        // Newest first: a reply to a reply, then the reply, then the start.
        store
            .put(
                account,
                inbox.id,
                &[mail(3, "c", &["a", "b"], Some("b"))],
                3,
                3,
            )
            .unwrap();
        store
            .put(account, inbox.id, &[mail(2, "b", &["a"], Some("a"))], 3, 2)
            .unwrap();
        store
            .put(account, inbox.id, &[mail(1, "a", &[], None)], 3, 1)
            .unwrap();
        assert_eq!(thread(&store, "a").as_deref(), Some("a@x"));
        assert_eq!(thread(&store, "b"), thread(&store, "a"));
        assert_eq!(thread(&store, "c"), thread(&store, "a"));
        // Only In-Reply-To, to one in the middle that came later.
        store
            .put(account, inbox.id, &[mail(5, "e", &[], Some("d"))], 5, 1)
            .unwrap();
        store
            .put(account, inbox.id, &[mail(4, "d", &["a"], Some("c"))], 5, 1)
            .unwrap();
        assert_eq!(thread(&store, "e"), thread(&store, "a"), "pulled in by d");
        store
            .put(account, inbox.id, &[mail(6, "z", &[], None)], 6, 1)
            .unwrap();
        assert_eq!(
            thread(&store, "z").as_deref(),
            Some("z@x"),
            "a thread of its own"
        );
    }
}
