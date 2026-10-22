//! Matrix for Greed's chat client, through matrix-rust-sdk. Each account
//! keeps its rooms, caches and encryption keys in a store of its own under
//! the data folder, locked with a passphrase. The passphrase and the
//! account's tokens make up its secret, which goes to the client for the
//! keyring and comes back with `restore`; nothing secret stays here.

mod login;

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::rc::{Rc, Weak};

use greed_chat::protocol::{
    Account, AccountParams, AccountState, Hello, PROTOCOL, SecretParams, ServerParams,
};
use greed_chat::rpc::{self, Failure, Notifier, Service};
use matrix_sdk::authentication::matrix::MatrixSession;
use matrix_sdk::{AuthSession, Client, ClientBuilder, SessionChange};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::broadcast::error::RecvError;

/// The Matrix service: the accounts signed in and the sign-ins going on.
pub struct Matrix {
    data: PathBuf,
    notifier: Notifier,
    /// For the tasks it starts, which end when it's gone.
    me: Weak<Matrix>,
    accounts: RefCell<BTreeMap<String, Signed>>,
    logins: RefCell<HashMap<String, login::Login>>,
}

/// A signed-in account.
struct Signed {
    client: Client,
    store: Store,
    name: Option<String>,
}

/// An account's store: its folder under the data folder, and the
/// passphrase that locks it.
#[derive(Clone, Serialize, Deserialize)]
struct Store {
    name: String,
    passphrase: String,
}

/// What an account's secret holds.
#[derive(Serialize, Deserialize)]
struct Secret {
    homeserver: String,
    store: Store,
    session: MatrixSession,
}

impl Matrix {
    /// Keeps stores in `data`, and sends notifications with `notifier`.
    pub fn new(data: PathBuf, notifier: Notifier) -> Rc<Self> {
        Rc::new_cyclic(|me| Self {
            data,
            notifier,
            me: me.clone(),
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
            .map_err(|e| Failure::new(format!("that isn't a Matrix account's secret: {e}")))?;
        let client = self
            .client(&secret.store)
            .homeserver_url(&secret.homeserver)
            .build()
            .await
            .map_err(|e| Failure::new(format!("can't open the account's store: {e}")))?;
        client
            .restore_session(secret.session)
            .await
            .map_err(|e| Failure::new(format!("can't restore the session: {e}")))?;
        Ok(self.signed_in(client, secret.store).await)
    }

    /// Takes on `client`, just signed in, and says who it is.
    async fn signed_in(&self, client: Client, store: Store) -> Account {
        let name = client.account().get_display_name().await.ok().flatten();
        let signed = Signed {
            client,
            store,
            name,
        };
        let account = signed.account();
        self.watch(&account.id, &signed.client);
        self.accounts
            .borrow_mut()
            .insert(account.id.clone(), signed);
        account
    }

    /// Passes on new tokens as `account.secret`, and a session the server
    /// ended as trouble, until the account's client is gone.
    fn watch(&self, id: &str, client: &Client) {
        let me = self.me.clone();
        let id = id.to_string();
        let mut changes = client.subscribe_to_session_changes();
        tokio::task::spawn_local(async move {
            loop {
                let change = match changes.recv().await {
                    Ok(change) => change,
                    Err(RecvError::Lagged(_)) => continue,
                    Err(RecvError::Closed) => break,
                };
                let Some(me) = me.upgrade() else { break };
                let accounts = me.accounts.borrow();
                let Some(signed) = accounts.get(&id) else {
                    continue;
                };
                match change {
                    SessionChange::TokensRefreshed => {
                        if let Some(secret) = secret(&signed.client, &signed.store) {
                            me.notifier.notify(
                                "account.secret",
                                &json!({ "account": id, "secret": secret }),
                            );
                        }
                    }
                    SessionChange::UnknownToken(_) => {
                        let account = Account {
                            state: AccountState::Trouble("the server signed you out".into()),
                            ..signed.account()
                        };
                        me.notifier.notify("account.changed", &json!(account));
                    }
                }
            }
        });
    }

    /// Signs `id` out, and forgets its store.
    async fn logout(&self, id: &str) -> Result<(), Failure> {
        let signed = self
            .accounts
            .borrow_mut()
            .remove(id)
            .ok_or_else(|| Failure::new(format!("no account {id}")))?;
        let done = signed.client.logout().await;
        drop(signed.client);
        self.forget(&signed.store);
        done.map_err(|e| Failure::new(format!("signed out here, but the server said: {e}")))
    }

    /// A client keeping its state in `store`, refreshing its tokens.
    fn client(&self, store: &Store) -> ClientBuilder {
        Client::builder()
            .sqlite_store(self.data.join(&store.name), Some(&store.passphrase))
            .handle_refresh_tokens()
    }

    /// Removes `store`'s folder, once its client is gone.
    fn forget(&self, store: &Store) {
        let _ = std::fs::remove_dir_all(self.data.join(&store.name));
    }
}

impl Signed {
    fn account(&self) -> Account {
        Account {
            id: self
                .client
                .user_id()
                .map(ToString::to_string)
                .unwrap_or_default(),
            server: self.client.homeserver().to_string(),
            name: self.name.clone(),
            state: AccountState::Ready,
        }
    }
}

/// The secret for `client`'s session in `store`, while it has one.
fn secret(client: &Client, store: &Store) -> Option<String> {
    let Some(AuthSession::Matrix(session)) = client.session() else {
        return None;
    };
    let secret = Secret {
        homeserver: client.homeserver().to_string(),
        store: store.clone(),
        session,
    };
    serde_json::to_string(&secret).ok()
}

impl Service for Matrix {
    async fn call(&self, method: &str, params: Value) -> Result<Value, Failure> {
        match method {
            "hello" => Ok(json!(Hello {
                protocol: PROTOCOL,
                service: "matrix".into(),
                version: env!("CARGO_PKG_VERSION").into(),
                can: Vec::new(),
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
            "login.start" => self.start(&rpc::parse(params)?).await,
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
            _ => Err(Failure::unknown(method)),
        }
    }
}
