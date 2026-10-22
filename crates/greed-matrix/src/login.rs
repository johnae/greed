//! Signing in: what a server offers, and the steps of each way.

use std::collections::HashMap;

use greed_chat::protocol::{Field, Method, Step};
use greed_chat::rpc::Failure;
use matrix_sdk::Client;
use matrix_sdk::ruma::api::client::session::get_login_types::v3::LoginType;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{Matrix, Store, random, secret};

/// The name a new device gets on the server, as its other sessions list it.
const DEVICE: &str = "Greed";

/// A sign-in going on: its client, with the store it'll keep if it works.
pub(crate) struct Login {
    client: Client,
    store: Store,
}

/// The ways `server` offers to sign in, the browser's first.
pub(crate) async fn methods(server: &str) -> Result<Vec<Method>, Failure> {
    let client = Client::builder()
        .server_name_or_homeserver_url(server)
        .build()
        .await
        .map_err(|e| reach(server, &e))?;
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
        .map_err(|e| reach(server, &e))?;
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

fn reach(server: &str, e: &impl std::fmt::Display) -> Failure {
    Failure::new(format!("can't reach {server}: {e}"))
}

#[derive(Deserialize)]
pub(crate) struct Start {
    server: String,
    method: Method,
}

#[derive(Deserialize)]
pub(crate) struct Answer {
    login: String,
    values: HashMap<String, String>,
}

#[derive(Deserialize)]
pub(crate) struct Cancel {
    login: String,
}

fn password_fields(why: Option<String>) -> Step {
    Step::Ask {
        fields: vec![
            Field {
                name: "user".into(),
                label: "Username".into(),
                secret: false,
            },
            Field {
                name: "password".into(),
                label: "Password".into(),
                secret: true,
            },
        ],
        why,
    }
}

impl Matrix {
    /// Starts signing in to `server` with `method`: `{login, step}`.
    pub(crate) async fn start(&self, start: Start) -> Result<Value, Failure> {
        if start.method != Method::Password {
            return Err(Failure::new("only passwords for now"));
        }
        let store = Store {
            name: random(8),
            passphrase: random(32),
        };
        let client = self
            .client(&store)
            .server_name_or_homeserver_url(&start.server)
            .build()
            .await
            .map_err(|e| reach(&start.server, &e))?;
        let id = random(8);
        self.logins
            .borrow_mut()
            .insert(id.clone(), Login { client, store });
        Ok(json!({ "login": id, "step": password_fields(None) }))
    }

    /// The step after `answer`'s values.
    pub(crate) async fn answer(&self, answer: Answer) -> Result<Value, Failure> {
        let client = self
            .logins
            .borrow()
            .get(&answer.login)
            .map(|login| login.client.clone())
            .ok_or_else(|| Failure::new("that sign-in is over"))?;
        let value = |name: &str| answer.values.get(name).map_or("", String::as_str);
        let sent = client
            .matrix_auth()
            .login_username(value("user"), value("password"))
            .initial_device_display_name(DEVICE)
            .send()
            .await;
        if let Err(e) = sent {
            return Ok(json!(password_fields(Some(e.to_string()))));
        }
        let Some(Login { client, store }) = self.logins.borrow_mut().remove(&answer.login) else {
            return Err(Failure::new("that sign-in is over"));
        };
        let Some(secret) = secret(&client, &store) else {
            return Ok(json!(Step::Failed {
                why: "signed in, but the server gave no session".into()
            }));
        };
        let account = self.signed_in(client, store).await;
        Ok(json!(Step::Done { account, secret }))
    }

    /// Gives up a sign-in, and the store it made.
    pub(crate) fn cancel(&self, cancel: &Cancel) {
        if let Some(login) = self.logins.borrow_mut().remove(&cancel.login) {
            drop(login.client);
            self.forget(&login.store);
        }
    }
}
