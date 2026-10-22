//! Channels' and threads' timelines as the client shows them: kept here
//! while open, so what comes over the WebSocket can change them; and what
//! you do to messages. A channel shows each thread's first message with
//! how many replies it has, as Mattermost's collapsed threads do; a
//! thread's timeline shows the replies.

use std::collections::BTreeMap;

use greed_chat::protocol::{
    Change, Item, ItemKind, Media, MessageParams, Person, Reaction, RoomParams, SendParams, Sending,
};
use greed_chat::rpc::Failure;
use serde_json::{Value, json};

use crate::Mattermost;
use crate::api::{Api, Post, Posts};

/// How many posts a timeline fetches at a time.
const PAGE: usize = 60;

/// The kind a post only you see is given here, as it comes over the
/// WebSocket (`ephemeral_message`), like what a command answered.
pub(crate) const EPHEMERAL: &str = "system_ephemeral";

/// The emoji Mattermost knows by these names, both ways: reactions are
/// named there, and shown as the emoji here.
const EMOJI: &[(&str, &str)] = &[
    ("👍", "+1"),
    ("👎", "-1"),
    ("❤️", "heart"),
    ("😄", "smile"),
    ("😂", "joy"),
    ("🎉", "tada"),
    ("👀", "eyes"),
    ("✅", "white_check_mark"),
    ("🙏", "pray"),
    ("🚀", "rocket"),
    ("🔥", "fire"),
    ("😢", "cry"),
    ("🤔", "thinking_face"),
    ("👏", "clap"),
];

/// The name Mattermost knows reaction `key` by: an emoji, or a name as is.
fn emoji_name(key: &str) -> String {
    let bare = key.trim_matches(':');
    EMOJI
        .iter()
        .find(|(emoji, _)| *emoji == bare)
        .map_or_else(|| bare.to_string(), |(_, name)| (*name).to_string())
}

/// How reaction `name` shows: its emoji, or `:name:` for one without.
fn emoji_shown(name: &str) -> String {
    EMOJI
        .iter()
        .find(|(_, known)| *known == name)
        .map_or_else(|| format!(":{name}:"), |(emoji, _)| (*emoji).to_string())
}

fn key(account: &str, room: &str, thread: Option<&str>) -> String {
    format!("{account} {room} {}", thread.unwrap_or(""))
}

fn key_of(params: &RoomParams) -> String {
    key(&params.account, &params.room, params.thread.as_deref())
}

impl Mattermost {
    /// Opens a channel's timeline, or a thread's: `{items}`, then
    /// `timeline.changed`.
    pub(crate) async fn open_timeline(&self, params: &RoomParams) -> Result<Value, Failure> {
        let (api, me) = self.signed(&params.account)?;
        let path = match &params.thread {
            Some(root) => format!("api/v4/posts/{root}/thread"),
            None => format!(
                "api/v4/channels/{}/posts?per_page={PAGE}&collapsedThreads=true",
                params.room
            ),
        };
        let posts: Posts = api
            .get(&path)
            .await
            .map_err(|e| Failure::new(format!("can't open the channel: {e}")))?;
        let posts = posts.oldest_first();
        let items = self.items(&params.account, &api, &me, &posts).await;
        self.timelines
            .borrow_mut()
            .insert(key_of(params), items.clone());
        Ok(json!({ "items": items }))
    }

    /// Stops keeping a timeline.
    pub(crate) fn close_timeline(&self, params: &RoomParams) {
        self.timelines.borrow_mut().remove(&key_of(params));
    }

