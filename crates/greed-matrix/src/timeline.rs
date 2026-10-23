//! Rooms' timelines as the client shows them, kept open and up to date
//! while it does, and sending to them.

use std::sync::Arc;

use futures_util::StreamExt;
use greed_chat::protocol::{
    Change, Item, ItemKind, Location, MessageParams, Person, Poll, PollAnswer, Reaction,
    RoomParams, SendParams, Sending, VoteParams,
};
use greed_chat::rpc::Failure;
use matrix_sdk::event_handler::EventHandlerDropGuard;
use matrix_sdk::room::edit::EditedContent;
use matrix_sdk::ruma::api::client::receipt::create_receipt::v3::ReceiptType;
use matrix_sdk::ruma::events::poll::unstable_response::UnstablePollResponseEventContent;
use matrix_sdk::ruma::events::room::message::{MessageType, RoomMessageEventContent};
use matrix_sdk::ruma::{EventId, OwnedUserId, RoomId, UserId};
use matrix_sdk_ui::Timeline;
use matrix_sdk_ui::eyeball_im::VectorDiff;
use matrix_sdk_ui::timeline::{
    EventSendState, EventTimelineItem, MembershipChange, MsgLikeKind, PollResult, TimelineBuilder,
    TimelineDetails, TimelineEventItemId, TimelineFocus, TimelineItem, TimelineItemContent,
    TimelineItemKind, TimelineReadReceiptTracking, VirtualTimelineItem, default_event_filter,
};
use serde_json::{Value, json};
use tokio::sync::broadcast::error::RecvError;
use tokio::task::AbortHandle;

use crate::Matrix;

/// How many older events `timeline.back` asks the server for.
const PAGE: u16 = 50;

/// How a room is set up, which Matrix clients don't show among its
/// messages.
const HIDDEN: &[&str] = &[
    "m.room.create",
    "m.room.power_levels",
    "m.room.join_rules",
    "m.room.history_visibility",
    "m.room.guest_access",
    "m.room.server_acl",
    "m.room.canonical_alias",
];

/// A timeline the client has open, and the tasks telling it what changes:
/// the items, and who's writing (for a room's).
pub(crate) struct Open {
    timeline: Arc<Timeline>,
    forwarding: AbortHandle,
    typing: Option<(AbortHandle, EventHandlerDropGuard)>,
}

impl Drop for Open {
    fn drop(&mut self) {
        self.forwarding.abort();
        if let Some((typing, _)) = &self.typing {
            typing.abort();
        }
    }
}

fn key(params: &RoomParams) -> String {
    format!(
        "{} {} {}",
        params.account,
        params.room,
        params.thread.as_deref().unwrap_or("")
    )
}

impl Matrix {
    /// The room `params` names.
    pub(crate) fn room(&self, params: &RoomParams) -> Result<matrix_sdk::Room, Failure> {
        let client = self.client_of(&params.account)?;
        let id = RoomId::parse(&params.room).map_err(Failure::params)?;
        client
            .get_room(&id)
            .ok_or_else(|| Failure::new(format!("{} has no room {}", params.account, params.room)))
    }

    /// The timeline `params` names, opened if it isn't: a room's, its
    /// threads' replies left to theirs, or a thread's.
    pub(crate) async fn timeline(&self, params: &RoomParams) -> Result<Arc<Timeline>, Failure> {
        if let Some(open) = self.timelines.borrow().get(&key(params)) {
            return Ok(open.timeline.clone());
        }
        let room = self.room(params)?;
        let focus = match &params.thread {
            Some(thread) => TimelineFocus::Thread {
                root_event_id: EventId::parse(thread).map_err(Failure::params)?,
            },
            None => TimelineFocus::Live {
                hide_threaded_events: true,
            },
        };
        let timeline = TimelineBuilder::new(&room)
            .with_focus(focus)
            .track_read_marker_and_receipts(TimelineReadReceiptTracking::MessageLikeEvents)
            .event_filter(|event, rules| {
                default_event_filter(event, rules)
                    && !HIDDEN.contains(&event.event_type().to_string().as_str())
            })
            .build()
            .await
            .map_err(|e| Failure::new(format!("can't open the room: {e}")))?;
        let timeline = Arc::new(timeline);
        // A room comes from the sync with its latest event only: some
        // history first, before what changes is followed, so the first
        // answer has it.
        timeline
            .paginate_backwards(PAGE)
            .await
            .map_err(|e| Failure::new(format!("can't fetch the room's messages: {e}")))?;
        let me = self.me.clone();
        let (account, room_id, thread) = (
            params.account.clone(),
            params.room.clone(),
            params.thread.clone(),
        );
        let here = Here::new(&timeline, &params.room);
        let (items, mut diffs) = timeline.subscribe().await;
        let mut len = items.len();
        let forwarding = tokio::task::spawn_local(async move {
            while let Some(batch) = diffs.next().await {
                let changes = changes(&mut len, batch, &here);
                let Some(me) = me.upgrade() else { break };
                let params = json!({
                    "account": account,
                    "room": room_id,
                    "thread": thread,
                    "changes": changes,
                });
                me.notifier.notify("timeline.changed", &params);
            }
        })
        .abort_handle();
        let typing = params
            .thread
            .is_none()
            .then(|| self.follow_typing(params, &room));
        self.timelines.borrow_mut().insert(
            key(params),
            Open {
                timeline: timeline.clone(),
                forwarding,
                typing,
            },
        );
        Ok(timeline)
    }

