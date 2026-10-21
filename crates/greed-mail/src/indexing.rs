//! The index the mail client searches: `index.db`, a `greed-index` index
//! of every message and thread, kept up with the store. The store marks
//! what changed; `catch_up` writes those and takes out what went, so the
//! index is behind at most until the next catch-up, never wrong for good.
//!
//! A message's fields: `from`, `to`, `cc` and `subject` (text), `date` (in
//! UTC), `size` (a value), `tag` (where it is: its folders and labels by
//! name, which `in:` matches, as `places` says), `account` and `list`
//! (exact), and of what's attached `file` (text: its names) and `type`
//! (exact: each one's extension, like pdf, and image, audio or video).
//! Its flags: `unread`, `flagged`, `answered`, `draft`, `attachment` and
//! `mine` (sent by the owner: in Sent, or from the account's address). A
//! thread is an item too, named by its first message's subject, with its
//! messages under it.

use std::collections::{BTreeSet, HashMap};
use std::path::Path;

use greed_index::index::{Index, Item};

use crate::addresses;
use crate::names;
use crate::store::{Indexable, Store, Trouble};

/// The field the index keeps a message's places in, for `in:`.
pub const PLACES: &str = "tag";

/// The fields searched by word: the text ones.
const WORDED: [&str; 5] = ["from", "to", "cc", "subject", "file"];

/// How many messages are written to the index at a time.
pub const BATCH: usize = 2000;

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

/// How messages are made items here; changing what an item holds changes
/// it, and every message is written again.
const INDEXED: &str = "3";

/// The index at `path`, for `store`. One that's empty (new, or made again
/// by a newer greed-index), or made by an `INDEXED` before, gets every
/// message again in the next catch-up.
pub fn open(store: &mut Store, path: &Path) -> Result<Index, Trouble> {
    let index = Index::open(path).map_err(|e| Trouble(e.0))?;
    let changed = store.indexed_as(INDEXED)?;
    if changed || index.count().map_err(|e| Trouble(e.0))? == 0 {
        store.unindex_all()?;
    }
    Ok(index)
}

/// Brings `index` up to `store`: writes what changed and takes out what
/// went. Gives how many messages it wrote.
pub fn catch_up(store: &mut Store, index: &mut Index) -> Result<usize, Trouble> {
    let mut written = 0;
    loop {
        let some = catch_up_some(store, index)?;
        if some == 0 {
            break;
        }
        written += some;
    }
    take_out_gone(store, index)?;
    Ok(written)
}

/// Writes the messages `ids` to `index` if they changed, and takes out
/// what went: what a change asked for needs at once, however much else
/// waits for a catch-up. Gives how many it wrote.
pub fn catch_up_on(store: &mut Store, index: &mut Index, ids: &[i64]) -> Result<usize, Trouble> {
    let mut written = 0;
    for some in ids.chunks(BATCH) {
        written += write_some(store, index, Some(some))?;
    }
    take_out_gone(store, index)?;
    Ok(written)
}

/// Writes the next `BATCH` of what changed to `index`, for a catch-up
/// that says how far it got as it goes; gives how many, 0 once none are
/// left. What went is left for `take_out_gone`.
pub fn catch_up_some(store: &mut Store, index: &mut Index) -> Result<usize, Trouble> {
    write_some(store, index, None)
}

