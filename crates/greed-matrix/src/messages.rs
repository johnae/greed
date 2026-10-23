//! Every message this device sees, for the client to keep for searching:
//! told as `messages` as they come, in any room and edits too, deletions as
//! `unsaid`, and a room's older ones by `history`, a page at a time.
//! Encrypted ones come once they're decrypted here.

use greed_chat::protocol::{History, HistoryParams, RoomParams, Said};
use greed_chat::rpc::Failure;
use matrix_sdk::room::MessagesOptions;
use matrix_sdk::ruma::events::room::message::{OriginalSyncRoomMessageEvent, Relation};
use matrix_sdk::ruma::events::room::redaction::OriginalSyncRoomRedactionEvent;
use matrix_sdk::ruma::events::{
    AnySyncMessageLikeEvent, AnySyncTimelineEvent, SyncMessageLikeEvent,
};
use matrix_sdk::ruma::{UInt, UserId};
use matrix_sdk::{Client, Room};
use serde_json::json;
use tokio::sync::mpsc;

use crate::Matrix;
use crate::alerts::describe;
use crate::rooms::{name_of, person};

/// The most messages a page of `history` holds.
const PAGE: u32 = 100;

/// What the handlers hear, handed to this thread.
enum Heard {
    Said(Box<OriginalSyncRoomMessageEvent>, Room),
    Unsaid(String, String),
}

impl Matrix {
    /// Tells of every message account `id` sees from now on, and of those
    /// deleted.
    pub(crate) fn hear_messages(&self, id: &str, client: &Client) {
        // The handlers run where matrix-sdk calls them; they hand what
        // they hear over to this thread.
        let (tell, mut told) = mpsc::unbounded_channel();
        let said = tell.clone();
        client.add_event_handler(move |event: OriginalSyncRoomMessageEvent, room: Room| {
            let said = said.clone();
            async move {
                let _ = said.send(Heard::Said(Box::new(event), room));
            }
        });
        client.add_event_handler(move |event: OriginalSyncRoomRedactionEvent, room: Room| {
            let tell = tell.clone();
            async move {
                if let Some(gone) = event.redacts.or(event.content.redacts) {
                    let _ = tell.send(Heard::Unsaid(room.room_id().to_string(), gone.to_string()));
                }
            }
        });
        let me = self.me.clone();
        let account = id.to_string();
        let mine = client.user_id().map(ToOwned::to_owned);
        tokio::task::spawn_local(async move {
            while let Some(heard) = told.recv().await {
                let Some(this) = me.upgrade() else { break };
                match heard {
                    Heard::Said(event, room) => {
                        let said = said_of(&event, &room, mine.as_deref()).await;
                        this.notifier.notify(
                            "messages",
                            &json!({ "account": account, "messages": [said] }),
                        );
                    }
                    Heard::Unsaid(room, event) => this.notifier.notify(
                        "unsaid",
                        &json!({ "account": account, "room": room, "event": event }),
                    ),
                }
            }
        });
    }

    /// A room's messages older than `params.before`, newest first, and the
    /// mark for those before them.
    pub(crate) async fn history(&self, params: &HistoryParams) -> Result<History, Failure> {
        let room = self.room(&RoomParams {
            account: params.account.clone(),
            room: params.room.clone(),
            thread: None,
            on: false,
        })?;
        let mut options = MessagesOptions::backward();
        options.from.clone_from(&params.before);
        options.limit = UInt::from(params.limit.unwrap_or(PAGE).min(PAGE));
        let page = room
            .messages(options)
            .await
            .map_err(|e| Failure::new(format!("can't fetch older messages: {e}")))?;
        let mine = room.client().user_id().map(ToOwned::to_owned);
        let mut messages = Vec::new();
        for event in &page.chunk {
            let Ok(AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::RoomMessage(
                SyncMessageLikeEvent::Original(message),
            ))) = event.raw().deserialize()
            else {
                continue;
            };
            messages.push(said_of(&message, &room, mine.as_deref()).await);
        }
        // The server marks where it stopped; an empty page is the start.
        let before = if page.chunk.is_empty() {
            None
        } else {
            page.end
        };
        Ok(History { messages, before })
    }
}

/// `message` in `room` as it's kept: an edit under the message it changes.
async fn said_of(
    message: &OriginalSyncRoomMessageEvent,
    room: &Room,
    mine: Option<&UserId>,
) -> Said {
    let (event, text) = match &message.content.relates_to {
        Some(Relation::Replacement(edit)) => (
            edit.event_id.to_string(),
            describe(&edit.new_content.msgtype),
        ),
        _ => (
            message.event_id.to_string(),
            describe(&message.content.msgtype),
        ),
    };
    let thread = match &message.content.relates_to {
        Some(Relation::Thread(thread)) => Some(thread.event_id.to_string()),
        _ => None,
    };
    Said {
        room: room.room_id().to_string(),
        room_name: name_of(room).await,
        event,
        sender: person(room, &message.sender).await,
        at: i64::from(message.origin_server_ts.0),
        text,
        thread,
        mine: mine == Some(message.sender.as_ref()),
        direct: room.is_direct().await.unwrap_or(false),
    }
}
