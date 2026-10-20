//! Sending what was changed here (the store's `pending`) to the server at
//! the start of a round, mailbox by mailbox: flags and Gmail labels first,
//! then copies (Bridge's labels), then moves, then deletes, each kind in
//! one command for all its messages. What the server
//! refuses is taken back here, so the store never says what the server
//! won't.

use crate::imap::{Answer, Changing};
use crate::store::{Pending, Store};
use crate::sync::Trouble;

/// What sending did.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Sent {
    /// Changes the server has now.
    pub sent: usize,
    /// What it refused, in words.
    pub refused: Vec<String>,
}

/// Sends `account`'s changes made here to `server`.
pub async fn send<S: Changing>(
    server: &mut S,
    store: &mut Store,
    account: i64,
) -> Result<Sent, Trouble> {
    let pending = store.pending(account)?;
    let mut mailboxes: Vec<&str> = Vec::new();
    for p in &pending {
        if !mailboxes.contains(&p.mailbox.as_str()) {
            mailboxes.push(&p.mailbox);
        }
    }
    let mut sent = Sent::default();
    for mailbox in mailboxes {
        let here: Vec<&Pending> = pending.iter().filter(|p| p.mailbox == mailbox).collect();
        let uid_validity = match server.select(mailbox).await? {
            Ok(uid_validity) => uid_validity,
            Err(why) => {
                store.take_back(&ids(&here), true)?;
                sent.refused.push(format!("{mailbox}: {why}"));
                continue;
            }
        };
        // Made under other UIDs: they mean nothing now.
        let (current, stale): (Vec<&Pending>, Vec<&Pending>) = here
            .into_iter()
            .partition(|p| p.uid_validity == Some(uid_validity));
        store.take_back(&ids(&stale), true)?;
        for group in groups(&current) {
            let uids: Vec<u32> = group.iter().map(|p| p.uid).collect();
            let first = group[0];
            let answer: Answer = match first.op.as_str() {
                "+" | "-" => server.flag(&uids, &first.arg, first.op == "+").await?,
                "label+" | "label-" => {
                    server
                        .label(&uids, &first.arg, first.op == "label+")
                        .await?
                }
                "copy" => server.copy_to(&uids, &first.arg).await?,
                "move" => server.move_to(&uids, &first.arg).await?,
                _ => server.expunge(&uids).await?,
            };
            match answer {
                Ok(()) => {
                    store.sent(&ids(&group))?;
                    sent.sent += group.len();
                }
                Err(why) => {
                    store.take_back(&ids(&group), false)?;
                    sent.refused.push(format!("{mailbox}: {why}"));
                }
            }
        }
    }
    Ok(sent)
}

fn ids(pending: &[&Pending]) -> Vec<i64> {
    pending.iter().map(|p| p.id).collect()
}

/// `pending` (in one mailbox) as the commands that send it: those alike
/// together, UIDs lowest first, flags and labels before copies before
/// moves before deletes, as a message moved or deleted has no UID here to
/// change.
fn groups<'a>(pending: &[&'a Pending]) -> Vec<Vec<&'a Pending>> {
    let rank = |p: &Pending| match p.op.as_str() {
        "+" | "-" | "label+" | "label-" => 0,
        "copy" => 1,
        "move" => 2,
        _ => 3,
    };
    let mut sorted = pending.to_vec();
    sorted.sort_by(|a, b| (rank(a), &a.op, &a.arg, a.uid).cmp(&(rank(b), &b.op, &b.arg, b.uid)));
    let mut groups: Vec<Vec<&Pending>> = Vec::new();
    for p in sorted {
        match groups.last_mut() {
            Some(last) if last[0].op == p.op && last[0].arg == p.arg => last.push(p),
            _ => groups.push(vec![p]),
        }
    }
    groups
}

#[cfg(test)]
mod tests {
    use std::future::ready;

    use super::*;
    use crate::header::Fetched;
    use crate::imap;
    use crate::store::Action;

    /// A server that takes every change but those to `refuse`, writing
    /// down each command.
    #[derive(Default)]
    struct Fake {
        uid_validity: u32,
        refuse: Option<&'static str>,
        said: Vec<String>,
    }

    impl Fake {
        fn answer(&mut self, command: String) -> Answer {
            let refused = self.refuse.is_some_and(|r| command.contains(r));
            self.said.push(command);
            if refused { Err("no".into()) } else { Ok(()) }
        }
    }

    impl Changing for Fake {
        fn select(
            &mut self,
            mailbox: &str,
        ) -> impl Future<Output = Result<Result<u32, String>, imap::Trouble>> {
            self.said.push(format!("select {mailbox}"));
            ready(Ok(Ok(self.uid_validity)))
        }

        fn flag(
            &mut self,
            uids: &[u32],
            flag: &str,
            on: bool,
        ) -> impl Future<Output = Result<Answer, imap::Trouble>> {
            let sign = if on { '+' } else { '-' };
            ready(Ok(self.answer(format!("{sign}{flag} {uids:?}"))))
        }

        fn move_to(
            &mut self,
            uids: &[u32],
            to: &str,
        ) -> impl Future<Output = Result<Answer, imap::Trouble>> {
            ready(Ok(self.answer(format!("move {uids:?} {to}"))))
        }

        fn copy_to(
            &mut self,
            uids: &[u32],
            to: &str,
        ) -> impl Future<Output = Result<Answer, imap::Trouble>> {
            ready(Ok(self.answer(format!("copy {uids:?} {to}"))))
        }

