//! Signing in: what a server offers, and the steps of each way.

use greed_chat::loopback::{self, Loopback};
use greed_chat::protocol::{Answer, Field, LoginParams, Method, Start, Step};
use greed_chat::rpc::Failure;
use greed_chat::{random, why};
use matrix_sdk::Client;
use matrix_sdk::authentication::oauth::registration::{
    ApplicationType, ClientMetadata, Localized, OAuthGrantType,
};
use matrix_sdk::ruma::api::client::session::get_login_types::v3::LoginType;
use matrix_sdk::ruma::serde::Raw;
use matrix_sdk::utils::UrlOrQuery;
use serde_json::{Value, json};
use tokio::task::AbortHandle;
use url::Url;

use crate::{Matrix, Store, secret};

/// The name a new device gets on the server, as its other sessions list it.
const DEVICE: &str = "Greed";

/// What Greed says it is to an OAuth server, which shows it when you sign in.
const CLIENT_URI: &str = "https://johnae.github.io/greed/";

/// Where an OAuth server sends the browser back to when it won't to a
/// loopback address: a scheme of Greed's own, its address's host reversed.
/// `greed link` takes it.
const OWN_SCHEME: &str = "io.github.johnae:/greed";

/// A sign-in going on: its client, with the store it'll keep if it works.
pub(crate) struct Login {
    client: Client,
    store: Store,
    way: Way,
}

enum Way {
    Password,
    /// Through the browser, `waiting` for it to come back: single sign-on,
    /// or OAuth.
    Browser {
        waiting: Option<AbortHandle>,
        oauth: bool,
    },
}

/// The ways `server` offers to sign in, the browser's first.
pub(crate) async fn methods(server: &str) -> Result<Vec<Method>, Failure> {
    let client = Client::builder()
        .server_name_or_homeserver_url(server)
        .build()
        .await
        .map_err(|e| reach(server, &why(&e)))?;
    let mut methods = Vec::new();
    if client.oauth().server_metadata().await.is_ok() {
        methods.push(Method::Browser {
            id: "oauth".into(),
            name: "your account's page".into(),
        });
    }
    let types = client
        .matrix_auth()
        .get_login_types()
        .await
        .map_err(|e| reach(server, &why(&e)))?;
    for flow in types.flows {
        match flow {
            LoginType::Password(_) => methods.push(Method::Password),
            LoginType::Sso(sso) if sso.identity_providers.is_empty() => {
                methods.push(Method::Browser {
                    id: "sso".into(),
                    name: "single sign-on".into(),
                });
            }
            LoginType::Sso(sso) => {
                methods.extend(sso.identity_providers.into_iter().map(|p| Method::Browser {
                    id: format!("sso:{}", p.id),
                    name: p.name,
                }));
            }
            _ => {}
        }
    }
    Ok(methods)
}

fn reach(server: &str, why: &str) -> Failure {
    Failure::new(format!("can't reach {server}: {why}"))
}

fn password_fields(why: Option<String>) -> Step {
    Step::Ask {
        fields: vec![
            Field::text("user", "Username"),
            Field::secret("password", "Password"),
        ],
        why,
    }
}

/// What the browser sign-in says to paste where the browser can't come
/// back to Greed by itself.
const PASTE: &str = "the link the browser ends on: http://127.0.0.1:…/?loginToken=…";

impl Matrix {
    /// Starts signing in to `server` with `method`: `{login, step}`.
    pub(crate) async fn start(&self, start: &Start) -> Result<Value, Failure> {
        let store = Store {
            name: random(8),
            passphrase: random(32),
        };
        let built = self
            .client(&store)
            .server_name_or_homeserver_url(&start.server)
            .build()
            .await;
        let client = match built {
            Ok(client) => client,
            Err(e) => {
                self.forget(&store);
                return Err(reach(&start.server, &why(&e)));
            }
        };
        let id = random(8);
        let (way, step) = match self.begin(&id, &client, start).await {
            Ok(begun) => begun,
            Err(e) => {
                // Nothing of a sign-in that didn't start is kept.
                drop(client);
                self.forget(&store);
                return Err(e);
            }
        };
        self.logins
            .borrow_mut()
            .insert(id.clone(), Login { client, store, way });
        Ok(json!({ "login": id, "step": step }))
    }

    /// The first step of sign-in `id` with `client`, the way `start` asks.
    async fn begin(
        &self,
        id: &str,
        client: &Client,
        start: &Start,
    ) -> Result<(Way, Step), Failure> {
        let Method::Browser { id: way, .. } = &start.method else {
            return match &start.method {
                Method::Password => Ok((Way::Password, password_fields(None))),
                _ => Err(Failure::new("that sign-in isn't there yet")),
            };
        };
        let loopback = Loopback::new()
            .await
            .map_err(|e| Failure::new(format!("can't wait for the browser: {e}")))?;
        let oauth = way == "oauth";
        // Whether the browser can come back to `loopback`; else the link
        // it ends on is pasted, or comes through `greed link`.
        let mut comes_back = true;
        let url = if oauth {
            let redirect = Url::parse(&loopback.url).map_err(|e| Failure::new(e.to_string()))?;
            match authorize(client, redirect).await {
                Ok(url) => url,
                // Some servers (Tuwunel) let a native client only come back
                // to a scheme of its own, made from its address.
                Err(e) if e.contains("invalid_redirect_uri") => {
                    comes_back = false;
                    let own = Url::parse(OWN_SCHEME).expect("Greed's scheme makes a URL");
                    authorize(client, own)
                        .await
                        .map_err(|e| reach(&start.server, &e))?
                }
                Err(e) => return Err(reach(&start.server, &e)),
            }
        } else if way == "sso" || way.starts_with("sso:") {
            client
                .matrix_auth()
                .get_sso_login_url(&loopback.url, way.strip_prefix("sso:"))
                .await
                .map_err(|e| reach(&start.server, &why(&e)))?
        } else {
            return Err(Failure::new(format!("{way} isn't a way to sign in here")));
        };
        let waiting = comes_back.then(|| self.wait_for_browser(id, loopback));
        let step = Step::Open {
            url,
            paste: Some(PASTE.into()),
        };
        Ok((Way::Browser { waiting, oauth }, step))
    }

