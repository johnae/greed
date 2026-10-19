//! Syncing a mailbox's headers into the store: the first time newest
//! first, going down until every message is in, and after that whatever
//! arrived above. Each batch goes into the store with how far the sync got,
//! so stopping at any point (a crash, a lost connection, a limit) and
//! starting again goes on from there, fetching at most one batch twice.

use crate::config::Provider;
use crate::imap::{Imap, Mailbox, Role};
use crate::store::Store;

/// How many messages a fetch asks for.
pub const BATCH: usize = 500;

/// How a sync goes.
#[derive(Debug, Clone, Copy)]
pub struct Options {
    pub batch: usize,
    /// Stop after fetching about this many messages, whole batches.
    pub limit: Option<usize>,
}

impl Default for Options {
    fn default() -> Options {
        Options {
            batch: BATCH,
            limit: None,
        }
    }
}

/// What a mailbox's sync did.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Synced {
    /// Messages fetched.
    pub fetched: usize,
    /// Whether every message in it is in the store now.
    pub done: bool,
}

/// What went wrong syncing, in words.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Trouble(pub String);

impl std::fmt::Display for Trouble {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl From<crate::imap::Trouble> for Trouble {
    fn from(trouble: crate::imap::Trouble) -> Trouble {
        Trouble(trouble.0)
    }
}

impl From<crate::store::Trouble> for Trouble {
    fn from(trouble: crate::store::Trouble) -> Trouble {
        Trouble(trouble.0)
    }
}

/// The mailboxes of `mailboxes` that are synced: on Gmail and Bridge All
/// Mail, which holds every message once (labels say where else each is);
/// elsewhere every one that holds messages.
pub fn chosen(provider: Option<Provider>, mailboxes: &[Mailbox]) -> Vec<&Mailbox> {
    let selectable = mailboxes.iter().filter(|m| m.selectable);
    if provider.is_some() {
        selectable.filter(|m| m.role == Some(Role::All)).collect()
    } else {
        selectable.collect()
    }
}

/// Syncs the headers of `account`'s mailbox `name` from `imap` into
/// `store`.
pub async fn mailbox<I: Imap>(
    imap: &mut I,
    store: &mut Store,
    account: i64,
    name: &str,
    role: Option<Role>,
    options: Options,
) -> Result<Synced, Trouble> {
    let opened = imap.open(name).await?;
    let role = role.map(Role::name);
    let mut state = store.mailbox(account, name, role)?;
    if state.uid_validity != Some(opened.uid_validity) {
        store.restart(state.id, opened.uid_validity)?;
        state = store.mailbox(account, name, role)?;
    }
    let top = opened.uid_next.saturating_sub(1);
    // Before the first sync, nothing is in: the top is where it starts.
    let (mut high, mut low) = if let (Some(high), Some(low)) = (state.high, state.low) {
        (high, low)
    } else {
        store.put(account, state.id, &[], top, top + 1)?;
        (top, top + 1)
    };
    let mut synced = Synced::default();
    let full = |synced: &Synced| options.limit.is_some_and(|limit| synced.fetched >= limit);
    let mut window = Window::new(options.batch);

    // What arrived since, oldest first, so `high` only ever goes up past
    // what's in.
    while high < top {
        if full(&synced) {
            return Ok(synced);
        }
        let to = high.saturating_add(window.width).min(top);
        let fetched = imap.fetch(high + 1, to).await?;
        high = to;
        store.put(account, state.id, &fetched, high, low)?;
        window.saw(fetched.len());
        synced.fetched += fetched.len();
    }

    // The first sync going down, newest first.
    while low > 1 {
        if full(&synced) {
            return Ok(synced);
        }
        let from = low.saturating_sub(window.width).max(1);
        let fetched = imap.fetch(from, low - 1).await?;
        low = from;
        store.put(account, state.id, &fetched, high, low)?;
        window.saw(fetched.len());
        synced.fetched += fetched.len();
    }
    synced.done = true;
    Ok(synced)
}

/// How many UIDs a fetch spans, so it brings about a batch: UIDs are
/// sparse where messages went, so a range wider than the batch can hold
/// fewer messages. It widens where they're sparse and narrows where they
/// aren't.
struct Window {
    batch: usize,
    width: u32,
}

impl Window {
    /// The widest a window gets, in batches.
    const WIDEST: u32 = 64;