    /// Says `typing.changed` whenever who's writing in `room` changes.
    fn follow_typing(
        &self,
        params: &RoomParams,
        room: &matrix_sdk::Room,
    ) -> (AbortHandle, EventHandlerDropGuard) {
        let (guard, mut typing) = room.subscribe_to_typing_notifications();
        let me = self.me.clone();
        let (account, room_id) = (params.account.clone(), params.room.clone());
        let room = room.clone();
        let task = tokio::task::spawn_local(async move {
            loop {
                let who = match typing.recv().await {
                    Ok(who) => who,
                    Err(RecvError::Lagged(_)) => continue,
                    Err(RecvError::Closed) => break,
                };
                let mut names = Vec::new();
                for user in who
                    .iter()
                    .filter(|user| Some(user.as_ref()) != room.client().user_id())
                {
                    let name = match room.get_member_no_sync(user).await {
                        Ok(Some(member)) => member.name().to_string(),
                        _ => user.localpart().to_string(),
                    };
                    names.push(name);
                }
                let Some(me) = me.upgrade() else { break };
                let params = json!({ "account": account, "room": room_id, "who": names });
                me.notifier.notify("typing.changed", &params);
            }
        })
        .abort_handle();
        (task, guard)
    }

    /// Opens a room's timeline: `{items}`, then `timeline.changed`.
    pub(crate) async fn open_timeline(&self, params: &RoomParams) -> Result<Value, Failure> {
        let timeline = self.timeline(params).await?;
        let here = Here::new(&timeline, &params.room);
        let items: Vec<Item> = timeline
            .items()
            .await
            .iter()
            .map(|it| item(it, &here))
            .collect();
        Ok(json!({ "items": items }))
    }

    /// Stops keeping a room's timeline.
    pub(crate) fn close_timeline(&self, params: &RoomParams) {
        self.timelines.borrow_mut().remove(&key(params));
    }

    /// Fetches older items into an open timeline: `{more}`, whether there
    /// are older ones still.
    pub(crate) async fn back(&self, params: &RoomParams) -> Result<Value, Failure> {
        let timeline = self.timeline(params).await?;
        let start = timeline
            .paginate_backwards(PAGE)
            .await
            .map_err(|e| Failure::new(format!("can't fetch older messages: {e}")))?;
        Ok(json!({ "more": !start }))
    }

    /// Sends a message, which shows in the timeline at once and changes
    /// there as it's sent. In a thread, it's one of the thread's replies.
    pub(crate) async fn send(&self, send: &SendParams) -> Result<(), Failure> {
        let params = RoomParams {
            account: send.account.clone(),
            room: send.room.clone(),
            thread: send.thread.clone(),
            on: false,
        };
        let timeline = self.timeline(&params).await?;
        let content = RoomMessageEventContent::text_markdown(&send.text);
        let outcome = match &send.reply_to {
            Some(event) => {
                let event = EventId::parse(event).map_err(Failure::params)?;
                timeline.send_reply(content.into(), event).await
            }
            None => timeline.send(content.into()).await,
        };
        outcome
            .map(drop)
            .map_err(|e| Failure::new(format!("can't send: {e}")))
    }