    /// Fetches older posts into an open channel's timeline: `{more}`. A
    /// thread comes whole.
    pub(crate) async fn back(&self, params: &RoomParams) -> Result<Value, Failure> {
        if params.thread.is_some() {
            return Ok(json!({ "more": false }));
        }
        let (api, me) = self.signed(&params.account)?;
        let timeline = key_of(params);
        let oldest = self
            .timelines
            .borrow()
            .get(&timeline)
            .and_then(|items| items.iter().find_map(|item| item.event.clone()))
            .ok_or_else(|| Failure::new("that timeline isn't open"))?;
        let posts: Posts = api
            .get(&format!(
                "api/v4/channels/{}/posts?per_page={PAGE}&before={oldest}&collapsedThreads=true",
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
        self.tell(&params.account, &params.room, None, &changes);
        Ok(json!({ "more": more }))
    }

    /// Sends a message, shown at once and changed when the server has it.
    /// A reply goes to the thread of what it answers, as Mattermost has it.
    pub(crate) async fn send(&self, send: &SendParams) -> Result<(), Failure> {
        let (api, me) = self.signed(&send.account)?;
        let pending = format!("{me}:{}", greed_chat::random(8));
        let root = match (&send.thread, &send.reply_to) {
            (Some(thread), _) => thread.clone(),
            (None, Some(post)) => self.thread_of(&send.account, &send.room, post),
            (None, None) => String::new(),
        };
        let thread = Some(root.as_str()).filter(|root| !root.is_empty());
        let echo = Item {
            id: pending.clone(),
            sender: Person {
                id: me.clone(),
                name: self.name_of(&send.account, &me),
                avatar: None,
            },
            at: now(),
            text: send.text.clone(),
            thread: thread.map(str::to_string),
            mine: true,
            sending: Some(Sending::Sending),
            ..Item::default()
        };
        self.upsert(&send.account, &send.room, thread, echo.clone());
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
                self.upsert(&send.account, &send.room, thread, failed);
                Err(Failure::new(format!("can't send: {e}")))
            }
        }
    }

    /// The thread a post in an open timeline is in, by its root: its own
    /// when it starts one or isn't in one.
    fn thread_of(&self, account: &str, room: &str, post: &str) -> String {
        let prefix = format!("{account} {room} ");
        self.timelines
            .borrow()
            .iter()
            .filter(|(key, _)| key.starts_with(&prefix))
            .flat_map(|(_, items)| items.iter())
            .find(|item| item.event.as_deref() == Some(post))
            .and_then(|item| item.thread.clone())
            .unwrap_or_else(|| post.to_string())
    }

    /// Changes what one of your messages says.
    pub(crate) async fn edit(&self, message: &MessageParams) -> Result<(), Failure> {
        let (api, _) = self.signed(&message.account)?;
        let path = format!("api/v4/posts/{}/patch", message.event);
        let post: Post = api
            .put(&path, &json!({ "message": message.text }))
            .await
            .map_err(|e| Failure::new(format!("can't change it: {e}")))?;
        self.posted(&message.account, &post).await;
        Ok(())
    }

    /// Deletes a message.
    pub(crate) async fn redact(&self, message: &MessageParams) -> Result<(), Failure> {
        let (api, _) = self.signed(&message.account)?;
        api.delete(&format!("api/v4/posts/{}", message.event))
            .await
            .map_err(|e| Failure::new(format!("can't delete it: {e}")))
    }

    /// Adds your reaction to a message, or takes it back if it's there.
    pub(crate) async fn react(&self, message: &MessageParams) -> Result<(), Failure> {
        let (api, me) = self.signed(&message.account)?;
        let name = emoji_name(&message.key);
        let post: Post = api
            .get(&format!("api/v4/posts/{}", message.event))
            .await
            .map_err(|e| Failure::new(format!("can't react: {e}")))?;
        let mine = post
            .metadata
            .reactions
            .iter()
            .any(|reaction| reaction.user_id == me && reaction.emoji_name == name);
        let done = if mine {
            api.delete(&format!(
                "api/v4/users/me/posts/{}/reactions/{name}",
                message.event
            ))
            .await
        } else {
            let body = json!({ "user_id": me, "post_id": message.event, "emoji_name": name });
            api.post::<Value>("api/v4/reactions", &body).await.map(drop)
        };
        done.map_err(|e| Failure::new(format!("can't react: {e}")))
    }

    /// Marks the channel read.
    pub(crate) async fn read(&self, params: &RoomParams) -> Result<(), Failure> {
        let (api, _) = self.signed(&params.account)?;
        api.post::<Value>(
            "api/v4/channels/members/me/view",
            &json!({ "channel_id": params.room }),
        )
        .await
        .map(drop)
        .map_err(|e| Failure::new(format!("can't mark it read: {e}")))
    }