    fn new(batch: usize) -> Window {
        let batch = batch.max(1);
        Window {
            batch,
            width: u32::try_from(batch).unwrap_or(u32::MAX),
        }
    }

    /// Takes in that the last fetch brought `found` messages.
    fn saw(&mut self, found: usize) {
        let batch = u32::try_from(self.batch).unwrap_or(u32::MAX);
        if found < self.batch / 2 {
            self.width = self
                .width
                .saturating_mul(2)
                .min(batch.saturating_mul(Self::WIDEST));
        } else if found > self.batch.saturating_mul(2) {
            self.width = (self.width / 2).max(batch);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::future::ready;

    use super::*;
    use crate::header::Fetched;
    use crate::imap::{self, Opened};

    /// A server holding one mailbox, in memory, that can be told to fail.
    #[derive(Default)]
    struct Fake {
        uid_validity: u32,
        messages: BTreeMap<u32, Fetched>,
        /// The fetch (counting from 1) that fails, as a dropped connection.
        fail_on: Option<usize>,
        fetches: usize,
    }

    impl Fake {
        fn with(uid_validity: u32, uids: impl IntoIterator<Item = u32>) -> Fake {
            let mut fake = Fake {
                uid_validity,
                ..Fake::default()
            };
            for uid in uids {
                fake.add(uid, &format!("m{uid}"));
            }
            fake
        }

        /// Adds a message whose Bridge id is `id`.
        fn add(&mut self, uid: u32, id: &str) {
            let raw = format!("Subject: {id}\r\nX-Pm-Internal-Id: {id}\r\n\r\n");
            self.messages.insert(
                uid,
                Fetched {
                    uid,
                    raw: raw.into_bytes(),
                    ..Fetched::default()
                },
            );
        }
    }

    impl Imap for Fake {
        fn open(&mut self, _mailbox: &str) -> impl Future<Output = Result<Opened, imap::Trouble>> {
            ready(Ok(Opened {
                uid_validity: self.uid_validity,
                uid_next: self.messages.keys().last().map_or(1, |uid| uid + 1),
                messages: u32::try_from(self.messages.len()).unwrap(),
            }))
        }

        fn fetch(
            &mut self,
            from: u32,
            to: u32,
        ) -> impl Future<Output = Result<Vec<Fetched>, imap::Trouble>> {
            self.fetches += 1;
            if self.fail_on == Some(self.fetches) {
                return ready(Err(imap::Trouble("connection lost".into())));
            }
            ready(Ok(self
                .messages
                .range(from..=to)
                .map(|(_, f)| f.clone())
                .collect()))
        }
    }

    fn store(name: &str) -> (Store, i64) {
        let dir = std::env::temp_dir().join(format!("gm-sync-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let store = Store::open(&dir).unwrap();
        let account = store.account("a", "a@example.com").unwrap();
        (store, account)
    }

    fn sync(
        fake: &mut Fake,
        store: &mut Store,
        account: i64,
        options: Options,
    ) -> Result<Synced, Trouble> {
        tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap()
            .block_on(mailbox(
                fake,
                store,
                account,
                "INBOX",
                Some(Role::Inbox),
                options,
            ))
    }

    fn batches_of(batch: usize) -> Options {
        Options { batch, limit: None }
    }

    #[test]
    fn gmail_and_bridge_sync_all_mail_and_others_every_folder() {
        let mailbox = |name: &str, role: Option<Role>, selectable: bool| Mailbox {
            name: name.into(),
            role,
            selectable,
        };
        let mailboxes = [
            mailbox("INBOX", Some(Role::Inbox), true),
            mailbox("[Gmail]", None, false),
            mailbox("[Gmail]/All Mail", Some(Role::All), true),
            mailbox("Work", None, true),
        ];
        let names = |chosen: Vec<&Mailbox>| -> Vec<String> {
            chosen.into_iter().map(|m| m.name.clone()).collect()
        };
        assert_eq!(
            names(chosen(Some(Provider::Gmail), &mailboxes)),
            ["[Gmail]/All Mail"]
        );
        assert_eq!(
            names(chosen(None, &mailboxes)),
            ["INBOX", "[Gmail]/All Mail", "Work"]
        );
    }

    #[test]
    fn the_first_sync_fetches_everything_newest_first() {
        let (mut store, account) = store("first");
        let mut fake = Fake::with(1, [1, 2, 3, 5, 8, 13, 21]);
        let synced = sync(&mut fake, &mut store, account, batches_of(3)).unwrap();
        assert_eq!(
            synced,
            Synced {
                fetched: 7,
                done: true
            }
        );
        assert!(fake.fetches >= 3, "in batches");
        let inbox = store.mailbox(account, "INBOX", None).unwrap();
        assert_eq!((inbox.high, inbox.low), (Some(21), Some(1)));
        assert_eq!(store.uids(inbox.id).unwrap(), [1, 2, 3, 5, 8, 13, 21]);
    }

    #[test]
    fn after_that_only_what_arrived_is_fetched() {
        let (mut store, account) = store("arrived");
        let mut fake = Fake::with(1, [1, 2, 3]);
        sync(&mut fake, &mut store, account, Options::default()).unwrap();
        fake.add(4, "new");
        fake.fetches = 0;
        let synced = sync(&mut fake, &mut store, account, Options::default()).unwrap();
        assert_eq!(
            synced,
            Synced {
                fetched: 1,
                done: true
            }
        );
        let again = sync(&mut fake, &mut store, account, Options::default()).unwrap();
        assert_eq!(again.fetched, 0, "nothing new, nothing fetched");
        assert_eq!(fake.fetches, 1);
    }

    #[test]
    fn a_sync_that_breaks_goes_on_where_it_got_to() {
        let (mut store, account) = store("broken");
        let mut fake = Fake::with(1, 1..=10);
        fake.fail_on = Some(3);
        let broken = sync(&mut fake, &mut store, account, batches_of(2));
        assert_eq!(broken, Err(Trouble("connection lost".into())));
        fake.fail_on = None;
        fake.fetches = 0;
        let synced = sync(&mut fake, &mut store, account, batches_of(2)).unwrap();
        assert!(synced.done);
        assert_eq!(synced.fetched, 6, "the 4 newest were in already");
        assert_eq!(store.counts(account).unwrap(), (10, 10), "each once");
    }

    #[test]
    fn a_limit_stops_after_whole_batches_and_the_next_sync_goes_on() {
        let (mut store, account) = store("limit");
        let mut fake = Fake::with(1, 1..=10);
        let limited = Options {
            batch: 4,
            limit: Some(5),
        };
        let first = sync(&mut fake, &mut store, account, limited).unwrap();
        assert_eq!(
            first,
            Synced {
                fetched: 8,
                done: false
            }
        );
        let rest = sync(&mut fake, &mut store, account, limited).unwrap();
        assert_eq!(
            rest,
            Synced {
                fetched: 2,
                done: true
            }
        );
        assert_eq!(store.counts(account).unwrap(), (10, 10));
    }

    #[test]
    fn a_new_uidvalidity_finds_the_same_messages_under_new_uids() {
        let (mut store, account) = store("validity");
        let mut fake = Fake::with(1, [1, 2, 3]);
        sync(&mut fake, &mut store, account, Options::default()).unwrap();
        let mut renumbered = Fake {
            uid_validity: 2,
            ..Fake::default()
        };
        for (uid, id) in [(10, "m1"), (11, "m2"), (12, "m3")] {
            renumbered.add(uid, id);
        }
        let synced = sync(&mut renumbered, &mut store, account, Options::default()).unwrap();
        assert!(synced.done);
        assert_eq!(store.counts(account).unwrap(), (3, 3), "no message twice");
        let inbox = store.mailbox(account, "INBOX", None).unwrap();
        assert_eq!(store.uids(inbox.id).unwrap(), [10, 11, 12]);
    }

    #[test]
    fn far_apart_uids_take_a_few_fetches_not_one_per_window() {
        let (mut store, account) = store("sparse");
        let mut fake = Fake::with(1, [1, 40_000, 80_000]);
        let synced = sync(&mut fake, &mut store, account, batches_of(10)).unwrap();
        assert_eq!(
            synced,
            Synced {
                fetched: 3,
                done: true
            }
        );
        assert!(fake.fetches < 200, "{} fetches", fake.fetches);
    }
}
