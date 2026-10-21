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

use crate::addresses;
use crate::body::Body;
use crate::header::{Fetched, Header};
use crate::imap::Change;
use crate::names;
use crate::send::Outgoing;

/// The version of the tables; a store from another is refused rather than
/// guessed at.
const VERSION: &str = "3";

const TABLES: &str = "
CREATE TABLE IF NOT EXISTS accounts (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    address TEXT NOT NULL,
    aliases TEXT NOT NULL DEFAULT ''
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
-- By thread and date: a thread's first message, for its subject, without
-- walking the account's mail in date order.
DROP INDEX IF EXISTS messages_thread;
CREATE INDEX IF NOT EXISTS messages_thread_date ON messages (account, thread, date);
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
-- Messages that came in since their mailbox was all synced, for rules
-- on new mail to look at; taken once looked at.
CREATE TABLE IF NOT EXISTS arrived (message INTEGER PRIMARY KEY);
-- Messages whose attachments were fetched ahead, kept beside the store
-- for opening at once (or tried and found gone).
CREATE TABLE IF NOT EXISTS ahead (message INTEGER PRIMARY KEY);
-- Changes made here that the server doesn't have yet, one for each place
-- they're made in, sent at the start of the next round: `op` is `+` or
-- `-` with `arg` a flag, `move` with `arg` the mailbox it goes to, or
-- `expunge`. `uidvalidity` is the mailbox's when it was made: under
-- another, `uid` means nothing. A message moved has a place in the
-- mailbox it goes to at once, by the UID `-id`, until the sync finds it
-- there under its real one.
CREATE TABLE IF NOT EXISTS pending (
    id INTEGER PRIMARY KEY,
    message INTEGER NOT NULL,
    mailbox INTEGER NOT NULL REFERENCES mailboxes (id),
    uid INTEGER NOT NULL,
    uidvalidity INTEGER,
    op TEXT NOT NULL,
    arg TEXT NOT NULL DEFAULT ''
);
-- Mail written here that its server hasn't taken yet: the message as it's
-- sent and who it goes to, the message it answers (marked answered once
-- it's gone), why its server refused it, when it did, and the time (Unix
-- seconds) before which it waits, to be taken back.
CREATE TABLE IF NOT EXISTS outbox (
    id INTEGER PRIMARY KEY,
    account INTEGER NOT NULL REFERENCES accounts (id),
    sender TEXT NOT NULL,
    recipients TEXT NOT NULL,
    message BLOB NOT NULL,
    replying INTEGER,
    refused TEXT,
    after INTEGER NOT NULL DEFAULT 0
);
";

/// The time now, in Unix seconds.
fn now() -> i64 {
    jiff::Timestamp::now().as_second()
}

/// Whether `schema`'s `table` has `column`.
fn has_column(db: &Connection, schema: &str, table: &str, column: &str) -> Result<bool, Trouble> {
    Ok(db
        .prepare(&format!(
            "SELECT 1 FROM {schema}.pragma_table_info(?1) WHERE name = ?2"
        ))?
        .exists([table, column])?)
}

/// Gives a store from before mail waited to be sent its outbox's `after`,
/// and from before aliases its accounts' `aliases`.
fn add_after(db: &Connection) -> Result<(), Trouble> {
    if !has_column(db, "main", "outbox", "after")? {
        db.execute_batch("ALTER TABLE outbox ADD COLUMN after INTEGER NOT NULL DEFAULT 0")?;
    }
    if !has_column(db, "main", "accounts", "aliases")? {
        db.execute_batch("ALTER TABLE accounts ADD COLUMN aliases TEXT NOT NULL DEFAULT ''")?;
    }
    Ok(())
}

/// Who you've had mail from or written to, for completing addresses: by
/// address (lowercase), the name they go by last, how many messages they're
/// in, how many you wrote them, and when last.
const CONTACTS: &str = "
CREATE TABLE IF NOT EXISTS contacts (
    address TEXT PRIMARY KEY,
    name TEXT NOT NULL DEFAULT '',
    seen INTEGER NOT NULL DEFAULT 0,
    written INTEGER NOT NULL DEFAULT 0,
    last TEXT
);
";

/// Notes the people message `id` is from and to in `contacts`; what goes
/// to them from one of your account's addresses counts as written.
fn note_contacts(db: &Connection, id: i64) -> Result<(), Trouble> {
    let (sender, recipients, cc, date, address, aliases): (
        String,
        String,
        String,
        Option<String>,
        String,
        String,
    ) = db.query_row(
        "SELECT messages.sender, messages.recipients, messages.cc, messages.date,
             accounts.address, accounts.aliases
         FROM messages JOIN accounts ON accounts.id = messages.account
         WHERE messages.id = ?1",
        [id],
        |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get(3)?,
                r.get(4)?,
                r.get(5)?,
            ))
        },
    )?;
    let own = addresses::own(&address, aliases.lines());
    let mine = own.contains(&addresses::bare(&sender));
    let note = |who: &str, wrote: bool| -> Result<(), Trouble> {
        let address = addresses::bare(who);
        if own.contains(&address) || !address.contains('@') {
            return Ok(());
        }
        db.execute(
            "INSERT INTO contacts (address, name, seen, written, last) VALUES (?1, ?2, 1, ?3, ?4)
             ON CONFLICT (address) DO UPDATE SET
                 seen = seen + 1,
                 written = written + ?3,
                 name = CASE WHEN ?2 != '' AND coalesce(?4, '') >= coalesce(last, '')
                     THEN ?2 ELSE name END,
                 last = max(coalesce(last, ''), coalesce(?4, ''))",
            params![
                address,
                addresses::name(who).unwrap_or_default(),
                i64::from(wrote),
                date
            ],
        )?;
        Ok(())
    };
    note(&sender, false)?;
    for who in addresses::split(&recipients)
        .iter()
        .chain(&addresses::split(&cc))
    {
        note(who, mine)?;
    }
    Ok(())
}

/// Fills `contacts` once from the mail already in a store from before it.
fn fill_contacts(db: &Connection) -> Result<(), Trouble> {
    let filled: bool = db
        .prepare("SELECT 1 FROM meta WHERE key = 'contacts'")?
        .exists([])?;
    if filled {
        return Ok(());
    }
    let tx = db.unchecked_transaction()?;
    let ids: Vec<i64> = tx
        .prepare("SELECT id FROM messages")?
        .query_map([], |r| r.get(0))?
        .collect::<Result<_, _>>()?;
    for id in ids {
        note_contacts(&tx, id)?;
    }
    tx.execute("INSERT INTO meta (key, value) VALUES ('contacts', '1')", [])?;
    tx.commit()?;
    Ok(())
}

/// Whether `messages`' row has flags changed here that aren't sent yet:
/// what the server says of its flags until then is from before.
const FLAGGING: &str = "EXISTS (SELECT 1 FROM pending
    WHERE pending.message = messages.id AND pending.op IN ('+', '-'))";

/// The same for Gmail labels put on or taken off here.
const LABELLING: &str = "EXISTS (SELECT 1 FROM pending
    WHERE pending.message = messages.id AND pending.op IN ('label+', 'label-'))";

/// `bodies.db`: each message's text, its HTML packed with zstd and what's
/// attached, by its id in `mail.db`, apart so `mail.db` stays small.
/// `complete` says the whole message was read; `calendar` is its iCalendar
/// part.
const BODIES: &str = "
CREATE TABLE IF NOT EXISTS bodies.bodies (
    message INTEGER PRIMARY KEY,
    text TEXT,
    html BLOB,
    attachments TEXT NOT NULL DEFAULT '',
    complete INTEGER NOT NULL,
    calendar TEXT
);
";

/// How many days back bodies are fetched again when a store gets its
/// `calendar` column, for the invites among them.
const INVITES_BACK: i64 = 60;

/// A body as `bodies.db` has it: text, packed HTML, attachments as JSON,
/// whether it's complete, its calendar.
type StoredBody = (
    Option<String>,
    Option<Vec<u8>>,
    String,
    bool,
    Option<String>,
);