/// Writes up to `BATCH` of what changed to `index`, of `only` those
/// messages when given; gives how many.
fn write_some(
    store: &mut Store,
    index: &mut Index,
    only: Option<&[i64]>,
) -> Result<usize, Trouble> {
    let messages = store.unindexed(BATCH, only)?;
    if messages.is_empty() {
        return Ok(0);
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
    Ok(messages.len())
}

/// Takes out of `index` what went from `store`.
pub fn take_out_gone(store: &mut Store, index: &mut Index) -> Result<(), Trouble> {
    loop {
        let keys = store.removed(BATCH)?;
        if keys.is_empty() {
            break;
        }
        index.remove(&keys).map_err(|e| Trouble(e.0))?;
        store.unlisted(&keys)?;
    }
    Ok(())
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
    field("date", &utc(m.date.as_deref().unwrap_or("")));
    field("size", &m.size.to_string());
    field("account", &m.account_name);
    field("list", m.list_id.as_deref().unwrap_or(""));
    for tag in tags(m) {
        field(PLACES, &tag);
    }
    for attached in &m.attached {
        field("file", &attached.name);
        for kind in kinds(attached) {
            field("type", &kind);
        }
    }
    let has = |flag: &str| m.flags.split(' ').any(|f| f.eq_ignore_ascii_case(flag));
    let mut flags = Vec::new();
    for (flag, on) in [
        ("unread", !has("\\Seen")),
        ("flagged", has("\\Flagged")),
        ("answered", has("\\Answered")),
        ("draft", has("\\Draft")),
        ("attachment", !m.attached.is_empty()),
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
    // What's attached is found by a plain word too.
    for attached in &m.attached {
        text.push('\n');
        text.push_str(&attached.name);
    }
    Item {
        key: message_key(m.account, &m.identity),
        parent: m.thread.as_deref().map(|t| thread_key(m.account, t)),
        name: None,
        text,
        fields,
        flags,
        words: Some(WORDED.iter().map(ToString::to_string).collect()),
    }
}

/// What kind of file `attached` is, as `type:` finds it: its extension
/// ("pdf", "jpg"), and "image", "audio" or "video" for those.
fn kinds(attached: &crate::body::Attachment) -> Vec<String> {
    let mut out = Vec::new();
    if let Some((_, ext)) = attached.name.rsplit_once('.')
        && !ext.is_empty()
        && ext.len() <= 8
    {
        out.push(ext.to_lowercase());
    }
    let major = attached.mime.split('/').next().unwrap_or("").to_lowercase();
    if matches!(major.as_str(), "image" | "audio" | "video") {
        out.push(major);
    }
    out
}

/// Whether `m` was sent by the account's owner: it's in a Sent mailbox, or
/// it's from the account's address or one of its aliases (people send
/// from more than mail.toml says, which the Sent mailbox knows).
fn mine(m: &Indexable) -> bool {
    let own = addresses::own(&m.address, &m.aliases);
    m.places
        .iter()
        .any(|(_, role)| role.as_deref() == Some("sent"))
        || addresses::split(&m.from)
            .iter()
            .any(|from| own.contains(&addresses::bare(from)))
}

fn tags(m: &Indexable) -> Vec<String> {
    tags_of(&m.places, &m.labels, &m.flags)
}

/// Where a message is, by name: the mailboxes it's in (`places`, by name
/// and role; All Mail aside, as every message is there), its Gmail
/// `labels` (one a line) and the keywords among its `flags`, each once.
pub fn tags_of(places: &[(String, Option<String>)], labels: &str, flags: &str) -> Vec<String> {
    let mut tags: Vec<String> = places
        .iter()
        .filter_map(|(name, role)| place_name(name, role.as_deref()))
        .collect();
    tags.extend(labels.lines().filter(|l| !l.is_empty()).map(label_name));
    tags.extend(flags.split(' ').filter(|f| is_tag(f)).map(str::to_string));
    tags.sort();
    tags.dedup();
    tags
}

/// The keywords servers and clients set for their own ends, which aren't
/// tags anyone gave: forwarded, receipts sent, junk marks.
const NOT_TAGS: &[&str] = &[
    "$forwarded",
    "$mdnsent",
    "$junk",
    "$notjunk",
    "junk",
    "nonjunk",
    "notjunk",
    "$phishing",
    "$submitpending",
    "$submitted",
];

/// Whether `flag` is a tag: a keyword (no `\` system flag) set by someone,
/// not one of `NOT_TAGS`.
pub fn is_tag(flag: &str) -> bool {
    !flag.is_empty() && !flag.starts_with('\\') && !NOT_TAGS.contains(&flag.to_lowercase().as_str())
}

/// `name` as an IMAP keyword, which a tag is on a plain IMAP server: an
/// atom, so nothing that has a meaning in IMAP's syntax; or why it can't
/// be one.
pub fn keyword(name: &str) -> Result<String, String> {
    let bad = |c: char| !c.is_ascii_graphic() || "(){%*\"\\]".contains(c);
    if name.is_empty() || name.chars().any(bad) {
        return Err(format!(
            "{name:?} can't be a tag here: no spaces, and none of ( ) {{ % * \" \\ ]"
        ));
    }
    if !is_tag(name) {
        return Err(format!("{name} is kept for the server's own use"));
    }
    Ok(name.to_string())
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

/// `date` (RFC 3339) in UTC, so every message's date sorts and compares
/// with every other's: as they come, each has its own offset. One that
/// doesn't read as a date stays as it is.
fn utc(date: &str) -> String {
    mail_parser::DateTime::parse_rfc3339(date).map_or_else(
        || date.to_string(),
        |d| mail_parser::DateTime::from_timestamp(d.to_timestamp()).to_rfc3339(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    use greed_index::index::View;
    use greed_index::query::{Flag, Kind, Node, Schema};

    use crate::body::{Attachment, Body};
    use crate::header::Fetched;

    #[test]
    fn a_messages_tags_are_its_places_labels_and_keywords() {
        let places = vec![
            ("INBOX".to_string(), Some("inbox".to_string())),
            ("All Mail".to_string(), Some("all".to_string())),
            ("Labels/Work".to_string(), None),
        ];
        let tags = tags_of(
            &places,
            "\\Important\nTrips",
            "\\Seen garden $Forwarded NonJunk",
        );
        assert_eq!(tags, ["Important", "Inbox", "Trips", "Work", "garden"]);
        assert_eq!(keyword("garden"), Ok("garden".into()));
        assert_eq!(keyword("$label1"), Ok("$label1".into()));
        assert!(keyword("two words").is_err());
        assert!(keyword("a(b").is_err());
        assert!(keyword("\\Seen").is_err(), "a system flag isn't a tag");
        assert!(keyword("$Junk").is_err(), "nor is a junk mark");
        assert!(keyword("").is_err());
    }

    #[test]
    fn dates_are_indexed_in_utc_so_they_sort_across_offsets() {
        assert_eq!(utc("2026-10-19T08:00:00+02:00"), "2026-10-19T06:00:00Z");
        assert_eq!(utc("2026-10-19T23:30:00-05:00"), "2026-10-20T04:30:00Z");
        assert_eq!(utc("2026-10-19T06:00:00Z"), "2026-10-19T06:00:00Z");
        assert_eq!(utc("not a date"), "not a date");
        assert_eq!(utc(""), "");
        // Later in the day by the clock, earlier in fact.
        assert!(utc("2026-10-19T08:00:00+02:00") < utc("2026-10-19T07:00:00Z"));
    }

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
            ("file", Kind::Text),
            ("type", Kind::Exact),
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
            attachments: vec![
                Attachment {
                    name: "Seed list.PDF".into(),
                    mime: "application/pdf".into(),
                    size: 1,
                },
                Attachment {
                    name: "plot.jpg".into(),
                    mime: "image/jpeg".into(),
                    size: 1,
                },
            ],
            ..Body::default()
        };
        store.put_bodies(&[(first, body)]).unwrap();
        assert_eq!(catch_up(&mut store, &mut index).unwrap(), 3);
        (store, index, account, all.id)
    }

    #[test]
    fn a_catch_up_on_some_writes_only_those_and_leaves_the_rest_waiting() {
        let (mut store, mut index, account, _) = sample("on");
        store.unindex_all().unwrap();
        let p1 = store.messages_of(&message_key(account, "pm:p1")).unwrap();
        assert_eq!(catch_up_on(&mut store, &mut index, &p1).unwrap(), 1);
        assert_eq!(store.unindexed_count().unwrap(), 2, "the others wait");
        assert_eq!(
            catch_up_on(&mut store, &mut index, &p1).unwrap(),
            0,
            "nothing new"
        );
        assert_eq!(catch_up(&mut store, &mut index).unwrap(), 2);
    }

    #[test]
    fn what_is_attached_is_found_by_its_name_and_kind() {
        let (_store, index, account, _) = sample("attached");
        let m1 = vec![message_key(account, "pm:p1")];
        assert_eq!(
            found(&index, &field("file", "seed")),
            m1,
            "by a word of its name"
        );
        assert_eq!(found(&index, &word("plot")), m1, "a plain word too");
        assert_eq!(
            found(&index, &field("type", "pdf")),
            m1,
            "its extension, any case"
        );
        assert_eq!(found(&index, &field("type", "image")), m1, "its kind");
        assert!(found(&index, &field("type", "docx")).is_empty());
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

    #[test]
    fn an_index_made_again_gets_every_message_again() {
        let (mut store, index, _, _) = sample("again");
        assert_eq!(index.count().unwrap(), 6);
        drop(index);
        let path = std::env::temp_dir().join(format!("gm-index-again-new-{}", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let mut fresh = open(&mut store, &path).unwrap();
        assert_eq!(catch_up(&mut store, &mut fresh).unwrap(), 3);
        assert_eq!(fresh.count().unwrap(), 6);
        let mut again = open(&mut store, &path).unwrap();
        assert_eq!(
            catch_up(&mut store, &mut again).unwrap(),
            0,
            "not when it has them"
        );
    }

    #[test]
    fn mine_is_from_your_address_not_one_that_ends_like_it() {
        let from = |from: &str| Indexable {
            from: from.into(),
            address: "anna@x".into(),
            ..Indexable::default()
        };
        assert!(mine(&from("Anna <ANNA@x>")));
        assert!(!mine(&from("Joanna <joanna@x>")));
        let sent = Indexable {
            places: vec![("Sent".into(), Some("sent".into()))],
            ..from("other@x")
        };
        assert!(mine(&sent), "in Sent, whoever it says");
        let alias = Indexable {
            aliases: vec!["support@hyper.example".into()],
            ..from("Support <SUPPORT@hyper.example>")
        };
        assert!(mine(&alias), "from an alias");
    }
}
