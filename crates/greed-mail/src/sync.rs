//! Syncing a mailbox's headers into the store: the first time newest
//! first, going down until every message is in, and after that whatever
//! arrived above. Each batch goes into the store with how far the sync got,
//! so stopping at any point (a crash, a lost connection, a limit) and
//! starting again goes on from there, fetching at most one batch twice.

use std::collections::{HashMap, HashSet};

use crate::body::{self, Body};
use crate::config::Provider;
use crate::imap::{Imap, Mailbox, Opened, Role};
use crate::store::{State, Store, Wanting};

/// How many messages a fetch asks for.
pub const BATCH: usize = 500;

/// How a sync goes.
#[derive(Debug, Clone, Copy)]
pub struct Options {
    pub batch: usize,
    /// Stop after fetching about this many messages, whole batches.
    pub limit: Option<usize>,
    /// Only what arrived since the last sync, quickly, before anything
    /// slower: no flags, no first sync, nothing after a UIDVALIDITY change.
    pub arrived_only: bool,
    /// Start a mailbox over under its new UIDVALIDITY even when the server
    /// has far fewer messages in it than the store (see [`held`]).
    pub start_over: bool,
}

impl Default for Options {
    fn default() -> Options {
        Options {
            batch: BATCH,
            limit: None,
            arrived_only: false,
            start_over: false,
        }
    }
}

/// Whether a mailbox with `now` messages on the server, where the store
/// has `had`, is held as it is rather than synced: when fewer than half
/// are there, the server more likely can't see them for a while (Proton
/// Bridge shows a big mailbox empty when its disk is full, or while it
/// builds its cache again) than they all went, and syncing would drop
/// them here.
pub fn held(had: u64, now: u64) -> bool {
    had >= 20 && now < had / 2
}

/// Fails with why `name` is held (see [`held`]), unless `options` start it
/// over.
fn hold(name: &str, had: u64, now: u64, options: Options) -> Result<(), Trouble> {
    if options.start_over || !held(had, now) {
        return Ok(());
    }
    Err(Trouble(format!(
        "{name} has {now} of the {had} messages here on the server, so it's kept as it was until they're back; if they did go, greed-mail --start-over sync"
    )))
}

/// What a mailbox's sync did.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Synced {
    /// Messages fetched.
    pub fetched: usize,
    /// Messages whose flags (or labels) changed.
    pub changed: usize,
    /// Messages gone from the mailbox.
    pub gone: usize,
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

