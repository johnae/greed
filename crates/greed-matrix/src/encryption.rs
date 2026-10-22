//! Encrypted rooms: the recovery key that unlocks the keys kept on the
//! server (so older messages decrypt), setting that up for an account that
//! hasn't, and verifying this device against another of yours by comparing
//! emoji. Cross-signing and key backup themselves are set up by
//! matrix-sdk after signing in.

use std::collections::HashMap;

use futures_util::StreamExt;
use greed_chat::protocol::AccountParams;
use greed_chat::rpc::Failure;
use matrix_sdk::Client;
use matrix_sdk::encryption::recovery::RecoveryState;
use matrix_sdk::encryption::verification::{
    SasState, SasVerification, Verification, VerificationRequest, VerificationRequestState,
};
use matrix_sdk::ruma::events::AnyToDeviceEvent;
use matrix_sdk::ruma::serde::Raw;
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::mpsc;

use crate::Matrix;

/// `encryption.recover`'s parameters.
#[derive(Deserialize)]
pub(crate) struct RecoverParams {
    account: String,
    key: String,
}

/// `verify.accept`, `verify.confirm` and `verify.cancel`'s parameters:
/// the verification by `id`, and for `verify.confirm` whether the emoji
/// were the same on both devices.
#[derive(Deserialize)]
pub(crate) struct VerifyParams {
    account: String,
    id: String,
    #[serde(default)]
    same: bool,
}

/// Verifications going on, by "account id": the request, and its emoji
/// comparison once it has one.
#[derive(Default)]
pub(crate) struct Verifications {
    requests: HashMap<String, VerificationRequest>,
    comparing: HashMap<String, SasVerification>,
}

fn state_name(state: RecoveryState) -> &'static str {
    match state {
        RecoveryState::Enabled => "enabled",
        RecoveryState::Disabled => "disabled",
        RecoveryState::Incomplete => "incomplete",
        RecoveryState::Unknown => "unknown",
    }
}

impl Matrix {
    fn request_of(&self, params: &VerifyParams) -> Option<VerificationRequest> {
        self.verifications
            .borrow()
            .requests
            .get(&format!("{} {}", params.account, params.id))
            .cloned()
    }

    /// How an account's encryption stands: `{recovery, verified}`, whether
    /// its keys are kept on the server with a recovery key ("enabled", or
    /// "incomplete" when this device hasn't the key yet) and whether this
    /// device is verified.
    pub(crate) async fn encryption_state(&self, params: &AccountParams) -> Result<Value, Failure> {
        let client = self.client_of(&params.account)?;
        let encryption = client.encryption();
        encryption.wait_for_e2ee_initialization_tasks().await;
        let verified = match encryption.get_own_device().await {
            Ok(Some(device)) => device.is_cross_signed_by_owner(),
            _ => false,
        };
        let recovery = state_name(encryption.recovery().state());
        Ok(json!({ "recovery": recovery, "verified": verified }))
    }

    /// Keeps the account's keys on the server, locked by a new recovery key:
    /// `{key}`, for you to write down.
    pub(crate) async fn encryption_setup(&self, params: &AccountParams) -> Result<Value, Failure> {
        let client = self.client_of(&params.account)?;
        let recovery = client.encryption().recovery();
        if recovery.state() == RecoveryState::Enabled {
            return Err(Failure::new(
                "this account has a recovery key already: enter it with :chat-recover",
            ));
        }
        let key = recovery
            .enable()
            .await
            .map_err(|e| Failure::new(format!("can't set it up: {e}")))?;
        Ok(json!({ "key": key }))
    }

    /// Unlocks the account's keys kept on the server with its recovery key,
    /// so older messages decrypt and this device is verified.
    pub(crate) async fn encryption_recover(&self, params: &RecoverParams) -> Result<(), Failure> {
        let client = self.client_of(&params.account)?;
        client
            .encryption()
            .recovery()
            .recover(params.key.trim())
            .await
            .map_err(|e| Failure::new(format!("that key didn't unlock it: {e}")))
    }

    /// Asks your other devices to verify this one: `{id}`; what follows
    /// comes as `verify.changed`.
    pub(crate) async fn verify_start(&self, params: &AccountParams) -> Result<Value, Failure> {
        let client = self.client_of(&params.account)?;
        let me = client
            .user_id()
            .ok_or_else(|| Failure::new("not signed in"))?
            .to_owned();
        let identity = client
            .encryption()
            // Asked of the server: a device just signed in may not have
            // heard of its account's identity yet.
            .request_user_identity(&me)
            .await
            .map_err(|e| Failure::new(e.to_string()))?
            .ok_or_else(|| {
                Failure::new("this account has no other verified device to verify with")
            })?;
        let request = identity
            .request_verification()
            .await
            .map_err(|e| Failure::new(format!("can't ask: {e}")))?;
        let id = request.flow_id().to_string();
        self.follow_request(&params.account, request);
        Ok(json!({ "id": id }))
    }

    /// Accepts another device's asking to verify this one.
    pub(crate) async fn verify_accept(&self, params: &VerifyParams) -> Result<(), Failure> {
        let request = self
            .request_of(params)
            .ok_or_else(|| Failure::new("that verification is over"))?;
        request
            .accept()
            .await
            .map_err(|e| Failure::new(format!("can't accept it: {e}")))
    }