    /// Finishes sign-in `id` when the browser comes back to `loopback`,
    /// sending the step it comes to as `login.step`.
    fn wait_for_browser(&self, id: &str, loopback: Loopback) -> AbortHandle {
        let me = self.me.clone();
        let id = id.to_string();
        tokio::task::spawn_local(async move {
            let caught = loopback.wait().await;
            let Some(me) = me.upgrade() else { return };
            let step = match caught {
                Ok(url) => me.finish_browser(&id, url.as_str()).await,
                Err(e) => Step::Failed {
                    why: format!("lost the browser: {e}"),
                },
            };
            me.notifier
                .notify("login.step", &json!({ "login": id, "step": step }));
        })
        .abort_handle()
    }

    /// The step after `answer`'s values: a name and password, or the link
    /// the browser ended on (`link`).
    pub(crate) async fn answer(&self, answer: &Answer) -> Result<Value, Failure> {
        let (client, browser) = self
            .logins
            .borrow()
            .get(&answer.login)
            .map(|login| {
                let waiting = match &login.way {
                    Way::Browser { waiting, .. } => Some(waiting.clone()),
                    Way::Password => None,
                };
                (login.client.clone(), waiting)
            })
            .ok_or_else(|| Failure::new("that sign-in is over"))?;
        if let Some(waiting) = browser {
            let link = answer.value("link");
            let query = loopback::query(link);
            if !query.contains_key("loginToken") && !query.contains_key("code") {
                return Err(Failure::new(format!("that isn't the link: paste {PASTE}")));
            }
            // The browser came back here instead; stop waiting for it.
            if let Some(task) = waiting {
                task.abort();
            }
            return Ok(json!(self.finish_browser(&answer.login, link).await));
        }
        let sent = client
            .matrix_auth()
            .login_username(answer.value("user"), answer.value("password"))
            .initial_device_display_name(DEVICE)
            .send()
            .await;
        match sent {
            Ok(_) => Ok(json!(self.signed_in_by(&answer.login).await)),
            Err(e) => Ok(json!(password_fields(Some(why(&e))))),
        }
    }

    /// Signs in `id` with the link the browser came back with: its
    /// `loginToken` from single sign-on, or OAuth's `code`.
    async fn finish_browser(&self, id: &str, link: &str) -> Step {
        let found = self.logins.borrow().get(id).map(|login| {
            let oauth = matches!(login.way, Way::Browser { oauth: true, .. });
            (login.client.clone(), oauth)
        });
        let Some((client, oauth)) = found else {
            return Step::Failed {
                why: "that sign-in is over".into(),
            };
        };
        let done = if oauth {
            let query = link.split_once('?').map_or(link, |(_, query)| query);
            client
                .oauth()
                .finish_login(UrlOrQuery::Query(query.to_string()))
                .await
                .map_err(|e| why(&e))
        } else {
            let query = loopback::query(link);
            let token = query.get("loginToken").map_or("", String::as_str);
            client
                .matrix_auth()
                .login_token(token)
                .initial_device_display_name(DEVICE)
                .send()
                .await
                .map(drop)
                .map_err(|e| why(&e))
        };
        match done {
            Ok(()) => self.signed_in_by(id).await,
            Err(e) => {
                // Not `cancel`: this may run in the waiting task itself.
                self.give_up(id);
                Step::Failed {
                    why: format!("the server didn't take the sign-in: {e}"),
                }
            }
        }
    }

    /// Takes on the account sign-in `id` signed in.
    async fn signed_in_by(&self, id: &str) -> Step {
        let Some(Login { client, store, .. }) = self.logins.borrow_mut().remove(id) else {
            return Step::Failed {
                why: "that sign-in is over".into(),
            };
        };
        let Some(secret) = secret(&client, &store) else {
            return Step::Failed {
                why: "signed in, but the server gave no session".into(),
            };
        };
        let account = self.signed_in(client, store).await;
        Step::Done { account, secret }
    }

    /// Gives up a sign-in, and the store it made.
    pub(crate) fn cancel(&self, cancel: &LoginParams) {
        if let Some(Way::Browser {
            waiting: Some(waiting),
            ..
        }) = self.give_up(&cancel.login)
        {
            waiting.abort();
        }
    }

    /// Drops sign-in `id` and the store it made, giving its way.
    fn give_up(&self, id: &str) -> Option<Way> {
        let login = self.logins.borrow_mut().remove(id)?;
        drop(login.client);
        self.forget(&login.store);
        Some(login.way)
    }
}

/// Registers Greed with `client`'s OAuth server, to come back to
/// `redirect`, and gives the address to send the browser to.
async fn authorize(client: &Client, redirect: Url) -> Result<String, String> {
    let home = Url::parse(CLIENT_URI).expect("Greed's address is a URL");
    let metadata = ClientMetadata::new(
        ApplicationType::Native,
        vec![OAuthGrantType::AuthorizationCode {
            redirect_uris: vec![redirect.clone()],
        }],
        Localized::new(home, []),
    );
    let metadata = Raw::new(&metadata).map_err(|e| e.to_string())?;
    let authorization = client
        .oauth()
        .login(redirect, None, Some(metadata.into()), None)
        .build()
        .await
        .map_err(|e| why(&e))?;
    Ok(authorization.url.to_string())
}