    /// The room's timeline (opened if it isn't) and the message `event`
    /// as the timeline names it.
    async fn message(
        &self,
        message: &MessageParams,
    ) -> Result<(Arc<Timeline>, TimelineEventItemId), Failure> {
        let params = RoomParams {
            account: message.account.clone(),
            room: message.room.clone(),
            thread: None,
            on: false,
        };
        let timeline = self.timeline(&params).await?;
        let event = EventId::parse(&message.event).map_err(Failure::params)?;
        Ok((timeline, TimelineEventItemId::EventId(event)))
    }

    /// Changes what one of your messages says.
    pub(crate) async fn edit(&self, message: &MessageParams) -> Result<(), Failure> {
        let (timeline, id) = self.message(message).await?;
        let content = RoomMessageEventContent::text_markdown(&message.text);
        timeline
            .edit(&id, EditedContent::RoomMessage(content.into()))
            .await
            .map_err(|e| Failure::new(format!("can't change it: {e}")))
    }

    /// Deletes a message (yours, or anyone's where you may).
    pub(crate) async fn redact(&self, message: &MessageParams) -> Result<(), Failure> {
        let (timeline, id) = self.message(message).await?;
        timeline
            .redact(&id, None)
            .await
            .map_err(|e| Failure::new(format!("can't delete it: {e}")))
    }

    /// Adds your reaction `key` to a message, or takes it back.
    pub(crate) async fn react(&self, message: &MessageParams) -> Result<(), Failure> {
        let (timeline, id) = self.message(message).await?;
        timeline
            .toggle_reaction(&id, &message.key)
            .await
            .map(drop)
            .map_err(|e| Failure::new(format!("can't react: {e}")))
    }

    /// Votes in a poll for the answers picked, by their ids.
    pub(crate) async fn vote(&self, vote: &VoteParams) -> Result<(), Failure> {
        let params = RoomParams {
            account: vote.account.clone(),
            room: vote.room.clone(),
            thread: None,
            on: false,
        };
        let timeline = self.timeline(&params).await?;
        let poll = EventId::parse(&vote.event).map_err(Failure::params)?;
        let content = UnstablePollResponseEventContent::new(vote.answers.clone(), poll);
        timeline
            .send(content.into())
            .await
            .map(drop)
            .map_err(|e| Failure::new(format!("can't vote: {e}")))
    }

    /// Marks the room read up to its latest message.
    pub(crate) async fn read(&self, params: &RoomParams) -> Result<(), Failure> {
        let timeline = self.timeline(params).await?;
        timeline
            .mark_as_read(ReceiptType::Read)
            .await
            .map(drop)
            .map_err(|e| Failure::new(format!("can't mark it read: {e}")))
    }

    /// Says you're writing in the room, or not any more.
    pub(crate) async fn typing(&self, params: &RoomParams) -> Result<(), Failure> {
        self.room(params)?
            .typing_notice(params.on)
            .await
            .map_err(|e| Failure::new(format!("can't say you're writing: {e}")))
    }
}

/// Where a timeline's items are: who's signed in (whose reactions are
/// "mine") and the room.
struct Here {
    me: OwnedUserId,
    room: String,
}

impl Here {
    fn new(timeline: &Timeline, room: &str) -> Self {
        Here {
            me: timeline.room().own_user_id().to_owned(),
            room: room.to_string(),
        }
    }
}

/// A batch of the timeline's diffs as the protocol's changes, keeping
/// `len` the number of items the client has.
fn changes(len: &mut usize, batch: Vec<VectorDiff<Arc<TimelineItem>>>, here: &Here) -> Vec<Change> {
    let mut changes = Vec::new();
    for diff in batch {
        match diff {
            VectorDiff::Append { values } => {
                for value in values {
                    changes.push(Change::Insert {
                        at: *len,
                        item: item(&value, here),
                    });
                    *len += 1;
                }
            }
            VectorDiff::Clear => {
                changes.push(Change::Clear);
                *len = 0;
            }
            VectorDiff::PushFront { value } => {
                changes.push(Change::Insert {
                    at: 0,
                    item: item(&value, here),
                });
                *len += 1;
            }
            VectorDiff::PushBack { value } => {
                changes.push(Change::Insert {
                    at: *len,
                    item: item(&value, here),
                });
                *len += 1;
            }
            VectorDiff::PopFront => {
                changes.push(Change::Remove { at: 0 });
                *len -= 1;
            }
            VectorDiff::PopBack => {
                *len -= 1;
                changes.push(Change::Remove { at: *len });
            }
            VectorDiff::Insert { index, value } => {
                changes.push(Change::Insert {
                    at: index,
                    item: item(&value, here),
                });
                *len += 1;
            }
            VectorDiff::Set { index, value } => changes.push(Change::Set {
                at: index,
                item: item(&value, here),
            }),
            VectorDiff::Remove { index } => {
                changes.push(Change::Remove { at: index });
                *len -= 1;
            }
            VectorDiff::Truncate { length } => {
                changes.push(Change::Truncate { len: length });
                *len = length;
            }
            VectorDiff::Reset { values } => {
                *len = values.len();
                changes.push(Change::Reset {
                    items: values.iter().map(|value| item(value, here)).collect(),
                });
            }
        }
    }
    changes
}

