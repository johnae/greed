//! What happens live, over the server's WebSocket: new and changed posts
//! into open timelines, channel changes as `rooms.changed`, and whether
//! the account is connected.

use std::sync::Arc;
use std::time::Duration;

use futures_util::StreamExt;
use greed_chat::protocol::AccountState;
use rustls_platform_verifier::ConfigVerifierExt;
use serde_json::{Value, json};
use tokio::task::AbortHandle;
use tokio_tungstenite::Connector;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

use crate::Mattermost;
use crate::api::{Api, Post};

/// The longest wait before connecting again.
const PATIENCE: Duration = Duration::from_secs(30);

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
];

impl Mattermost {
    /// Keeps account `id` connected to its server's WebSocket, until the
    /// handle is aborted.
    pub(crate) fn connect(&self, id: &str, api: &Api) -> AbortHandle {
        let me = self.me.clone();
        let id = id.to_string();
        let api = api.clone();
        tokio::task::spawn_local(async move {
            let mut wait = Duration::from_secs(1);
            loop {
                let failed = match listen(&api).await {
                    Ok(mut socket) => {
                        wait = Duration::from_secs(1);
                        let Some(this) = me.upgrade() else { return };
                        this.changed(&id, AccountState::Ready);
                        drop(this);
                        while let Some(message) = socket.next().await {
                            let Ok(Message::Text(text)) = message else {
                                continue;
                            };
                            let Ok(event) = serde_json::from_str::<Value>(&text) else {
                                continue;
                            };
                            let Some(this) = me.upgrade() else { return };
                            this.heard(&id, &event).await;
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

    /// Acts on an event from account `id`'s server.
    async fn heard(&self, id: &str, event: &Value) {
        let name = event["event"].as_str().unwrap_or_default();
        let post = || {
            event["data"]["post"]
                .as_str()
                .and_then(|post| serde_json::from_str::<Post>(post).ok())
        };
        match name {
            "posted" | "post_edited" | "post_deleted" => {
                if let Some(post) = post() {
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
            _ => {}
        }
        if ROOM_EVENTS.contains(&name) {
            self.notifier
                .notify("rooms.changed", &json!({ "account": id }));
        }
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
