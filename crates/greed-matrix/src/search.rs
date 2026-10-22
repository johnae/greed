//! Searching messages: in this device's own index of what it has seen,
//! which takes in encrypted rooms too, and on the server, which reaches
//! further back in rooms that aren't encrypted.

use std::collections::HashSet;

use futures_util::StreamExt;
use greed_chat::protocol::{Found, Item, SearchParams};
use greed_chat::rpc::Failure;
use matrix_sdk::ruma::api::client::search::search_events::v3::{
    Categories, Criteria, OrderBy, Request,
};
use matrix_sdk::ruma::events::room::message::Relation;
use matrix_sdk::ruma::events::{
    AnySyncMessageLikeEvent, AnySyncTimelineEvent, AnyTimelineEvent, SyncMessageLikeEvent,
};
use matrix_sdk::ruma::serde::Raw;
use matrix_sdk::ruma::{OwnedRoomId, UserId};
use matrix_sdk::{Client, Room};

use crate::Matrix;
use crate::rooms::{name_of, person};
use crate::timeline::kind_of;

/// The most messages a search gives.
const MOST: usize = 50;

impl Matrix {
    /// The messages `params.query` finds, newest first.
    pub(crate) async fn search(&self, params: &SearchParams) -> Result<Vec<Found>, Failure> {
        let client = self.client_of(&params.account)?;
        let me = client
            .user_id()
            .ok_or_else(|| Failure::new("not signed in"))?
            .to_owned();
        let only = match &params.room {
            Some(room) => {
                let id = OwnedRoomId::try_from(room.as_str())
                    .map_err(|_| Failure::new(format!("{room} isn't a room")))?;
                Some(
                    client
                        .get_room(&id)
                        .ok_or_else(|| Failure::new(format!("not in {id}")))?,
                )
            }
            None => None,
        };
        let rooms = match &only {
            Some(room) => vec![room.clone()],
            None => client.joined_rooms(),
        };
        for room in &rooms {
            index_decrypted(&client, room).await;
        }
        // What this device has seen, its first page.
        let query = params.query.clone();
        let mut events: Vec<(Room, Raw<AnySyncTimelineEvent>)> = if let Some(room) = &only {
            let page = Box::pin(room.search_messages_events(query)).next().await;
            page.and_then(Result::ok)
                .unwrap_or_default()
                .into_iter()
                .map(|event| (room.clone(), event.raw().clone()))
                .collect()
        } else {
            let page = Box::pin(client.search_messages(query).build_events())
                .next()
                .await;
            page.and_then(Result::ok)
                .unwrap_or_default()
                .into_iter()
                .filter_map(|(id, event)| Some((client.get_room(&id)?, event.raw().clone())))
                .collect()
        };

        // What the server finds; a server without search finds nothing.
        let mut criteria = Criteria::new(params.query.clone());
        criteria.order_by = Some(OrderBy::Recent);
        criteria.filter.rooms = only.map(|room| vec![room.room_id().to_owned()]);
        let mut categories = Categories::new();
        categories.room_events = Some(criteria);
        if let Ok(response) = client.send(Request::new(categories)).await {
            for raw in response
                .search_categories
                .room_events
                .results
                .into_iter()
                .filter_map(|result| result.result)
            {
                let Ok(event) = raw.deserialize() else {
                    continue;
                };
                if let Some(room) = client.get_room(event.room_id()) {
                    events.push((
                        room,
                        raw.cast_unchecked::<AnyTimelineEvent>().cast_unchecked(),
                    ));
                }
            }
        }

        let mut seen = HashSet::new();
        let mut found = Vec::new();
        for (room, raw) in events {
            let Some(item) = message(&room, &raw, &me).await else {
                continue;
            };
            if seen.insert(item.event.clone()) {
                found.push(Found {
                    room: room.room_id().to_string(),
                    room_name: name_of(&room).await,
                    item,
                });
            }
        }
        found.sort_by_key(|found| std::cmp::Reverse(found.item.at));
        found.truncate(MOST);
        Ok(found)
    }
}

/// `raw` in `room` as an item, if it's a message (and not a change to one).
async fn message(room: &Room, raw: &Raw<AnySyncTimelineEvent>, me: &UserId) -> Option<Item> {
    let AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::RoomMessage(
        SyncMessageLikeEvent::Original(event),
    )) = raw.deserialize().ok()?
    else {
        return None;
    };
    if matches!(event.content.relates_to, Some(Relation::Replacement(_))) {
        return None;
    }
    Some(Item {
        id: event.event_id.to_string(),
        event: Some(event.event_id.to_string()),
        sender: person(room, &event.sender).await,
        at: i64::from(event.origin_server_ts.0),
        kind: kind_of(&event.content.msgtype),
        text: event.content.body().to_string(),
        mine: event.sender == me,
        link: Some(format!(
            "https://matrix.to/#/{}/{}",
            room.room_id(),
            event.event_id
        )),
        media: crate::media::media_of(&event.content.msgtype),
        ..Item::default()
    })
}

/// Hands the messages of `room` that were decrypted after they came to
/// the index again. matrix-sdk 0.19 reads a message back from its cache
/// when it's decrypted late, and may read the still encrypted one, leaving
/// it out; what's indexed already is left as it is.
async fn index_decrypted(client: &Client, room: &Room) {
    let Ok((cache, _handles)) = client.event_cache().room(room.room_id()).await else {
        return;
    };
    let Ok(events) = cache.events().await else {
        return;
    };
    let decrypted: Vec<_> = events
        .into_iter()
        .filter(|event| !event.kind.is_utd() && event.encryption_info().is_some())
        .collect();
    if decrypted.is_empty() {
        return;
    }
    let rules = room.clone_info().room_version_rules_or_default().redaction;
    let mut index = client.search_index().lock().await;
    let _ = index
        .bulk_handle_timeline_event(decrypted.into_iter(), &cache, room.room_id(), &rules)
        .await;
}
