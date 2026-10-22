//! The protocol Greed's chat client speaks with every service: the objects
//! it shows and the steps of signing in. Every object has an id that stays
//! the same across restarts; a service fills in what it has and leaves the
//! rest out.
//!
//! Requests every service answers: `hello`, `accounts`, `restore`,
//! `login.methods`, `login.start`, `login.answer`, `login.cancel`, `logout`,
//! `rooms`, `timeline`, `timeline.back`, `timeline.close`, `send`, `edit`,
//! `redact`, `react`, `read`, `typing`, `media.get`, `upload`, `search`,
//! `join` (a room by its id or address, or an invite), `leave` (or decline
//! an invite) and `directory` (rooms you could join).
//! Those that can ("commands" in `hello`) also answer `commands` and
//! `press`: a `send` starting with `/` runs a command, and a message's
//! `actions` are pressed or picked from. With "previews", `preview` says
//! what a link leads to; others give a message's `preview` with it.
//! Notifications: `account.changed`, `account.secret`, `rooms.changed`,
//! `timeline.changed`, `typing.changed`, `login.step`, `alert`.
//!
//! `alert` is an `Alert`: a new message for you, as the service decides by
//! your settings there (a mention, a direct message, a keyword), for the
//! client to tell you about.
//!
//! Rooms: `rooms {account}` answers the account's rooms, and
//! `rooms.changed {account}` says to ask again. A timeline: `timeline
//! {account, room, thread?}` answers `{items}` and keeps it open, sending
//! `timeline.changed {account, room, thread, changes}` until
//! `timeline.close`; `timeline.back` fetches older items into it,
//! answering whether there are more. While a room's timeline is open,
//! `typing.changed {account, room, who}` names who's writing.
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
    /// For a direct message: whether the other person is "online", "away",
    /// "dnd" or "offline", where the service says.
    #[serde(default)]
    pub presence: Option<String>,
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

/// A new message for you, sent as `alert`.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Alert {
    pub account: String,
    pub room: String,
    /// The room's name, as the list shows it.
    pub room_name: String,
    /// The message's id, to go to it.
    pub event: String,
    pub sender: Person,
    /// The message's text, or what it is ("sent a picture").
    pub body: String,
    /// Whether it names you, outside a direct message.
    pub mention: bool,
    /// Whether it's in a direct message, with one person or several.
    pub direct: bool,
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
    /// Who has read up to here, as far as the service says (Matrix).
    #[serde(default)]
    pub read_by: Vec<Person>,
    /// The file it carries, for a picture, a file and the like.
    #[serde(default)]
    pub media: Option<Media>,
    /// Where the message opens in the service's own app or web client, as
    /// for joining a call there.
    #[serde(default)]
    pub link: Option<String>,
    /// Buttons and menus an integration put in it, pressed with `press`.
    #[serde(default)]
    pub actions: Vec<Action>,
    /// What its first link leads to, where the service gives it with the
    /// message (Mattermost).
    #[serde(default)]
    pub preview: Option<Preview>,
}

/// A button or menu in a message.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Action {
    pub id: String,
    pub name: String,
    /// What's picked from, for a menu; none for a button.
    #[serde(default)]
    pub options: Vec<Choice>,
}

/// One thing a menu offers.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Choice {
    pub text: String,
    pub value: String,
}

/// A command `commands` lists, run by sending `/trigger`.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Command {
    pub trigger: String,
    /// What follows it, like "[message]".
    pub hint: String,
    pub description: String,
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

/// A file a message carries: a picture, a video, a recording or any file.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Media {
    pub name: String,
    /// Its type, like `image/png`.
    pub mime: String,
    pub size: Option<u64>,
    /// A picture's or video's size in pixels.
    pub width: Option<u64>,
    pub height: Option<u64>,
    /// Whether there's a small picture of it (`media.get` with `thumbnail`).
    pub thumbnail: bool,
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

/// `timeline`, `timeline.back`, `timeline.close`, `read` and `typing`'s
/// parameters. With `thread`, by its first message's `event`, the timeline
/// is that thread's; without, the room's, which shows each thread's first
/// message with how many replies it has. `on` is for `typing`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RoomParams {
    pub account: String,
    pub room: String,
    #[serde(default)]
    pub thread: Option<String>,
    #[serde(default)]
    pub on: bool,
}

/// `preview`'s parameters: a link in a message in `room`. Answers a
/// `Preview`, or null where there's none or it isn't asked for (an
/// encrypted room, whose links the server shouldn't learn).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PreviewParams {
    pub account: String,
    pub room: String,
    pub url: String,
}

/// What a link leads to, as the page says of itself.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Preview {
    pub url: String,
    pub title: Option<String>,
    pub description: Option<String>,
    /// The site's name, like "GitHub".
    pub site: Option<String>,
}

impl Preview {
    /// The preview of `url` from what a server says of the page: its title,
    /// description and site under the names `names` gives. None when it
    /// has neither a title nor a description.
    pub fn from_page(url: &str, page: &serde_json::Value, names: [&str; 3]) -> Option<Self> {
        let field = |name: &str| {
            page[name]
                .as_str()
                .map(str::trim)
                .filter(|text| !text.is_empty())
                .map(str::to_string)
        };
        let [title, description, site] = names;
        let preview = Self {
            url: url.to_string(),
            title: field(title),
            description: field(description),
            site: field(site),
        };
        (preview.title.is_some() || preview.description.is_some()).then_some(preview)
    }
}

/// `media.get`'s parameters: the message's file, or with `thumbnail` a
/// small picture of it, fetched to where it can be opened; answers `{path}`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaParams {
    pub account: String,
    pub room: String,
    pub event: String,
    #[serde(default)]
    pub thumbnail: bool,
}

/// `upload`'s parameters: the file at `path` sent to the room, or into
/// `thread`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UploadParams {
    pub account: String,
    pub room: String,
    pub path: String,
    #[serde(default)]
    pub thread: Option<String>,
}

/// `edit`, `redact` and `react`'s parameters: the message by its `event`,
/// and the new `text` (Markdown) or the reaction's `key` (an emoji, or a
/// Mattermost emoji's name).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MessageParams {
    pub account: String,
    pub room: String,
    pub event: String,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub key: String,
}

/// A room `directory` lists, one you can join.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Listed {
    /// What `join` takes: its id.
    pub id: String,
    pub name: String,
    pub topic: Option<String>,
    /// How many have joined it, where the service says.
    pub members: Option<u64>,
    /// Its address, where it has one (`#garden:example.org`), or the team
    /// it's in (Mattermost).
    pub address: Option<String>,
}

/// `directory`'s parameters: the words its rooms' names or topics have.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DirectoryParams {
    pub account: String,
    #[serde(default)]
    pub query: String,
}

/// `search`'s parameters: the words to find, in `room` or else everywhere.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchParams {
    pub account: String,
    pub query: String,
    #[serde(default)]
    pub room: Option<String>,
}

/// A message `search` found, newest first: where, and the message.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Found {
    pub room: String,
    pub room_name: String,
    pub item: Item,
}

/// `press`'s parameters: the message's `action`, and for a menu the
/// `option` picked, by its value.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PressParams {
    pub account: String,
    pub room: String,
    pub event: String,
    pub action: String,
    #[serde(default)]
    pub option: Option<String>,
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
