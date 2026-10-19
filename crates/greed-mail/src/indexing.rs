//! The index the mail client searches: `index.db`, a `greed-index` index
//! of every message and thread, kept up with the store. The store marks
//! what changed; `catch_up` writes those and takes out what went, so the
//! index is behind at most until the next catch-up, never wrong for good.
//!
//! A message's fields: `from`, `to`, `cc` and `subject` (text), `date`,
//! `size` (a value), `tag` (where it is: its folders and labels by name,
//! which `in:` matches, as `places` says), `account` and `list` (exact).
//! Its flags: `unread`, `flagged`, `answered`, `draft`, `attachment` and
//! `mine` (sent by the owner: in Sent, or from the account's address). A
//! thread is an item too, named by its first message's subject, with its
//! messages under it.

use std::collections::{BTreeSet, HashMap};

use greed_index::index::{Index, Item};

use crate::names;
use crate::store::{Indexable, Store, Trouble};

/// The field the index keeps a message's places in, for `in:`.
pub const PLACES: &str = "tag";

/// How many messages are written to the index at a time.
const BATCH: usize = 500;

/// The most of a body's text that's indexed.
const TEXT: usize = 64 * 1024;

/// The key of `account`'s message `identity` in the index.
pub fn message_key(account: i64, identity: &str) -> String {
    format!("m:{account}:{identity}")
}

/// The key of `account`'s thread `thread` in the index.
pub fn thread_key(account: i64, thread: &str) -> String {
    format!("t:{account}:{thread}")
}

/// Brings `index` up to `store`: writes what changed and takes out what
/// went. Gives how many messages it wrote.
pub fn catch_up(store: &mut Store, index: &mut Index) -> Result<usize, Trouble> {
    let mut written = 0;
    loop {
        let messages = store.unindexed(BATCH)?;
        if messages.is_empty() {
            break;
        }
        let mut items: Vec<Item> = messages.iter().map(item).collect();
        let threads: BTreeSet<(i64, &str)> = messages
            .iter()
            .filter_map(|m| Some((m.account, m.thread.as_deref()?)))
            .collect();
        for (account, thread) in threads {
            items.push(Item {
                key: thread_key(account, thread),
                name: Some(store.thread_subject(account, thread)?),
                ..Item::default()
            });
        }
        index.write(&items).map_err(|e| Trouble(e.0))?;
        let ids: Vec<i64> = messages.iter().map(|m| m.id).collect();
        store.indexed(&ids)?;
        written += messages.len();
    }
    loop {
        let keys = store.removed(BATCH)?;
        if keys.is_empty() {
            break;
        }
        index.remove(&keys).map_err(|e| Trouble(e.0))?;
        store.unlisted(&keys)?;
    }
    Ok(written)
}

/// The index's item for message `m`.
fn item(m: &Indexable) -> Item {
    let mut fields: HashMap<String, Vec<String>> = HashMap::new();
    let mut field = |name: &str, value: &str| {
        if !value.is_empty() {
            fields.entry(name.into()).or_default().push(value.into());
        }
    };
    field("from", &m.from);
    field("to", &m.to);
    field("cc", &m.cc);
    field("subject", &m.subject);
    field("date", m.date.as_deref().unwrap_or(""));
    field("size", &m.size.to_string());
    field("account", &m.account_name);
    field("list", m.list_id.as_deref().unwrap_or(""));
    for tag in tags(m) {
        field(PLACES, &tag);
    }
    let has = |flag: &str| m.flags.split(' ').any(|f| f.eq_ignore_ascii_case(flag));
    let mut flags = Vec::new();
    for (flag, on) in [
        ("unread", !has("\\Seen")),
        ("flagged", has("\\Flagged")),
        ("answered", has("\\Answered")),
        ("draft", has("\\Draft")),
        ("attachment", m.attached),
        ("mine", mine(m)),
    ] {
        if on {
            flags.push(flag.to_string());
        }
    }
    let mut text = m.subject.clone();
    if let Some(body) = &m.text {
        text.push('\n');
        text.push_str(cut(body, TEXT));
    }
    Item {
        key: message_key(m.account, &m.identity),
        parent: m.thread.as_deref().map(|t| thread_key(m.account, t)),
        name: None,
        text,
        fields,
        flags,
    }
}