        fn label(
            &mut self,
            uids: &[u32],
            label: &str,
            on: bool,
        ) -> impl Future<Output = Result<Answer, imap::Trouble>> {
            let sign = if on { '+' } else { '-' };
            ready(Ok(self.answer(format!("{sign}label {label} {uids:?}"))))
        }

        fn expunge(&mut self, uids: &[u32]) -> impl Future<Output = Result<Answer, imap::Trouble>> {
            ready(Ok(self.answer(format!("expunge {uids:?}"))))
        }

        fn append(
            &mut self,
            mailbox: &str,
            message: &[u8],
        ) -> impl Future<Output = Result<Answer, imap::Trouble>> {
            ready(Ok(
                self.answer(format!("append {mailbox} {}", message.len()))
            ))
        }
    }

    fn run<F: Future>(future: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap()
            .block_on(future)
    }

    fn message(uid: u32) -> Fetched {
        Fetched {
            uid,
            raw: format!("X-Pm-Internal-Id: p{uid}\r\nMessage-ID: <{uid}@x>\r\n\r\n").into_bytes(),
            ..Fetched::default()
        }
    }

    /// A store with messages at UIDs 1 to 3 in INBOX (UIDVALIDITY 7), and
    /// an Archive.
    fn store(name: &str) -> (Store, i64) {
        let dir = std::env::temp_dir().join(format!("gm-pending-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut store = Store::open(&dir).unwrap();
        let account = store.account("a", "a@example.com").unwrap();
        let inbox = store.mailbox(account, "INBOX", Some("inbox")).unwrap();
        store.mailbox(account, "Archive", Some("archive")).unwrap();
        store.restart(inbox.id, 7).unwrap();
        let messages: Vec<Fetched> = (1..=3).map(message).collect();
        store.put(account, inbox.id, &messages, 3, 1).unwrap();
        (store, account)
    }

    fn id(store: &Store, account: i64, uid: u32) -> i64 {
        store
            .messages_of(&format!("m:{account}:pm:p{uid}"))
            .unwrap()[0]
    }

    const SEEN: fn() -> Action = || Action::Flag {
        flag: "\\Seen".into(),
        on: true,
    };

    #[test]
    fn alike_changes_go_in_one_command_flags_before_moves() {
        let (mut store, account) = store("alike");
        let (one, two, three) = (
            id(&store, account, 1),
            id(&store, account, 2),
            id(&store, account, 3),
        );
        store.act(three, &Action::Archive).unwrap();
        store.act(one, &SEEN()).unwrap();
        store.act(two, &SEEN()).unwrap();
        store.act(one, &Action::Archive).unwrap();
        let mut server = Fake {
            uid_validity: 7,
            ..Fake::default()
        };
        let sent = run(send(&mut server, &mut store, account)).unwrap();
        assert_eq!(
            server.said,
            ["select INBOX", "+\\Seen [1, 2]", "move [1, 3] Archive"]
        );
        assert_eq!(
            sent,
            Sent {
                sent: 4,
                refused: Vec::new()
            }
        );
        assert!(store.pending(account).unwrap().is_empty());
        let again = run(send(&mut server, &mut store, account)).unwrap();
        assert_eq!(again.sent, 0, "nothing twice");
    }

    #[test]
    fn what_the_server_refuses_is_taken_back() {
        let (mut store, account) = store("refused");
        let one = id(&store, account, 1);
        store.act(one, &SEEN()).unwrap();
        store.act(one, &Action::Archive).unwrap();
        let mut server = Fake {
            uid_validity: 7,
            refuse: Some("move"),
            ..Fake::default()
        };
        let sent = run(send(&mut server, &mut store, account)).unwrap();
        assert_eq!(sent.sent, 1, "the flag went");
        assert_eq!(sent.refused, ["INBOX: no"]);
        let inbox = store.mailbox(account, "INBOX", None).unwrap();
        assert_eq!(
            store.uids(inbox.id).unwrap(),
            [1, 2, 3],
            "back in the inbox"
        );
    }

    #[test]
    fn changes_made_under_other_uids_are_dropped() {
        let (mut store, account) = store("stale");
        store.act(id(&store, account, 1), &SEEN()).unwrap();
        let mut server = Fake {
            uid_validity: 8,
            ..Fake::default()
        };
        let sent = run(send(&mut server, &mut store, account)).unwrap();
        assert_eq!(
            server.said,
            ["select INBOX"],
            "nothing sent to other messages"
        );
        assert_eq!(sent.sent, 0);
        assert!(store.pending(account).unwrap().is_empty());
    }

    #[test]
    fn labels_go_before_copies_before_moves_before_deletes() {
        let p = |id: i64, op: &str| Pending {
            id,
            mailbox: "INBOX".into(),
            uid: u32::try_from(id).unwrap(),
            uid_validity: Some(1),
            op: op.into(),
            arg: String::new(),
        };
        let all = [
            p(1, "expunge"),
            p(2, "move"),
            p(3, "copy"),
            p(4, "label+"),
            p(5, "+"),
        ];
        let refs: Vec<&Pending> = all.iter().collect();
        let order: Vec<&str> = groups(&refs).iter().map(|g| g[0].op.as_str()).collect();
        assert_eq!(order, ["+", "label+", "copy", "move", "expunge"]);
    }
}
