//! Mattermost for Greed's chat client, through its REST API and, for what
//! happens live, its WebSocket. An account's secret is its server and
//! session token, which go to the client for the keyring and come back with
//! `restore`; nothing secret stays here.

mod alerts;
mod api;
mod commands;
mod live;
mod login;
mod media;
mod rooms;
mod search;
mod timeline;

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::rc::{Rc, Weak};
use std::time::Instant;

use greed_chat::protocol::{
    Account, AccountParams, AccountState, Hello, Item, PROTOCOL, SecretParams, SendParams,
    ServerParams,
};
use greed_chat::rpc::{self, Failure, Notifier, Service};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::mpsc;
use tokio::task::AbortHandle;

use api::{Api, User};

/// The Mattermost service: the accounts signed in and the sign-ins going on.
pub struct Mattermost {
    data: PathBuf,
    notifier: Notifier,
    /// For the tasks it starts, which end when it's gone.
    me: Weak<Mattermost>,
    accounts: RefCell<BTreeMap<String, Signed>>,
    logins: RefCell<HashMap<String, login::Login>>,
    /// The people accounts have come across, by "account user".
    people: RefCell<HashMap<String, User>>,
    /// The timelines the client has open, by "account channel".
    timelines: RefCell<HashMap<String, Vec<Item>>>,
    /// Who's writing where, by "account channel", and when they last said so.
    typing: RefCell<HashMap<String, HashMap<String, Instant>>>,
}

/// A signed-in account: its server with the token, and who it is.
struct Signed {
    api: Api,
    user: User,
    state: AccountState,
    /// Its WebSocket, kept connected.
    live: Option<AbortHandle>,
    /// What goes to the WebSocket, like saying you're writing.
    outgoing: mpsc::UnboundedSender<Value>,
}

impl Drop for Signed {
    fn drop(&mut self) {
        if let Some(live) = &self.live {
            live.abort();
        }
    }
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
        Rc::new_cyclic(|me| Self {
            data,
            notifier,
            me: me.clone(),
            accounts: RefCell::default(),
            logins: RefCell::default(),
            people: RefCell::default(),
            timelines: RefCell::default(),
            typing: RefCell::default(),
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
        Ok(self.signed_in(api, user))
    }

    /// Takes on an account just signed in, and keeps it connected.
    fn signed_in(&self, api: Api, user: User) -> Account {
        let (outgoing, sent) = mpsc::unbounded_channel();
        let mut signed = Signed {
            api,
            user,
            state: AccountState::Syncing,
            live: None,
            outgoing,
        };
        let account = signed.account();
        signed.live = Some(self.connect(&account.id, &signed.api, sent));
        self.accounts
            .borrow_mut()
            .insert(account.id.clone(), signed);
        account
    }

    /// Notes account `id`'s new state, and tells the client.
    fn changed(&self, id: &str, state: AccountState) {
        let account = {
            let mut accounts = self.accounts.borrow_mut();
            let Some(signed) = accounts.get_mut(id) else {
                return;
            };
            if signed.state == state {
                return;
            }
            signed.state = state;
            signed.account()
        };
        self.notifier.notify("account.changed", &json!(account));
    }

    /// Signs `id` out.
    async fn logout(&self, id: &str) -> Result<(), Failure> {
        let signed = self
            .accounts
            .borrow_mut()
            .remove(id)
            .ok_or_else(|| Failure::new(format!("no account {id}")))?;
        self.timelines
            .borrow_mut()
            .retain(|key, _| !key.starts_with(&format!("{id} ")));
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
            state: self.state.clone(),
        }
    }
}

/// The secret for a session with `api`.
fn secret(api: &Api) -> String {
    let secret = Secret {
        server: api.address(),
        token: api.token.clone().unwrap_or_default(),
    };
    json!(secret).to_string()
}

impl Service for Mattermost {
    async fn call(&self, method: &str, params: Value) -> Result<Value, Failure> {
        match method {
            "hello" => Ok(json!(Hello {
                protocol: PROTOCOL,
                service: "mattermost".into(),
                version: env!("CARGO_PKG_VERSION").into(),
                can: ["threads", "presence", "commands"]
                    .map(String::from)
                    .to_vec(),
            })),
            "accounts" => Ok(json!(self.accounts())),
            "restore" => {
                let SecretParams { secret } = rpc::parse(params)?;
                Ok(json!(self.restore(&secret).await?))
            }
            "login.methods" => {
                let ServerParams { server } = rpc::parse(params)?;
                Ok(json!(login::methods(&server).await?))
            }
            "login.start" => self.start(&rpc::parse(params)?),
            "login.answer" => self.answer(&rpc::parse(params)?).await,
            "login.cancel" => {
                self.cancel(&rpc::parse(params)?);
                Ok(Value::Null)
            }
            "logout" => {
                let AccountParams { account } = rpc::parse(params)?;
                self.logout(&account).await?;
                Ok(Value::Null)
            }
            "rooms" => {
                let AccountParams { account } = rpc::parse(params)?;
                Ok(json!(self.rooms(&account).await?))
            }
            "timeline" => self.open_timeline(&rpc::parse(params)?).await,
            "timeline.back" => self.back(&rpc::parse(params)?).await,
            "timeline.close" => {
                self.close_timeline(&rpc::parse(params)?);
                Ok(Value::Null)
            }
            "send" => {
                let send: SendParams = rpc::parse(params)?;
                if send.text.starts_with('/') {
                    return self.run_command(&send).await;
                }
                self.send(&send).await?;
                Ok(Value::Null)
            }
            "commands" => Ok(json!(self.commands(&rpc::parse(params)?).await?)),
            "press" => self.press(&rpc::parse(params)?).await.map(|()| Value::Null),
            "search" => Ok(json!(self.search(&rpc::parse(params)?).await?)),
            "edit" => self.edit(&rpc::parse(params)?).await.map(|()| Value::Null),
            "redact" => self
                .redact(&rpc::parse(params)?)
                .await
                .map(|()| Value::Null),
            "react" => self.react(&rpc::parse(params)?).await.map(|()| Value::Null),
            "read" => self.read(&rpc::parse(params)?).await.map(|()| Value::Null),
            "typing" => self.typing(&rpc::parse(params)?).map(|()| Value::Null),
            "media.get" => self.media_get(&rpc::parse(params)?).await,
            "upload" => self
                .upload(&rpc::parse(params)?)
                .await
                .map(|()| Value::Null),
            _ => Err(Failure::unknown(method)),
        }
    }
}
