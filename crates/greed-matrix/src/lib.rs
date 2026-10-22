//! Matrix for Greed's chat client, through matrix-rust-sdk. Each account
//! keeps its rooms, caches and encryption keys in a store of its own under
//! the data folder, locked with a passphrase. The passphrase and the
//! account's tokens make up its secret, which goes to the client for the
//! keyring and comes back with `restore`; nothing secret stays here.

// matrix-sdk's futures nest deeper than the compiler's default allows.
#![recursion_limit = "256"]

mod alerts;
mod encryption;
mod login;
mod media;
mod rooms;
mod search;
mod timeline;

use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::pin::Pin;
use std::rc::{Rc, Weak};
use std::sync::Arc;

use greed_chat::protocol::{
    Account, AccountParams, AccountState, Hello, PROTOCOL, SecretParams, ServerParams,
};
use greed_chat::rpc::{self, Failure, Notifier, Service};
use greed_chat::why;
use matrix_sdk::authentication::matrix::MatrixSession;
use matrix_sdk::authentication::oauth::{ClientId, OAuthSession, UserSession};
use matrix_sdk::encryption::{BackupDownloadStrategy, EncryptionSettings};
use matrix_sdk::search_index::SearchIndexStoreKind;
use matrix_sdk::{AuthSession, Client, ClientBuilder, SessionChange};
use matrix_sdk_ui::sync_service::SyncService;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::broadcast::error::RecvError;

/// How long a sync is waited for to stop, at signing out.
const STOPPING: std::time::Duration = std::time::Duration::from_secs(2);

/// The Matrix service: the accounts signed in and the sign-ins going on.
pub struct Matrix {
    data: PathBuf,
    notifier: Notifier,
    /// For the tasks it starts, which end when it's gone.
    me: Weak<Matrix>,
    accounts: RefCell<BTreeMap<String, Signed>>,
    logins: RefCell<HashMap<String, login::Login>>,
    /// The timelines the client has open, by "account room".
    timelines: RefCell<HashMap<String, timeline::Open>>,
    /// Verifications of this device going on.
    verifications: RefCell<encryption::Verifications>,
}

/// A signed-in account.
struct Signed {
    client: Client,
    store: Store,
    name: Option<String>,
    state: AccountState,
    /// Its sync, once started.
    sync: Option<Arc<SyncService>>,
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
    session: Session,
}

/// An account's session: signed in with Matrix's own sign-in (a password,
/// single sign-on), or through OAuth with the client id it registered.
#[derive(Serialize, Deserialize)]
#[serde(tag = "auth", rename_all = "snake_case")]
enum Session {
    Matrix {
        session: MatrixSession,
    },
    #[serde(rename = "oauth")]
    OAuth {
        client_id: String,
        user: UserSession,
    },
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
            timelines: RefCell::default(),
            verifications: RefCell::default(),
        })
    }

    fn accounts(&self) -> Vec<Account> {
        self.accounts
            .borrow()
            .values()
            .map(Signed::account)
            .collect()
    }

    /// The client of account `account`.
    fn client_of(&self, account: &str) -> Result<Client, Failure> {
        self.accounts
            .borrow()
            .get(account)
            .map(|signed| signed.client.clone())
            .ok_or_else(|| Failure::new(format!("no account {account}")))
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
            .map_err(|e| Failure::new(format!("can't open the account's store: {}", why(&e))))?;
        let session: AuthSession = match secret.session {
            Session::Matrix { session } => session.into(),
            Session::OAuth { client_id, user } => OAuthSession {
                client_id: ClientId::new(client_id),
                user,
            }
            .into(),
        };
        client
            .restore_session(session)
            .await
            .map_err(|e| Failure::new(format!("can't restore the session: {}", why(&e))))?;
        Ok(self.signed_in(client, secret.store).await)
    }

    /// Takes on `client`, just signed in, starts syncing it, and says who
    /// it is.
    async fn signed_in(&self, client: Client, store: Store) -> Account {
        let name = client.account().get_display_name().await.ok().flatten();
        let signed = Signed {
            client: client.clone(),
            store,
            name,
            state: AccountState::Syncing,
            sync: None,
        };
        let id = signed.account().id;
        self.watch(&id, &client);
        self.hear_verifications(&id, &client);
        self.hear_alerts(&id, &client).await;
        self.accounts.borrow_mut().insert(id.clone(), signed);
        let sync = self.sync(&id, &client).await;
        let mut accounts = self.accounts.borrow_mut();
        let signed = accounts.get_mut(&id).expect("just taken on");
        signed.sync = sync;
        signed.account()
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
                match change {
                    SessionChange::TokensRefreshed => {
                        let secret = me
                            .accounts
                            .borrow()
                            .get(&id)
                            .and_then(|signed| secret(&signed.client, &signed.store));
                        if let Some(secret) = secret {
                            me.notifier.notify(
                                "account.secret",
                                &json!({ "account": id, "secret": secret }),
                            );
                        }
                    }
                    SessionChange::UnknownToken(_) => {
                        me.changed(
                            &id,
                            AccountState::Trouble("the server signed you out".into()),
                        );
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
        self.timelines
            .borrow_mut()
            .retain(|key, _| !key.starts_with(&format!("{id} ")));
        // Its sync is asked to stop, but not waited for long: stopping waits
        // for the sync's request in flight, which a server may hold open.
        // Ending the session below ends the sync anyway.
        if let Some(sync) = &signed.sync {
            let _ = tokio::time::timeout(STOPPING, sync.stop()).await;
        }
        let done = signed.client.logout().await;
        drop(signed.client);
        self.forget(&signed.store);
        done.map_err(|e| Failure::new(format!("signed out here, but the server said: {}", why(&e))))
    }

    /// A client keeping its state in `store`, refreshing its tokens.
    fn client(&self, store: &Store) -> ClientBuilder {
        Client::builder()
            .sqlite_store(self.data.join(&store.name), Some(&store.passphrase))
            .handle_refresh_tokens()
            // Cross-signing and a key backup set up after signing in, as
            // Element does; keys fetched from the backup as they're missing.
            .with_encryption_settings(EncryptionSettings {
                auto_enable_cross_signing: true,
                auto_enable_backups: true,
                backup_download_strategy: BackupDownloadStrategy::AfterDecryptionFailure,
            })
            // What it has seen, searchable, kept locked with the store's key.
            .search_index_store(SearchIndexStoreKind::EncryptedDirectory(
                self.data.join(&store.name).join("search"),
                store.passphrase.clone(),
            ))
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
            state: self.state.clone(),
        }
    }
}

