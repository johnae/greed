//! The protocol Greed's chat client speaks with every service: the objects
//! it shows and the steps of signing in. Every object has an id that stays
//! the same across restarts; a service fills in what it has and leaves the
//! rest out.
//!
//! Requests every service answers: `hello`, `accounts`, `restore`,
//! `login.methods`, `login.start`, `login.answer`, `login.cancel`, `logout`,
//! `rooms`, `timeline`, `timeline.back`, `timeline.close`, `send`.
//! Notifications: `account.changed`, `account.secret`, `rooms.changed`,
//! `timeline.changed`, `login.step`.
//!
//! Rooms: `rooms {account}` answers the account's rooms, and
//! `rooms.changed {account}` says to ask again. A timeline: `timeline
//! {account, room}` answers `{items}` and keeps it open, sending
//! `timeline.changed {account, room, changes}` until `timeline.close`;
//! `timeline.back` fetches older items into it, answering whether there are
//! more.
//!
//! Signing in: `login.start {server, method}` answers `{login, step}`, the
//! first `Step`; `login.answer {login, values}` answers the next one, until
//! `Done` or `Failed`. Steps that wait on something else, like the browser
//! coming back, arrive as `login.step {login, step}`. `Done` carries the
//! account's secret (its tokens and its store's key), which the client keeps
//! in the keyring and hands back with `restore {secret}` the next time. A
//! service keeps no secrets itself, and sends `account.secret {account,
//! secret}` when they change, as when tokens are refreshed.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

/// What the protocol is at: a client and a service that disagree say so,
/// and which to update, rather than misreading each other.
pub const PROTOCOL: u32 = 1;

/// What `hello` answers.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Hello {
    pub protocol: u32,
    /// "matrix", "mattermost".
    pub service: String,
    pub version: String,
    /// What this service can do beyond what every one does, like
    /// "threads", "encryption", "slash-commands", "polls".
    pub can: Vec<String>,
}

/// A signed-in account, or one signing in.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Account {
    /// The service's own id for you: `@sam:example.org`, or the server and
    /// user id for Mattermost.
    pub id: String,
    pub server: String,
    pub name: Option<String>,
    pub state: AccountState,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case", tag = "state", content = "why")]
pub enum AccountState {
    /// Catching up, the first time or after being away.
    Syncing,
    /// Up to date, and kept so.
    Ready,
    /// Can't reach the server or was signed out; the why says which.
    Trouble(String),
}

/// A way to sign in that a server offers.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case", tag = "kind")]
pub enum Method {
    /// Name and password (and a code where the server asks for one).
    Password,
    /// Through the browser: SSO, `OpenID` Connect, OAuth. `name` is what the
    /// server calls it ("evroc Keycloak").
    Browser { id: String, name: String },
    /// A code to enter on another device's browser (OAuth device grant).
    DeviceCode,
    /// A QR code shown by a device that's signed in already.
    Qr,
}

/// What signing in needs from you next, sent as `login.step` and answered
/// with `login.answer`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case", tag = "step")]
pub enum Step {
    /// Fill these in (`name`, `password`, `code`...); secret ones aren't
    /// shown. `why` says what was wrong with the last answers.
    Ask {
        fields: Vec<Field>,
        why: Option<String>,
    },
    /// Open this in the browser. When it comes back by itself, the next
    /// step arrives as `login.step`; where it can't (over ssh, or with no
    /// URL handler), `paste` says what link to paste, the answer's `link`.
    Open { url: String, paste: Option<String> },
    /// Go to `url` on any device and enter `code`.
    Code { url: String, code: String },
    /// Show this as a QR code for another device to scan, or scan its.
    Qr { data: String },
    /// Compare these with the other device (emoji verification).
    Compare { emoji: Vec<(String, String)> },
    /// Signed in. `secret` is for the keyring, and `restore`.
    Done { account: Account, secret: String },
    /// It didn't work; why.
    Failed { why: String },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Field {
    pub name: String,
    pub label: String,
    pub secret: bool,
}

impl Field {
    /// A field that shows what's typed.
    pub fn text(name: &str, label: &str) -> Self {
        Self {
            name: name.into(),
            label: label.into(),
            secret: false,
        }
    }

    /// A field that shows dots, for passwords.
    pub fn secret(name: &str, label: &str) -> Self {
        Self {
            secret: true,
            ..Self::text(name, label)
        }
    }
}

/// A room, channel or direct message.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Room {
    pub id: String,
    pub account: String,
    pub name: String,
    pub kind: RoomKind,
    pub topic: Option<String>,
    /// The space or team it's in, by id.
    pub parent: Option<String>,
    pub unread: u64,
    /// Messages that mention you or are otherwise for you.
    pub mentions: u64,
    pub favourite: bool,
    pub muted: bool,
    pub encrypted: bool,
    /// When something last happened in it, in milliseconds since 1970.
    pub active: Option<i64>,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RoomKind {
    #[default]
    Room,
    /// A direct message with one person.
    Direct,
    /// A direct message with several.
    Group,
    /// A space or team, holding rooms.
    Space,
    /// Asked to join, not joined yet.
    Invite,
}

/// Someone, as a message shows them.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Person {
    pub id: String,
    pub name: String,
    /// Media id of their picture.
    pub avatar: Option<String>,
}