/// Whether `m` was sent by the account's owner: it's in a Sent mailbox, or
/// it's from the account's address (people send from more than one, which
/// the Sent mailbox knows and the address doesn't).
fn mine(m: &Indexable) -> bool {
    m.places
        .iter()
        .any(|(_, role)| role.as_deref() == Some("sent"))
        || (!m.address.is_empty() && m.from.to_lowercase().contains(&m.address.to_lowercase()))
}

/// Where `m` is, by name: the mailboxes it's in (All Mail aside, as every
/// message is there) and its Gmail labels, each once.
fn tags(m: &Indexable) -> Vec<String> {
    let mut tags: Vec<String> = m
        .places
        .iter()
        .filter_map(|(name, role)| place_name(name, role.as_deref()))
        .collect();
    tags.extend(m.labels.lines().filter(|l| !l.is_empty()).map(label_name));
    tags.sort();
    tags.dedup();
    tags
}

/// A mailbox's name as a place: readable, Bridge's `Labels/` and
/// `Folders/` left off; none for All Mail.
fn place_name(name: &str, role: Option<&str>) -> Option<String> {
    if role == Some("all") {
        return None;
    }
    if name.eq_ignore_ascii_case("INBOX") {
        return Some("Inbox".into());
    }
    let name = names::decode(name);
    let short = ["Labels/", "Folders/"]
        .iter()
        .find_map(|prefix| name.strip_prefix(prefix));
    Some(short.unwrap_or(&name).to_string())
}

/// A Gmail label as a place: its system labels by the names Gmail shows.
fn label_name(label: &str) -> String {
    match label {
        "\\Inbox" => "Inbox",
        "\\Sent" => "Sent",
        "\\Draft" => "Drafts",
        "\\Important" => "Important",
        "\\Starred" => "Starred",
        "\\Spam" => "Spam",
        "\\Trash" => "Trash",
        other => other,
    }
    .to_string()
}

/// The start of `text`, at most `most` bytes, cut where a character ends.
fn cut(text: &str, most: usize) -> &str {
    if text.len() <= most {
        return text;
    }
    let mut end = most;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}

#[cfg(test)]
mod tests {
    use super::*;

    use greed_index::index::View;
    use greed_index::query::{Flag, Kind, Node, Schema};

    use crate::body::Body;
    use crate::header::Fetched;

    #[test]
    fn places_read_as_names() {
        assert_eq!(place_name("INBOX", Some("inbox")).as_deref(), Some("Inbox"));
        assert_eq!(place_name("All Mail", Some("all")), None);
        assert_eq!(place_name("Labels/Work", None).as_deref(), Some("Work"));
        assert_eq!(
            place_name("Folders/Resor/G&APY-teborg", None).as_deref(),
            Some("Resor/Göteborg")
        );
        assert_eq!(label_name("\\Inbox"), "Inbox");
        assert_eq!(label_name("Kids"), "Kids");
    }

    fn mail(uid: u32, id: &str, from: &str, subject: &str, flags: &[&str]) -> Fetched {
        let raw = format!(
            "From: {from}\r\nSubject: {subject}\r\nMessage-ID: <{id}@x>\r\n\
             X-Pm-Internal-Id: {id}\r\nDate: Sun, 19 Oct 2026 10:00:00 +0200\r\n\r\n"
        );
        Fetched {
            uid,
            raw: raw.into_bytes(),
            flags: flags.iter().map(ToString::to_string).collect(),
            ..Fetched::default()
        }
    }

    fn schema() -> Schema {
        let mut schema = Schema {
            places: Some(PLACES.into()),
            ..Schema::default()
        };
        for (name, kind) in [
            ("from", Kind::Text),
            ("subject", Kind::Text),
            ("tag", Kind::Exact),
            ("date", Kind::Date),
        ] {
            schema.fields.insert(name.into(), kind);
        }
        for flag in ["unread", "flagged", "mine", "attachment"] {
            schema.flags.insert(flag.into(), Flag::Row);
        }
        schema
    }