/// The secret for `client`'s session in `store`, while it has one.
fn secret(client: &Client, store: &Store) -> Option<String> {
    let session = match client.session()? {
        AuthSession::Matrix(session) => Session::Matrix { session },
        AuthSession::OAuth(session) => Session::OAuth {
            client_id: session.client_id.as_str().to_string(),
            user: session.user,
        },
        _ => return None,
    };
    let secret = Secret {
        homeserver: client.homeserver().to_string(),
        store: store.clone(),
        session,
    };
    serde_json::to_string(&secret).ok()
}

impl Service for Matrix {
    fn call(&self, method: &str, params: Value) -> impl Future<Output = Result<Value, Failure>> {
        // Boxed and unnamed: the futures matrix-sdk makes nest too deep for
        // the crates awaiting this to work out.
        let method = method.to_string();
        let answer: Pin<Box<dyn Future<Output = _> + '_>> =
            Box::pin(async move { self.handle(&method, params).await });
        answer
    }
}

impl Matrix {
    async fn handle(&self, method: &str, params: Value) -> Result<Value, Failure> {
        match method {
            "hello" => Ok(json!(Hello {
                protocol: PROTOCOL,
                service: "matrix".into(),
                version: env!("CARGO_PKG_VERSION").into(),
                can: ["threads", "encryption", "receipts", "previews", "polls"]
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
            "rooms" => {
                let AccountParams { account } = rpc::parse(params)?;
                let rooms = self.rooms(&account).await;
                rooms
                    .map(|rooms| json!(rooms))
                    .ok_or_else(|| Failure::new(format!("no account {account}")))
            }
            "timeline" => self.open_timeline(&rpc::parse(params)?).await,
            "timeline.back" => self.back(&rpc::parse(params)?).await,
            "timeline.close" => {
                self.close_timeline(&rpc::parse(params)?);
                Ok(Value::Null)
            }
            "send" => {
                self.send(&rpc::parse(params)?).await?;
                Ok(Value::Null)
            }
            "edit" => self.edit(&rpc::parse(params)?).await.map(|()| Value::Null),
            "redact" => self
                .redact(&rpc::parse(params)?)
                .await
                .map(|()| Value::Null),
            "react" => self.react(&rpc::parse(params)?).await.map(|()| Value::Null),
            "vote" => self.vote(&rpc::parse(params)?).await.map(|()| Value::Null),
            "read" => self.read(&rpc::parse(params)?).await.map(|()| Value::Null),
            "typing" => self
                .typing(&rpc::parse(params)?)
                .await
                .map(|()| Value::Null),
            "media.get" => self.media_get(&rpc::parse(params)?).await,
            "preview" => Ok(json!(self.preview(&rpc::parse(params)?).await?)),
            "search" => Ok(json!(self.search(&rpc::parse(params)?).await?)),
            "join" => self.join(&rpc::parse(params)?).await,
            "leave" => self.leave(&rpc::parse(params)?).await.map(|()| Value::Null),
            "directory" => Ok(json!(self.directory(&rpc::parse(params)?).await?)),
            "upload" => self
                .upload(&rpc::parse(params)?)
                .await
                .map(|()| Value::Null),
            "encryption.state" => self.encryption_state(&rpc::parse(params)?).await,
            "encryption.setup" => self.encryption_setup(&rpc::parse(params)?).await,
            "encryption.recover" => self
                .encryption_recover(&rpc::parse(params)?)
                .await
                .map(|()| Value::Null),
            "verify.start" => self.verify_start(&rpc::parse(params)?).await,
            "verify.accept" => self
                .verify_accept(&rpc::parse(params)?)
                .await
                .map(|()| Value::Null),
            "verify.confirm" => self
                .verify_confirm(&rpc::parse(params)?)
                .await
                .map(|()| Value::Null),
            "verify.cancel" => self
                .verify_cancel(&rpc::parse(params)?)
                .await
                .map(|()| Value::Null),
            _ => Err(Failure::unknown(method)),
        }
    }
}
