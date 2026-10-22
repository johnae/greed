//! What happens live, over the server's WebSocket: new and changed posts
//! into open timelines, channel changes as `rooms.changed`, and whether
//! the account is connected.

use std::sync::Arc;
use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use greed_chat::protocol::{AccountState, RoomParams};
use greed_chat::rpc::Failure;
use rustls_platform_verifier::ConfigVerifierExt;
use serde_json::{Value, json};
use tokio::sync::mpsc;
use tokio::task::AbortHandle;
use tokio_tungstenite::Connector;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

use crate::Mattermost;
use crate::api::{Api, Post};

/// The longest wait before connecting again.
const PATIENCE: Duration = Duration::from_secs(30);

/// How long someone writing is shown after they last said so.
const TYPING: Duration = Duration::from_secs(6);

/// Events that change what a list of channels shows.
const ROOM_EVENTS: &[&str] = &[
    "posted",
    "channel_viewed",
    "multiple_channels_viewed",
    "channel_created",
    "channel_updated",
    "channel_deleted",
    "channel_converted",
    "channel_member_updated",
    "direct_added",
    "group_added",
    "user_added",
    "user_removed",
    "added_to_team",
    "leave_team",
    "status_change",
];

impl Mattermost {
    /// Keeps account `id` connected to its server's WebSocket, sending it
    /// what comes on `outgoing`, until the handle is aborted.
    pub(crate) fn connect(
        &self,
        id: &str,
        api: &Api,
        mut outgoing: mpsc::UnboundedReceiver<Value>,
    ) -> AbortHandle {
        let me = self.me.clone();
        let id = id.to_string();
        let api = api.clone();
        tokio::task::spawn_local(async move {
            let mut wait = Duration::from_secs(1);
            let mut seq = 1;
            loop {
                let failed = match listen(&api).await {
                    Ok(mut socket) => {
                        wait = Duration::from_secs(1);
                        let Some(this) = me.upgrade() else { return };
                        this.changed(&id, AccountState::Ready);
                        drop(this);
                        loop {
                            tokio::select! {
                                message = socket.next() => {
                                    let Some(message) = message else { break };
                                    let Ok(Message::Text(text)) = message else {
                                        continue;
                                    };
                                    let Ok(event) = serde_json::from_str::<Value>(&text) else {
                                        continue;
                                    };
                                    let Some(this) = me.upgrade() else { return };
                                    this.heard(&id, &event).await;
                                }
                                Some(mut action) = outgoing.recv() => {
                                    seq += 1;
                                    action["seq"] = json!(seq);
                                    if socket.send(Message::text(action.to_string())).await.is_err() {
                                        break;
                                    }
                                }
                            }
                        }
                        "the connection to the server dropped".to_string()
                    }
                    Err(why) => why,
                };
                let Some(this) = me.upgrade() else { return };
                this.changed(&id, AccountState::Trouble(failed));
                drop(this);
                tokio::time::sleep(wait).await;
                wait = (wait * 2).min(PATIENCE);
            }
        })
        .abort_handle()
    }

    /// Says over the WebSocket that you're writing in a channel; Mattermost
    /// has no saying you've stopped, it forgets after a few seconds.
    pub(crate) fn typing(&self, params: &RoomParams) -> Result<(), Failure> {
        if !params.on {
            return Ok(());
        }
        let accounts = self.accounts.borrow();
        let signed = accounts
            .get(&params.account)
            .ok_or_else(|| Failure::new(format!("no account {}", params.account)))?;
        let action = json!({
            "action": "user_typing",
            "data": { "channel_id": params.room, "parent_id": params.thread.as_deref().unwrap_or_default() },
        });
        signed
            .outgoing
            .send(action)
            .map_err(|_| Failure::new("not connected"))
    }