    fn word(text: &str) -> Node {
        Node {
            kind: "word".into(),
            text: Some(text.into()),
            ..Node::default()
        }
    }

    fn field(name: &str, value: &str) -> Node {
        Node {
            kind: "field".into(),
            field: Some(name.into()),
            op: Some(":".into()),
            value: Some(value.into()),
            ..Node::default()
        }
    }

    fn found(index: &Index, node: &Node) -> Vec<String> {
        let mut keys = index
            .search(Some(node), &schema(), &View::default())
            .unwrap()
            .keys;
        keys.sort();
        keys
    }

    /// A store and its index caught up: p1 from Bob in All Mail with a
    /// body, p2 the owner's in All Mail and Work, p3 sent from another of
    /// the owner's addresses. Gives the store, the index, the account and
    /// All Mail's id.
    fn sample(name: &str) -> (Store, Index, i64, i64) {
        let dir = std::env::temp_dir().join(format!("gm-index-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut store = Store::open(&dir).unwrap();
        let mut index = Index::open(&dir.join("index.db")).unwrap();
        let account = store.account("proton", "anna@example.com").unwrap();
        let all = store.mailbox(account, "All Mail", Some("all")).unwrap();
        let work = store.mailbox(account, "Labels/Work", None).unwrap();
        let sent = store.mailbox(account, "Sent", Some("sent")).unwrap();
        let p1 = mail(1, "p1", "Bob <bob@x>", "Garden plans", &[]);
        let p2 = mail(
            2,
            "p2",
            "Anna <anna@example.com>",
            "Re: invoice",
            &["\\Seen"],
        );
        let p3 = mail(3, "p3", "Anna <anna@other.example>", "Seeds", &["\\Seen"]);
        store.put(account, all.id, &[p1, p2.clone()], 2, 1).unwrap();
        store
            .put(account, work.id, &[Fetched { uid: 7, ..p2 }], 7, 1)
            .unwrap();
        store.put(account, sent.id, &[p3], 3, 1).unwrap();
        let wanting = store.wanting(all.id, 10).unwrap();
        let first = wanting.iter().find(|w| w.uid == 1).unwrap().message;
        let body = Body {
            text: Some("tomatoes by the fence".into()),
            ..Body::default()
        };
        store.put_bodies(&[(first, body)]).unwrap();
        assert_eq!(catch_up(&mut store, &mut index).unwrap(), 3);
        (store, index, account, all.id)
    }

    #[test]
    fn the_index_finds_mail_by_words_places_and_flags() {
        let (mut store, mut index, account, _) = sample("finds");
        assert_eq!(index.count().unwrap(), 6, "three messages, three threads");
        let m1 = message_key(account, "pm:p1");
        let m2 = message_key(account, "pm:p2");
        let m3 = message_key(account, "pm:p3");
        assert_eq!(
            found(&index, &word("tomatoes")),
            std::slice::from_ref(&m1),
            "from the body"
        );
        assert_eq!(
            found(&index, &word("garden")),
            std::slice::from_ref(&m1),
            "from the subject"
        );
        assert_eq!(
            found(&index, &field("in", "work")),
            std::slice::from_ref(&m2)
        );
        assert_eq!(found(&index, &field("is", "unread")), [m1]);
        assert_eq!(
            found(&index, &field("is", "mine")),
            [m2, m3],
            "by address, and by Sent"
        );
        assert_eq!(
            catch_up(&mut store, &mut index).unwrap(),
            0,
            "nothing changed since"
        );
    }

    #[test]
    fn what_goes_from_the_server_goes_from_the_index() {
        let (mut store, mut index, _, all) = sample("goes");
        store.forget(all, &[1]).unwrap();
        catch_up(&mut store, &mut index).unwrap();
        assert_eq!(found(&index, &word("tomatoes")), Vec::<String>::new());
        assert_eq!(index.count().unwrap(), 4, "p1 and its thread went");
    }

    #[test]
    fn text_is_cut_where_a_character_ends() {
        assert_eq!(cut("café", 4), "caf");
        assert_eq!(cut("café", 5), "café");
    }
}
