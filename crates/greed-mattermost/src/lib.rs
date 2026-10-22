//! Mattermost for Greed's chat client, through its REST API and, for what
//! happens live, its WebSocket. An account's secret is its server and
//! session token, which go to the client for the keyring and come back with
//! `restore`; nothing secret stays here.

mod api;
mod login;

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::rc::Rc;

use greed_chat::protocol::{Account, AccountState, Hello, PROTOCOL};
use greed_chat::rpc::{self, Failure, Notifier, Service};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use api::{Api, User};

/// The Mattermost service: the accounts signed in and the sign-ins going on.
pub struct Mattermost {
    #[allow(dead_code, reason = "the local store comes with the timeline")]
    data: PathBuf,
    #[allow(dead_code, reason = "events from the WebSocket come next")]
    notifier: Notifier,
    accounts: RefCell<BTreeMap<String, Signed>>,
    logins: RefCell<HashMap<String, login::Login>>,
}

/// A signed-in account: its server with the token, and who it is.
struct Signed {
    api: Api,
    user: User,
}

/// What an account's secret holds.
#[derive(Serialize, Deserialize)]
struct Secret {
    server: String,
    token: String,
}

impl Mattermost {
    /// Keeps what it stores in `data`, and sends notifications with
    /// `notifier`.
    pub fn new(data: PathBuf, notifier: Notifier) -> Rc<Self> {
        Rc::new(Self {
            data,
            notifier,
            accounts: RefCell::default(),
            logins: RefCell::default(),
        })
    }

    fn accounts(&self) -> Vec<Account> {
        self.accounts
            .borrow()
            .values()
            .map(Signed::account)
            .collect()
    }

    /// Signs in again with a secret `Done` gave.
    async fn restore(&self, secret: &str) -> Result<Account, Failure> {
        let secret: Secret = serde_json::from_str(secret)
            .map_err(|e| Failure::new(format!("that isn't a Mattermost account's secret: {e}")))?;
        let api = Api::new(&secret.server)
            .map_err(Failure::new)?
            .with_token(secret.token);
        let user: User = api.get("api/v4/users/me").await.map_err(|e| {
            if e.signed_out() {
                Failure::new("signed out; sign in again")
            } else {
                Failure::new(format!("can't reach {}: {e}", api.address()))
            }
        })?;
        Ok(self.signed_in(Signed { api, user }))
    }

    /// Takes on an account just signed in.
    fn signed_in(&self, signed: Signed) -> Account {
        let account = signed.account();
        self.accounts
            .borrow_mut()
            .insert(account.id.clone(), signed);
        account
    }

    /// Signs `id` out.
    async fn logout(&self, id: &str) -> Result<(), Failure> {
        let signed = self
            .accounts
            .borrow_mut()
            .remove(id)
            .ok_or_else(|| Failure::new(format!("no account {id}")))?;
        signed
            .api
            .post::<Value>("api/v4/users/logout", &json!({}))
            .await
            .map(drop)
            .map_err(|e| Failure::new(format!("signed out here, but the server said: {e}")))
    }
}

impl Signed {
    /// The account's id: the user's id at the server's host, which stays
    /// the same when they change their username.
    fn account(&self) -> Account {
        let host = self.api.server.host_str().unwrap_or_default();
        Account {
            id: format!("{}@{host}", self.user.id),
            server: self.api.address(),
            name: Some(self.user.name()),
            state: AccountState::Ready,
        }
    }

    fn secret(&self) -> String {
        let secret = Secret {
            server: self.api.address(),
            token: self.api.token.clone().unwrap_or_default(),
        };
        json!(secret).to_string()
    }
}

#[derive(Deserialize)]
struct Server {
    server: String,
}

#[derive(Deserialize)]
struct SecretParams {
    secret: String,
}

#[derive(Deserialize)]
struct AccountParams {
    account: String,
}

impl Service for Mattermost {
    async fn call(&self, method: &str, params: Value) -> Result<Value, Failure> {
        match method {
            "hello" => Ok(json!(Hello {
                protocol: PROTOCOL,
                service: "mattermost".into(),
                version: env!("CARGO_PKG_VERSION").into(),
                can: Vec::new(),
            })),
            "accounts" => Ok(json!(self.accounts())),
            "restore" => {
                let SecretParams { secret } = rpc::parse(params)?;
                Ok(json!(self.restore(&secret).await?))
            }
            "login.methods" => {
                let Server { server } = rpc::parse(params)?;
                Ok(json!(login::methods(&server).await?))
            }
            "login.start" => self.start(&rpc::parse(params)?),
            "login.answer" => self.answer(rpc::parse(params)?).await,
            "login.cancel" => {
                self.cancel(&rpc::parse(params)?);
                Ok(Value::Null)
            }
            "logout" => {
                let AccountParams { account } = rpc::parse(params)?;
                self.logout(&account).await?;
                Ok(Value::Null)
            }
            _ => Err(Failure::unknown(method)),
        }
    }
}