/// A timeline item as the client shows it, `here`.
fn item(it: &TimelineItem, here: &Here) -> Item {
    let id = it.unique_id().0.clone();
    match it.kind() {
        TimelineItemKind::Virtual(virtual_item) => {
            let (kind, at) = match virtual_item {
                VirtualTimelineItem::DateDivider(at) => (ItemKind::Day, i64::from(at.0)),
                VirtualTimelineItem::ReadMarker => (ItemKind::ReadMarker, 0),
                VirtualTimelineItem::TimelineStart => (ItemKind::Start, 0),
            };
            Item {
                id,
                kind,
                at,
                ..Item::default()
            }
        }
        TimelineItemKind::Event(event) => Item {
            id,
            ..event_item(event, here)
        },
    }
}

fn event_item(event: &EventTimelineItem, here: &Here) -> Item {
    let sender = event.sender();
    let (name, avatar) = match event.sender_profile() {
        TimelineDetails::Ready(profile) => (
            profile.display_name.clone(),
            profile.avatar_url.as_ref().map(ToString::to_string),
        ),
        _ => (None, None),
    };
    let mut item = Item {
        event: event.event_id().map(ToString::to_string),
        sender: Person {
            id: sender.to_string(),
            name: name.unwrap_or_else(|| sender.localpart().to_string()),
            avatar,
        },
        at: i64::from(event.timestamp().0),
        mine: event.is_own(),
        read_by: readers(event, &here.me, sender),
        link: event
            .event_id()
            .map(|id| format!("https://matrix.to/#/{}/{id}", here.room)),
        sending: sending(event),
        ..Item::default()
    };
    match event.content() {
        TimelineItemContent::MsgLike(like) => {
            item.reply_to = like.in_reply_to.as_ref().map(|r| r.event_id.to_string());
            item.thread = like.thread_root.as_ref().map(ToString::to_string);
            item.replies = like
                .thread_summary
                .as_ref()
                .map_or(0, |summary| u64::from(summary.num_replies));
            item.reactions = like
                .reactions
                .iter()
                .map(|(key, senders)| Reaction {
                    key: key.clone(),
                    count: senders.len() as u64,
                    mine: senders.contains_key(&here.me),
                })
                .collect();
            match &like.kind {
                MsgLikeKind::Message(message) => {
                    item.kind = kind_of(message.msgtype());
                    item.text = message.body().to_string();
                    item.edited = message.is_edited();
                    item.media = crate::media::media_of(message.msgtype());
                    item.location = location_of(message.msgtype());
                }
                MsgLikeKind::Sticker(sticker) => {
                    item.kind = ItemKind::Sticker;
                    item.text.clone_from(&sticker.content().body);
                }
                MsgLikeKind::Poll(poll) => {
                    let poll = poll_of(&poll.results(), &here.me);
                    item.kind = ItemKind::Poll;
                    item.text.clone_from(&poll.question);
                    item.poll = Some(poll);
                }
                MsgLikeKind::Redacted => item.kind = ItemKind::Deleted,
                MsgLikeKind::UnableToDecrypt(_) => item.kind = ItemKind::Unreadable,
                MsgLikeKind::LiveLocation(_) => item.kind = ItemKind::Location,
                MsgLikeKind::Other(_) => {}
            }
        }
        TimelineItemContent::MembershipChange(change) => {
            item.kind = ItemKind::Change;
            let who = change
                .display_name()
                .unwrap_or_else(|| change.user_id().to_string());
            let what = change
                .change()
                .map_or("changed their membership", membership);
            item.text = format!("{who} {what}");
        }
        TimelineItemContent::ProfileChange(_) => {
            item.kind = ItemKind::Change;
            item.text = format!("{} changed their profile", item.sender.name);
        }
        TimelineItemContent::OtherState(state) => {
            item.kind = ItemKind::Change;
            let what = state_change(&state.content().event_type().to_string());
            item.text = format!("{} {what}", item.sender.name);
        }
        TimelineItemContent::CallInvite | TimelineItemContent::RtcNotification { .. } => {
            item.kind = ItemKind::Call;
        }
        TimelineItemContent::FailedToParseMessageLike { .. }
        | TimelineItemContent::FailedToParseState { .. } => item.kind = ItemKind::Unreadable,
    }
    item
}

