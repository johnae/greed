//! Keeping an account synced, and its rooms as the client lists them.

use std::sync::Arc;
use std::time::Duration;

use greed_chat::protocol::{
    AccountState, DirectoryParams, Listed, Person, Room, RoomKind, RoomParams,
};
use greed_chat::rpc::Failure;
use greed_chat::why;
use matrix_sdk::ruma::UserId;
use matrix_sdk::ruma::api::client::directory::get_public_rooms_filtered;
use matrix_sdk::ruma::directory::Filter;
use matrix_sdk::ruma::{RoomId, RoomOrAliasId, UInt};
use matrix_sdk::{Client, RoomState};
use matrix_sdk_ui::sync_service::{State, SyncService};
use serde_json::{Value, json};
use tokio::sync::broadcast::error::RecvError;

use crate::Matrix;

/// How long changes to rooms gather before the client hears of them: a
/// sync brings many at once.
const GATHER: Duration = Duration::from_millis(100);

/// The most rooms `directory` lists.
const LISTED: u32 = 50;

impl Matrix {
    /// Starts syncing `client` (account `id`), saying how that goes as
    /// `account.changed` and when its rooms change as `rooms.changed`.
    pub(crate) async fn sync(&self, id: &str, client: &Client) -> Option<Arc<SyncService>> {
        let sync = match SyncService::builder(client.clone()).build().await {
            Ok(sync) => Arc::new(sync),
            Err(e) => {
                self.changed(
                    id,
                    AccountState::Trouble(format!("can't sync: {}", why(&e))),
                );
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
                    State::Error(e) => AccountState::Trouble(why(&e)),
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

    /// Joins a room by its id or address (`#garden:example.org`), or the
    /// one you're asked to: `{room}`, its id.
    pub(crate) async fn join(&self, params: &RoomParams) -> Result<Value, Failure> {
        let client = self.client_of(&params.account)?;
        let target = RoomOrAliasId::parse(params.room.trim())
            .map_err(|_| Failure::new(format!("{} isn't a room's id or address", params.room)))?;
        let room = client
            .join_room_by_id_or_alias(&target, &[])
            .await
            .map_err(|e| Failure::new(format!("can't join it: {}", why(&e))))?;
        Ok(json!({ "room": room.room_id() }))
    }

    /// Leaves a room, or says no to being asked to one.
    pub(crate) async fn leave(&self, params: &RoomParams) -> Result<(), Failure> {
        let client = self.client_of(&params.account)?;
        let room = RoomId::parse(&params.room)
            .ok()
            .and_then(|id| client.get_room(&id))
            .ok_or_else(|| Failure::new(format!("not in {}", params.room)))?;
        room.leave()
            .await
            .map_err(|e| Failure::new(format!("can't leave it: {}", why(&e))))
    }

    /// The rooms the server lists publicly whose names or topics have
    /// `params.query`, but those you're in.
    pub(crate) async fn directory(&self, params: &DirectoryParams) -> Result<Vec<Listed>, Failure> {
        let client = self.client_of(&params.account)?;
        let mut filter = Filter::new();
        filter.generic_search_term =
            Some(params.query.trim().to_string()).filter(|query| !query.is_empty());
        let mut request = get_public_rooms_filtered::v3::Request::new();
        request.filter = filter;
        request.limit = Some(UInt::from(LISTED));
        let listed = client
            .public_rooms_filtered(request)
            .await
            .map_err(|e| Failure::new(format!("can't list the server's rooms: {}", why(&e))))?;
        Ok(listed
            .chunk
            .into_iter()
            .filter(|room| {
                client
                    .get_room(&room.room_id)
                    .is_none_or(|known| known.state() != RoomState::Joined)
            })
            .map(|room| {
                let address = room.canonical_alias.map(|alias| alias.to_string());
                Listed {
                    id: room.room_id.to_string(),
                    name: room
                        .name
                        .or_else(|| address.clone())
                        .unwrap_or_else(|| room.room_id.to_string()),
                    topic: room.topic,
                    members: Some(u64::from(room.num_joined_members)),
                    address,
                }
            })
            .collect())
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
