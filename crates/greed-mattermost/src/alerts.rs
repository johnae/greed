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

/// The type of a post with attachments, as integrations and webhooks send
/// (alerts, CI): an ordinary post whose text is mostly in them.
const WITH_ATTACHMENTS: &str = "slack_attachment";

/// What `post` says in words: its message, then its attachments' text.
pub(crate) fn words(post: &Post) -> String {
    let attached = crate::commands::attachments_text(post);
    [post.message.as_str(), attached.as_str()]
        .into_iter()
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("\n\n")
}

/// Who `post` says it's from, when a webhook posted it under a name of its
/// own; otherwise it's from whoever it's from.
pub(crate) fn webhook_name(post: &Post) -> Option<String> {
    (post.props["from_webhook"] == "true")
        .then(|| post.props["override_username"].as_str())
        .flatten()
        .filter(|name| !name.is_empty())
        .map(str::to_string)
}

/// A post's text, or what it is when it's a file or a call; nothing for
/// what the server says itself (someone joining).
pub(crate) fn describe(post: &Post) -> Option<String> {
    if post.kind == "custom_calls" {
        return Some("is calling".into());
    }
    if !post.kind.is_empty() && post.kind != WITH_ATTACHMENTS {
        return None;
    }
    let said = words(post);
    if !said.is_empty() {
        return Some(said);
    }
    let file = post.metadata.files.first()?;
    Some(if file.mime_type.starts_with("image/") {
        "sent a picture".into()
    } else {
        "sent a file".into()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn post(fields: &Value) -> Post {
        let mut post = json!({ "id": "p", "channel_id": "c", "user_id": "u" });
        if let (Some(post), Some(fields)) = (post.as_object_mut(), fields.as_object()) {
            post.extend(fields.clone());
        }
        serde_json::from_value(post).expect("a post")
    }

    #[test]
    fn a_webhook_alert_says_what_its_attachments_say_under_the_hook_name() {
        let alert = post(&json!({
            "type": "slack_attachment",
            "props": {
                "from_webhook": "true",
                "override_username": "Alertmanager",
                "attachments": [{
                    "title": "[FIRING:1] KubePodCrashLooping",
                    "text": "Pod api-7f9 is restarting",
                    "fields": [{ "title": "cluster", "value": "prod-eu" }]
                }]
            }
        }));
        let said = describe(&alert).expect("kept");
        assert!(said.contains("KubePodCrashLooping"), "{said}");
        assert!(said.contains("Pod api-7f9 is restarting"), "{said}");
        assert!(said.contains("**cluster**: prod-eu"), "{said}");
        assert_eq!(webhook_name(&alert).as_deref(), Some("Alertmanager"));
    }

    #[test]
    fn a_message_with_attachments_says_both_and_the_server_saying_things_says_nothing() {
        let both = post(&json!({
            "type": "slack_attachment",
            "message": "deploy finished",
            "props": { "attachments": [{ "text": "all green" }] }
        }));
        assert_eq!(
            describe(&both).as_deref(),
            Some("deploy finished\n\nall green")
        );
        assert_eq!(webhook_name(&both), None, "not from a webhook");
        let joined = post(&json!({ "type": "system_join_channel", "message": "anna joined" }));
        assert_eq!(describe(&joined), None);
        let plain = post(&json!({ "message": "hi", "props": { "from_webhook": "true" } }));
        assert_eq!(
            webhook_name(&plain),
            None,
            "a webhook without a name of its own"
        );
    }
}