/// The mailboxes of `mailboxes` that are synced. On Gmail, All Mail: it
/// holds every message once, and each message's labels say where else it
/// is. Elsewhere every one that holds messages, All Mail first where
/// there is one (Bridge), so the others find their messages in already and
/// only add where they are.
pub fn chosen(provider: Option<Provider>, mailboxes: &[Mailbox]) -> Vec<&Mailbox> {
    let mut chosen: Vec<&Mailbox> = mailboxes.iter().filter(|m| m.selectable).collect();
    if provider == Some(Provider::Gmail) {
        chosen.retain(|m| m.role == Some(Role::All));
    }
    chosen.sort_by_key(|m| m.role != Some(Role::All));
    chosen
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
    let started = state.high.is_some() && state.low.is_some();
    if options.arrived_only && (!started || state.uid_validity != Some(opened.uid_validity)) {
        return Ok(Synced::default());
    }
    if state.uid_validity != Some(opened.uid_validity) {
        let had = store.count_in(state.id)?;
        hold(name, had, u64::from(opened.messages), options)?;
        store.restart(state.id, opened.uid_validity)?;
        state = store.mailbox(account, name, role)?;
    }
    let top = opened.uid_next.saturating_sub(1);
    // Before the first sync, nothing is in: the top is where it starts.
    // Its flags are as they are now, so changes made while it goes on are
    // found once it's done.
    let (mut high, mut low) = if let (Some(high), Some(low)) = (state.high, state.low) {
        (high, low)
    } else {
        store.put(account, state.id, &[], top, top + 1)?;
        store.set_modseq(state.id, opened.highest_modseq)?;
        (top, top + 1)
    };
    let was_done = low <= 1;
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
    if options.arrived_only {
        return Ok(synced);
    }

    // What changed and went among those that were in.
    if was_done {
        refresh(
            imap,
            store,
            &state,
            &opened,
            high,
            &mut synced,
            name,
            options,
        )
        .await?;
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

/// Brings the flags of the messages up to `high` in the store up to date,
/// and takes out those gone from the mailbox. With CONDSTORE, only flags
/// changed since the last time come, and the UIDs are listed only when the
/// mailbox holds fewer messages than the store has in it; without, every
/// message's flags come, which lists every UID too. A mailbox the server
/// suddenly lists nearly empty is held as it is (see [`held`]).
#[allow(clippy::too_many_arguments)]
async fn refresh<I: Imap>(
    imap: &mut I,
    store: &mut Store,
    state: &State,
    opened: &Opened,
    high: u32,
    synced: &mut Synced,
    name: &str,
    options: Options,
) -> Result<(), Trouble> {
    let local = store.uids(state.id)?;
    let listed = if let (Some(now), Some(since)) = (opened.highest_modseq, state.modseq) {
        if now != since {
            let changes = imap.changes(1, high, Some(since)).await?;
            synced.changed += store.set_flags(state.id, &changes)?;
        }
        if local.len() == usize::try_from(opened.messages).unwrap_or(usize::MAX) {
            None
        } else {
            Some(imap.uids(1, high).await?)
        }
    } else {
        let changes = imap.changes(1, high, None).await?;
        synced.changed += store.set_flags(state.id, &changes)?;
        Some(changes.iter().map(|c| c.uid).collect())
    };
    if let Some(listed) = listed {
        let listed: HashSet<u32> = listed.into_iter().collect();
        hold(name, local.len() as u64, listed.len() as u64, options)?;
        let gone: Vec<u32> = local
            .into_iter()
            .filter(|uid| !listed.contains(uid))
            .collect();
        store.forget(state.id, &gone)?;
        synced.gone += gone.len();
    }
    store.set_modseq(state.id, opened.highest_modseq)?;
    Ok(())
}

/// Fetches the bodies of the messages in `account`'s mailbox `name` that
/// don't have theirs in yet, unread first, then newest, up to
/// `options.limit` of them; gives how many came. A message gone before its
/// body came gets an empty one, as there's nothing to fetch, and goes at
/// the next sync.
pub async fn bodies<I: Imap>(
    imap: &mut I,
    store: &mut Store,
    account: i64,
    name: &str,
    options: Options,
) -> Result<usize, Trouble> {
    let state = store.mailbox(account, name, None)?;
    imap.open(name).await?;
    let mut fetched = 0;
    while options.limit.is_none_or(|limit| fetched < limit) {
        let wanting = store.wanting(state.id, options.batch.clamp(1, BODY_BATCH))?;
        if wanting.is_empty() {
            break;
        }
        fetched += fetch_bodies(imap, store, &wanting).await?;
    }
    Ok(fetched)
}

/// Fetches the bodies of `wanting`, in the mailbox open in `imap`, into
/// `store`; gives how many came.
pub async fn fetch_bodies<I: Imap>(
    imap: &mut I,
    store: &mut Store,
    wanting: &[Wanting],
) -> Result<usize, Trouble> {
    let mut uids: Vec<u32> = wanting.iter().map(|w| w.uid).collect();
    uids.sort_unstable();
    let raw: HashMap<u32, Vec<u8>> = imap.bodies(&uids, body::CAP).await?.into_iter().collect();
    let found: Vec<(i64, Body)> = wanting
        .iter()
        .map(|w| {
            let body = raw.get(&w.uid).map_or_else(Body::default, |raw| {
                Body::of(raw, usize::try_from(w.size).unwrap_or(usize::MAX))
            });
            (w.message, body)
        })
        .collect();
    store.put_bodies(&found)?;
    Ok(raw.len())
}

/// The most bodies a fetch asks for: each can be up to `body::CAP`.
const BODY_BATCH: usize = 50;

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
    /// With `condstore`, every change gets the next mod-sequence, as a
    /// server with CONDSTORE gives them.
    #[derive(Default)]
    struct Fake {
        uid_validity: u32,
        messages: BTreeMap<u32, Fetched>,
        /// The fetch (counting from 1) that fails, as a dropped connection.
        fail_on: Option<usize>,
        fetches: usize,
        condstore: bool,
        modseq: u64,
        /// The mod-sequence each message last changed at.
        changed_at: BTreeMap<u32, u64>,
        /// How many times the UIDs were listed.
        listings: usize,
        /// The UIDs each fetch of bodies asked for.
        asked: Vec<Vec<u32>>,
    }

    /// A message the fake holds, whole: its header, then a line of text.
    fn whole(f: &Fetched) -> Vec<u8> {
        let mut raw = f.raw.clone();
        raw.extend(format!("text of {}\r\n", f.uid).bytes());
        raw
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
            let mut fetched = Fetched {
                uid,
                raw: raw.into_bytes(),
                // Newer the higher the UID.
                arrived: Some(format!("2026-10-{:02}T00:00:00+00:00", uid % 28 + 1)),
                ..Fetched::default()
            };
            fetched.size = u32::try_from(whole(&fetched).len()).unwrap();
            self.messages.insert(uid, fetched);
            self.touch(uid);
        }

        fn touch(&mut self, uid: u32) {
            self.modseq += 1;
            self.changed_at.insert(uid, self.modseq);
        }

        /// Gives the message at `uid` `flags` (and on Gmail `labels`).
        fn flag(&mut self, uid: u32, flags: &[&str], labels: &[&str]) {
            let message = self.messages.get_mut(&uid).unwrap();
            message.flags = flags.iter().map(ToString::to_string).collect();
            message.labels = labels.iter().map(ToString::to_string).collect();
            self.touch(uid);
        }

        fn remove(&mut self, uid: u32) {
            self.messages.remove(&uid);
            self.changed_at.remove(&uid);
            self.modseq += 1;
        }
    }

    impl Imap for Fake {
        fn open(&mut self, _mailbox: &str) -> impl Future<Output = Result<Opened, imap::Trouble>> {
            ready(Ok(Opened {
                uid_validity: self.uid_validity,
                uid_next: self.messages.keys().last().map_or(1, |uid| uid + 1),
                messages: u32::try_from(self.messages.len()).unwrap(),
                highest_modseq: self.condstore.then_some(self.modseq),
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

        fn changes(
            &mut self,
            from: u32,
            to: u32,
            since: Option<u64>,
        ) -> impl Future<Output = Result<Vec<imap::Change>, imap::Trouble>> {
            ready(Ok(self
                .messages
                .range(from..=to)
                .filter(|(uid, _)| since.is_none_or(|since| self.changed_at[uid] > since))
                .map(|(uid, f)| imap::Change {
                    uid: *uid,
                    flags: f.flags.clone(),
                    labels: (!f.labels.is_empty()).then(|| f.labels.clone()),
                })
                .collect()))
        }

        fn uids(
            &mut self,
            from: u32,
            to: u32,
        ) -> impl Future<Output = Result<Vec<u32>, imap::Trouble>> {
            self.listings += 1;
            ready(Ok(self
                .messages
                .range(from..=to)
                .map(|(uid, _)| *uid)
                .collect()))
        }

        fn bodies(
            &mut self,
            uids: &[u32],
            cap: u32,
        ) -> impl Future<Output = Result<Vec<(u32, Vec<u8>)>, imap::Trouble>> {
            self.asked.push(uids.to_vec());
            let cap = usize::try_from(cap).unwrap();
            ready(Ok(uids
                .iter()
                .filter_map(|uid| {
                    let mut raw = whole(self.messages.get(uid)?);
                    raw.truncate(cap);
                    Some((*uid, raw))
                })
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
        sync_in(fake, store, account, "INBOX", options)
    }

    fn sync_in(
        fake: &mut Fake,
        store: &mut Store,
        account: i64,
        name: &str,
        options: Options,
    ) -> Result<Synced, Trouble> {
        tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap()
            .block_on(mailbox(fake, store, account, name, None, options))
    }

    /// The flags and labels the store has for the message with Bridge id
    /// `id`.
    fn flags_of(store: &Store, account: i64, id: &str) -> Option<(String, String)> {
        store.flags(account, &format!("pm:{id}")).unwrap()
    }

    fn batches_of(batch: usize) -> Options {
        Options {
            batch,
            ..Options::default()
        }
    }

    #[test]
    fn gmail_syncs_all_mail_and_others_every_folder_all_mail_first() {
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
            names(chosen(Some(Provider::ProtonBridge), &mailboxes)),
            ["[Gmail]/All Mail", "INBOX", "Work"]
        );
        assert_eq!(names(chosen(None, &mailboxes)).len(), 3);
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
                done: true,
                ..Synced::default()
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
                done: true,
                ..Synced::default()
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
            ..Options::default()
        };
        let first = sync(&mut fake, &mut store, account, limited).unwrap();
        assert_eq!(
            first,
            Synced {
                fetched: 8,
                done: false,
                ..Synced::default()
            }
        );
        let rest = sync(&mut fake, &mut store, account, limited).unwrap();
        assert_eq!(
            rest,
            Synced {
                fetched: 2,
                done: true,
                ..Synced::default()
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
    fn a_mailbox_that_starts_over_nearly_empty_is_held_until_its_mail_is_back() {
        let (mut store, account) = store("held");
        let mut fake = Fake::with(1, 1..=40);
        sync(&mut fake, &mut store, account, Options::default()).unwrap();
        // The server lost track: new UIDs, and only 3 of the 40 there.
        let mut emptied = Fake {
            uid_validity: 2,
            ..Fake::default()
        };
        for uid in 1..=3 {
            emptied.add(100 + uid, &format!("m{uid}"));
        }
        let held = sync(&mut emptied, &mut store, account, Options::default()).unwrap_err();
        assert!(held.0.contains("3 of the 40"), "{held}");
        assert_eq!(store.counts(account).unwrap(), (40, 40), "kept as it was");
        // Asked to, it starts over all the same.
        let anyway = Options {
            start_over: true,
            ..Options::default()
        };
        assert!(
            sync(&mut emptied, &mut store, account, anyway)
                .unwrap()
                .done
        );
        let inbox = store.mailbox(account, "INBOX", None).unwrap();
        assert_eq!(store.uids(inbox.id).unwrap(), [101, 102, 103]);
    }

    #[test]
    fn a_mailbox_the_server_suddenly_lists_nearly_empty_is_held() {
        let (mut store, account) = store("vanished");
        let mut fake = Fake::with(1, 1..=40);
        sync(&mut fake, &mut store, account, Options::default()).unwrap();
        // Same UIDs, but the server lists only 3 of them, as Bridge does
        // when its disk is full.
        for uid in 4..=40 {
            fake.remove(uid);
        }
        let held = sync(&mut fake, &mut store, account, Options::default()).unwrap_err();
        assert!(held.0.contains("INBOX has 3 of the 40"), "{held}");
        assert_eq!(store.counts(account).unwrap(), (40, 40), "kept as it was");
        // A few going is mail going, as ever.
        let mut fewer = Fake::with(1, 1..=40);
        for uid in 1..=5 {
            fewer.remove(uid);
        }
        let synced = sync(&mut fewer, &mut store, account, Options::default()).unwrap();
        assert_eq!(synced.gone, 5);
        // Asked to, it lets most of them go too: all but 1 to 3 of the 35
        // left.
        let anyway = Options {
            start_over: true,
            ..Options::default()
        };
        assert_eq!(
            sync(&mut fake, &mut store, account, anyway).unwrap().gone,
            35
        );
    }

    #[test]
    fn a_mailbox_is_held_only_when_most_of_a_fair_number_went() {
        assert!(held(40, 19));
        assert!(!held(40, 20), "half is there");
        assert!(!held(19, 0), "too few to tell");
        assert!(!held(0, 0));
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
                done: true,
                ..Synced::default()
            }
        );
        assert!(fake.fetches < 200, "{} fetches", fake.fetches);
    }

    #[test]
    fn with_condstore_only_what_changed_since_comes_and_nothing_is_listed() {
        let (mut store, account) = store("condstore");
        let mut fake = Fake::with(1, 1..=5);
        fake.condstore = true;
        sync(&mut fake, &mut store, account, Options::default()).unwrap();
        fake.flag(2, &["\\Seen"], &[]);
        fake.flag(4, &["\\Seen", "\\Flagged"], &[]);
        let synced = sync(&mut fake, &mut store, account, Options::default()).unwrap();
        assert_eq!((synced.changed, synced.gone), (2, 0));
        assert_eq!(flags_of(&store, account, "m2").unwrap().0, "\\Seen");
        assert_eq!(
            flags_of(&store, account, "m4").unwrap().0,
            "\\Seen \\Flagged"
        );
        assert_eq!(fake.listings, 0, "the counts agree, so nothing went");
        let again = sync(&mut fake, &mut store, account, Options::default()).unwrap();
        assert_eq!(again.changed, 0, "nothing since");
    }

    #[test]
    fn with_condstore_what_went_is_found_when_the_counts_disagree() {
        let (mut store, account) = store("condstore-gone");
        let mut fake = Fake::with(1, 1..=5);
        fake.condstore = true;
        sync(&mut fake, &mut store, account, Options::default()).unwrap();
        fake.remove(3);
        let synced = sync(&mut fake, &mut store, account, Options::default()).unwrap();
        assert_eq!(synced.gone, 1);
        assert_eq!(fake.listings, 1);
        assert_eq!(
            store.counts(account).unwrap(),
            (4, 4),
            "the message went too"
        );
        assert_eq!(flags_of(&store, account, "m3"), None);
    }

    #[test]
    fn arrived_only_brings_new_mail_and_leaves_the_slow_rest_for_later() {
        let (mut store, account) = store("quick");
        let mut fake = Fake::with(1, 1..=3);
        let quick = Options {
            arrived_only: true,
            ..Options::default()
        };
        let before = sync(&mut fake, &mut store, account, quick).unwrap();
        assert_eq!(before, Synced::default(), "nothing before the first sync");
        assert_eq!(store.counts(account).unwrap(), (0, 0));
        sync(&mut fake, &mut store, account, Options::default()).unwrap();
        fake.add(4, "m4");
        fake.flag(1, &["\\Seen"], &[]);
        let synced = sync(&mut fake, &mut store, account, quick).unwrap();
        assert_eq!(synced.fetched, 1, "what arrived");
        assert_eq!(synced.changed, 0, "no flags: that's the slow part");
        assert_eq!(store.counts(account).unwrap(), (4, 4));
        let rest = sync(&mut fake, &mut store, account, Options::default()).unwrap();
        assert_eq!((rest.fetched, rest.changed), (0, 1), "the flags come next");
    }

    #[test]
    fn without_condstore_every_flag_comes_and_lists_what_went() {
        let (mut store, account) = store("plain");
        let mut fake = Fake::with(1, 1..=4);
        sync(&mut fake, &mut store, account, Options::default()).unwrap();
        fake.flag(1, &["\\Seen"], &[]);
        fake.remove(2);
        let synced = sync(&mut fake, &mut store, account, Options::default()).unwrap();
        assert_eq!((synced.changed, synced.gone), (1, 1));
        assert_eq!(fake.listings, 0, "the flags list the UIDs");
        assert_eq!(store.counts(account).unwrap(), (3, 3));
    }

    #[test]
    fn gmail_labels_change_with_the_flags() {
        let (mut store, account) = store("labels");
        let mut fake = Fake::with(1, 1..=2);
        fake.condstore = true;
        fake.flag(1, &[], &["\\Inbox", "Work"]);
        sync(&mut fake, &mut store, account, Options::default()).unwrap();
        assert_eq!(flags_of(&store, account, "m1").unwrap().1, "\\Inbox\nWork");
        fake.flag(1, &["\\Seen"], &["Work"]);
        sync(&mut fake, &mut store, account, Options::default()).unwrap();
        assert_eq!(
            flags_of(&store, account, "m1").unwrap(),
            ("\\Seen".into(), "Work".into()),
            "archived: no longer in the inbox"
        );
    }

    #[test]
    fn a_message_in_two_mailboxes_goes_only_when_its_gone_from_both() {
        let (mut store, account) = store("two");
        let mut all = Fake::with(1, 1..=3);
        let mut inbox = Fake::with(1, []);
        inbox.add(7, "m2");
        sync_in(
            &mut all,
            &mut store,
            account,
            "All Mail",
            Options::default(),
        )
        .unwrap();
        sync_in(&mut inbox, &mut store, account, "INBOX", Options::default()).unwrap();
        assert_eq!(store.counts(account).unwrap(), (3, 4), "m2 is in both");
        inbox.remove(7);
        let synced = sync_in(&mut inbox, &mut store, account, "INBOX", Options::default()).unwrap();
        assert_eq!(synced.gone, 1);
        assert_eq!(store.counts(account).unwrap(), (3, 3), "still in All Mail");
        all.remove(2);
        sync_in(
            &mut all,
            &mut store,
            account,
            "All Mail",
            Options::default(),
        )
        .unwrap();
        assert_eq!(store.counts(account).unwrap(), (2, 2));
        assert_eq!(flags_of(&store, account, "m2"), None);
    }

    fn bodies_of(fake: &mut Fake, store: &mut Store, account: i64, options: Options) -> usize {
        tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap()
            .block_on(bodies(fake, store, account, "INBOX", options))
            .unwrap()
    }

    #[test]
    fn bodies_come_unread_first_then_newest_and_once() {
        let (mut store, account) = store("bodies");
        let mut fake = Fake::with(1, 1..=6);
        fake.flag(5, &["\\Seen"], &[]);
        fake.flag(6, &["\\Seen"], &[]);
        sync(&mut fake, &mut store, account, Options::default()).unwrap();
        let first = Options {
            batch: 4,
            limit: Some(1),
            ..Options::default()
        };
        assert_eq!(
            bodies_of(&mut fake, &mut store, account, first),
            4,
            "a whole batch"
        );
        assert_eq!(
            fake.asked,
            [vec![1, 2, 3, 4]],
            "the unread ones, before read 5 and 6"
        );
        let body = store.body(account, "pm:m3").unwrap().unwrap();
        assert_eq!(body.text.as_deref(), Some("text of 3\r\n"));
        assert!(body.complete);
        assert_eq!(
            bodies_of(&mut fake, &mut store, account, Options::default()),
            2,
            "then the rest"
        );
        assert_eq!(
            bodies_of(&mut fake, &mut store, account, Options::default()),
            0,
            "once"
        );
    }

    #[test]
    fn a_message_gone_before_its_body_came_isnt_asked_for_again() {
        let (mut store, account) = store("bodies-gone");
        let mut fake = Fake::with(1, 1..=3);
        sync(&mut fake, &mut store, account, Options::default()).unwrap();
        fake.remove(2);
        assert_eq!(
            bodies_of(&mut fake, &mut store, account, Options::default()),
            2
        );
        assert_eq!(
            bodies_of(&mut fake, &mut store, account, Options::default()),
            0
        );
        sync(&mut fake, &mut store, account, Options::default()).unwrap();
        assert_eq!(
            store.body(account, "pm:m2").unwrap(),
            None,
            "gone with its message"
        );
    }
}
