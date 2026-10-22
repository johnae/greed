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
        Self::new(e.to_string())
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
        let response = send(self.request(Method::POST, path).json(body)).await?;
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
