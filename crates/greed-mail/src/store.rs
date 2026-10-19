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

use crate::header::{Fetched, Header};

/// The version of the tables; a store from another is refused rather than
/// guessed at.
const VERSION: &str = "1";

const TABLES: &str = "
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
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
    UNIQUE (account, identity)
);
CREATE INDEX IF NOT EXISTS messages_date ON messages (account, date);
CREATE INDEX IF NOT EXISTS messages_message_id ON messages (message_id);
CREATE TABLE IF NOT EXISTS places (
    message INTEGER NOT NULL REFERENCES messages (id),
    mailbox INTEGER NOT NULL REFERENCES mailboxes (id),
    uid INTEGER NOT NULL,
    PRIMARY KEY (mailbox, uid)
);
CREATE INDEX IF NOT EXISTS places_message ON places (message);
";

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
        db.execute_batch(TABLES)?;
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
    /// if it's new.
    pub fn mailbox(&self, account: i64, name: &str, role: Option<&str>) -> Result<State, Trouble> {
        self.db.execute(
            "INSERT INTO mailboxes (account, name, role) VALUES (?1, ?2, ?3)
             ON CONFLICT (account, name) DO UPDATE SET role = ?3",
            params![account, name, role],
        )?;
        Ok(self.db.query_row(
            "SELECT id, uidvalidity, high, low FROM mailboxes WHERE account = ?1 AND name = ?2",
            params![account, name],
            |r| {
                Ok(State {
                    id: r.get(0)?,
                    uid_validity: r.get(1)?,
                    high: r.get(2)?,
                    low: r.get(3)?,
                })
            },
        )?)
    }

    /// Starts a mailbox's sync again under `uid_validity`: its UIDs from
    /// before mean nothing now, so its places go and the sync starts from
    /// the top. Messages stay: their headers come again under the new
    /// UIDs and match them by identity, so none is kept twice.
    pub fn restart(&mut self, mailbox: i64, uid_validity: u32) -> Result<(), Trouble> {
        let tx = self.db.transaction()?;
        tx.execute("DELETE FROM places WHERE mailbox = ?1", [mailbox])?;
        tx.execute(
            "UPDATE mailboxes SET uidvalidity = ?2, high = NULL, low = NULL WHERE id = ?1",
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
         ON CONFLICT (account, identity) DO UPDATE SET flags = ?14, labels = ?15",
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
    Ok(tx.query_row(
        "SELECT id FROM messages WHERE account = ?1 AND identity = ?2",
        params![account, identity],
        |r| r.get(0),
    )?)
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
}
