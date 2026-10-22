//! Keeping an account synced, and its rooms as the client lists them.

use std::sync::Arc;
use std::time::Duration;

use greed_chat::protocol::{AccountState, Person, Room, RoomKind};
use matrix_sdk::ruma::UserId;
use matrix_sdk::{Client, RoomState};
use matrix_sdk_ui::sync_service::{State, SyncService};
use serde_json::json;
use tokio::sync::broadcast::error::RecvError;

use crate::Matrix;

/// How long changes to rooms gather before the client hears of them: a
/// sync brings many at once.
const GATHER: Duration = Duration::from_millis(100);

impl Matrix {
    /// Starts syncing `client` (account `id`), saying how that goes as
    /// `account.changed` and when its rooms change as `rooms.changed`.
    pub(crate) async fn sync(&self, id: &str, client: &Client) -> Option<Arc<SyncService>> {
        let sync = match SyncService::builder(client.clone()).build().await {
            Ok(sync) => Arc::new(sync),
            Err(e) => {
                self.changed(id, AccountState::Trouble(format!("can't sync: {e}")));
                return None;
            }
        };
        let mut states = sync.state();
        let me = self.me.clone();
        let account = id.to_string();
        tokio::task::spawn_local(async move {
            while let Some(state) = states.next().await {
                let Some(me) = me.upgrade() else { break };
                let state = match state {
                    State::Running => AccountState::Ready,
                    State::Idle | State::Terminated => AccountState::Syncing,
                    State::Error(e) => AccountState::Trouble(e.to_string()),
                    State::Offline => AccountState::Trouble("can't reach the server".into()),
                };
                me.changed(&account, state);
            }
        });
        self.watch_rooms(id, client);
        sync.start().await;
        Some(sync)
    }

    /// Says `rooms.changed` for account `id` when any of its rooms change,
    /// once a burst of changes is over.
    fn watch_rooms(&self, id: &str, client: &Client) {
        let mut notable = client.room_info_notable_update_receiver();
        let mut updates = client.subscribe_to_all_room_updates();
        let me = self.me.clone();
        let account = id.to_string();
        tokio::task::spawn_local(async move {
            loop {
                let closed = tokio::select! {
                    got = notable.recv() => matches!(got, Err(RecvError::Closed)),
                    got = updates.recv() => matches!(got, Err(RecvError::Closed)),
                };
                if closed {
                    break;
                }
                tokio::time::sleep(GATHER).await;
                notable = notable.resubscribe();
                updates = updates.resubscribe();
                let Some(me) = me.upgrade() else { break };
                me.notifier
                    .notify("rooms.changed", &json!({ "account": account }));
            }
        });
    }

    /// The rooms of account `id`, invites included.
    pub(crate) async fn rooms(&self, id: &str) -> Option<Vec<Room>> {
        let client = self.accounts.borrow().get(id)?.client.clone();
        let mut rooms = Vec::new();
        for room in client.rooms() {
            let kind = match room.state() {
                RoomState::Joined => joined_kind(&room).await,
                RoomState::Invited => RoomKind::Invite,
                _ => continue,
            };
            rooms.push(room_of(id, &room, kind).await);
        }
        Some(rooms)
    }
}

/// What a joined room is: a space, a direct message or a room.
async fn joined_kind(room: &matrix_sdk::Room) -> RoomKind {
    if room.is_space() {
        RoomKind::Space
    } else if room.is_direct().await.unwrap_or(false) {
        if room.direct_targets_length() > 1 {
            RoomKind::Group
        } else {
            RoomKind::Direct
        }
    } else {
        RoomKind::Room
    }
}

/// `room`'s name, as the list shows it.
pub(crate) async fn name_of(room: &matrix_sdk::Room) -> String {
    match room.display_name().await {
        Ok(name) => name.to_string(),
        Err(_) => room.room_id().to_string(),
    }
}

/// `user` as `room` knows them: their name there, or their id's local part.
pub(crate) async fn person(room: &matrix_sdk::Room, user: &UserId) -> Person {
    let name = match room.get_member_no_sync(user).await {
        Ok(Some(member)) => member.display_name().map(str::to_string),
        _ => None,
    };
    Person {
        id: user.to_string(),
        name: name.unwrap_or_else(|| user.localpart().to_string()),
        avatar: None,
    }
}

async fn room_of(account: &str, room: &matrix_sdk::Room, kind: RoomKind) -> Room {
    let name = name_of(room).await;
    Room {
        id: room.room_id().to_string(),
        account: account.to_string(),
        name,
        kind,
        topic: room.topic(),
        parent: None,
        unread: room.num_unread_messages(),
        mentions: room.num_unread_mentions(),
        favourite: room.is_favourite(),
        muted: matches!(
            room.cached_user_defined_notification_mode(),
            Some(matrix_sdk::notification_settings::RoomNotificationMode::Mute)
        ),
        encrypted: room.encryption_state().is_encrypted(),
        active: room.latest_event_timestamp().map(|at| i64::from(at.0)),
        // Presence isn't in what the sync brings.
        presence: None,
    }
}