/// An item in a room's timeline: a message, or something that happened.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Item {
    /// The item's id in the timeline, which stays the same from sending to
    /// sent and for things that aren't messages (a day starting).
    pub id: String,
    /// The server's id for the message once it has one: what replies,
    /// reactions and links name.
    pub event: Option<String>,
    pub sender: Person,
    /// Milliseconds since 1970.
    pub at: i64,
    pub kind: ItemKind,
    /// The message as Markdown, as written or turned from HTML.
    pub text: String,
    pub reply_to: Option<String>,
    /// The thread it's in, by its first message's id.
    pub thread: Option<String>,
    /// Replies in the thread it starts.
    pub replies: u64,
    pub reactions: Vec<Reaction>,
    pub edited: bool,
    pub mine: bool,
    pub sending: Option<Sending>,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ItemKind {
    #[default]
    Message,
    Notice,
    Emote,
    Image,
    File,
    Audio,
    Video,
    Sticker,
    Poll,
    Location,
    /// The room changed: name, members, settings.
    Change,
    Call,
    Deleted,
    /// Encrypted, and the key isn't here (yet).
    Unreadable,
    /// A new day starts here (`at`).
    Day,
    /// What's after this you haven't read.
    ReadMarker,
    /// The room's very first item: nothing comes before it.
    Start,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Reaction {
    pub key: String,
    pub count: u64,
    pub mine: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case", tag = "state", content = "why")]
pub enum Sending {
    Sending,
    Failed(String),
}

/// A change to a room's timeline, as `timeline.changed` sends them in
/// order: the client applies each to the items it shows.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case", tag = "op")]
pub enum Change {
    /// Everything at once, as when a timeline opens.
    Reset {
        items: Vec<Item>,
    },
    Insert {
        at: usize,
        item: Item,
    },
    Set {
        at: usize,
        item: Item,
    },
    Remove {
        at: usize,
    },
    /// Only the first `len` items stay.
    Truncate {
        len: usize,
    },
    Clear,
}

/// `login.methods`'s parameters.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerParams {
    pub server: String,
}

/// `login.start`'s parameters.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Start {
    pub server: String,
    pub method: Method,
}

/// `login.answer`'s parameters: the values of the fields asked for.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Answer {
    pub login: String,
    #[serde(default)]
    pub values: HashMap<String, String>,
}

impl Answer {
    /// The value of field `name`, empty when it wasn't given.
    pub fn value(&self, name: &str) -> &str {
        self.values.get(name).map_or("", String::as_str)
    }
}

/// `login.cancel`'s parameters.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoginParams {
    pub login: String,
}

/// `restore`'s parameters.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SecretParams {
    pub secret: String,
}

/// `logout`'s parameters.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountParams {
    pub account: String,
}

/// `timeline`, `timeline.back` and `timeline.close`'s parameters.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RoomParams {
    pub account: String,
    pub room: String,
}

/// `send`'s parameters: `text` is Markdown; `reply_to` and `thread`
/// name messages by their `event`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SendParams {
    pub account: String,
    pub room: String,
    pub text: String,
    #[serde(default)]
    pub reply_to: Option<String>,
    #[serde(default)]
    pub thread: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn steps_and_states_read_as_the_client_expects() {
        let step = Step::Open {
            url: "https://mm.example.com/oauth/openid/login".into(),
            paste: Some("the mattermost:// link".into()),
        };
        assert_eq!(
            serde_json::to_value(&step).unwrap(),
            json!({ "step": "open", "url": "https://mm.example.com/oauth/openid/login", "paste": "the mattermost:// link" })
        );
        let state = AccountState::Trouble("signed out".into());
        assert_eq!(
            serde_json::to_value(&state).unwrap(),
            json!({ "state": "trouble", "why": "signed out" })
        );
        let method = Method::Browser {
            id: "openid".into(),
            name: "evroc Keycloak".into(),
        };
        assert_eq!(
            serde_json::to_value(&method).unwrap(),
            json!({ "kind": "browser", "id": "openid", "name": "evroc Keycloak" })
        );
        let change: Change = serde_json::from_value(json!({ "op": "remove", "at": 3 })).unwrap();
        assert_eq!(change, Change::Remove { at: 3 });
    }
}