/// A change to someone's membership of a room, in words.
fn membership(change: MembershipChange) -> &'static str {
    match change {
        MembershipChange::Joined | MembershipChange::InvitationAccepted => "joined",
        MembershipChange::Left => "left",
        MembershipChange::Banned | MembershipChange::KickedAndBanned => "was banned",
        MembershipChange::Unbanned => "was let back in",
        MembershipChange::Kicked => "was removed",
        MembershipChange::Invited => "was invited",
        MembershipChange::InvitationRejected => "turned down the invite",
        MembershipChange::InvitationRevoked => "was uninvited",
        MembershipChange::Knocked => "asked to join",
        MembershipChange::KnockAccepted => "was let in",
        MembershipChange::KnockRetracted => "stopped asking to join",
        MembershipChange::KnockDenied => "wasn't let in",
        _ => "changed their membership",
    }
}

/// A change to a room's state, in words, by its event type.
fn state_change(event_type: &str) -> String {
    match event_type {
        "m.room.name" => "named the room".into(),
        "m.room.topic" => "changed the topic".into(),
        "m.room.avatar" => "changed the room's picture".into(),
        "m.room.encryption" => "turned on encryption".into(),
        "m.room.pinned_events" => "changed the pinned messages".into(),
        "m.room.tombstone" => "moved the room to a new one".into(),
        "m.space.child" | "m.space.parent" => "changed the space".into(),
        other => format!("changed {other}"),
    }
}

/// Who, besides you and whoever sent it, has read up to `event`.
fn readers(event: &EventTimelineItem, mine: &UserId, sender: &UserId) -> Vec<Person> {
    event
        .read_receipts()
        .keys()
        .filter(|user| *user != mine && *user != sender)
        .map(|user| Person {
            id: user.to_string(),
            name: user.localpart().to_string(),
            avatar: None,
        })
        .collect()
}

/// How sending `event` goes, while it's yours and not sent.
fn sending(event: &EventTimelineItem) -> Option<Sending> {
    match event.send_state() {
        Some(EventSendState::NotSentYet { .. }) => Some(Sending::Sending),
        Some(EventSendState::SendingFailed { error, .. }) => {
            Some(Sending::Failed(error.to_string()))
        }
        _ => None,
    }
}

/// What kind of item a message of type `message` is.
pub(crate) fn kind_of(message: &MessageType) -> ItemKind {
    match message {
        MessageType::Notice(_) => ItemKind::Notice,
        MessageType::Emote(_) => ItemKind::Emote,
        MessageType::Image(_) => ItemKind::Image,
        MessageType::File(_) => ItemKind::File,
        MessageType::Audio(_) => ItemKind::Audio,
        MessageType::Video(_) => ItemKind::Video,
        MessageType::Location(_) => ItemKind::Location,
        _ => ItemKind::Message,
    }
}

/// A poll as it stands, `me` being the one who asks.
fn poll_of(results: &PollResult, me: &UserId) -> Poll {
    let me = me.as_str();
    let answers = results
        .answers
        .iter()
        .map(|answer| {
            let votes = results.votes.get(&answer.id);
            PollAnswer {
                id: answer.id.clone(),
                text: answer.text.clone(),
                votes: votes.map_or(0, |votes| votes.len() as u64),
                mine: votes.is_some_and(|votes| votes.iter().any(|voter| voter == me)),
            }
        })
        .collect();
    Poll {
        question: results.question.clone(),
        answers,
        picks: results.max_selections,
        ended: results.end_time.is_some(),
    }
}

/// Where a location message points, from its `geo:` URI.
fn location_of(message: &MessageType) -> Option<Location> {
    let MessageType::Location(location) = message else {
        return None;
    };
    let place = location.geo_uri.strip_prefix("geo:")?;
    let place = place.split(';').next()?;
    let mut parts = place.split(',');
    let latitude = parts.next()?.trim().parse().ok()?;
    let longitude = parts.next()?.trim().parse().ok()?;
    Some(Location {
        latitude,
        longitude,
    })
}
