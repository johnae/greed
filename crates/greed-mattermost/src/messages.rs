//! Every post an account sees, for the client to keep for searching: told
//! as `messages` as they come, in any channel and edits too, deletions as
//! `unsaid`, and a channel's older ones by `history`, a page at a time.

use greed_chat::protocol::{History, HistoryParams, Person, Said};
use greed_chat::rpc::Failure;
use serde_json::json;

use crate::Mattermost;
use crate::alerts::describe;
use crate::api::{Api, Channel, Post, Posts};
use crate::rooms::other_in;

/// The most posts a page of `history` holds.
const PAGE: u32 = 100;

impl Mattermost {
    /// Tells of `post`, posted or changed in account `id`.
    pub(crate) async fn said(&self, id: &str, post: &Post) {
        let Ok((api, me)) = self.signed(id) else {
            return;
        };
        if post.delete_at > 0 {
            self.notifier.notify(
                "unsaid",
                &json!({ "account": id, "room": post.channel_id, "event": post.id }),
            );
            return;
        }
        let messages = self.kept(id, &api, &me, std::slice::from_ref(post)).await;
        if !messages.is_empty() {
            self.notifier
                .notify("messages", &json!({ "account": id, "messages": messages }));
        }
    }

    /// A channel's posts older than `params.before`, newest first, and the
    /// mark for those before them.
    pub(crate) async fn history(&self, params: &HistoryParams) -> Result<History, Failure> {
        let (api, me) = self.signed(&params.account)?;
        let limit = params.limit.unwrap_or(PAGE).min(PAGE);
        let before = params
            .before
            .as_ref()
            .map_or(String::new(), |before| format!("&before={before}"));
        let path = format!(
            "api/v4/channels/{}/posts?per_page={limit}{before}",
            params.room
        );
        let posts: Posts = api
            .get(&path)
            .await
            .map_err(|e| Failure::new(format!("can't fetch older posts: {e}")))?;
        let mut posts = posts.oldest_first();
        posts.reverse();
        let before = posts.last().map(|post| post.id.clone());
        let messages = self.kept(&params.account, &api, &me, &posts).await;
        Ok(History { messages, before })
    }

    /// `posts` as they're kept, leaving out what the server says itself.
    async fn kept(&self, id: &str, api: &Api, me: &str, posts: &[Post]) -> Vec<Said> {
        let senders: Vec<String> = posts.iter().map(|post| post.user_id.clone()).collect();
        self.people(id, api, &senders).await;
        let mut kept = Vec::new();
        for post in posts {
            let Some(text) = describe(post) else {
                continue;
            };
            let (room_name, direct) = self.channel(id, api, me, &post.channel_id).await;
            kept.push(Said {
                room: post.channel_id.clone(),
                room_name,
                event: post.id.clone(),
                sender: Person {
                    id: post.user_id.clone(),
                    name: self.name_of(id, &post.user_id),
                    avatar: None,
                },
                at: post.create_at,
                text,
                thread: Some(post.root_id.clone()).filter(|root| !root.is_empty()),
                mine: post.user_id == me,
                direct,
            });
        }
        kept
    }

    /// What channel `room` of account `id` is called, and whether it's a
    /// direct message, asked of the server the first time.
    async fn channel(&self, id: &str, api: &Api, me: &str, room: &str) -> (String, bool) {
        let key = format!("{id} {room}");
        if let Some(known) = self.channels.borrow().get(&key) {
            return known.clone();
        }
        let Ok(channel) = api.get::<Channel>(&format!("api/v4/channels/{room}")).await else {
            return (room.to_string(), false);
        };
        let direct = matches!(channel.kind.as_str(), "D" | "G");
        if channel.kind == "D"
            && let Some(other) = other_in(&channel, me)
        {
            self.people(id, api, &[other]).await;
        }
        let name = self.channel_name(id, me, &channel);
        self.channels
            .borrow_mut()
            .insert(key, (name.clone(), direct));
        (name, direct)
    }
}
