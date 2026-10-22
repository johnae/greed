//! Mattermost's REST API (v4), as far as Greed uses it.

use reqwest::{Method, RequestBuilder, StatusCode};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::Value;
use url::Url;

/// A server, and the token of whoever is signed in to it.
#[derive(Clone)]
pub(crate) struct Api {
    http: reqwest::Client,
    pub(crate) server: Url,
    pub(crate) token: Option<String>,
}

/// What a request that failed says: the server's error id (like
/// `api.user.login.invalid_credentials_email_username`) and its message.
#[derive(Debug)]
pub(crate) struct Error {
    pub(crate) status: Option<StatusCode>,
    pub(crate) id: String,
    pub(crate) message: String,
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl Error {
    fn new(message: String) -> Self {
        Self {
            status: None,
            id: String::new(),
            message,
        }
    }

    fn transport(e: &reqwest::Error) -> Self {
        Self::new(greed_chat::why(e))
    }

    /// Whether the token is no good (any more).
    pub(crate) fn signed_out(&self) -> bool {
        self.status == Some(StatusCode::UNAUTHORIZED)
    }
}

/// Someone on the server.
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct User {
    pub(crate) id: String,
    pub(crate) username: String,
    #[serde(default)]
    pub(crate) first_name: String,
    #[serde(default)]
    pub(crate) last_name: String,
    #[serde(default)]
    pub(crate) nickname: String,
}

impl User {
    /// The name to show: their full name or nickname where they have one.
    pub(crate) fn name(&self) -> String {
        let full = format!("{} {}", self.first_name, self.last_name);
        let full = full.trim();
        if !full.is_empty() {
            full.to_string()
        } else if !self.nickname.is_empty() {
            self.nickname.clone()
        } else {
            self.username.clone()
        }
    }
}

/// A team, which holds channels.
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct Team {
    pub(crate) id: String,
    pub(crate) display_name: String,
}

/// A channel: public (`O`), private (`P`), direct (`D`) or group (`G`).
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct Channel {
    pub(crate) id: String,
    #[serde(default)]
    pub(crate) team_id: String,
    #[serde(rename = "type")]
    pub(crate) kind: String,
    #[serde(default)]
    pub(crate) display_name: String,
    /// For a direct channel, the two users' ids joined by `__`.
    #[serde(default)]
    pub(crate) name: String,
    #[serde(default)]
    pub(crate) header: String,
    #[serde(default)]
    pub(crate) last_post_at: i64,
    #[serde(default)]
    pub(crate) total_msg_count: u64,
}

/// Your membership of a channel: how much of it you've read.
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct Member {
    pub(crate) channel_id: String,
    #[serde(default)]
    pub(crate) msg_count: u64,
    #[serde(default)]
    pub(crate) mention_count: u64,
    #[serde(default)]
    pub(crate) notify_props: Value,
}

/// A message.
#[derive(Debug, Clone, Deserialize)]
pub(crate) struct Post {
    pub(crate) id: String,
    pub(crate) channel_id: String,
    pub(crate) user_id: String,
    #[serde(default)]
    pub(crate) root_id: String,
    #[serde(default)]
    pub(crate) message: String,
    #[serde(default, rename = "type")]
    pub(crate) kind: String,
    #[serde(default)]
    pub(crate) create_at: i64,
    #[serde(default)]
    pub(crate) edit_at: i64,
    #[serde(default)]
    pub(crate) delete_at: i64,
    #[serde(default)]
    pub(crate) reply_count: u64,
    /// The id it had while it was being sent, from the one who sent it.
    #[serde(default)]
    pub(crate) pending_post_id: String,
    #[serde(default)]
    pub(crate) metadata: Metadata,
    /// What integrations add, like attachments with buttons.
    #[serde(default)]
    pub(crate) props: Value,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub(crate) struct Metadata {
    #[serde(default)]
    pub(crate) reactions: Vec<PostReaction>,
    #[serde(default)]
    pub(crate) files: Vec<File>,
    /// What links in it lead to, as the server read them.
    #[serde(default)]
    pub(crate) embeds: Vec<Value>,
}

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct PostReaction {
    pub(crate) user_id: String,
    pub(crate) emoji_name: String,
}

#[derive(Debug, Clone, Deserialize)]
pub(crate) struct File {
    #[serde(default)]
    pub(crate) id: String,
    #[serde(default)]
    pub(crate) name: String,
    #[serde(default)]
    pub(crate) mime_type: String,
    #[serde(default)]
    pub(crate) size: u64,
    #[serde(default)]
    pub(crate) width: u64,
    #[serde(default)]
    pub(crate) height: u64,
    #[serde(default)]
    pub(crate) has_preview_image: bool,
}

/// Posts as the server lists them: their ids newest first.
#[derive(Debug, Clone, Default, Deserialize)]
pub(crate) struct Posts {
    #[serde(default)]
    pub(crate) order: Vec<String>,
    #[serde(default)]
    pub(crate) posts: std::collections::HashMap<String, Post>,
}

impl Posts {
    /// The posts, oldest first.
    pub(crate) fn oldest_first(mut self) -> Vec<Post> {
        self.order
            .iter()
            .rev()
            .filter_map(|id| self.posts.remove(id))
            .collect()
    }
}

impl Api {
    /// The server at `server`: a URL, or a host name for https.
    pub(crate) fn new(server: &str) -> Result<Api, String> {
        let server = server.trim().trim_end_matches('/');
        let with_scheme = if server.contains("://") {
            server.to_string()
        } else {
            format!("https://{server}")
        };
        let server = Url::parse(&format!("{with_scheme}/"))
            .map_err(|e| format!("{server} isn't a server address: {e}"))?;
        let http = reqwest::Client::builder()
            .user_agent(concat!("greed-mattermost/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| e.to_string())?;
        Ok(Api {
            http,
            server,
            token: None,
        })
    }

    /// The same server with `token`.
    pub(crate) fn with_token(&self, token: String) -> Api {
        Api {
            token: Some(token),
            ..self.clone()
        }
    }

    /// The server's address as people write it, without the slash.
    pub(crate) fn address(&self) -> String {
        self.server.as_str().trim_end_matches('/').to_string()
    }

    fn request(&self, method: Method, path: &str) -> RequestBuilder {
        let url = self
            .server
            .join(path.trim_start_matches('/'))
            .expect("API paths join");
        let request = self.http.request(method, url);
        match &self.token {
            Some(token) => request.bearer_auth(token),
            None => request,
        }
    }

    pub(crate) async fn get<T: DeserializeOwned>(&self, path: &str) -> Result<T, Error> {
        let response = send(self.request(Method::GET, path)).await?;
        response.json().await.map_err(|e| Error::transport(&e))
    }

    pub(crate) async fn post<T: DeserializeOwned>(
        &self,
        path: &str,
        body: &Value,
    ) -> Result<T, Error> {
        self.with_body(Method::POST, path, body).await
    }

    pub(crate) async fn put<T: DeserializeOwned>(
        &self,
        path: &str,
        body: &Value,
    ) -> Result<T, Error> {
        self.with_body(Method::PUT, path, body).await
    }

    /// The bytes `path` answers with, like a file's.
    pub(crate) async fn bytes(&self, path: &str) -> Result<Vec<u8>, Error> {
        let response = send(self.request(Method::GET, path)).await?;
        let bytes = response.bytes().await.map_err(|e| Error::transport(&e))?;
        Ok(bytes.to_vec())
    }

    /// Uploads the file `name` with `bytes` to channel `channel`, giving
    /// its id there.
    pub(crate) async fn upload(
        &self,
        channel: &str,
        name: &str,
        mime: &str,
        bytes: Vec<u8>,
    ) -> Result<String, Error> {
        let part = reqwest::multipart::Part::bytes(bytes)
            .file_name(name.to_string())
            .mime_str(mime)
            .map_err(|e| Error::transport(&e))?;
        let form = reqwest::multipart::Form::new()
            .text("channel_id", channel.to_string())
            .part("files", part);
        let response = send(self.request(Method::POST, "api/v4/files").multipart(form)).await?;
        let uploaded: Value = response.json().await.map_err(|e| Error::transport(&e))?;
        uploaded["file_infos"][0]["id"]
            .as_str()
            .map(str::to_string)
            .ok_or_else(|| Error::new("the server took the file but gave no id".into()))
    }

    /// Deletes what `path` names; the answer doesn't matter.
    pub(crate) async fn delete(&self, path: &str) -> Result<(), Error> {
        send(self.request(Method::DELETE, path)).await.map(drop)
    }

    async fn with_body<T: DeserializeOwned>(
        &self,
        method: Method,
        path: &str,
        body: &Value,
    ) -> Result<T, Error> {
        let response = send(self.request(method, path).json(body)).await?;
        response.json().await.map_err(|e| Error::transport(&e))
    }

    /// Signs in with `body` (`login_id` and `password`, or a desktop token's
    /// parts), giving the session's token and who it is.
    pub(crate) async fn login(&self, path: &str, body: &Value) -> Result<(String, User), Error> {
        let response = send(self.request(Method::POST, path).json(body)).await?;
        let token = response
            .headers()
            .get("token")
            .and_then(|token| token.to_str().ok())
            .map(str::to_string);
        let user = response.json().await.map_err(|e| Error::transport(&e))?;
        let token = token.ok_or_else(|| Error::new("the server gave no session token".into()))?;
        Ok((token, user))
    }
}

/// Sends `request`, turning a status that isn't success into its `Error`.
async fn send(request: RequestBuilder) -> Result<reqwest::Response, Error> {
    let response = request.send().await.map_err(|e| Error::transport(&e))?;
    let status = response.status();
    if status.is_success() {
        return Ok(response);
    }
    let body: Value = response.json().await.unwrap_or_default();
    let text = |key: &str| body.get(key).and_then(Value::as_str).map(str::to_string);
    Err(Error {
        status: Some(status),
        id: text("id").unwrap_or_default(),
        message: text("message").unwrap_or_else(|| status.to_string()),
    })
}
