//! Channels' timelines as the client shows them: kept here while open, so
//! what comes over the WebSocket can change them, and sending to them.

use std::collections::BTreeMap;

use greed_chat::protocol::{
    Change, Item, ItemKind, Person, Reaction, RoomParams, SendParams, Sending,
};
use greed_chat::rpc::Failure;
use serde_json::{Value, json};

use crate::Mattermost;
use crate::api::{Api, Post, Posts};

/// How many posts a timeline fetches at a time.
const PAGE: usize = 60;

fn key(account: &str, room: &str) -> String {
    format!("{account} {room}")
}

impl Mattermost {
    /// Opens a channel's timeline: `{items}`, then `timeline.changed`.
    pub(crate) async fn open_timeline(&self, params: &RoomParams) -> Result<Value, Failure> {
        let (api, me) = self.signed(&params.account)?;
        let posts: Posts = api
            .get(&format!(
                "api/v4/channels/{}/posts?per_page={PAGE}",
                params.room
            ))
            .await
            .map_err(|e| Failure::new(format!("can't open the channel: {e}")))?;
        let posts = posts.oldest_first();
        let items = self.items(&params.account, &api, &me, &posts).await;
        self.timelines
            .borrow_mut()
            .insert(key(&params.account, &params.room), items.clone());
        Ok(json!({ "items": items }))
    }

    /// Stops keeping a channel's timeline.
    pub(crate) fn close_timeline(&self, params: &RoomParams) {
        self.timelines
            .borrow_mut()
            .remove(&key(&params.account, &params.room));
    }

    /// Fetches older posts into an open timeline: `{more}`.
    pub(crate) async fn back(&self, params: &RoomParams) -> Result<Value, Failure> {
        let (api, me) = self.signed(&params.account)?;
        let timeline = key(&params.account, &params.room);
        let oldest = self
            .timelines
            .borrow()
            .get(&timeline)
            .and_then(|items| items.iter().find_map(|item| item.event.clone()))
            .ok_or_else(|| Failure::new("that timeline isn't open"))?;
        let posts: Posts = api
            .get(&format!(
                "api/v4/channels/{}/posts?per_page={PAGE}&before={oldest}",
                params.room
            ))
            .await
            .map_err(|e| Failure::new(format!("can't fetch older messages: {e}")))?;
        let posts = posts.oldest_first();
        let more = posts.len() == PAGE;
        let older = self.items(&params.account, &api, &me, &posts).await;
        let changes: Vec<Change> = older
            .iter()
            .enumerate()
            .map(|(at, item)| Change::Insert {
                at,
                item: item.clone(),
            })
            .collect();
        if let Some(items) = self.timelines.borrow_mut().get_mut(&timeline) {
            items.splice(0..0, older);
        }
        self.tell(&params.account, &params.room, &changes);
        Ok(json!({ "more": more }))
    }

    /// Sends a message, shown at once and changed when the server has it.
    pub(crate) async fn send(&self, send: &SendParams) -> Result<(), Failure> {
        let (api, me) = self.signed(&send.account)?;
        let pending = format!("{me}:{}", greed_chat::random(8));
        // A reply in Mattermost goes to the thread of what it answers.
        let root = match send.thread.as_ref().or(send.reply_to.as_ref()) {
            Some(post) => self.thread_of(&send.account, &send.room, post),
            None => String::new(),
        };
        let echo = Item {
            id: pending.clone(),
            sender: Person {
                id: me.clone(),
                name: self.name_of(&send.account, &me),
                avatar: None,
            },
            at: now(),
            text: send.text.clone(),
            thread: Some(root.clone()).filter(|root| !root.is_empty()),
            mine: true,
            sending: Some(Sending::Sending),
            ..Item::default()
        };
        self.upsert(&send.account, &send.room, echo.clone());
        let body = json!({
            "channel_id": send.room,
            "message": send.text,
            "root_id": root,
            "pending_post_id": pending,
        });
        match api.post::<Post>("api/v4/posts", &body).await {
            Ok(post) => {
                self.posted(&send.account, &post).await;
                Ok(())
            }
            Err(e) => {
                let failed = Item {
                    sending: Some(Sending::Failed(e.message.clone())),
                    ..echo
                };
                self.upsert(&send.account, &send.room, failed);
                Err(Failure::new(format!("can't send: {e}")))
            }
        }
    }

