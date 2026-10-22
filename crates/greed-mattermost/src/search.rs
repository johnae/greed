//! Searching posts, in every team you're in or one channel, with the
//! server's own search (its words and `from:`, `in:`, `before:`...).

use std::collections::HashMap;

use greed_chat::protocol::{Found, SearchParams};
use greed_chat::rpc::Failure;
use serde_json::{Value, json};

use crate::Mattermost;
use crate::api::Posts;

/// The most posts a search gives.
const MOST: usize = 50;

impl Mattermost {
    /// The posts `params.query` finds, newest first.
    pub(crate) async fn search(&self, params: &SearchParams) -> Result<Vec<Found>, Failure> {
        let (api, me) = self.signed(&params.account)?;
        let fail = |e: crate::api::Error| Failure::new(format!("can't search: {e}"));
        let teams: Vec<Value> = api.get("api/v4/users/me/teams").await.map_err(fail)?;
        let body =
            json!({ "terms": params.query, "is_or_search": false, "page": 0, "per_page": MOST });
        let mut posts = Vec::new();
        for team in teams.iter().filter_map(|team| team["id"].as_str()) {
            let found: Posts = api
                .post(&format!("api/v4/teams/{team}/posts/search"), &body)
                .await
                .map_err(fail)?;
            posts.extend(found.oldest_first());
        }
        if let Some(room) = &params.room {
            posts.retain(|post| &post.channel_id == room);
        }
        posts.sort_by_key(|post| std::cmp::Reverse(post.create_at));
        posts.dedup_by(|a, b| a.id == b.id);
        posts.truncate(MOST);
        let names: HashMap<String, String> = self
            .rooms(&params.account)
            .await?
            .into_iter()
            .map(|room| (room.id, room.name))
            .collect();
        let items = self.items(&params.account, &api, &me, &posts).await;
        Ok(posts
            .iter()
            .zip(items)
            .map(|(post, item)| Found {
                room: post.channel_id.clone(),
                room_name: names.get(&post.channel_id).cloned().unwrap_or_default(),
                item,
            })
            .collect())
    }
}