/// Gives a store from before invites its `calendar` column, and has the
/// last `INVITES_BACK` days' bodies fetched again so their invites show.
/// Only this store changes; the mail on the server is left as it is.
fn add_calendar(db: &Connection) -> Result<(), Trouble> {
    if has_column(db, "bodies", "bodies", "calendar")? {
        return Ok(());
    }
    let since = jiff::Timestamp::now()
        .checked_sub(jiff::SignedDuration::from_hours(24 * INVITES_BACK))
        .map_err(|e| Trouble(e.to_string()))?
        .strftime("%Y-%m-%d")
        .to_string();
    db.execute_batch("ALTER TABLE bodies.bodies ADD COLUMN calendar TEXT")?;
    db.execute(
        "DELETE FROM bodies.bodies
         WHERE message IN (SELECT id FROM messages WHERE date >= ?1)",
        [since],
    )?;
    Ok(())
}

/// Has the bodies a store from before called cut short fetched again, once:
/// `complete` used to mean the whole message was read, and now means none
/// of its text is missing, which most of those had all along.
fn recheck_cut(db: &Connection) -> Result<(), Trouble> {
    let done = db
        .prepare("SELECT 1 FROM meta WHERE key = 'complete'")?
        .exists([])?;
    if !done {
        db.execute_batch(
            "DELETE FROM bodies.bodies WHERE complete = 0;
             INSERT INTO meta (key, value) VALUES ('complete', 'text');",
        )?;
    }
    Ok(())
}

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
    /// Its other addresses, mail.toml's `aliases`.
    pub aliases: Vec<String>,
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
    /// What's attached, once its body is in.
    pub attached: Vec<crate::body::Attachment>,
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

/// A change to a message, made in the store at once and on its server in
/// the next round.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    /// Sets (`on`) or clears a flag, like `\Seen`.
    Flag { flag: String, on: bool },
    /// Moves it to the mailbox named `to`, out of every folder it's in.
    Move { to: String },
    /// Moves it to the archive.
    Archive,
    /// Moves it to the trash, or deletes it for good when it's there.
    Trash,
    /// Puts Gmail's label `name` on (`on`) or takes it off; it stays where
    /// it is.
    GmailLabel { name: String, on: bool },
    /// Puts Bridge's label `name` on by copying it into `Labels/NAME`, or
    /// takes it off by deleting it from there, which on Bridge only takes
    /// the label off.
    FolderLabel { name: String, on: bool },
}

/// What undoes a change to one message (`Store::undo`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Undo {
    /// The opposite change: a flag or label as it was.
    Act(Action),
    /// Back in the folder `to` it was in: the move taken back while it
    /// waits to be made on the server, made back once it's been made.
    Back { to: String },
}

/// A change made here, as it's sent: what to do with the message at
/// `uid` in `mailbox`, `op` and `arg` as in the `pending` table.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pending {
    pub id: i64,
    pub mailbox: String,
    pub uid: u32,
    /// The mailbox's UIDVALIDITY when it was made.
    pub uid_validity: Option<u32>,
    pub op: String,
    pub arg: String,
}

/// Mail in the outbox: its id there, the mail, and the id of the message
/// it answers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Posted {
    pub id: i64,
    pub outgoing: Outgoing,
    pub replying: Option<i64>,
}

/// A place of a message, as an action needs it.
struct Place {
    mailbox: i64,
    /// Below 0 for a move made here that the sync hasn't found yet.
    uid: i64,
    uid_validity: Option<u32>,
    name: String,
    role: Option<String>,
}

impl Place {
    /// Whether the message is filed here, as in a folder: not All Mail,
    /// which holds everything, nor a Bridge label.
    fn folder(&self) -> bool {
        self.uid > 0 && self.role.as_deref() != Some("all") && !self.name.starts_with("Labels/")
    }

    /// Whether this is Bridge's label `name` (its `Labels/NAME` mailbox),
    /// there or on its way there.
    fn is_label(&self, name: &str) -> bool {
        names::decode(&self.name) == format!("Labels/{name}")
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
    /// Held while it's open, so no other greed-mail syncs it.
    lock: File,
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
        let db = connect(dir)?;
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
        db.execute_batch(BODIES)?;
        add_calendar(&db)?;
        add_after(&db)?;
        recheck_cut(&db)?;
        db.execute_batch(CONTACTS)?;
        fill_contacts(&db)?;
        Ok(Store { db, lock })
    }

