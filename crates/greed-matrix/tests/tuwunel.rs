//! greed-matrix against a real homeserver: Tuwunel, started for each test in
//! a folder of its own. Skipped, saying so, when there's no `tuwunel` (devenv
//! has it; `GREED_MATRIX_TUWUNEL` names another).

use std::net::TcpStream;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::rc::Rc;
use std::time::{Duration, Instant};

use greed_chat::rpc::{self, Service};
use greed_chat::testing::{browse, find, free_port, heard, item_with, oauth_provider};
use greed_matrix::Matrix;
use matrix_sdk::Client;
use matrix_sdk::ruma::api::client::account::register;
use matrix_sdk::ruma::api::client::uiaa::{AuthData, RegistrationToken};
use serde_json::{Value, json};

/// A Tuwunel running for one test, stopped when dropped.
struct Tuwunel {
    child: Child,
    port: u16,
    dir: PathBuf,
}

impl Tuwunel {
    /// Starts one, signing in through `provider` too when given, or None
    /// when there's no Tuwunel to start.
    fn start(name: &str, provider: Option<&str>) -> Option<Tuwunel> {
        let program = std::env::var_os("GREED_MATRIX_TUWUNEL")
            .map(PathBuf::from)
            .or_else(|| find("tuwunel"));
        let Some(program) = program else {
            eprintln!("skipped: no tuwunel on PATH (devenv has it)");
            return None;
        };
        let dir = std::env::temp_dir().join(format!("gx-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let port = free_port();
        let provider = provider.map_or_else(String::new, |at| {
            format!(
                r#"
[[global.identity_provider]]
brand = "custom"
name = "Bea's provider"
client_id = "greed"
client_secret = "secret"
issuer_url = "{at}"
callback_url = "http://127.0.0.1:{port}/_matrix/client/unstable/login/sso/callback/greed"

[global.well_known]
client = "http://127.0.0.1:{port}"
"#
            )
        });
        let config = format!(
            r#"[global]
server_name = "localhost"
database_path = "{db}"
address = ["127.0.0.1"]
port = {port}
allow_registration = true
registration_token = "greed"
allow_federation = false
allow_check_for_updates = false
startup_netburst = false
log = "warn"
# Link previews, of pages tests serve here.
url_preview_domain_contains_allowlist = ["*"]
ip_range_denylist = []
{provider}"#,
            db = dir.join("db").display()
        );
        std::fs::write(dir.join("tuwunel.toml"), config).unwrap();
        let log = std::fs::File::create(dir.join("log")).unwrap();
        let child = Command::new(program)
            .arg("-c")
            .arg(dir.join("tuwunel.toml"))
            .stdout(Stdio::null())
            .stderr(log)
            .spawn()
            .unwrap();
        let tuwunel = Tuwunel { child, port, dir };
        let started = Instant::now();
        while TcpStream::connect(("127.0.0.1", port)).is_err() {
            assert!(
                started.elapsed() < Duration::from_secs(20),
                "tuwunel didn't start: {}",
                std::fs::read_to_string(tuwunel.dir.join("log")).unwrap_or_default()
            );
            std::thread::sleep(Duration::from_millis(50));
        }
        Some(tuwunel)
    }

    fn url(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }

    /// Makes an account `user` with `password`, through the registration
    /// token every test server has.
    async fn register(&self, user: &str, password: &str) {
        let client = Client::builder()
            .homeserver_url(self.url())
            .build()
            .await
            .unwrap();
        let mut request = register::v3::Request::new();
        request.username = Some(user.into());
        request.password = Some(password.into());
        request.inhibit_login = true;
        // The server can be up before it takes registrations; it's asked
        // again for a while.
        let mut session = None;
        let mut said = String::new();
        for _ in 0..50 {
            match client.matrix_auth().register(request.clone()).await {
                Ok(_) => return,
                Err(e) => match e.as_uiaa_response().and_then(|info| info.session.clone()) {
                    Some(asked) => {
                        session = Some(asked);
                        break;
                    }
                    None => said = e.to_string(),
                },
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        let session = session.unwrap_or_else(|| panic!("can't register {user}: {said}"));
        let mut token = RegistrationToken::new("greed".into());
        token.session = Some(session);
        request.auth = Some(AuthData::RegistrationToken(token));
        client.matrix_auth().register(request).await.unwrap();
    }
}

impl Drop for Tuwunel {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// Runs `test` on a runtime with a `LocalSet`, as `greed-matrix serve` does.
fn run(test: impl Future<Output = ()>) {
    greed_chat::program::run(test).unwrap();
}

async fn call(matrix: &Matrix, method: &str, params: Value) -> Value {
    match matrix.call(method, params).await {
        Ok(result) => result,
        Err(e) => panic!("{method}: {}", e.message),
    }
}

#[test]
fn signs_in_with_a_password_restores_and_signs_out() {
    let Some(server) = Tuwunel::start("password", None) else {
        return;
    };
    let data = server.dir.join("data");
    run(async {
        server.register("anna", "secret").await;
        let (notifier, _notices) = rpc::notifier();
        let matrix = Matrix::new(data.clone(), notifier);

        let methods = call(&matrix, "login.methods", json!({ "server": server.url() })).await;
        assert!(
            methods
                .as_array()
                .unwrap()
                .contains(&json!({ "kind": "password" })),
            "{methods}"
        );

        let started = call(
            &matrix,
            "login.start",
            json!({ "server": server.url(), "method": { "kind": "password" } }),
        )
        .await;
        let login = started["login"].clone();
        assert_eq!(started["step"]["step"], "ask", "{started}");

        let wrong = call(
            &matrix,
            "login.answer",
            json!({ "login": login, "values": { "user": "anna", "password": "nope" } }),
        )
        .await;
        assert_eq!(wrong["step"], "ask", "asked again: {wrong}");
        assert!(wrong["why"].is_string(), "saying why: {wrong}");

        let done = call(
            &matrix,
            "login.answer",
            json!({ "login": login, "values": { "user": "anna", "password": "secret" } }),
        )
        .await;
        assert_eq!(done["step"], "done", "{done}");
        assert_eq!(done["account"]["id"], "@anna:localhost");
        let secret = done["secret"].as_str().unwrap().to_string();
        assert!(!secret.contains("secret\""), "the password isn't kept");
        let accounts = call(&matrix, "accounts", Value::Null).await;
        assert_eq!(accounts[0]["id"], "@anna:localhost", "{accounts}");
        drop(matrix);

        // As after a restart: a new service, the same data folder.
        let (notifier, _notices) = rpc::notifier();
        let matrix = Matrix::new(data.clone(), notifier);
        assert_eq!(call(&matrix, "accounts", Value::Null).await, json!([]));
        let restored = call(&matrix, "restore", json!({ "secret": secret })).await;
        assert_eq!(restored["id"], "@anna:localhost", "{restored}");
        assert_eq!(
            restored["state"]["state"], "syncing",
            "until its sync is running"
        );

        call(&matrix, "logout", json!({ "account": "@anna:localhost" })).await;
        assert_eq!(call(&matrix, "accounts", Value::Null).await, json!([]));
        let stores = std::fs::read_dir(&data).unwrap().count();
        assert_eq!(stores, 0, "the store is gone with the account");
    });
}

#[test]
fn a_cancelled_sign_in_leaves_no_store() {
    let Some(server) = Tuwunel::start("cancel", None) else {
        return;
    };
    let data = server.dir.join("data");
    run(async {
        let (notifier, _notices) = rpc::notifier();
        let matrix = Matrix::new(data.clone(), notifier);
        let started = call(
            &matrix,
            "login.start",
            json!({ "server": server.url(), "method": { "kind": "password" } }),
        )
        .await;
        call(
            &matrix,
            "login.cancel",
            json!({ "login": started["login"] }),
        )
        .await;
        let left = std::fs::read_dir(&data).map_or(0, Iterator::count);
        assert_eq!(left, 0);
        let over = matrix
            .call(
                "login.answer",
                json!({ "login": started["login"], "values": {} }),
            )
            .await;
        assert!(over.is_err());
    });
}

/// Starts single sign-on with Tuwunel's provider, giving the sign-in's id
/// and the address to open.
async fn start_sso(matrix: &Matrix, server: &Tuwunel) -> (Value, String) {
    let methods = call(matrix, "login.methods", json!({ "server": server.url() })).await;
    let sso = methods
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["id"].as_str().is_some_and(|id| id.starts_with("sso")))
        .unwrap_or_else(|| panic!("no single sign-on in {methods}"))
        .clone();
    assert_eq!(sso["name"], "Bea's provider", "{sso}");
    let started = call(
        matrix,
        "login.start",
        json!({ "server": server.url(), "method": sso }),
    )
    .await;
    assert_eq!(started["step"]["step"], "open", "{started}");
    let url = started["step"]["url"].as_str().unwrap().to_string();
    (started["login"].clone(), url)
}

#[test]
fn signs_in_through_the_browser_coming_back_by_itself() {
    let provider = oauth_provider();
    let Some(server) = Tuwunel::start("sso", Some(&provider)) else {
        return;
    };
    let jar = server.dir.join("cookies");
    run(async {
        let (notifier, mut notices) = rpc::notifier();
        let matrix = Matrix::new(server.dir.join("data"), notifier);
        let (login, url) = start_sso(&matrix, &server).await;
        // The browser goes on its own; curl would hold up the listener.
        let browser = tokio::task::spawn_blocking(move || browse(&url, &jar, None));
        let notice = tokio::time::timeout(std::time::Duration::from_secs(30), notices.recv())
            .await
            .expect("the sign-in finishes")
            .unwrap();
        let notice: Value = serde_json::from_str(&notice).unwrap();
        assert_eq!(notice["method"], "login.step", "{notice}");
        assert_eq!(notice["params"]["login"], login);
        let step = &notice["params"]["step"];
        assert_eq!(step["step"], "done", "{step}");
        assert_eq!(step["account"]["id"], "@bea:localhost");
        browser.await.unwrap();
    });
}

#[test]
fn signs_in_through_the_browser_with_the_link_pasted() {
    let provider = oauth_provider();
    let Some(server) = Tuwunel::start("paste", Some(&provider)) else {
        return;
    };
    let jar = server.dir.join("cookies");
    run(async {
        let (notifier, _notices) = rpc::notifier();
        let matrix = Matrix::new(server.dir.join("data"), notifier);
        let (login, url) = start_sso(&matrix, &server).await;
        // As from another machine: the redirect to Greed goes nowhere.
        let loopback = greed_chat::loopback::query(&url)["redirectUrl"].clone();
        let link = tokio::task::spawn_blocking(move || browse(&url, &jar, Some(&loopback)))
            .await
            .unwrap();
        assert!(
            link.contains("loginToken="),
            "{link}: {}",
            std::fs::read_to_string(server.dir.join("log")).unwrap_or_default()
        );
        let done = call(
            &matrix,
            "login.answer",
            json!({ "login": login, "values": { "link": link } }),
        )
        .await;
        assert_eq!(done["step"], "done", "{done}");
        assert_eq!(done["account"]["id"], "@bea:localhost");
    });
}

/// A plain client signed in as `user`, for the other side of a test.
async fn other(server: &Tuwunel, user: &str, password: &str) -> Client {
    let client = Client::builder()
        .homeserver_url(server.url())
        .build()
        .await
        .unwrap();
    client
        .matrix_auth()
        .login_username(user, password)
        .send()
        .await
        .unwrap();
    client
}

/// Signs `user` in through the service with a password.
async fn sign_in(matrix: &Matrix, server: &Tuwunel, user: &str, password: &str) {
    let started = call(
        matrix,
        "login.start",
        json!({ "server": server.url(), "method": { "kind": "password" } }),
    )
    .await;
    let done = call(
        matrix,
        "login.answer",
        json!({ "login": started["login"], "values": { "user": user, "password": password } }),
    )
    .await;
    assert_eq!(done["step"], "done", "{done}");
}

/// Asks `method` again until its answer satisfies `wanted`, giving it.
async fn until(
    matrix: &Matrix,
    method: &str,
    params: &Value,
    wanted: impl Fn(&Value) -> bool,
) -> Value {
    for _ in 0..100 {
        if let Ok(answer) = matrix.call(method, params.clone()).await
            && wanted(&answer)
        {
            return answer;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("{method} {params} never came to what was wanted");
}

#[test]
fn lists_rooms_and_keeps_a_timeline() {
    use matrix_sdk::ruma::api::client::room::create_room;
    use matrix_sdk::ruma::events::room::message::RoomMessageEventContent;

    let Some(server) = Tuwunel::start("rooms", None) else {
        return;
    };
    run(async {
        server.register("anna", "secret").await;
        server.register("bea", "secret").await;
        let bea = other(&server, "bea", "secret").await;
        let mut request = create_room::v3::Request::new();
        request.name = Some("Plans".into());
        request.invite = vec!["@anna:localhost".try_into().unwrap()];
        let room = bea.create_room(request).await.unwrap();
        let room_id = room.room_id().to_string();

        let (notifier, mut notices) = rpc::notifier();
        let matrix = Matrix::new(server.dir.join("data"), notifier);
        sign_in(&matrix, &server, "anna", "secret").await;
        let anna = "@anna:localhost";

        // The invite shows once the sync brings it.
        let account = json!({ "account": anna });
        let rooms = until(&matrix, "rooms", &account, |rooms| {
            rooms
                .as_array()
                .unwrap()
                .iter()
                .any(|r| r["id"] == room_id.as_str())
        })
        .await;
        let invite = rooms
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["id"] == room_id.as_str())
            .unwrap();
        assert_eq!(invite["kind"], "invite", "{invite}");
        assert_eq!(invite["name"], "Plans");

        // Joined (from another client for now), it has a timeline.
        other(&server, "anna", "secret")
            .await
            .join_room_by_id(room.room_id())
            .await
            .unwrap();
        let params = json!({ "account": anna, "room": room_id });
        let opened = until(&matrix, "timeline", &params, |_| true).await;
        assert!(opened["items"].is_array(), "{opened}");

        bea.get_room(room.room_id())
            .unwrap()
            .send(RoomMessageEventContent::text_plain("lunch at noon?"))
            .await
            .unwrap();
        let changed = heard(&mut notices, |n| {
            n["method"] == "timeline.changed"
                && item_with(&n["params"]["changes"], "lunch at noon?").is_some()
        })
        .await;
        assert_eq!(changed["room"], room_id.as_str());
        let lunch = item_with(&changed["changes"], "lunch at noon?").unwrap();
        assert_eq!(lunch["sender"]["id"], "@bea:localhost");
        assert_eq!(lunch["mine"], false);
        let event = lunch["event"].as_str().unwrap().to_string();

        let reply =
            json!({ "account": anna, "room": room_id, "text": "**yes**", "reply_to": event });
        call(&matrix, "send", reply).await;
        let sent = heard(&mut notices, |n| {
            n["method"] == "timeline.changed"
                && item_with(&n["params"]["changes"], "**yes**")
                    .is_some_and(|yes| yes["sending"].is_null() && yes["event"].is_string())
        })
        .await;
        let yes = item_with(&sent["changes"], "**yes**").unwrap();
        assert_eq!(yes["mine"], true);
        assert_eq!(yes["reply_to"], event.as_str());

        call(&matrix, "timeline.close", params).await;
    });
}

/// Anna signed in through the service, and Bea (a plain client) in room
/// "Plans" with her: the service, its notifications, Bea, the room's id.
async fn plans(
    server: &Tuwunel,
) -> (
    Rc<Matrix>,
    tokio::sync::mpsc::UnboundedReceiver<String>,
    Client,
    String,
) {
    use matrix_sdk::ruma::api::client::room::create_room;

    server.register("anna", "secret").await;
    server.register("bea", "secret").await;
    let bea = other(server, "bea", "secret").await;
    let mut request = create_room::v3::Request::new();
    request.name = Some("Plans".into());
    request.invite = vec!["@anna:localhost".try_into().unwrap()];
    let room = bea.create_room(request).await.unwrap();
    other(server, "anna", "secret")
        .await
        .join_room_by_id(room.room_id())
        .await
        .unwrap();
    let (notifier, notices) = rpc::notifier();
    let matrix = Matrix::new(server.dir.join("data"), notifier);
    sign_in(&matrix, server, "anna", "secret").await;
    (matrix, notices, bea, room.room_id().to_string())
}

#[test]
fn reactions_edits_deleting_threads_typing_and_reading() {
    use matrix_sdk::ruma::events::room::message::RoomMessageEventContent;

    let Some(server) = Tuwunel::start("step4", None) else {
        return;
    };
    run(async {
        let (matrix, mut notices, bea, room_id) = plans(&server).await;
        let anna = "@anna:localhost";
        let params = json!({ "account": anna, "room": room_id });
        until(&matrix, "timeline", &params, |_| true).await;
        let bea_room = bea
            .get_room(&matrix_sdk::ruma::RoomId::parse(&room_id).unwrap())
            .unwrap();
        bea_room
            .send(RoomMessageEventContent::text_plain("lunch?"))
            .await
            .unwrap();
        let lunch = heard(&mut notices, |n| {
            n["method"] == "timeline.changed"
                && item_with(&n["params"]["changes"], "lunch?").is_some()
        })
        .await;
        let lunch = item_with(&lunch["changes"], "lunch?").unwrap();
        let lunch_event = lunch["event"].as_str().unwrap().to_string();
        assert!(
            lunch["link"]
                .as_str()
                .is_some_and(|link| link.starts_with("https://matrix.to/#/!")),
            "{lunch}"
        );
        let message = |event: &str| json!({ "account": anna, "room": room_id, "event": event });

        // A reaction, mine.
        let mut react = message(&lunch_event);
        react["key"] = json!("👍");
        call(&matrix, "react", react).await;
        heard(&mut notices, |n| {
            item_with(&n["params"]["changes"], "lunch?").is_some_and(|it| {
                it["reactions"][0]["key"] == "👍" && it["reactions"][0]["mine"] == true
            })
        })
        .await;

        // Sent, changed, then deleted.
        let send = json!({ "account": anna, "room": room_id, "text": "noon" });
        call(&matrix, "send", send).await;
        let noon = heard(&mut notices, |n| {
            item_with(&n["params"]["changes"], "noon").is_some_and(|it| it["event"].is_string())
        })
        .await;
        let noon_event = item_with(&noon["changes"], "noon").unwrap()["event"]
            .as_str()
            .unwrap()
            .to_string();
        let mut edit = message(&noon_event);
        edit["text"] = json!("one");
        call(&matrix, "edit", edit).await;
        heard(&mut notices, |n| {
            item_with(&n["params"]["changes"], "one").is_some_and(|it| it["edited"] == true)
        })
        .await;
        call(&matrix, "redact", message(&noon_event)).await;
        heard(&mut notices, |n| {
            n["params"]["changes"].as_array().is_some_and(|changes| {
                changes.iter().any(|c| {
                    c["item"]["event"] == noon_event.as_str() && c["item"]["kind"] == "deleted"
                })
            })
        })
        .await;

        // A reply in lunch's thread: the thread has it, the room counts it.
        let in_thread =
            json!({ "account": anna, "room": room_id, "text": "at one", "thread": lunch_event });
        call(&matrix, "send", in_thread).await;
        heard(&mut notices, |n| {
            n["params"]["thread"].is_null()
                && item_with(&n["params"]["changes"], "lunch?").is_some_and(|it| it["replies"] == 1)
        })
        .await;
        let thread = json!({ "account": anna, "room": room_id, "thread": lunch_event });
        let opened = until(&matrix, "timeline", &thread, |t| {
            t["items"]
                .as_array()
                .unwrap()
                .iter()
                .any(|it| it["text"] == "at one")
        })
        .await;
        assert!(opened["items"].is_array());

        writing_and_reading(&matrix, &mut notices, &bea_room, &room_id).await;
        call(&matrix, "read", params).await;
    });
}

/// Bea writing in the room shows; then Anna's message shows Bea read it.
async fn writing_and_reading(
    matrix: &Matrix,
    notices: &mut tokio::sync::mpsc::UnboundedReceiver<String>,
    bea_room: &matrix_sdk::Room,
    room_id: &str,
) {
    use matrix_sdk::ruma::api::client::receipt::create_receipt::v3::ReceiptType;
    use matrix_sdk::ruma::events::receipt::ReceiptThread;

    bea_room.typing_notice(true).await.unwrap();
    let typing = heard(notices, |n| n["method"] == "typing.changed").await;
    let who = typing["who"].as_array().unwrap();
    assert!(
        who.len() == 1 && who[0].as_str().unwrap().starts_with("bea"),
        "{typing}"
    );
    let bye = json!({ "account": "@anna:localhost", "room": room_id, "text": "see you" });
    call(matrix, "send", bye).await;
    let said = heard(notices, |n| {
        item_with(&n["params"]["changes"], "see you").is_some_and(|it| it["event"].is_string())
    })
    .await;
    let latest: matrix_sdk::ruma::OwnedEventId =
        item_with(&said["changes"], "see you").unwrap()["event"]
            .as_str()
            .unwrap()
            .try_into()
            .unwrap();
    bea_room
        .send_single_receipt(ReceiptType::Read, ReceiptThread::Unthreaded, latest)
        .await
        .unwrap();
    heard(notices, |n| {
        n["params"]["changes"].as_array().is_some_and(|changes| {
            changes.iter().any(|c| {
                c["item"]["read_by"]
                    .as_array()
                    .is_some_and(|by| by.iter().any(|p| p["id"] == "@bea:localhost"))
            })
        })
    })
    .await;
}

/// A 1×1 PNG, red.
const PNG: &[u8] = &[
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
    0xde, 0x00, 0x00, 0x00, 0x0c, 0x49, 0x44, 0x41, 0x54, 0x08, 0xd7, 0x63, 0xf8, 0xcf, 0xc0, 0x00,
    0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xdd, 0x8d, 0xb0, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
    0x44, 0xae, 0x42, 0x60, 0x82,
];

#[test]
fn sends_a_picture_and_fetches_it_back() {
    let Some(server) = Tuwunel::start("media", None) else {
        return;
    };
    run(async {
        let (matrix, mut notices, _bea, room_id) = plans(&server).await;
        let anna = "@anna:localhost";
        let params = json!({ "account": anna, "room": room_id });
        until(&matrix, "timeline", &params, |_| true).await;
        let file = server.dir.join("beds.png");
        std::fs::write(&file, PNG).unwrap();
        let upload = json!({ "account": anna, "room": room_id, "path": file });
        call(&matrix, "upload", upload).await;
        let sent = heard(&mut notices, |n| {
            n["params"]["changes"].as_array().is_some_and(|changes| {
                changes.iter().any(|c| {
                    c["item"]["kind"] == "image"
                        && c["item"]["event"].is_string()
                        && c["item"]["sending"].is_null()
                })
            })
        })
        .await;
        let picture = sent["changes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["item"]["kind"] == "image")
            .unwrap()["item"]
            .clone();
        assert_eq!(picture["media"]["name"], "beds.png", "{picture}");
        assert_eq!(picture["media"]["mime"], "image/png");
        let event = picture["event"].clone();
        let got = call(
            &matrix,
            "media.get",
            json!({ "account": anna, "room": room_id, "event": event }),
        )
        .await;
        let path = got["path"].as_str().unwrap();
        assert_eq!(std::fs::read(path).unwrap(), PNG, "the same picture");
        let small = json!({ "account": anna, "room": room_id, "event": event, "thumbnail": true });
        let got = call(&matrix, "media.get", small).await;
        assert!(
            std::path::Path::new(got["path"].as_str().unwrap()).is_file(),
            "{got}"
        );
    });
}

#[test]
fn signs_in_with_oauth_and_restores_that_session() {
    let provider = oauth_provider();
    let Some(server) = Tuwunel::start("oauth", Some(&provider)) else {
        return;
    };
    let jar = server.dir.join("cookies");
    let data = server.dir.join("data");
    run(async {
        let (notifier, _notices) = rpc::notifier();
        let matrix = Matrix::new(data.clone(), notifier);
        let methods = call(&matrix, "login.methods", json!({ "server": server.url() })).await;
        let oauth = methods
            .as_array()
            .unwrap()
            .iter()
            .find(|m| m["id"] == "oauth")
            .unwrap_or_else(|| panic!("no OAuth in {methods}"))
            .clone();
        let started = call(
            &matrix,
            "login.start",
            json!({ "server": server.url(), "method": oauth }),
        )
        .await;
        assert_eq!(started["step"]["step"], "open", "{started}");
        let url = started["step"]["url"].as_str().unwrap().to_string();
        let back = greed_chat::loopback::query(&url)["redirect_uri"].clone();
        let link = tokio::task::spawn_blocking(move || browse(&url, &jar, Some(&back)))
            .await
            .unwrap();
        // Tuwunel asks you to approve Greed first; the answer sends the
        // browser on to Greed with the code.
        let link = approve(&link, &server.dir.join("cookies"));
        assert!(link.contains("code="), "{link}");
        let done = call(
            &matrix,
            "login.answer",
            json!({ "login": started["login"], "values": { "link": link } }),
        )
        .await;
        assert_eq!(done["step"], "done", "{done}");
        let id = done["account"]["id"].clone();
        let secret = done["secret"].as_str().unwrap().to_string();
        assert!(secret.contains("\"oauth\""), "an OAuth session: {secret}");
        drop(matrix);

        let (notifier, _notices) = rpc::notifier();
        let matrix = Matrix::new(data, notifier);
        let restored = call(&matrix, "restore", json!({ "secret": secret })).await;
        assert_eq!(restored["id"], id, "{restored}");
    });
}

/// Presses Approve on Tuwunel's page asking whether to let Greed sign in,
/// at `page`, and gives the link its next page continues to: back to
/// Greed, by Greed's own scheme.
fn approve(page: &str, jar: &std::path::Path) -> String {
    let query = greed_chat::loopback::query(page);
    let action = page.split_once('?').map_or(page, |(path, _)| path);
    let out = Command::new("curl")
        .args(["-s", "-b"])
        .arg(jar)
        .args(["-XPOST", action])
        .args([
            "--data-urlencode",
            &format!("oidc_req_id={}", query["oidc_req_id"]),
        ])
        .args([
            "--data-urlencode",
            &format!("loginToken={}", query["loginToken"]),
        ])
        .args(["--data-urlencode", "action=approve"])
        .output()
        .unwrap();
    let html = String::from_utf8(out.stdout).unwrap();
    let start = html
        .find("href=\"io.github.johnae:")
        .expect("a link back to Greed")
        + 6;
    let end = start + html[start..].find('"').unwrap();
    html[start..end].replace("&amp;", "&")
}

/// Anna's phone: a plain client signed in as her, setting up cross-signing
/// and a key backup as Element does, accepting what asks to verify against
/// it, and syncing in the background.
async fn phone(server: &Tuwunel) -> Client {
    use matrix_sdk::config::SyncSettings;
    use matrix_sdk::encryption::{BackupDownloadStrategy, EncryptionSettings};

    let client = Client::builder()
        .homeserver_url(server.url())
        .with_encryption_settings(EncryptionSettings {
            auto_enable_cross_signing: true,
            auto_enable_backups: true,
            backup_download_strategy: BackupDownloadStrategy::AfterDecryptionFailure,
        })
        .build()
        .await
        .unwrap();
    client
        .matrix_auth()
        .login_username("anna", "secret")
        .initial_device_display_name("Anna's phone")
        .send()
        .await
        .unwrap();
    client
        .encryption()
        .wait_for_e2ee_initialization_tasks()
        .await;
    // Before the sync starts, or it isn't heard.
    phone_accepts(&client);
    let syncing = client.clone();
    tokio::task::spawn_local(async move {
        let _ = syncing.sync(SyncSettings::default()).await;
    });
    client
}

/// The phone accepts whatever asks to verify against it, and confirms the
/// emoji: as you would, having checked them.
fn phone_accepts(client: &Client) {
    use futures_util::StreamExt;
    use matrix_sdk::encryption::verification::{SasState, Verification, VerificationRequestState};
    use matrix_sdk::ruma::events::AnyToDeviceEvent;
    use matrix_sdk::ruma::serde::Raw;

    let handle = client.clone();
    client.add_event_handler(move |event: Raw<AnyToDeviceEvent>| {
        let client = handle.clone();
        async move {
            let Ok(AnyToDeviceEvent::KeyVerificationRequest(event)) = event.deserialize() else {
                return;
            };
            let Some(request) = client
                .encryption()
                .get_verification_request(&event.sender, &event.content.transaction_id)
                .await
            else {
                return;
            };
            // Followed apart from the handler: the sync waits for handlers,
            // and what comes next comes with the sync.
            tokio::spawn(async move {
                request.accept().await.unwrap();
                let mut changes = request.changes();
                while let Some(state) = changes.next().await {
                    if let VerificationRequestState::Transitioned {
                        verification: Verification::SasV1(sas),
                    } = state
                    {
                        sas.accept().await.unwrap();
                        let mut sas_changes = sas.changes();
                        while let Some(sas_state) = sas_changes.next().await {
                            match sas_state {
                                SasState::KeysExchanged { .. } => sas.confirm().await.unwrap(),
                                SasState::Done { .. } | SasState::Cancelled(_) => return,
                                _ => {}
                            }
                        }
                    }
                }
            });
        }
    });
}

#[test]
fn recovery_key_unlocks_old_messages_and_a_device_verifies() {
    use matrix_sdk::ruma::api::client::room::create_room;
    use matrix_sdk::ruma::events::InitialStateEvent;
    use matrix_sdk::ruma::events::room::encryption::RoomEncryptionEventContent;
    use matrix_sdk::ruma::events::room::message::RoomMessageEventContent;

    let Some(server) = Tuwunel::start("encryption", None) else {
        return;
    };
    run(async {
        server.register("anna", "secret").await;
        let phone = phone(&server).await;
        let key = phone.encryption().recovery().enable().await.unwrap();
        let mut request = create_room::v3::Request::new();
        request.name = Some("Secrets".into());
        request.initial_state = vec![
            InitialStateEvent::with_empty_state_key(
                RoomEncryptionEventContent::with_recommended_defaults(),
            )
            .to_raw_any(),
        ];
        let room = phone.create_room(request).await.unwrap();
        room.send(RoomMessageEventContent::text_plain(
            "the plans are in the shed",
        ))
        .await
        .unwrap();
        let room_id = room.room_id().to_string();
        // The room's key reaches the backup before Greed asks for it.
        phone
            .encryption()
            .backups()
            .wait_for_steady_state()
            .await
            .unwrap();

        // Greed, a new device: unverified until the recovery key.
        let (notifier, _notices) = rpc::notifier();
        let matrix = Matrix::new(server.dir.join("data"), notifier);
        sign_in(&matrix, &server, "anna", "secret").await;
        let anna = json!({ "account": "@anna:localhost" });
        let state = call(&matrix, "encryption.state", anna.clone()).await;
        assert_eq!(state["verified"], false, "{state}");
        let mut recover = anna.clone();
        recover["key"] = json!(key);
        call(&matrix, "encryption.recover", recover).await;
        // The key verifies this device, once its signature is up.
        until(&matrix, "encryption.state", &anna, |state| {
            state["verified"] == true
        })
        .await;
        let params = json!({ "account": "@anna:localhost", "room": room_id });
        until(&matrix, "timeline", &params, |t| {
            t["items"]
                .as_array()
                .unwrap()
                .iter()
                .any(|it| it["text"] == "the plans are in the shed")
        })
        .await;

        // Another new device, verified against the phone by emoji.
        let (notifier, mut notices) = rpc::notifier();
        let laptop = Matrix::new(server.dir.join("laptop"), notifier);
        sign_in(&laptop, &server, "anna", "secret").await;
        // The phone takes a request only from a device it has heard of.
        let me = matrix_sdk::ruma::user_id!("@anna:localhost");
        for _ in 0..100 {
            let devices = phone.encryption().get_user_devices(me).await.unwrap();
            if devices.devices().count() >= 3 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        let started = call(&laptop, "verify.start", anna.clone()).await;
        let id = started["id"].clone();
        let compare = heard(&mut notices, |n| {
            n["method"] == "verify.changed" && n["params"]["state"] == "compare"
        })
        .await;
        assert_eq!(compare["emoji"].as_array().unwrap().len(), 7, "{compare}");
        let confirm = json!({ "account": "@anna:localhost", "id": id, "same": true });
        call(&laptop, "verify.confirm", confirm).await;
        heard(&mut notices, |n| {
            n["method"] == "verify.changed" && n["params"]["state"] == "done"
        })
        .await;
        // The phone signs this device's keys once the emoji match.
        until(&laptop, "encryption.state", &anna, |state| {
            state["verified"] == true
        })
        .await;
    });
}

#[test]
fn new_messages_for_you_are_alerts() {
    use matrix_sdk::ruma::events::Mentions;
    use matrix_sdk::ruma::events::room::message::RoomMessageEventContent;

    let Some(server) = Tuwunel::start("alerts", None) else {
        return;
    };
    run(async {
        let (matrix, mut notices, bea, room_id) = plans(&server).await;
        let anna = "@anna:localhost";
        let params = json!({ "account": anna, "room": room_id });
        until(&matrix, "timeline", &params, |_| true).await;
        // Anna's own message isn't one.
        call(
            &matrix,
            "send",
            json!({ "account": anna, "room": room_id, "text": "hi" }),
        )
        .await;
        let bea_room = bea
            .get_room(&matrix_sdk::ruma::RoomId::parse(&room_id).unwrap())
            .unwrap();
        bea_room
            .send(RoomMessageEventContent::text_plain("lunch?"))
            .await
            .unwrap();
        let lunch = heard(&mut notices, |n| n["method"] == "alert").await;
        assert_eq!(lunch["body"], "lunch?", "{lunch}");
        assert_eq!(lunch["room"], room_id.as_str());
        assert_eq!(lunch["room_name"], "Plans");
        assert_eq!(lunch["sender"]["id"], "@bea:localhost");
        assert_eq!(lunch["mention"], false);
        assert_eq!(lunch["direct"], false);
        assert!(lunch["event"].as_str().unwrap().starts_with('$'), "{lunch}");

        let named = RoomMessageEventContent::text_plain("anna, are you in?").add_mentions(
            Mentions::with_user_ids([matrix_sdk::ruma::OwnedUserId::try_from(anna).unwrap()]),
        );
        bea_room.send(named).await.unwrap();
        let named = heard(&mut notices, |n| n["method"] == "alert").await;
        assert_eq!(named["body"], "anna, are you in?", "{named}");
        assert_eq!(named["mention"], true);
    });
}

#[test]
fn searches_messages() {
    use matrix_sdk::ruma::api::client::room::create_room;
    use matrix_sdk::ruma::events::InitialStateEvent;
    use matrix_sdk::ruma::events::room::encryption::RoomEncryptionEventContent;
    use matrix_sdk::ruma::events::room::message::RoomMessageEventContent;

    let Some(server) = Tuwunel::start("search", None) else {
        return;
    };
    run(async {
        let (matrix, _notices, bea, room_id) = plans(&server).await;
        let anna = "@anna:localhost";
        let bea_room = bea
            .get_room(&matrix_sdk::ruma::RoomId::parse(&room_id).unwrap())
            .unwrap();
        for message in [
            "the tomatoes are ripe",
            "nothing to see",
            "more tomatoes soon",
        ] {
            bea_room
                .send(RoomMessageEventContent::text_plain(message))
                .await
                .unwrap();
        }
        let query = json!({ "account": anna, "query": "tomatoes" });
        let found = until(&matrix, "search", &query, |found| {
            found.as_array().is_some_and(|hits| hits.len() == 2) && found[0]["room_name"] == "Plans"
        })
        .await;
        assert_eq!(found[0]["item"]["text"], "more tomatoes soon", "{found}");
        assert_eq!(found[1]["item"]["text"], "the tomatoes are ripe");
        assert_eq!(found[0]["room"], room_id.as_str());
        assert_eq!(found[0]["item"]["sender"]["id"], "@bea:localhost");

        let elsewhere =
            json!({ "account": anna, "query": "tomatoes", "room": "!nowhere:localhost" });
        assert!(matrix.call("search", elsewhere).await.is_err());

        // An encrypted room the server can't search: this device's index can.
        let mut request = create_room::v3::Request::new();
        request.name = Some("Secrets".into());
        request.invite = vec![anna.try_into().unwrap()];
        request.initial_state = vec![
            InitialStateEvent::with_empty_state_key(
                RoomEncryptionEventContent::with_recommended_defaults(),
            )
            .to_raw_any(),
        ];
        let secrets = bea.create_room(request).await.unwrap();
        other(&server, "anna", "secret")
            .await
            .join_room_by_id(secrets.room_id())
            .await
            .unwrap();
        bea.sync_once(matrix_sdk::config::SyncSettings::default())
            .await
            .unwrap();
        secrets
            .send(RoomMessageEventContent::text_plain(
                "tomatoes under the floor",
            ))
            .await
            .unwrap();
        let hidden = json!({ "account": anna, "query": "floor" });
        // Once the room's name has come too.
        until(&matrix, "search", &hidden, |found| {
            found.as_array().is_some_and(|hits| hits.len() == 1)
                && found[0]["room_name"] == "Secrets"
        })
        .await;
    });
}

#[test]
fn previews_links_but_not_in_encrypted_rooms() {
    use matrix_sdk::ruma::api::client::room::create_room;
    use matrix_sdk::ruma::events::InitialStateEvent;
    use matrix_sdk::ruma::events::room::encryption::RoomEncryptionEventContent;

    let Some(server) = Tuwunel::start("preview", None) else {
        return;
    };
    run(async {
        let (matrix, _notices, bea, room_id) = plans(&server).await;
        let anna = "@anna:localhost";
        let page = greed_chat::testing::web_page(
            r#"<html><head><title>x</title>
<meta property="og:title" content="Garden plans">
<meta property="og:description" content="Beds, tomatoes and compost">
<meta property="og:site_name" content="Plots">
</head><body>beds</body></html>"#,
        );
        let url = format!("{page}/beds");
        let asked = json!({ "account": anna, "room": room_id, "url": url });
        let preview = until(&matrix, "preview", &asked, |p| p["title"].is_string()).await;
        assert_eq!(preview["title"], "Garden plans", "{preview}");
        assert_eq!(preview["description"], "Beds, tomatoes and compost");
        assert_eq!(preview["url"], url.as_str());

        let mut request = create_room::v3::Request::new();
        request.invite = vec![anna.try_into().unwrap()];
        request.initial_state = vec![
            InitialStateEvent::with_empty_state_key(
                RoomEncryptionEventContent::with_recommended_defaults(),
            )
            .to_raw_any(),
        ];
        let secrets = bea.create_room(request).await.unwrap();
        other(&server, "anna", "secret")
            .await
            .join_room_by_id(secrets.room_id())
            .await
            .unwrap();
        let secrets = secrets.room_id().to_string();
        until(&matrix, "rooms", &json!({ "account": anna }), |rooms| {
            rooms.as_array().is_some_and(|rooms| {
                rooms
                    .iter()
                    .any(|r| r["id"] == secrets.as_str() && r["encrypted"] == true)
            })
        })
        .await;
        let hidden = json!({ "account": anna, "room": secrets, "url": url });
        assert_eq!(call(&matrix, "preview", hidden).await, Value::Null);
    });
}

#[test]
fn joins_by_address_and_from_the_directory_leaves_and_answers_invites() {
    use matrix_sdk::ruma::api::client::room::{Visibility, create_room};

    let Some(server) = Tuwunel::start("join", None) else {
        return;
    };
    run(async {
        server.register("anna", "secret").await;
        server.register("bea", "secret").await;
        let bea = other(&server, "bea", "secret").await;
        let (notifier, _notices) = rpc::notifier();
        let matrix = Matrix::new(server.dir.join("data"), notifier);
        sign_in(&matrix, &server, "anna", "secret").await;
        let anna = "@anna:localhost";
        let account = json!({ "account": anna });
        // The kind room `id` has in Anna's list, or null when it isn't there.
        let kind_of = |rooms: &Value, id: &str| {
            rooms
                .as_array()
                .unwrap()
                .iter()
                .find(|r| r["id"] == id)
                .map_or(Value::Null, |r| r["kind"].clone())
        };

        let mut request = create_room::v3::Request::new();
        request.name = Some("Garden".into());
        request.topic = Some("Beds and tomatoes".into());
        request.room_alias_name = Some("garden".into());
        request.visibility = Visibility::Public;
        let garden = bea.create_room(request).await.unwrap();
        let garden = garden.room_id().to_string();

        let listed = call(
            &matrix,
            "directory",
            json!({ "account": anna, "query": "garden" }),
        )
        .await;
        let found = listed
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["id"] == garden.as_str())
            .unwrap_or_else(|| panic!("no Garden in {listed}"));
        assert_eq!(found["name"], "Garden");
        assert_eq!(found["topic"], "Beds and tomatoes");
        assert_eq!(found["address"], "#garden:localhost");
        assert_eq!(found["members"], 1);

        let joined = call(
            &matrix,
            "join",
            json!({ "account": anna, "room": "#garden:localhost" }),
        )
        .await;
        assert_eq!(joined["room"], garden.as_str());
        until(&matrix, "rooms", &account, |rooms| {
            kind_of(rooms, &garden) == "room"
        })
        .await;
        let listed = call(
            &matrix,
            "directory",
            json!({ "account": anna, "query": "" }),
        )
        .await;
        assert!(
            listed
                .as_array()
                .unwrap()
                .iter()
                .all(|r| r["id"] != garden.as_str()),
            "rooms you're in aren't listed: {listed}"
        );
        call(&matrix, "leave", json!({ "account": anna, "room": garden })).await;
        until(&matrix, "rooms", &account, |rooms| {
            kind_of(rooms, &garden).is_null()
        })
        .await;

        // Asked to a room: no, then yes.
        for answer in ["leave", "join"] {
            let mut request = create_room::v3::Request::new();
            request.name = Some("Plans".into());
            request.invite = vec![anna.try_into().unwrap()];
            let plans = bea
                .create_room(request)
                .await
                .unwrap()
                .room_id()
                .to_string();
            until(&matrix, "rooms", &account, |rooms| {
                kind_of(rooms, &plans) == "invite"
            })
            .await;
            call(&matrix, answer, json!({ "account": anna, "room": plans })).await;
            let wanted = if answer == "join" {
                json!("room")
            } else {
                Value::Null
            };
            until(&matrix, "rooms", &account, |rooms| {
                kind_of(rooms, &plans) == wanted
            })
            .await;
        }
    });
}