    /// Says whether the emoji were the same on both devices: verifying this
    /// one if they were, calling it off if not.
    pub(crate) async fn verify_confirm(&self, params: &VerifyParams) -> Result<(), Failure> {
        let sas = self
            .verifications
            .borrow()
            .comparing
            .get(&format!("{} {}", params.account, params.id))
            .cloned()
            .ok_or_else(|| Failure::new("that verification has nothing to compare"))?;
        let done = if params.same {
            sas.confirm().await
        } else {
            sas.mismatch().await
        };
        done.map_err(|e| Failure::new(e.to_string()))
    }

    /// Calls a verification off.
    pub(crate) async fn verify_cancel(&self, params: &VerifyParams) -> Result<(), Failure> {
        if let Some(request) = self.request_of(params) {
            request
                .cancel()
                .await
                .map_err(|e| Failure::new(e.to_string()))?;
        }
        Ok(())
    }

    /// Hears your other devices asking to verify this one, for account `id`.
    pub(crate) fn hear_verifications(&self, id: &str, client: &Client) {
        // The handler runs where matrix-sdk calls it; it hands the request
        // over to this thread.
        let (asked, mut asks) = mpsc::unbounded_channel();
        let handle = client.clone();
        client.add_event_handler(
            // The client held, not asked for as the handler's context: a
            // handler asking for it isn't called for to-device events
            // (matrix-sdk 0.19).
            move |event: Raw<AnyToDeviceEvent>| {
                let asked = asked.clone();
                let client = handle.clone();
                async move {
                    let Ok(AnyToDeviceEvent::KeyVerificationRequest(event)) = event.deserialize()
                    else {
                        return;
                    };
                    if let Some(request) = client
                        .encryption()
                        .get_verification_request(&event.sender, &event.content.transaction_id)
                        .await
                    {
                        let _ = asked.send(request);
                    }
                }
            },
        );
        let me = self.me.clone();
        let account = id.to_string();
        tokio::task::spawn_local(async move {
            while let Some(request) = asks.recv().await {
                let Some(this) = me.upgrade() else { break };
                let id = request.flow_id().to_string();
                let device = match request.state() {
                    VerificationRequestState::Requested {
                        other_device_data, ..
                    } => other_device_data
                        .display_name()
                        .map_or_else(|| other_device_data.device_id().to_string(), str::to_string),
                    _ => String::new(),
                };
                this.verify_said(&account, &id, json!({ "state": "asked", "from": device }));
                this.follow_request(&account, request);
            }
        });
    }

    fn verify_said(&self, account: &str, id: &str, mut about: Value) {
        about["account"] = json!(account);
        about["id"] = json!(id);
        self.notifier.notify("verify.changed", &about);
    }

    /// Follows a verification request through to comparing emoji and its
    /// end, saying each step as `verify.changed`.
    fn follow_request(&self, account: &str, request: VerificationRequest) {
        let key = format!("{account} {}", request.flow_id());
        self.verifications
            .borrow_mut()
            .requests
            .insert(key.clone(), request.clone());
        let me = self.me.clone();
        let account = account.to_string();
        tokio::task::spawn_local(async move {
            let id = request.flow_id().to_string();
            let mut changes = request.changes();
            while let Some(state) = changes.next().await {
                let Some(this) = me.upgrade() else { return };
                match state {
                    VerificationRequestState::Ready { .. } if request.we_started() => {
                        if let Ok(Some(sas)) = request.start_sas().await {
                            this.follow_sas(&account, &id, sas);
                        }
                    }
                    VerificationRequestState::Transitioned {
                        verification: Verification::SasV1(sas),
                    } if !sas.we_started() => {
                        let _ = sas.accept().await;
                        this.follow_sas(&account, &id, sas);
                    }
                    VerificationRequestState::Done => {
                        this.verify_said(&account, &id, json!({ "state": "done" }));
                        break;
                    }
                    VerificationRequestState::Cancelled(info) => {
                        let why = info.reason().to_string();
                        this.verify_said(
                            &account,
                            &id,
                            json!({ "state": "cancelled", "why": why }),
                        );
                        break;
                    }
                    _ => {}
                }
            }
            if let Some(this) = me.upgrade() {
                let mut verifications = this.verifications.borrow_mut();
                verifications.requests.remove(&key);
                verifications.comparing.remove(&key);
            }
        });
    }

    /// Follows the emoji comparison of verification `id`.
    fn follow_sas(&self, account: &str, id: &str, sas: SasVerification) {
        let key = format!("{account} {id}");
        self.verifications
            .borrow_mut()
            .comparing
            .insert(key, sas.clone());
        let me = self.me.clone();
        let (account, id) = (account.to_string(), id.to_string());
        tokio::task::spawn_local(async move {
            let mut changes = sas.changes();
            while let Some(state) = changes.next().await {
                let Some(this) = me.upgrade() else { return };
                match state {
                    SasState::KeysExchanged { .. } => {
                        let emoji: Vec<Value> = sas
                            .emoji()
                            .map(|all| {
                                all.iter()
                                    .map(|e| json!([e.symbol, e.description]))
                                    .collect()
                            })
                            .unwrap_or_default();
                        this.verify_said(
                            &account,
                            &id,
                            json!({ "state": "compare", "emoji": emoji }),
                        );
                    }
                    SasState::Done { .. } | SasState::Cancelled(_) => break,
                    _ => {}
                }
            }
        });
    }
}
