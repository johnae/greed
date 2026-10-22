//! New posts for you, told as `alert`: those that mention you, and every
//! post in a direct or group message.

use greed_chat::protocol::{Alert, Person};
use serde_json::{Value, json};

use crate::Mattermost;
use crate::api::Post;

impl Mattermost {
    /// Tells of `post`, which came as the `posted` event `event` to account
    /// `id`, if it's for you.
    pub(crate) fn alert(&self, id: &str, event: &Value, post: &Post) {
        let Ok((_, me)) = self.signed(id) else {
            return;
        };
        if post.user_id == me {
            return;
        }
        let data = &event["data"];
        let direct = matches!(data["channel_type"].as_str(), Some("D" | "G"));
        // The server counts a direct message as mentioning everyone in it.
        let mention = !direct
            && data["mentions"]
                .as_str()
                .and_then(|ids| serde_json::from_str::<Vec<String>>(ids).ok())
                .is_some_and(|ids| ids.contains(&me));
        if !mention && !direct {
            return;
        }
        let Some(body) = describe(post) else {
            return;
        };
        let named = |field: &str| {
            data[field]
                .as_str()
                .unwrap_or_default()
                .trim_start_matches('@')
                .to_string()
        };
        let alert = Alert {
            account: id.to_string(),
            room: post.channel_id.clone(),
            room_name: named("channel_display_name"),
            event: post.id.clone(),
            sender: Person {
                id: post.user_id.clone(),
                name: named("sender_name"),
                avatar: None,
            },
            body,
            mention,
            direct,
        };
        self.notifier.notify("alert", &json!(alert));
    }
}

/// A post's text, or what it is when it's a file or a call; nothing for
/// what the server says itself (someone joining).
fn describe(post: &Post) -> Option<String> {
    if post.kind == "custom_calls" {
        return Some("is calling".into());
    }
    if !post.kind.is_empty() {
        return None;
    }
    if !post.message.is_empty() {
        return Some(post.message.clone());
    }
    let file = post.metadata.files.first()?;
    Some(if file.mime_type.starts_with("image/") {
        "sent a picture".into()
    } else {
        "sent a file".into()
    })
}