    /// Takes in a post that's new or changed, in whatever timeline shows
    /// it: its local echo, or the post as it was, is replaced. A reply
    /// changes its thread's first message in the channel too (how many
    /// replies it has).
    pub(crate) async fn posted(&self, account: &str, post: &Post) {
        let thread = Some(post.root_id.as_str()).filter(|root| !root.is_empty());
        if let Some(root) = thread {
            self.refresh(account, &post.channel_id, root).await;
        }
        let shown = key(account, &post.channel_id, thread);
        if !self.timelines.borrow().contains_key(&shown) {
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
                .get(&shown)
                .is_some_and(|items| items.iter().any(|it| it.id == post.pending_post_id));
        if echoed {
            item.id.clone_from(&post.pending_post_id);
        }
        self.upsert(account, &post.channel_id, thread, item);
    }

    /// Fetches a thread's first message again into its channel's open
    /// timeline, for its count of replies.
    async fn refresh(&self, account: &str, room: &str, first: &str) {
        if !self
            .timelines
            .borrow()
            .contains_key(&key(account, room, None))
        {
            return;
        }
        let Ok((api, me)) = self.signed(account) else {
            return;
        };
        let Ok(post) = api.get::<Post>(&format!("api/v4/posts/{first}")).await else {
            return;
        };
        if let Some(item) = self
            .items(account, &api, &me, std::slice::from_ref(&post))
            .await
            .pop()
        {
            self.upsert(account, room, None, item);
        }
    }

    /// Puts `item` in its place in a timeline, by id or by the post it
    /// is, or at the end, and tells the client.
    fn upsert(&self, account: &str, room: &str, thread: Option<&str>, item: Item) {
        let change = {
            let mut timelines = self.timelines.borrow_mut();
            let Some(items) = timelines.get_mut(&key(account, room, thread)) else {
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
        self.tell(account, room, thread, &[change]);
    }

    fn tell(&self, account: &str, room: &str, thread: Option<&str>, changes: &[Change]) {
        if changes.is_empty() {
            return;
        }
        let params =
            json!({ "account": account, "room": room, "thread": thread, "changes": changes });
        self.notifier.notify("timeline.changed", &params);
    }

    /// `posts` as items, with their senders' names fetched.
    pub(crate) async fn items(
        &self,
        account: &str,
        api: &Api,
        me: &str,
        posts: &[Post],
    ) -> Vec<Item> {
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
                    key: emoji_shown(&reaction.emoji_name),
                    count: 0,
                    mine: false,
                });
            entry.count += 1;
            entry.mine |= reaction.user_id == me;
        }
        let kind = if post.delete_at > 0 {
            ItemKind::Deleted
        } else if post.kind == "custom_calls" {
            ItemKind::Call
        } else if post.kind == EPHEMERAL {
            ItemKind::Notice
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
        // One only you see isn't on the server to answer or link to.
        let on_server = post.kind != EPHEMERAL;
        Item {
            id: post.id.clone(),
            event: on_server.then(|| post.id.clone()),
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
            read_by: Vec::new(),
            media: post.metadata.files.first().map(media_of),
            // The server sends a permalink on to the post's team and channel.
            link: self
                .signed(account)
                .ok()
                .filter(|_| on_server)
                .map(|(api, _)| format!("{}/_redirect/pl/{}", api.address(), post.id)),
            actions: crate::commands::actions(post),
            preview: crate::media::preview(post),
            poll: None,
            location: None,
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

/// What a post says: its message and its attachments' text, or the files
/// it holds when that's empty.
fn text(post: &Post) -> String {
    let attached = crate::commands::attachments_text(post);
    let said: Vec<&str> = [post.message.as_str(), attached.as_str()]
        .into_iter()
        .filter(|part| !part.is_empty())
        .collect();
    if said.is_empty() {
        let names: Vec<&str> = post
            .metadata
            .files
            .iter()
            .map(|f| f.name.as_str())
            .collect();
        names.join(", ")
    } else {
        said.join("\n\n")
    }
}

/// What a file attached to a post is.
fn media_of(file: &crate::api::File) -> Media {
    let pixels = |n: u64| (n > 0).then_some(n);
    Media {
        name: file.name.clone(),
        mime: file.mime_type.clone(),
        size: Some(file.size),
        width: pixels(file.width),
        height: pixels(file.height),
        thumbnail: file.has_preview_image || file.mime_type.starts_with("image/"),
    }
}
