//! New messages for you, as your push rules on the server pick them
//! (mentions, direct messages, keywords), told as `alert`.

use greed_chat::protocol::Alert;
use matrix_sdk::deserialized_responses::RawAnySyncOrStrippedTimelineEvent;
use matrix_sdk::ruma::events::room::message::{MessageType, Relation};
use matrix_sdk::ruma::events::{
    AnySyncMessageLikeEvent, AnySyncTimelineEvent, SyncMessageLikeEvent,
};
use matrix_sdk::ruma::push::Action;
use matrix_sdk::ruma::{MilliSecondsSinceUnixEpoch, OwnedUserId};
use matrix_sdk::sync::Notification;
use matrix_sdk::{Client, Room};
use serde_json::json;
use tokio::sync::mpsc;

use crate::Matrix;
use crate::rooms::{name_of, person};

impl Matrix {
    /// Tells of new messages for account `id` from now on: not those that
    /// came while it was away, which its rooms' counts show.
    pub(crate) async fn hear_alerts(&self, id: &str, client: &Client) {
        let Some(mine) = client.user_id().map(ToOwned::to_owned) else {
            return;
        };
        let since = MilliSecondsSinceUnixEpoch::now();
        // The handler runs where matrix-sdk calls it; it hands what it
        // hears over to this thread.
        let (tell, mut told) = mpsc::unbounded_channel();
        client
            .register_notification_handler(move |notification: Notification, room: Room, _| {
                let tell = tell.clone();
                async move {
                    let _ = tell.send((notification, room));
                }
            })
            .await;
        let me = self.me.clone();
        let account = id.to_string();
        tokio::task::spawn_local(async move {
            while let Some((notification, room)) = told.recv().await {
                let Some(alert) = alert(&account, &mine, since, &notification, &room).await else {
                    continue;
                };
                let Some(this) = me.upgrade() else { break };
                this.notifier.notify("alert", &json!(alert));
            }
        });
    }
}

/// The alert for `notification` in `room`, if it's a new message from
/// someone else.
async fn alert(
    account: &str,
    mine: &OwnedUserId,
    since: MilliSecondsSinceUnixEpoch,
    notification: &Notification,
    room: &Room,
) -> Option<Alert> {
    let RawAnySyncOrStrippedTimelineEvent::Sync(raw) = &notification.event else {
        return None;
    };
    let AnySyncTimelineEvent::MessageLike(event) = raw.deserialize().ok()? else {
        return None;
    };
    let sender = event.sender();
    if sender == mine || event.origin_server_ts() < since {
        return None;
    }
    let body =
        match &event {
            AnySyncMessageLikeEvent::RoomMessage(SyncMessageLikeEvent::Original(message)) => {
                // An edit isn't news.
                if matches!(message.content.relates_to, Some(Relation::Replacement(_))) {
                    return None;
                }
                describe(&message.content.msgtype)
            }
            AnySyncMessageLikeEvent::RoomEncrypted(_) => "sent an encrypted message".into(),
            AnySyncMessageLikeEvent::Sticker(_) => "sent a sticker".into(),
            AnySyncMessageLikeEvent::PollStart(_)
            | AnySyncMessageLikeEvent::UnstablePollStart(_) => "started a poll".into(),
            AnySyncMessageLikeEvent::CallInvite(_)
            | AnySyncMessageLikeEvent::RtcNotification(_) => "is calling".into(),
            _ => return None,
        };
    let direct = room.is_direct().await.unwrap_or(false);
    Some(Alert {
        account: account.to_string(),
        room: room.room_id().to_string(),
        room_name: name_of(room).await,
        event: event.event_id().to_string(),
        sender: person(room, sender).await,
        body,
        mention: !direct && notification.actions.iter().any(Action::is_highlight),
        direct,
    })
}

/// A message's text, or what it is when it's a file.
pub(crate) fn describe(message: &MessageType) -> String {
    match message {
        MessageType::Image(_) => "sent a picture".into(),
        MessageType::Video(_) => "sent a video".into(),
        MessageType::Audio(_) => "sent a recording".into(),
        MessageType::File(_) => "sent a file".into(),
        MessageType::Location(_) => "shared a location".into(),
        other => other.body().to_string(),
    }
}