    /// The same store (in `dir`) again, for another part of this greed-mail
    /// to change while this one waits on a server: their changes go one
    /// after the other, never at once.
    pub fn beside(&self, dir: &Path) -> Result<Store, Trouble> {
        let lock = self
            .lock
            .try_clone()
            .map_err(|e| Trouble(format!("couldn't share the store's lock: {e}")))?;
        Ok(Store {
            db: connect(dir)?,
            lock,
        })
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

    /// Notes `account`'s other addresses (mail.toml's `aliases`). When they
    /// changed, what's yours is told again: its mail is indexed again (for
    /// `is:mine`) and contacts are filled again without them.
    pub fn set_aliases(&mut self, account: i64, aliases: &[String]) -> Result<(), Trouble> {
        let now = aliases.join("\n");
        let changed = self.db.execute(
            "UPDATE accounts SET aliases = ?2 WHERE id = ?1 AND aliases != ?2",
            params![account, now],
        )? > 0;
        if changed {
            self.db
                .execute_batch("DELETE FROM contacts; DELETE FROM meta WHERE key = 'contacts';")?;
            fill_contacts(&self.db)?;
            self.db.execute(
                "UPDATE messages SET indexed = 0 WHERE account = ?1",
                [account],
            )?;
        }
        Ok(())
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
    /// messages at those UIDs in `mailbox`; gives how many changed. Flags
    /// changed here and not sent yet stay as they are.
    pub fn set_flags(&mut self, mailbox: i64, changes: &[Change]) -> Result<usize, Trouble> {
        let tx = self.db.transaction()?;
        let mut updated = 0;
        for change in changes {
            updated += tx.execute(
                &format!(
                    "UPDATE messages SET flags = CASE WHEN {FLAGGING} THEN flags ELSE ?3 END,
                     labels = CASE WHEN {LABELLING} THEN labels ELSE coalesce(?4, labels) END,
                     indexed = 0
                     WHERE id = (SELECT message FROM places WHERE mailbox = ?1 AND uid = ?2)
                     AND ((flags != ?3 AND NOT {FLAGGING})
                         OR (labels != coalesce(?4, labels) AND NOT {LABELLING}))"
                ),
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
        let account: i64 = tx.query_row(
            "SELECT account FROM mailboxes WHERE id = ?1",
            [mailbox],
            |r| r.get(0),
        )?;
        drop_placeless(&tx, account)?;
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
    /// got (`high`, `low`), in one transaction. Messages new to the store
    /// in a mailbox that was all in already have arrived: new mail, which
    /// a first sync, however long, never is.
    pub fn put(
        &mut self,
        account: i64,
        mailbox: i64,
        fetched: &[Fetched],
        high: u32,
        low: u32,
    ) -> Result<(), Trouble> {
        let tx = self.db.transaction()?;
        let was_in: Option<u32> =
            tx.query_row("SELECT low FROM mailboxes WHERE id = ?1", [mailbox], |r| {
                r.get(0)
            })?;
        let whole = was_in == Some(1);
        for f in fetched {
            let (id, new) = put_message(&tx, account, f)?;
            if new {
                note_contacts(&tx, id)?;
            }
            if whole && new {
                tx.execute("INSERT OR IGNORE INTO arrived (message) VALUES (?1)", [id])?;
            }
            tx.execute(
                "INSERT INTO places (message, mailbox, uid) VALUES (?1, ?2, ?3)
                 ON CONFLICT (mailbox, uid) DO UPDATE SET message = ?1",
                params![id, mailbox, f.uid],
            )?;
            // Moved here from this end, it's found under its real UID.
            tx.execute(
                "DELETE FROM places WHERE message = ?1 AND mailbox = ?2 AND uid < 0",
                params![id, mailbox],
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
                 WHERE messages.account = ?1 AND messages.identity = ?2 AND places.uid > 0
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
             AND places.uid > 0
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

    /// Up to `most` of `account`'s messages worth having what's attached
    /// fetched ahead: something attached, at most `bytes` in all, flagged
    /// or come since the day `since` ("2026-10-07"), newest first, and not
    /// fetched ahead before. Each one's id and identity.
    pub fn ahead(
        &self,
        account: i64,
        since: &str,
        bytes: u32,
        most: usize,
    ) -> Result<Vec<(i64, String)>, Trouble> {
        let mut statement = self.db.prepare(
            "SELECT messages.id, messages.identity FROM messages
             JOIN bodies.bodies ON bodies.message = messages.id
             WHERE messages.account = ?1 AND bodies.attachments != '[]'
             AND (messages.date >= ?2 OR instr(messages.flags, '\\Flagged') > 0)
             AND messages.size <= ?3
             AND messages.id NOT IN (SELECT message FROM ahead)
             ORDER BY messages.date DESC LIMIT ?4",
        )?;
        let most = i64::try_from(most).unwrap_or(i64::MAX);
        let found = statement
            .query_map(params![account, since, bytes, most], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })?
            .collect::<Result<_, _>>()?;
        Ok(found)
    }

    /// Notes that message `id`'s attachments were fetched ahead.
    pub fn fetched_ahead(&mut self, id: i64) -> Result<(), Trouble> {
        self.db
            .execute("INSERT OR IGNORE INTO ahead (message) VALUES (?1)", [id])?;
        Ok(())
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
                "INSERT OR REPLACE INTO bodies.bodies
                     (message, text, html, attachments, complete, calendar)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    message,
                    body.text,
                    html,
                    attachments,
                    body.complete,
                    body.calendar
                ],
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
                "SELECT text, html, attachments, complete, calendar FROM bodies.bodies
                 JOIN messages ON messages.id = bodies.message
                 WHERE messages.account = ?1 AND messages.identity = ?2",
                params![account, identity],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
            )
            .optional()?;
        let Some((text, html, attachments, complete, calendar)) = found else {
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
            calendar,
            complete,
        }))
    }

    /// How many messages the index doesn't have as they are now.
    pub fn unindexed_count(&self) -> Result<usize, Trouble> {
        let count: i64 =
            self.db
                .query_row("SELECT count(*) FROM messages WHERE indexed = 0", [], |r| {
                    r.get(0)
                })?;
        Ok(usize::try_from(count).unwrap_or(0))
    }

    /// Up to `most` messages the index doesn't have as they are now; of
    /// `only` those, when given.
    pub fn unindexed(&self, most: usize, only: Option<&[i64]>) -> Result<Vec<Indexable>, Trouble> {
        let mut rows = self.db.prepare(
            "SELECT messages.id, messages.account, accounts.name, accounts.address,
                    messages.identity, messages.thread, messages.date, messages.sender,
                    messages.recipients, messages.cc, messages.subject, messages.list_id,
                    messages.size, messages.flags, messages.labels,
                    bodies.text, bodies.attachments,
                    accounts.aliases
             FROM messages JOIN accounts ON accounts.id = messages.account
             LEFT JOIN bodies.bodies ON bodies.message = messages.id
             WHERE messages.indexed = 0
             AND (?2 IS NULL OR messages.id IN (SELECT value FROM json_each(?2)))
             LIMIT ?1",
        )?;
        let mut places = self.db.prepare(
            "SELECT mailboxes.name, mailboxes.role FROM places
             JOIN mailboxes ON mailboxes.id = places.mailbox WHERE places.message = ?1",
        )?;
        let most = i64::try_from(most).unwrap_or(i64::MAX);
        let only = only.map(|ids| serde_json::to_string(ids).unwrap_or_default());
        let mut found: Vec<Indexable> = rows
            .query_map(params![most, only], |r| {
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
                    attached: r
                        .get::<_, Option<String>>(16)?
                        .and_then(|a| serde_json::from_str(&a).ok())
                        .unwrap_or_default(),
                    aliases: r
                        .get::<_, String>(17)?
                        .lines()
                        .map(str::to_string)
                        .collect(),
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

    /// Notes that the index has nothing: every message is written to it
    /// again.
    pub fn unindex_all(&mut self) -> Result<(), Trouble> {
        self.db
            .execute_batch("UPDATE messages SET indexed = 0; DELETE FROM unindexed;")?;
        Ok(())
    }

    /// Notes that the index is made as `version` says; gives whether it
    /// was made another way before, so all of it is written again.
    pub fn indexed_as(&mut self, version: &str) -> Result<bool, Trouble> {
        let was: Option<String> = self
            .db
            .query_row("SELECT value FROM meta WHERE key = 'indexed'", [], |r| {
                r.get(0)
            })
            .optional()?;
        self.db.execute(
            "INSERT INTO meta (key, value) VALUES ('indexed', ?1)
             ON CONFLICT (key) DO UPDATE SET value = ?1",
            [version],
        )?;
        Ok(was.as_deref() != Some(version))
    }

    /// The keys of the messages that arrived since this was last asked,
    /// still there, oldest first; asked once, they're forgotten.
    pub fn arrived(&mut self) -> Result<Vec<String>, Trouble> {
        let tx = self.db.transaction()?;
        let keys = {
            let mut statement = tx.prepare(
                "SELECT 'm:' || messages.account || ':' || messages.identity FROM arrived
                 JOIN messages ON messages.id = arrived.message ORDER BY messages.date",
            )?;
            statement
                .query_map([], |r| r.get(0))?
                .collect::<Result<Vec<String>, _>>()?
        };
        tx.execute("DELETE FROM arrived", [])?;
        tx.commit()?;
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
            .prepare("SELECT uid FROM places WHERE mailbox = ?1 AND uid > 0 ORDER BY uid")?;
        let uids = statement
            .query_map([mailbox], |r| r.get(0))?
            .collect::<Result<_, _>>()?;
        Ok(uids)
    }

    /// The ids of the messages `key` names: a message's
    /// (`m:ACCOUNT:IDENTITY`), or every one in a thread's
    /// (`t:ACCOUNT:THREAD`).
    pub fn messages_of(&self, key: &str) -> Result<Vec<i64>, Trouble> {
        let mut parts = key.splitn(3, ':');
        let (Some(kind), Some(account), Some(name)) = (parts.next(), parts.next(), parts.next())
        else {
            return Ok(Vec::new());
        };
        let column = match kind {
            "m" => "identity",
            "t" => "thread",
            _ => return Ok(Vec::new()),
        };
        let mut statement = self.db.prepare(&format!(
            "SELECT id FROM messages WHERE account = ?1 AND {column} = ?2 ORDER BY date"
        ))?;
        let ids = statement
            .query_map(params![account, name], |r| r.get(0))?
            .collect::<Result<_, _>>()?;
        Ok(ids)
    }

    /// What undoes `action` on message `id`, asked before it's made: None
    /// when it would change nothing, or can't be undone (deleting for
    /// good).
    pub fn undoing(&self, id: i64, action: &Action) -> Result<Option<Undo>, Trouble> {
        let Some((flags, labels)): Option<(String, String)> = self
            .db
            .query_row(
                "SELECT flags, labels FROM messages WHERE id = ?1",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?
        else {
            return Ok(None);
        };
        let places = places_of(&self.db, id)?;
        let folder = places.iter().find(|p| p.folder());
        let back = |unless: &dyn Fn(&Place) -> bool| {
            folder
                .filter(|f| !unless(f))
                .map(|f| Undo::Back { to: f.name.clone() })
        };
        // The opposite of `action`, when it changes something.
        let opposite = |has: bool, on: bool, other: Action| (has != on).then_some(Undo::Act(other));
        Ok(match action {
            Action::Flag { flag, on } => opposite(
                flags.split_whitespace().any(|f| f == flag),
                *on,
                Action::Flag {
                    flag: flag.clone(),
                    on: !on,
                },
            ),
            Action::GmailLabel { name, on } => opposite(
                labels.lines().any(|l| l == name),
                *on,
                Action::GmailLabel {
                    name: name.clone(),
                    on: !on,
                },
            ),
            Action::FolderLabel { name, on } => opposite(
                places.iter().any(|p| p.is_label(name)),
                *on,
                Action::FolderLabel {
                    name: name.clone(),
                    on: !on,
                },
            ),
            Action::Move { to } => back(&|f| f.name == *to),
            Action::Archive => back(&|f| f.role.as_deref() == Some("archive")),
            Action::Trash => back(&|f| f.role.as_deref() == Some("trash")),
        })
    }

    /// Undoes a change to message `id`; gives whether anything changed.
    pub fn undo(&mut self, id: i64, undo: &Undo) -> Result<bool, Trouble> {
        match undo {
            Undo::Act(action) => self.act(id, action),
            Undo::Back { to } => {
                let waiting: Vec<i64> = self
                    .db
                    .prepare(
                        "SELECT id FROM pending WHERE message = ?1 AND op = 'move' ORDER BY id",
                    )?
                    .query_map([id], |r| r.get(0))?
                    .collect::<Result<_, _>>()?;
                if waiting.is_empty() {
                    self.act(id, &Action::Move { to: to.clone() })
                } else {
                    self.take_back(&waiting, false)?;
                    Ok(true)
                }
            }
        }
    }

    /// Whether message `id` is in the trash, where trashing it deletes it
    /// for good.
    pub fn in_trash(&self, id: i64) -> Result<bool, Trouble> {
        Ok(places_of(&self.db, id)?
            .iter()
            .any(|p| p.uid > 0 && p.role.as_deref() == Some("trash")))
    }

    /// Makes `action` on message `id` here, and queues it to be made on
    /// its server; gives whether anything changed.
    pub fn act(&mut self, id: i64, action: &Action) -> Result<bool, Trouble> {
        let tx = self.db.transaction()?;
        let Some((account, flags, labels)): Option<(i64, String, String)> = tx
            .query_row(
                "SELECT account, flags, labels FROM messages WHERE id = ?1",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?
        else {
            return Ok(false);
        };
        let places = places_of(&tx, id)?;
        let changed = match action {
            Action::Flag { flag, on } => flag_here(&tx, id, &flags, &places, flag, *on)?,
            Action::GmailLabel { name, on } => {
                gmail_label_here(&tx, id, &labels, &places, name, *on)?
            }
            Action::FolderLabel { name, on } => {
                let folder = names::encode(&format!("Labels/{name}"));
                let label = mailbox_where(&tx, account, "name", &folder)?.ok_or_else(|| {
                    Trouble(format!("there's no label {name}: make it in Proton first"))
                })?;
                folder_label_here(&tx, id, &places, &label, *on)?
            }
            Action::Move { to } => {
                let to = mailbox_where(&tx, account, "name", to)?
                    .ok_or_else(|| Trouble(format!("there's no mailbox {to}")))?;
                move_here(&tx, id, &places, &to)?
            }
            Action::Archive => {
                let to = mailbox_where(&tx, account, "role", "archive")?
                    .ok_or_else(|| Trouble("there's no archive to move it to".into()))?;
                move_here(&tx, id, &places, &to)?
            }
            Action::Trash => {
                let trash = mailbox_where(&tx, account, "role", "trash")?
                    .ok_or_else(|| Trouble("there's no trash to move it to".into()))?;
                if places.iter().any(|p| p.mailbox == trash.0 && p.uid > 0) {
                    expunge_here(&tx, id, account, &places, trash.0)?
                } else {
                    move_here(&tx, id, &places, &trash)?
                }
            }
        };
        tx.commit()?;
        Ok(changed)
    }

    /// What `account` changed here that its server doesn't have yet, in
    /// the order it was done.
    pub fn pending(&self, account: i64) -> Result<Vec<Pending>, Trouble> {
        let mut statement = self.db.prepare(
            "SELECT pending.id, mailboxes.name, pending.uid, pending.uidvalidity, pending.op,
                 pending.arg
             FROM pending JOIN mailboxes ON mailboxes.id = pending.mailbox
             WHERE mailboxes.account = ?1 ORDER BY pending.id",
        )?;
        let pending = statement
            .query_map([account], |r| {
                Ok(Pending {
                    id: r.get(0)?,
                    mailbox: r.get(1)?,
                    uid: r.get(2)?,
                    uid_validity: r.get(3)?,
                    op: r.get(4)?,
                    arg: r.get(5)?,
                })
            })?
            .collect::<Result<_, _>>()?;
        Ok(pending)
    }

    /// Notes that the server has the changes `ids`.
    pub fn sent(&mut self, ids: &[i64]) -> Result<(), Trouble> {
        let tx = self.db.transaction()?;
        for id in ids {
            tx.execute("DELETE FROM pending WHERE id = ?1", [id])?;
        }
        tx.commit()?;
        Ok(())
    }

    /// Puts `outgoing` in `account`'s outbox, answering message `replying`,
    /// to wait there until `after` (Unix seconds); gives its id there.
    pub fn post(
        &mut self,
        account: i64,
        outgoing: &Outgoing,
        replying: Option<i64>,
        after: i64,
    ) -> Result<i64, Trouble> {
        self.db.execute(
            "INSERT INTO outbox (account, sender, recipients, message, replying, after)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                account,
                outgoing.sender,
                outgoing.recipients.join("\n"),
                outgoing.message,
                replying,
                after
            ],
        )?;
        Ok(self.db.last_insert_rowid())
    }

    /// Takes mail `id` out of the outbox while it still waits; gives
    /// whether it did, false once it's on its way.
    pub fn unpost(&mut self, id: i64) -> Result<bool, Trouble> {
        Ok(self.db.execute(
            "DELETE FROM outbox WHERE id = ?1 AND after > ?2 AND refused IS NULL",
            params![id, now()],
        )? > 0)
    }

    /// When the next mail waiting in the outbox may go (Unix seconds).
    pub fn next_due(&self) -> Result<Option<i64>, Trouble> {
        Ok(self.db.query_row(
            "SELECT min(after) FROM outbox WHERE refused IS NULL AND after > ?1",
            [now()],
            |r| r.get(0),
        )?)
    }

    /// What's in `account`'s outbox to send, oldest first: not what its
    /// server refused, nor what still waits.
    pub fn outbox(&self, account: i64) -> Result<Vec<Posted>, Trouble> {
        let mut statement = self.db.prepare(
            "SELECT id, sender, recipients, message, replying FROM outbox
             WHERE account = ?1 AND refused IS NULL AND after <= ?2 ORDER BY id",
        )?;
        let posted = statement
            .query_map(params![account, now()], |r| {
                let recipients: String = r.get(2)?;
                Ok(Posted {
                    id: r.get(0)?,
                    outgoing: Outgoing {
                        sender: r.get(1)?,
                        recipients: recipients.lines().map(str::to_string).collect(),
                        message: r.get(3)?,
                    },
                    replying: r.get(4)?,
                })
            })?
            .collect::<Result<_, _>>()?;
        Ok(posted)
    }

    /// Takes mail `id` out of the outbox: it's gone, or with `refused` its
    /// server won't take it and it stays, not sent again, saying why.
    pub fn sent_out(&mut self, id: i64, refused: Option<&str>) -> Result<(), Trouble> {
        match refused {
            None => self.db.execute("DELETE FROM outbox WHERE id = ?1", [id])?,
            Some(why) => self.db.execute(
                "UPDATE outbox SET refused = ?2 WHERE id = ?1",
                params![id, why],
            )?,
        };
        Ok(())
    }

    /// The name of `account`'s mailbox with `role` (sent, trash...).
    pub fn role(&self, account: i64, role: &str) -> Result<Option<String>, Trouble> {
        Ok(mailbox_where(&self.db, account, "role", role)?.map(|(_, name)| name))
    }

    /// Takes back the changes `ids`, which the server refused or which
    /// came too late (the mailbox's UIDs started over): a flag is as it
    /// was, a message moved or deleted is back where it was, unless
    /// `forsaken`, when its old place means nothing now.
    pub fn take_back(&mut self, ids: &[i64], forsaken: bool) -> Result<(), Trouble> {
        let tx = self.db.transaction()?;
        for id in ids {
            let Some((message, mailbox, uid, op, arg)): Option<(i64, i64, u32, String, String)> =
                tx.query_row(
                    "SELECT message, mailbox, uid, op, arg FROM pending WHERE id = ?1",
                    [id],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
                )
                .optional()?
            else {
                continue;
            };
            tx.execute("DELETE FROM pending WHERE id = ?1", [id])?;
            tx.execute("UPDATE messages SET indexed = 0 WHERE id = ?1", [message])?;
            match op.as_str() {
                "+" | "-" => {
                    let flags: String =
                        tx.query_row("SELECT flags FROM messages WHERE id = ?1", [message], |r| {
                            r.get(0)
                        })?;
                    let flags = with_flag(&flags, &arg, op == "-");
                    tx.execute(
                        "UPDATE messages SET flags = ?2 WHERE id = ?1",
                        params![message, flags],
                    )?;
                }
                "label+" | "label-" => {
                    let labels: String = tx.query_row(
                        "SELECT labels FROM messages WHERE id = ?1",
                        [message],
                        |r| r.get(0),
                    )?;
                    let labels = with_label(&labels, &arg, op == "label-");
                    tx.execute(
                        "UPDATE messages SET labels = ?2 WHERE id = ?1",
                        params![message, labels],
                    )?;
                }
                // A label that didn't go on: only its place there goes.
                "copy" => {
                    tx.execute(
                        "DELETE FROM places WHERE message = ?1 AND uid = ?2",
                        params![message, -id],
                    )?;
                }
                _ => {
                    tx.execute(
                        "DELETE FROM places WHERE message = ?1 AND uid < 0",
                        [message],
                    )?;
                    if !forsaken {
                        tx.execute(
                            "INSERT OR IGNORE INTO places (message, mailbox, uid)
                             VALUES (?1, ?2, ?3)",
                            params![message, mailbox, uid],
                        )?;
                    }
                }
            }
        }
        tx.commit()?;
        Ok(())
    }
}

/// A connection to the store in `dir`, `bodies.db` attached.
fn connect(dir: &Path) -> Result<Connection, Trouble> {
    let db = Connection::open(dir.join("mail.db"))?;
    db.pragma_update(None, "journal_mode", "WAL")?;
    db.pragma_update(None, "synchronous", "NORMAL")?;
    db.pragma_update(None, "foreign_keys", "ON")?;
    db.busy_timeout(std::time::Duration::from_secs(5))?;
    db.execute(
        "ATTACH DATABASE ?1 AS bodies",
        [dir.join("bodies.db").to_string_lossy()],
    )?;
    db.pragma_update(Some("bodies"), "journal_mode", "WAL")?;
    Ok(db)
}

/// Takes out `account`'s messages that are in no mailbox now, from the
/// index too, and their threads when nothing's left in them.
fn drop_placeless(tx: &Transaction<'_>, account: i64) -> Result<(), Trouble> {
    let gone = "account = ?1
         AND NOT EXISTS (SELECT 1 FROM places WHERE places.message = messages.id)";
    tx.execute(
        &format!(
            "INSERT OR IGNORE INTO unindexed (key)
             SELECT 'm:' || account || ':' || identity FROM messages WHERE {gone}"
        ),
        [account],
    )?;
    tx.execute(
        &format!(
            "INSERT OR IGNORE INTO unindexed (key)
             SELECT DISTINCT 't:' || account || ':' || thread FROM messages WHERE {gone}
             AND NOT EXISTS (SELECT 1 FROM messages AS other JOIN places
                 ON places.message = other.id
                 WHERE other.account = messages.account AND other.thread = messages.thread)"
        ),
        [account],
    )?;
    tx.execute(&format!("DELETE FROM messages WHERE {gone}"), [account])?;
    tx.execute(
        "DELETE FROM bodies.bodies WHERE message NOT IN (SELECT id FROM messages)",
        [],
    )?;
    Ok(())
}

/// Message `id`'s places, those it's moving to included.
fn places_of(db: &Connection, id: i64) -> Result<Vec<Place>, Trouble> {
    let mut statement = db.prepare(
        "SELECT places.mailbox, places.uid, mailboxes.uidvalidity, mailboxes.name, mailboxes.role
         FROM places JOIN mailboxes ON mailboxes.id = places.mailbox
         WHERE places.message = ?1",
    )?;
    let places = statement
        .query_map([id], |r| {
            Ok(Place {
                mailbox: r.get(0)?,
                uid: r.get(1)?,
                uid_validity: r.get(2)?,
                name: r.get(3)?,
                role: r.get(4)?,
            })
        })?
        .collect::<Result<_, _>>()?;
    Ok(places)
}

/// The id and name of `account`'s mailbox whose `column` (name or role)
/// is `value`.
fn mailbox_where(
    db: &Connection,
    account: i64,
    column: &str,
    value: &str,
) -> Result<Option<(i64, String)>, Trouble> {
    Ok(db
        .query_row(
            &format!("SELECT id, name FROM mailboxes WHERE account = ?1 AND {column} = ?2"),
            params![account, value],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?)
}

/// `flags` (as the store keeps them, apart by spaces) with `flag` set
/// (`on`) or cleared.
fn with_flag(flags: &str, flag: &str, on: bool) -> String {
    let mut list: Vec<&str> = flags.split_whitespace().filter(|f| *f != flag).collect();
    if on {
        list.push(flag);
    }
    list.join(" ")
}

/// `labels` (one a line) with `name` put on (`on`) or taken off.
fn with_label(labels: &str, name: &str, on: bool) -> String {
    let mut list: Vec<&str> = labels
        .lines()
        .filter(|l| !l.is_empty() && *l != name)
        .collect();
    if on {
        list.push(name);
    }
    list.join("\n")
}

/// Queues a change for message `id` in `place`, giving its id.
fn queue(
    tx: &Transaction<'_>,
    id: i64,
    place: &Place,
    op: &str,
    arg: &str,
) -> Result<i64, Trouble> {
    tx.execute(
        "INSERT INTO pending (message, mailbox, uid, uidvalidity, op, arg)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![id, place.mailbox, place.uid, place.uid_validity, op, arg],
    )?;
    Ok(tx.last_insert_rowid())
}

/// Sets or clears `flag` on message `id` (whose flags are `flags`) here
/// and, queued, in each of its places; a change to the same flag still
/// waiting gives way to this one.
fn flag_here(
    tx: &Transaction<'_>,
    id: i64,
    flags: &str,
    places: &[Place],
    flag: &str,
    on: bool,
) -> Result<bool, Trouble> {
    if flags.split_whitespace().any(|f| f == flag) == on {
        return Ok(false);
    }
    tx.execute(
        "UPDATE messages SET flags = ?2, indexed = 0 WHERE id = ?1",
        params![id, with_flag(flags, flag, on)],
    )?;
    tx.execute(
        "DELETE FROM pending WHERE message = ?1 AND op IN ('+', '-') AND arg = ?2",
        params![id, flag],
    )?;
    for place in places.iter().filter(|p| p.uid > 0) {
        queue(tx, id, place, if on { "+" } else { "-" }, flag)?;
    }
    Ok(true)
}

/// Puts Gmail's label `name` on message `id` (whose labels are `labels`,
/// one a line) or takes it off, here and, queued, on the server in its
/// All Mail place; a change to the same label still waiting gives way.
fn gmail_label_here(
    tx: &Transaction<'_>,
    id: i64,
    labels: &str,
    places: &[Place],
    name: &str,
    on: bool,
) -> Result<bool, Trouble> {
    if labels.lines().any(|l| l == name) == on {
        return Ok(false);
    }
    let place = places
        .iter()
        .filter(|p| p.uid > 0)
        .max_by_key(|p| p.role.as_deref() == Some("all"))
        .ok_or_else(|| Trouble("it isn't on the server yet".into()))?;
    tx.execute(
        "UPDATE messages SET labels = ?2, indexed = 0 WHERE id = ?1",
        params![id, with_label(labels, name, on)],
    )?;
    tx.execute(
        "DELETE FROM pending WHERE message = ?1 AND op IN ('label+', 'label-') AND arg = ?2",
        params![id, name],
    )?;
    queue(tx, id, place, if on { "label+" } else { "label-" }, name)?;
    Ok(true)
}

/// Puts Bridge's label `label` (its mailbox's id and name) on message `id`
/// by copying it there from a folder it's in, or takes it off by deleting
/// it from there, which on Bridge leaves the message where else it is. A
/// copy still waiting is dropped rather than undone on the server.
fn folder_label_here(
    tx: &Transaction<'_>,
    id: i64,
    places: &[Place],
    label: &(i64, String),
    on: bool,
) -> Result<bool, Trouble> {
    let there = places.iter().find(|p| p.mailbox == label.0);
    match (on, there) {
        (true, Some(_)) | (false, None) => return Ok(false),
        (true, None) => {
            let from = places
                .iter()
                .filter(|p| p.uid > 0 && !p.name.starts_with("Labels/"))
                .max_by_key(|p| p.folder())
                .ok_or_else(|| Trouble("it isn't on the server yet".into()))?;
            let copy = queue(tx, id, from, "copy", &label.1)?;
            tx.execute(
                "INSERT INTO places (message, mailbox, uid) VALUES (?1, ?2, ?3)",
                params![id, label.0, -copy],
            )?;
        }
        (false, Some(there)) if there.uid < 0 => {
            tx.execute(
                "DELETE FROM pending WHERE id = ?1 AND op = 'copy'",
                [-there.uid],
            )?;
            tx.execute(
                "DELETE FROM places WHERE message = ?1 AND mailbox = ?2",
                params![id, label.0],
            )?;
        }
        (false, Some(there)) => {
            queue(tx, id, there, "expunge", "")?;
            tx.execute(
                "DELETE FROM places WHERE mailbox = ?1 AND uid = ?2",
                params![there.mailbox, there.uid],
            )?;
        }
    }
    tx.execute("UPDATE messages SET indexed = 0 WHERE id = ?1", [id])?;
    Ok(true)
}

/// Moves message `id` out of each folder it's in to mailbox `to` (its id
/// and name), where it has a place at once.
fn move_here(
    tx: &Transaction<'_>,
    id: i64,
    places: &[Place],
    to: &(i64, String),
) -> Result<bool, Trouble> {
    let from: Vec<&Place> = places
        .iter()
        .filter(|p| p.folder() && p.mailbox != to.0)
        .collect();
    if from.is_empty() {
        return Ok(false);
    }
    let mut last = 0;
    for place in from {
        last = queue(tx, id, place, "move", &to.1)?;
        tx.execute(
            "DELETE FROM places WHERE mailbox = ?1 AND uid = ?2",
            params![place.mailbox, place.uid],
        )?;
    }
    if !places.iter().any(|p| p.mailbox == to.0) {
        tx.execute(
            "INSERT INTO places (message, mailbox, uid) VALUES (?1, ?2, ?3)",
            params![id, to.0, -last],
        )?;
    }
    tx.execute("UPDATE messages SET indexed = 0 WHERE id = ?1", [id])?;
    Ok(true)
}

/// Deletes message `id` for good from mailbox `trash`; once it's in no
/// mailbox, it's gone here.
fn expunge_here(
    tx: &Transaction<'_>,
    id: i64,
    account: i64,
    places: &[Place],
    trash: i64,
) -> Result<bool, Trouble> {
    for place in places.iter().filter(|p| p.mailbox == trash && p.uid > 0) {
        queue(tx, id, place, "expunge", "")?;
        tx.execute(
            "DELETE FROM places WHERE mailbox = ?1 AND uid = ?2",
            params![place.mailbox, place.uid],
        )?;
    }
    tx.execute("UPDATE messages SET indexed = 0 WHERE id = ?1", [id])?;
    drop_placeless(tx, account)?;
    Ok(true)
}

/// Puts one message in, or updates the one with its identity; gives its id
/// and whether it's new to the store.
fn put_message(tx: &Transaction<'_>, account: i64, f: &Fetched) -> Result<(i64, bool), Trouble> {
    let header = Header::of(f);
    let identity = header.identity(f);
    tx.execute(
        &format!(
            "INSERT INTO messages (account, identity, message_id, date, sender, recipients, cc,
                 subject, in_reply_to, refs, list_id, size, headers, flags, labels)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
             ON CONFLICT (account, identity) DO UPDATE SET
                 flags = CASE WHEN {FLAGGING} THEN flags ELSE ?14 END,
                 labels = CASE WHEN {LABELLING} THEN labels ELSE ?15 END, indexed = 0"
        ),
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
    let new = thread.is_none();
    if new {
        put_thread(tx, account, id, &header, &identity)?;
    }
    Ok((id, new))
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
    fn bodies_called_cut_short_before_are_fetched_again_once() {
        let dir = temp("recheck");
        let mut store = Store::open(&dir).unwrap();
        let account = store.account("a", "a@example.com").unwrap();
        let inbox = store.mailbox(account, "INBOX", Some("inbox")).unwrap();
        let raw = b"Message-ID: <x@example.com>\r\nX-Pm-Internal-Id: p1\r\n\r\n".to_vec();
        let fetched = Fetched {
            uid: 1,
            raw,
            ..Fetched::default()
        };
        store.put(account, inbox.id, &[fetched], 1, 1).unwrap();
        let id = store.wanting(inbox.id, 10).unwrap()[0].message;
        let cut = Body {
            text: Some("hi".into()),
            complete: false,
            ..Body::default()
        };
        store.put_bodies(&[(id, cut)]).unwrap();
        drop(store);
        let store = Store::open(&dir).unwrap();
        assert!(
            store.wanting(inbox.id, 10).unwrap().is_empty(),
            "a store made now keeps it"
        );
        store
            .db
            .execute("DELETE FROM meta WHERE key = 'complete'", [])
            .unwrap();
        drop(store);
        let store = Store::open(&dir).unwrap();
        assert_eq!(
            store.wanting(inbox.id, 10).unwrap().len(),
            1,
            "one from before fetches it again"
        );
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

    /// The places of message `id`, as (mailbox, UID), sorted.
    fn places(store: &Store, id: i64) -> Vec<(i64, i64)> {
        let mut statement = store
            .db
            .prepare("SELECT mailbox, uid FROM places WHERE message = ?1 ORDER BY mailbox, uid")
            .unwrap();
        statement
            .query_map([id], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }

    fn flags_of(store: &Store, id: i64) -> String {
        store
            .db
            .query_row("SELECT flags FROM messages WHERE id = ?1", [id], |r| {
                r.get(0)
            })
            .unwrap()
    }

    fn seen(on: bool) -> Action {
        Action::Flag {
            flag: "\\Seen".into(),
            on,
        }
    }

    #[test]
    fn a_flag_changes_here_at_once_and_waits_for_the_server() {
        let dir = temp("flag");
        let mut store = Store::open(&dir).unwrap();
        let account = store.account("a", "a@example.com").unwrap();
        let inbox = store.mailbox(account, "INBOX", Some("inbox")).unwrap();
        let all = store.mailbox(account, "All Mail", Some("all")).unwrap();
        store
            .put(account, all.id, &[mail(9, "a", &[], None)], 9, 9)
            .unwrap();
        store
            .put(account, inbox.id, &[mail(1, "a", &[], None)], 1, 1)
            .unwrap();
        let id = store.messages_of(&format!("m:{account}:pm:a")).unwrap()[0];
        assert!(store.act(id, &seen(true)).unwrap());
        assert!(!store.act(id, &seen(true)).unwrap(), "already read");
        assert_eq!(flags_of(&store, id), "\\Seen");
        let pending = store.pending(account).unwrap();
        assert_eq!(pending.len(), 2, "one for each place: {pending:?}");
        assert!(pending.iter().all(|p| p.op == "+" && p.arg == "\\Seen"));
        // The server, not told yet, still says unread.
        let unread = Change {
            uid: 1,
            flags: Vec::new(),
            labels: None,
        };
        store.set_flags(inbox.id, &[unread]).unwrap();
        assert_eq!(flags_of(&store, id), "\\Seen", "what's waiting stays");
        // Unread again before it went: only the last one goes.
        store.act(id, &seen(false)).unwrap();
        let pending = store.pending(account).unwrap();
        assert_eq!(pending.len(), 2, "{pending:?}");
        assert!(pending.iter().all(|p| p.op == "-"));
        let ids: Vec<i64> = pending.iter().map(|p| p.id).collect();
        store.take_back(&ids, false).unwrap();
        assert_eq!(flags_of(&store, id), "\\Seen", "refused: as it was");
        assert!(store.pending(account).unwrap().is_empty());
    }

    #[test]
    fn a_message_moved_is_there_at_once_and_found_there_under_its_uid() {
        let dir = temp("move");
        let mut store = Store::open(&dir).unwrap();
        let account = store.account("a", "a@example.com").unwrap();
        let inbox = store.mailbox(account, "INBOX", Some("inbox")).unwrap();
        let archive = store.mailbox(account, "Archive", Some("archive")).unwrap();
        let label = store.mailbox(account, "Labels/Work", None).unwrap();
        store
            .put(account, inbox.id, &[mail(1, "a", &[], None)], 1, 1)
            .unwrap();
        store
            .put(account, label.id, &[mail(4, "a", &[], None)], 4, 4)
            .unwrap();
        let id = store.messages_of(&format!("m:{account}:pm:a")).unwrap()[0];
        assert!(store.act(id, &Action::Archive).unwrap());
        let pending = store.pending(account).unwrap();
        assert_eq!(pending.len(), 1, "labels stay: {pending:?}");
        assert_eq!((pending[0].mailbox.as_str(), pending[0].uid), ("INBOX", 1));
        assert_eq!(
            (pending[0].op.as_str(), pending[0].arg.as_str()),
            ("move", "Archive")
        );
        assert_eq!(
            places(&store, id),
            [(archive.id, -pending[0].id), (label.id, 4)],
            "in the archive already, by no UID yet"
        );
        assert!(store.uids(archive.id).unwrap().is_empty());
        assert!(store.uids(inbox.id).unwrap().is_empty());
        store.sent(&[pending[0].id]).unwrap();
        store
            .put(account, archive.id, &[mail(7, "a", &[], None)], 7, 7)
            .unwrap();
        assert_eq!(places(&store, id), [(archive.id, 7), (label.id, 4)]);
        // Back to the inbox, refused: where it was again.
        store.act(id, &Action::Move { to: "INBOX".into() }).unwrap();
        let back: Vec<i64> = store
            .pending(account)
            .unwrap()
            .iter()
            .map(|p| p.id)
            .collect();
        store.take_back(&back, false).unwrap();
        assert_eq!(places(&store, id), [(archive.id, 7), (label.id, 4)]);
        let Err(trouble) = store.act(
            id,
            &Action::Move {
                to: "Nowhere".into(),
            },
        ) else {
            panic!("moved to no mailbox");
        };
        assert_eq!(trouble.0, "there's no mailbox Nowhere");
    }

    #[test]
    fn trash_twice_deletes_for_good() {
        let dir = temp("trash");
        let mut store = Store::open(&dir).unwrap();
        let account = store.account("a", "a@example.com").unwrap();
        let inbox = store.mailbox(account, "INBOX", Some("inbox")).unwrap();
        let trash = store.mailbox(account, "Trash", Some("trash")).unwrap();
        store
            .put(account, inbox.id, &[mail(1, "a", &[], None)], 1, 1)
            .unwrap();
        let id = store.messages_of(&format!("t:{account}:a@x")).unwrap()[0];
        store.act(id, &Action::Trash).unwrap();
        let ids: Vec<i64> = store
            .pending(account)
            .unwrap()
            .iter()
            .map(|p| p.id)
            .collect();
        store.sent(&ids).unwrap();
        store
            .put(account, trash.id, &[mail(3, "a", &[], None)], 3, 3)
            .unwrap();
        assert_eq!(places(&store, id), [(trash.id, 3)]);
        store.act(id, &Action::Trash).unwrap();
        let pending = store.pending(account).unwrap();
        assert_eq!((pending[0].op.as_str(), pending[0].uid), ("expunge", 3));
        assert!(
            store
                .messages_of(&format!("m:{account}:pm:a"))
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            store.removed(10).unwrap(),
            [format!("m:{account}:pm:a"), format!("t:{account}:a@x")]
        );
    }

    #[test]
    fn only_mail_after_a_mailbox_is_all_in_has_arrived() {
        let dir = temp("arrived");
        let mut store = Store::open(&dir).unwrap();
        let account = store.account("a", "a@example.com").unwrap();
        let inbox = store.mailbox(account, "INBOX", Some("inbox")).unwrap();
        let archive = store.mailbox(account, "Archive", Some("archive")).unwrap();
        // The first sync, newest first, down to 1.
        store
            .put(account, inbox.id, &[mail(5, "e", &[], None)], 5, 5)
            .unwrap();
        store
            .put(account, inbox.id, &[mail(1, "a", &[], None)], 5, 1)
            .unwrap();
        assert!(
            store.arrived().unwrap().is_empty(),
            "a first sync brings no new mail"
        );
        store
            .put(account, inbox.id, &[mail(6, "f", &[], None)], 6, 1)
            .unwrap();
        // Seen elsewhere already: moved, not new.
        store
            .put(account, archive.id, &[mail(1, "e", &[], None)], 1, 1)
            .unwrap();
        store
            .put(account, archive.id, &[mail(2, "e", &[], None)], 2, 1)
            .unwrap();
        assert_eq!(store.arrived().unwrap(), [format!("m:{account}:pm:f")]);
        assert!(store.arrived().unwrap().is_empty(), "said once");
    }

    #[test]
    fn a_store_from_before_invites_fetches_recent_bodies_again() {
        let dir = temp("calendar");
        let mut store = Store::open(&dir).unwrap();
        let account = store.account("a", "a@example.com").unwrap();
        let inbox = store.mailbox(account, "INBOX", Some("inbox")).unwrap();
        let dated = |uid: u32, id: &str, date: &str| Fetched {
            uid,
            raw: format!("X-Pm-Internal-Id: {id}\r\nMessage-ID: <{id}@x>\r\nDate: {date}\r\n\r\n")
                .into_bytes(),
            ..Fetched::default()
        };
        let today = jiff::Timestamp::now().strftime("%a, %d %b %Y %H:%M:%S +0000");
        store
            .put(
                account,
                inbox.id,
                &[
                    dated(2, "new", &today.to_string()),
                    dated(1, "old", "Sun, 19 Oct 2014 10:00:00 +0200"),
                ],
                2,
                1,
            )
            .unwrap();
        let bodies: Vec<(i64, Body)> = store
            .wanting(inbox.id, 10)
            .unwrap()
            .iter()
            .map(|w| {
                let body = Body {
                    text: Some("hi".into()),
                    calendar: Some("BEGIN:VCALENDAR".into()),
                    complete: true,
                    ..Body::default()
                };
                (w.message, body)
            })
            .collect();
        store.put_bodies(&bodies).unwrap();
        let calendar = store.body(account, "pm:new").unwrap().unwrap().calendar;
        assert_eq!(calendar.as_deref(), Some("BEGIN:VCALENDAR"));
        drop(store);
        let old = Connection::open(dir.join("bodies.db")).unwrap();
        old.execute_batch("ALTER TABLE bodies DROP COLUMN calendar")
            .unwrap();
        drop(old);
        let store = Store::open(&dir).unwrap();
        assert_eq!(
            store.body(account, "pm:new").unwrap(),
            None,
            "fetched again"
        );
        let kept = store.body(account, "pm:old").unwrap().unwrap();
        assert_eq!((kept.text.as_deref(), kept.calendar), (Some("hi"), None));
        let wanting = store.wanting(inbox.id, 10).unwrap();
        assert_eq!(wanting.len(), 1);
    }

    #[test]
    fn a_change_undoes_while_it_waits_and_once_its_made() {
        let dir = temp("undo");
        let mut store = Store::open(&dir).unwrap();
        let account = store.account("a", "a@example.com").unwrap();
        let inbox = store.mailbox(account, "INBOX", Some("inbox")).unwrap();
        let archive = store.mailbox(account, "Archive", Some("archive")).unwrap();
        let trash = store.mailbox(account, "Trash", Some("trash")).unwrap();
        store
            .put(account, inbox.id, &[mail(1, "a", &[], None)], 1, 1)
            .unwrap();
        let id = store.messages_of(&format!("m:{account}:pm:a")).unwrap()[0];
        let read = Action::Flag {
            flag: "\\Seen".into(),
            on: true,
        };
        let undo = store.undoing(id, &read).unwrap().unwrap();
        assert_eq!(
            undo,
            Undo::Act(Action::Flag {
                flag: "\\Seen".into(),
                on: false
            })
        );
        store.act(id, &read).unwrap();
        assert_eq!(store.undoing(id, &read).unwrap(), None, "read already");
        store.undo(id, &undo).unwrap();
        let flags: String = store
            .db
            .query_row("SELECT flags FROM messages WHERE id = ?1", [id], |r| {
                r.get(0)
            })
            .unwrap();
        assert!(!flags.contains("\\Seen"), "unread again: {flags}");
        // Archived and undone before the server has it: taken back.
        let back = store.undoing(id, &Action::Archive).unwrap().unwrap();
        assert_eq!(back, Undo::Back { to: "INBOX".into() });
        store.act(id, &Action::Archive).unwrap();
        store.undo(id, &back).unwrap();
        assert_eq!(places(&store, id), [(inbox.id, 1)]);
        assert!(
            store
                .pending(account)
                .unwrap()
                .iter()
                .all(|p| p.op != "move"),
            "nothing left to move"
        );
        // Archived, made on the server, then undone: moved back.
        store.act(id, &Action::Archive).unwrap();
        let moved: Vec<i64> = store
            .pending(account)
            .unwrap()
            .iter()
            .filter(|p| p.op == "move")
            .map(|p| p.id)
            .collect();
        store.sent(&moved).unwrap();
        store
            .put(account, archive.id, &[mail(5, "a", &[], None)], 5, 5)
            .unwrap();
        store.undo(id, &back).unwrap();
        let again = store.pending(account).unwrap();
        let last = again.last().unwrap();
        assert_eq!(
            (last.mailbox.as_str(), last.op.as_str(), last.arg.as_str()),
            ("Archive", "move", "INBOX")
        );
        assert!(!store.in_trash(id).unwrap());
        // In the trash, trashing deletes for good, which nothing undoes.
        store
            .sent(&again.iter().map(|p| p.id).collect::<Vec<_>>())
            .unwrap();
        store
            .put(account, trash.id, &[mail(9, "a", &[], None)], 9, 9)
            .unwrap();
        assert!(store.in_trash(id).unwrap());
    }

    #[test]
    fn mail_waits_in_the_outbox_and_is_taken_back_until_it_goes() {
        let dir = temp("waits");
        let mut store = Store::open(&dir).unwrap();
        let account = store.account("a", "a@example.com").unwrap();
        let outgoing = Outgoing {
            sender: "a@example.com".into(),
            recipients: vec!["b@example.com".into()],
            message: b"hi".to_vec(),
        };
        let later = store.post(account, &outgoing, None, now() + 60).unwrap();
        assert!(store.outbox(account).unwrap().is_empty(), "it waits");
        assert!(store.next_due().unwrap().is_some_and(|at| at > now()));
        assert!(store.unpost(later).unwrap(), "taken back");
        assert_eq!(store.next_due().unwrap(), None);
        let now_id = store.post(account, &outgoing, None, now()).unwrap();
        assert_eq!(store.outbox(account).unwrap().len(), 1);
        assert!(!store.unpost(now_id).unwrap(), "on its way already");
    }

    #[test]
    #[ignore = "a measurement: cargo test -p greed-mail --lib -- --ignored --nocapture contacts_fill"]
    fn contacts_fill_from_a_big_store() {
        let dir = temp("contacts-fill");
        let mut store = Store::open(&dir).unwrap();
        let account = store.account("a", "anna@x").unwrap();
        let inbox = store.mailbox(account, "INBOX", Some("inbox")).unwrap();
        for batch in 0..85u32 {
            let fetched: Vec<Fetched> = (0..1000u32)
                .map(|n| {
                    let uid = batch * 1000 + n + 1;
                    Fetched {
                        uid,
                        raw: format!(
                            "From: Person {p} <p{p}@x>\r\nTo: anna@x, other{q}@x\r\n\
                             Message-ID: <{uid}@x>\r\nX-Pm-Internal-Id: f{uid}\r\n\r\n",
                            p = uid % 3000,
                            q = uid % 500
                        )
                        .into_bytes(),
                        ..Fetched::default()
                    }
                })
                .collect();
            store.put(account, inbox.id, &fetched, 85_000, 1).unwrap();
        }
        store
            .db
            .execute_batch("DELETE FROM contacts; DELETE FROM meta WHERE key = 'contacts';")
            .unwrap();
        let started = std::time::Instant::now();
        fill_contacts(&store.db).unwrap();
        println!(
            "filling contacts from 85k messages: {:?}",
            started.elapsed()
        );
        drop(store);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_gmail_label_goes_on_here_at_once_and_stays_until_the_server_has_it() {
        let dir = temp("gmail-label");
        let mut store = Store::open(&dir).unwrap();
        let account = store.account("a", "anna@x").unwrap();
        let all = store
            .mailbox(account, "[Gmail]/All Mail", Some("all"))
            .unwrap();
        store
            .put(account, all.id, &[mail(7, "a", &[], None)], 7, 7)
            .unwrap();
        let id = store.messages_of(&format!("m:{account}:pm:a")).unwrap()[0];
        let on = Action::GmailLabel {
            name: "Resor/Göteborg".into(),
            on: true,
        };
        let undo = store.undoing(id, &on).unwrap();
        assert!(store.act(id, &on).unwrap());
        assert!(!store.act(id, &on).unwrap(), "on already");
        let labels = |store: &Store| -> String {
            store
                .db
                .query_row("SELECT labels FROM messages WHERE id = ?1", [id], |r| {
                    r.get(0)
                })
                .unwrap()
        };
        assert_eq!(labels(&store), "Resor/Göteborg");
        let pending = store.pending(account).unwrap();
        assert_eq!(
            (
                pending[0].op.as_str(),
                pending[0].arg.as_str(),
                pending[0].uid
            ),
            ("label+", "Resor/Göteborg", 7)
        );
        // What the server says before it has the label doesn't take it off.
        let before = Change {
            uid: 7,
            flags: vec![],
            labels: Some(vec![]),
        };
        store
            .set_flags(all.id, std::slice::from_ref(&before))
            .unwrap();
        assert_eq!(labels(&store), "Resor/Göteborg");
        // Refused: as it was.
        store.take_back(&[pending[0].id], false).unwrap();
        assert_eq!(labels(&store), "");
        store.act(id, &on).unwrap();
        let ids: Vec<i64> = store
            .pending(account)
            .unwrap()
            .iter()
            .map(|p| p.id)
            .collect();
        store.sent(&ids).unwrap();
        store.undo(id, &undo.unwrap()).unwrap();
        assert_eq!(labels(&store), "", "undone: off again");
        assert_eq!(store.pending(account).unwrap()[0].op, "label-");
    }
}