    /// Acts on an event from account `id`'s server.
    async fn heard(&self, id: &str, event: &Value) {
        let name = event["event"].as_str().unwrap_or_default();
        let post = || {
            event["data"]["post"]
                .as_str()
                .and_then(|post| serde_json::from_str::<Post>(post).ok())
        };
        match name {
            "posted" | "post_edited" => {
                if let Some(post) = post() {
                    self.posted(id, &post).await;
                }
            }
            "post_deleted" => {
                if let Some(mut post) = post() {
                    post.delete_at = post.delete_at.max(1);
                    self.posted(id, &post).await;
                }
            }
            "reaction_added" | "reaction_removed" => {
                let reaction: Value = event["data"]["reaction"]
                    .as_str()
                    .and_then(|r| serde_json::from_str(r).ok())
                    .unwrap_or_default();
                if let (Some(post), Ok((api, _))) = (reaction["post_id"].as_str(), self.signed(id))
                    && let Ok(post) = api.get::<Post>(&format!("api/v4/posts/{post}")).await
                {
                    self.posted(id, &post).await;
                }
            }
            "typing" => {
                let room = event["broadcast"]["channel_id"]
                    .as_str()
                    .unwrap_or_default();
                let user = event["data"]["user_id"].as_str().unwrap_or_default();
                self.someone_typing(id, room, user);
            }
            _ => {}
        }
        if ROOM_EVENTS.contains(&name) {
            self.notifier
                .notify("rooms.changed", &json!({ "account": id }));
        }
    }

    /// Notes that `user` is writing in `room`, says who is, and forgets them
    /// once they've said nothing for a while.
    fn someone_typing(&self, account: &str, room: &str, user: &str) {
        let key = format!("{account} {room}");
        self.typing
            .borrow_mut()
            .entry(key.clone())
            .or_default()
            .insert(user.to_string(), Instant::now());
        self.tell_typing(account, room);
        let me = self.me.clone();
        let (account, room) = (account.to_string(), room.to_string());
        tokio::task::spawn_local(async move {
            tokio::time::sleep(TYPING).await;
            let Some(this) = me.upgrade() else { return };
            let forgot = this.typing.borrow_mut().get_mut(&key).is_some_and(|who| {
                let before = who.len();
                who.retain(|_, at| at.elapsed() < TYPING);
                who.len() != before
            });
            if forgot {
                this.tell_typing(&account, &room);
            }
        });
    }

    fn tell_typing(&self, account: &str, room: &str) {
        let names: Vec<String> = self
            .typing
            .borrow()
            .get(&format!("{account} {room}"))
            .map(|who| who.keys().map(|user| self.name_of(account, user)).collect())
            .unwrap_or_default();
        let params = json!({ "account": account, "room": room, "who": names });
        self.notifier.notify("typing.changed", &params);
    }
}

type Socket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// The server's WebSocket, signed in with the account's token.
async fn listen(api: &Api) -> Result<Socket, String> {
    let mut url = api
        .server
        .join("api/v4/websocket")
        .map_err(|e| e.to_string())?;
    let scheme = if url.scheme() == "https" { "wss" } else { "ws" };
    url.set_scheme(scheme)
        .map_err(|()| "can't make a WebSocket address".to_string())?;
    let mut request = url
        .as_str()
        .into_client_request()
        .map_err(|e| e.to_string())?;
    let token = api.token.clone().unwrap_or_default();
    let bearer = format!("Bearer {token}")
        .parse()
        .map_err(|_| "the token isn't a header".to_string())?;
    request.headers_mut().insert("Authorization", bearer);
    let tls = rustls::ClientConfig::with_platform_verifier()
        .map_err(|e| format!("setting up TLS: {e}"))?;
    let connector = Connector::Rustls(Arc::new(tls));
    let (socket, _) =
        tokio_tungstenite::connect_async_tls_with_config(request, None, false, Some(connector))
            .await
            .map_err(|e| format!("can't connect for live updates: {e}"))?;
    Ok(socket)
}