    /// The thread a post in an open timeline is in, by its root.
    fn thread_of(&self, account: &str, room: &str, post: &str) -> String {
        self.timelines
            .borrow()
            .get(&key(account, room))
            .and_then(|items| {
                items
                    .iter()
                    .find(|item| item.event.as_deref() == Some(post))
            })
            .and_then(|item| item.thread.clone())
            .unwrap_or_else(|| post.to_string())
    }

    /// Takes in a post that's new or changed, in whatever timeline shows
    /// its channel: its local echo, or the post as it was, is replaced.
    pub(crate) async fn posted(&self, account: &str, post: &Post) {
        if !self
            .timelines
            .borrow()
            .contains_key(&key(account, &post.channel_id))
        {
            return;
        }
        let Ok((api, me)) = self.signed(account) else {
            return;
        };
        let Some(mut item) = self
            .items(account, &api, &me, std::slice::from_ref(post))
            .await
            .pop()
        else {
            return;
        };
        // Under the id its echo has, so the client changes that one.
        let echoed = !post.pending_post_id.is_empty()
            && self
                .timelines
                .borrow()
                .get(&key(account, &post.channel_id))
                .is_some_and(|items| items.iter().any(|it| it.id == post.pending_post_id));
        if echoed {
            item.id.clone_from(&post.pending_post_id);
        }
        self.upsert(account, &post.channel_id, item);
    }

    /// Puts `item` in its place in a timeline, by id or by the post it
    /// is, or at the end, and tells the client.
    fn upsert(&self, account: &str, room: &str, item: Item) {
        let change = {
            let mut timelines = self.timelines.borrow_mut();
            let Some(items) = timelines.get_mut(&key(account, room)) else {
                return;
            };
            let at = items.iter().position(|it| {
                it.id == item.id || (item.event.is_some() && it.event == item.event)
            });
            if let Some(at) = at {
                let item = Item {
                    id: items[at].id.clone(),
                    ..item
                };
                items[at] = item.clone();
                Change::Set { at, item }
            } else {
                items.push(item.clone());
                Change::Insert {
                    at: items.len() - 1,
                    item,
                }
            }
        };
        self.tell(account, room, &[change]);
    }

    fn tell(&self, account: &str, room: &str, changes: &[Change]) {
        if changes.is_empty() {
            return;
        }
        let params = json!({ "account": account, "room": room, "changes": changes });
        self.notifier.notify("timeline.changed", &params);
    }

    /// `posts` as items, with their senders' names fetched.
    async fn items(&self, account: &str, api: &Api, me: &str, posts: &[Post]) -> Vec<Item> {
        let senders: Vec<String> = posts.iter().map(|post| post.user_id.clone()).collect();
        self.people(account, api, &senders).await;
        posts
            .iter()
            .map(|post| self.item(account, me, post))
            .collect()
    }

    fn item(&self, account: &str, me: &str, post: &Post) -> Item {
        let mut reactions: BTreeMap<&str, Reaction> = BTreeMap::new();
        for reaction in &post.metadata.reactions {
            let entry = reactions
                .entry(&reaction.emoji_name)
                .or_insert_with(|| Reaction {
                    key: reaction.emoji_name.clone(),
                    count: 0,
                    mine: false,
                });
            entry.count += 1;
            entry.mine |= reaction.user_id == me;
        }
        let kind = if post.delete_at > 0 {
            ItemKind::Deleted
        } else if post.kind.starts_with("system_") {
            ItemKind::Change
        } else if let Some(file) = post.metadata.files.first() {
            if file.mime_type.starts_with("image/") {
                ItemKind::Image
            } else {
                ItemKind::File
            }
        } else {
            ItemKind::Message
        };
        Item {
            id: post.id.clone(),
            event: Some(post.id.clone()),
            sender: Person {
                id: post.user_id.clone(),
                name: self.name_of(account, &post.user_id),
                avatar: None,
            },
            at: post.create_at,
            kind,
            text: text(post),
            reply_to: None,
            thread: Some(post.root_id.clone()).filter(|root| !root.is_empty()),
            replies: post.reply_count,
            reactions: reactions.into_values().collect(),
            edited: post.edit_at > 0,
            mine: post.user_id == me,
            sending: None,
        }
    }
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| {
            i64::try_from(since.as_millis()).unwrap_or(i64::MAX)
        })
}

/// What a post says: its message, or what it holds when that's empty.
fn text(post: &Post) -> String {
    if post.message.is_empty() {
        let names: Vec<&str> = post
            .metadata
            .files
            .iter()
            .map(|f| f.name.as_str())
            .collect();
        names.join(", ")
    } else {
        post.message.clone()
    }
}
