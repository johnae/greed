//! greed-mattermost against a real Mattermost, started for each test with a
//! PostgreSQL of its own in a temporary folder. Skipped, saying so, when
//! `mattermost`, `initdb` or `pg_ctl` isn't on PATH (devenv has them).

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use greed_chat::rpc::{self, Service};
use greed_chat::testing::{
    browse, find, free_port, heard, item_with, json_service, oauth_provider,
};
use greed_mattermost::Mattermost;
use serde_json::{Value, json};

/// A Mattermost and its PostgreSQL, stopped when dropped.
struct Server {
    mattermost: Child,
    pg_ctl: PathBuf,
    port: u16,
    dir: PathBuf,
}

impl Server {
    /// Starts one, or None when there's no Mattermost or PostgreSQL.
    fn start(name: &str, settings: &[(&str, String)]) -> Option<Server> {
        let (Some(mattermost), Some(initdb), Some(pg_ctl)) =
            (find("mattermost"), find("initdb"), find("pg_ctl"))
        else {
            eprintln!(
                "skipped: mattermost, initdb and pg_ctl aren't all on PATH (devenv has them)"
            );
            return None;
        };
        let dir = std::env::temp_dir().join(format!("gmm-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        for sub in ["pg", "files"] {
            std::fs::create_dir_all(dir.join(sub)).unwrap();
        }
        // Postgres listens only on a socket in the folder.
        quiet(
            Command::new(initdb)
                .args(["-U", "mm", "--auth=trust", "-D"])
                .arg(dir.join("pg")),
        );
        let options = format!("-k {} -c listen_addresses=", dir.display());
        quiet(
            Command::new(&pg_ctl)
                .arg("-D")
                .arg(dir.join("pg"))
                .args(["-o", &options, "-l"])
                .arg(dir.join("pg.log"))
                .args(["-w", "start"]),
        );
        let postgres = postgres(&dir);
        std::fs::write(dir.join("config.json"), "{}").unwrap();
        let port = free_port();
        let url = format!("http://127.0.0.1:{port}");
        let log = std::fs::File::create(dir.join("mattermost.log")).unwrap();
        let mattermost = Command::new(&mattermost)
            .arg("server")
            // Where its web app is, for the pages it serves.
            .current_dir(mattermost.parent().and_then(Path::parent).unwrap())
            .env("MM_CONFIG", dir.join("config.json"))
            .env("MM_SQLSETTINGS_DRIVERNAME", "postgres")
            .env("MM_SQLSETTINGS_DATASOURCE", postgres)
            .env(
                "MM_SERVICESETTINGS_LISTENADDRESS",
                format!("127.0.0.1:{port}"),
            )
            .env("MM_SERVICESETTINGS_SITEURL", &url)
            .env("MM_FILESETTINGS_DIRECTORY", dir.join("files"))
            .env("MM_LOGSETTINGS_ENABLECONSOLE", "false")
            .env("MM_LOGSETTINGS_ENABLEFILE", "false")
            .env("MM_PLUGINSETTINGS_ENABLE", "false")
            .env("MM_TEAMSETTINGS_ENABLEOPENSERVER", "true")
            .env("MM_SERVICESETTINGS_ENABLEDEVELOPER", "false")
            .envs(settings.iter().map(|(key, value)| (key, value)))
            .stdout(Stdio::null())
            .stderr(log)
            .spawn()
            .unwrap();
        let server = Server {
            mattermost,
            pg_ctl,
            port,
            dir,
        };
        let started = Instant::now();
        while !server.up() {
            assert!(
                started.elapsed() < Duration::from_secs(60),
                "mattermost didn't start: {}",
                std::fs::read_to_string(server.dir.join("mattermost.log")).unwrap_or_default()
            );
            std::thread::sleep(Duration::from_millis(100));
        }
        Some(server)
    }

    fn url(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }

    /// Whether it answers yet.
    fn up(&self) -> bool {
        let ping = Command::new("curl")
            .args(["-sf", &format!("{}/api/v4/system/ping", self.url())])
            .stdout(Stdio::null())
            .status();
        ping.is_ok_and(|status| status.success())
    }

    /// Makes an account `user` with `password`; the first is the admin.
    fn user(&self, user: &str, password: &str) {
        let body = json!({ "email": format!("{user}@example.com"), "username": user, "password": password });
        let made = Command::new("curl")
            .args(["-sf", "-XPOST", &format!("{}/api/v4/users", self.url())])
            .args(["-d", &body.to_string()])
            .stdout(Stdio::null())
            .status()
            .unwrap();
        assert!(made.success(), "couldn't make {user}");
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.mattermost.kill();
        let _ = self.mattermost.wait();
        let _ = Command::new(&self.pg_ctl)
            .arg("-D")
            .arg(self.dir.join("pg"))
            .args(["-m", "immediate", "stop"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// The database Mattermost keeps, at Postgres's socket in `dir`.
fn postgres(dir: &Path) -> String {
    let createdb = find("createdb").expect("createdb comes with initdb");
    quiet(
        Command::new(createdb)
            .arg("-h")
            .arg(dir)
            .args(["-U", "mm", "mattermost"]),
    );
    format!(
        "postgres://mm@/mattermost?host={}&sslmode=disable",
        dir.display()
    )
}

fn quiet(command: &mut Command) {
    let out = command.output().unwrap();
    assert!(
        out.status.success(),
        "{command:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

fn run(test: impl Future<Output = ()>) {
    greed_chat::program::run(test).unwrap();
}

async fn call(service: &Mattermost, method: &str, params: Value) -> Value {
    match service.call(method, params).await {
        Ok(result) => result,
        Err(e) => panic!("{method}: {}", e.message),
    }
}

#[test]
fn signs_in_with_a_password_restores_and_signs_out() {
    let Some(server) = Server::start("password", &[]) else {
        return;
    };
    server.user("anna", "Secret-pass1");
    let data = server.dir.join("data");
    run(async {
        let (notifier, _notices) = rpc::notifier();
        let service = Mattermost::new(data.clone(), notifier);

        let methods = call(&service, "login.methods", json!({ "server": server.url() })).await;
        assert_eq!(methods, json!([{ "kind": "password" }]));

        let started = call(
            &service,
            "login.start",
            json!({ "server": server.url(), "method": { "kind": "password" } }),
        )
        .await;
        let login = started["login"].clone();
        assert_eq!(started["step"]["step"], "ask", "{started}");

        let wrong = call(
            &service,
            "login.answer",
            json!({ "login": login, "values": { "user": "anna", "password": "nope" } }),
        )
        .await;
        assert_eq!(wrong["step"], "ask", "asked again: {wrong}");
        assert!(wrong["why"].is_string(), "saying why: {wrong}");

        let done = call(
            &service,
            "login.answer",
            json!({ "login": login, "values": { "user": "anna", "password": "Secret-pass1" } }),
        )
        .await;
        assert_eq!(done["step"], "done", "{done}");
        assert_eq!(done["account"]["name"], "anna");
        let id = done["account"]["id"].as_str().unwrap().to_string();
        assert!(id.ends_with("@127.0.0.1"), "{id}");
        let secret = done["secret"].as_str().unwrap().to_string();
        assert!(!secret.contains("Secret-pass1"), "the password isn't kept");

        // As after a restart: a new service, the same secret.
        let (notifier, _notices) = rpc::notifier();
        let service = Mattermost::new(data.clone(), notifier);
        let restored = call(&service, "restore", json!({ "secret": secret })).await;
        assert_eq!(restored["id"], id.as_str(), "{restored}");

        call(&service, "logout", json!({ "account": id })).await;
        assert_eq!(call(&service, "accounts", Value::Null).await, json!([]));
        let again = service.call("restore", json!({ "secret": secret })).await;
        assert!(
            again.is_err_and(|e| e.message.contains("signed out")),
            "the token is gone with the session"
        );
    });
}

#[test]
fn signs_in_through_the_browser_with_a_desktop_token() {
    let gitlab = oauth_provider();
    let settings = [
        ("MM_GITLABSETTINGS_ENABLE", "true".to_string()),
        ("MM_GITLABSETTINGS_ID", "greed".to_string()),
        ("MM_GITLABSETTINGS_SECRET", "secret".to_string()),
        (
            "MM_GITLABSETTINGS_AUTHENDPOINT",
            format!("{gitlab}/oauth/authorize"),
        ),
        (
            "MM_GITLABSETTINGS_TOKENENDPOINT",
            format!("{gitlab}/oauth/token"),
        ),
        (
            "MM_GITLABSETTINGS_USERAPIENDPOINT",
            format!("{gitlab}/api/v4/user"),
        ),
        (
            "MM_SERVICESETTINGS_ALLOWEDUNTRUSTEDINTERNALCONNECTIONS",
            "127.0.0.1".to_string(),
        ),
    ];
    let Some(server) = Server::start("browser", &settings) else {
        return;
    };
    server.user("anna", "Secret-pass1");
    let data = server.dir.join("data");
    let jar = server.dir.join("cookies");
    run(async {
        let (notifier, _notices) = rpc::notifier();
        let service = Mattermost::new(data, notifier);
        // Only licensed servers say they have GitLab (or OpenID) in their
        // public config, so this one isn't asked; its sign-in works all the same.
        let started = call(
            &service,
            "login.start",
            json!({ "server": server.url(),
                    "method": { "kind": "browser", "id": "gitlab", "name": "GitLab" } }),
        )
        .await;
        assert_eq!(started["step"]["step"], "open", "{started}");
        let login = started["login"].clone();

        let ended = browse(started["step"]["url"].as_str().unwrap(), &jar, None);
        assert!(ended.contains("/login/desktop?"), "{ended}");

        let other = ended.replace("client_token=", "client_token=x");
        let refused = service
            .call(
                "login.answer",
                json!({ "login": login, "values": { "link": other } }),
            )
            .await;
        assert!(refused.is_err(), "a link from another sign-in is refused");

        // As the desktop page hands it on, under Mattermost's own scheme.
        let link = ended.replacen("http:", "mattermost:", 1);
        let done = call(
            &service,
            "login.answer",
            json!({ "login": login, "values": { "link": link } }),
        )
        .await;
        assert_eq!(done["step"], "done", "{done}");
        assert_eq!(done["account"]["name"], "Bea Berg");
    });
}

/// Someone on the server, through its REST API, for the other side of a
/// test.
struct Rest {
    http: reqwest::Client,
    url: String,
    token: String,
    id: String,
}

impl Rest {
    async fn login(server: &Server, user: &str, password: &str) -> Rest {
        let http = reqwest::Client::new();
        let response = http
            .post(format!("{}/api/v4/users/login", server.url()))
            .json(&json!({ "login_id": user, "password": password }))
            .send()
            .await
            .unwrap();
        let token = response.headers()["token"].to_str().unwrap().to_string();
        let me: Value = response.json().await.unwrap();
        Rest {
            http,
            url: server.url(),
            token,
            id: me["id"].as_str().unwrap().to_string(),
        }
    }

    async fn post(&self, path: &str, body: &Value) -> Value {
        let response = self
            .http
            .post(format!("{}/api/v4/{path}", self.url))
            .bearer_auth(&self.token)
            .json(body)
            .send()
            .await
            .unwrap();
        assert!(
            response.status().is_success(),
            "{path}: {}",
            response.status()
        );
        response.json().await.unwrap()
    }
}

/// Signs `user` in through the service with a password: their account.
async fn sign_in(service: &Mattermost, server: &Server, user: &str, password: &str) -> String {
    let started = call(
        service,
        "login.start",
        json!({ "server": server.url(), "method": { "kind": "password" } }),
    )
    .await;
    let values = json!({ "user": user, "password": password });
    let done = call(
        service,
        "login.answer",
        json!({ "login": started["login"], "values": values }),
    )
    .await;
    done["account"]["id"].as_str().unwrap().to_string()
}

#[test]
fn lists_channels_and_keeps_a_timeline() {
    let Some(server) = Server::start("channels", &[]) else {
        return;
    };
    server.user("anna", "Secret-pass1");
    server.user("bea", "Secret-pass1");
    run(async {
        let anna_rest = Rest::login(&server, "anna", "Secret-pass1").await;
        let bea = Rest::login(&server, "bea", "Secret-pass1").await;
        let team = anna_rest
            .post(
                "teams",
                &json!({ "name": "crew", "display_name": "Crew", "type": "O" }),
            )
            .await;
        let team_id = team["id"].as_str().unwrap();
        anna_rest
            .post(
                &format!("teams/{team_id}/members"),
                &json!({ "team_id": team_id, "user_id": bea.id }),
            )
            .await;
        let channel = anna_rest
            .post(
                "channels",
                &json!({ "team_id": team_id, "name": "plans", "display_name": "Plans", "type": "O" }),
            )
            .await;
        let channel_id = channel["id"].as_str().unwrap().to_string();
        bea.post(
            &format!("channels/{channel_id}/members"),
            &json!({ "user_id": bea.id }),
        )
        .await;

        let (notifier, mut notices) = rpc::notifier();
        let service = Mattermost::new(server.dir.join("data"), notifier);
        let anna = sign_in(&service, &server, "anna", "Secret-pass1").await;
        heard(&mut notices, |n| {
            n["method"] == "account.changed" && n["params"]["state"]["state"] == "ready"
        })
        .await;

        let rooms = call(&service, "rooms", json!({ "account": anna })).await;
        let find = |id: &str| {
            rooms
                .as_array()
                .unwrap()
                .iter()
                .find(|r| r["id"] == id)
                .cloned()
                .unwrap_or_else(|| panic!("no {id} in {rooms}"))
        };
        assert_eq!(find(team_id)["kind"], "space");
        let plans = find(&channel_id);
        assert_eq!(plans["name"], "Plans");
        assert_eq!(plans["parent"], team_id);

        let params = json!({ "account": anna, "room": channel_id });
        let opened = call(&service, "timeline", params.clone()).await;
        assert!(opened["items"].is_array(), "{opened}");

        let lunch = bea
            .post(
                "posts",
                &json!({ "channel_id": channel_id, "message": "lunch at noon?" }),
            )
            .await;
        let changed = heard(&mut notices, |n| {
            n["method"] == "timeline.changed"
                && item_with(&n["params"]["changes"], "lunch at noon?").is_some()
        })
        .await;
        let item = item_with(&changed["changes"], "lunch at noon?").unwrap();
        assert_eq!(item["sender"]["name"], "bea");
        assert_eq!(item["mine"], false);
        assert_eq!(item["event"], lunch["id"]);
        assert!(
            item["link"]
                .as_str()
                .is_some_and(|link| link
                    .ends_with(&format!("/_redirect/pl/{}", lunch["id"].as_str().unwrap()))),
            "{item}"
        );

        call(
            &service,
            "send",
            json!({ "account": anna, "room": channel_id, "text": "yes", "reply_to": lunch["id"] }),
        )
        .await;
        // The reply goes in the thread; the channel counts it.
        heard(&mut notices, |n| {
            n["params"]["thread"].is_null()
                && item_with(&n["params"]["changes"], "lunch at noon?")
                    .is_some_and(|lunch| lunch["replies"] == 1)
        })
        .await;
        let thread = json!({ "account": anna, "room": channel_id, "thread": lunch["id"] });
        let opened = call(&service, "timeline", thread).await;
        let yes = item_with(&json!([{ "items": opened["items"] }]), "yes")
            .expect("the thread has the reply");
        assert_eq!(yes["mine"], true);
        assert_eq!(yes["thread"], lunch["id"]);
    });
}

#[test]
fn reactions_edits_deleting_typing_reading_and_presence() {
    let Some(server) = Server::start("step4", &[]) else {
        return;
    };
    server.user("anna", "Secret-pass1");
    server.user("bea", "Secret-pass1");
    run(async {
        let anna_rest = Rest::login(&server, "anna", "Secret-pass1").await;
        let bea = Rest::login(&server, "bea", "Secret-pass1").await;
        let direct = anna_rest
            .post("channels/direct", &json!([anna_rest.id, bea.id]))
            .await;
        let room = direct["id"].as_str().unwrap().to_string();

        let (notifier, mut notices) = rpc::notifier();
        let service = Mattermost::new(server.dir.join("data"), notifier);
        let anna = sign_in(&service, &server, "anna", "Secret-pass1").await;
        heard(&mut notices, |n| {
            n["method"] == "account.changed" && n["params"]["state"]["state"] == "ready"
        })
        .await;

        // Bea as a direct message, with whether she's around.
        let rooms = call(&service, "rooms", json!({ "account": anna })).await;
        let dm = rooms
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["id"] == room.as_str())
            .unwrap_or_else(|| panic!("no direct message in {rooms}"))
            .clone();
        assert_eq!(dm["kind"], "direct");
        assert_eq!(dm["name"], "bea");
        assert!(dm["presence"].is_string(), "{dm}");

        let params = json!({ "account": anna, "room": room });
        call(&service, "timeline", params.clone()).await;
        let send = json!({ "account": anna, "room": room, "text": "noon" });
        call(&service, "send", send).await;
        let noon = heard(&mut notices, |n| {
            item_with(&n["params"]["changes"], "noon").is_some_and(|it| it["sending"].is_null())
        })
        .await;
        let event = item_with(&noon["changes"], "noon").unwrap()["event"].clone();
        let message = |extra: Value| {
            let mut message = json!({ "account": anna, "room": room, "event": event });
            for (key, value) in extra.as_object().unwrap() {
                message[key] = value.clone();
            }
            message
        };

        call(&service, "react", message(json!({ "key": "👍" }))).await;
        heard(&mut notices, |n| {
            item_with(&n["params"]["changes"], "noon").is_some_and(|it| {
                it["reactions"][0]["key"] == "👍" && it["reactions"][0]["mine"] == true
            })
        })
        .await;
        call(&service, "react", message(json!({ "key": "👍" }))).await;
        heard(&mut notices, |n| {
            item_with(&n["params"]["changes"], "noon")
                .is_some_and(|it| it["reactions"].as_array().unwrap().is_empty())
        })
        .await;

        call(&service, "edit", message(json!({ "text": "one" }))).await;
        heard(&mut notices, |n| {
            item_with(&n["params"]["changes"], "one").is_some_and(|it| it["edited"] == true)
        })
        .await;
        call(&service, "redact", message(json!({}))).await;
        heard(&mut notices, |n| {
            n["params"]["changes"].as_array().is_some_and(|changes| {
                changes
                    .iter()
                    .any(|c| c["item"]["event"] == event && c["item"]["kind"] == "deleted")
            })
        })
        .await;

        // Bea writing.
        bea.post(
            &format!("users/{}/typing", bea.id),
            &json!({ "channel_id": room }),
        )
        .await;
        let typing = heard(&mut notices, |n| n["method"] == "typing.changed").await;
        assert_eq!(typing["who"], json!(["bea"]), "{typing}");

        let mut typing_on = params.clone();
        typing_on["on"] = json!(true);
        call(&service, "typing", typing_on).await;
        call(&service, "read", params).await;
    });
}

#[test]
fn sends_a_file_and_fetches_it_back() {
    let Some(server) = Server::start("files", &[]) else {
        return;
    };
    server.user("anna", "Secret-pass1");
    server.user("bea", "Secret-pass1");
    run(async {
        let anna_rest = Rest::login(&server, "anna", "Secret-pass1").await;
        let bea = Rest::login(&server, "bea", "Secret-pass1").await;
        let direct = anna_rest
            .post("channels/direct", &json!([anna_rest.id, bea.id]))
            .await;
        let room = direct["id"].as_str().unwrap().to_string();
        let (notifier, mut notices) = rpc::notifier();
        let service = Mattermost::new(server.dir.join("data"), notifier);
        let anna = sign_in(&service, &server, "anna", "Secret-pass1").await;
        let params = json!({ "account": anna, "room": room });
        call(&service, "timeline", params).await;
        let file = server.dir.join("notes.txt");
        std::fs::write(&file, "tomatoes by the fence\n").unwrap();
        call(
            &service,
            "upload",
            json!({ "account": anna, "room": room, "path": file }),
        )
        .await;
        let sent = heard(&mut notices, |n| {
            item_with(&n["params"]["changes"], "notes.txt").is_some_and(|it| it["kind"] == "file")
        })
        .await;
        let item = item_with(&sent["changes"], "notes.txt").unwrap();
        assert_eq!(item["media"]["name"], "notes.txt", "{item}");
        let got = call(
            &service,
            "media.get",
            json!({ "account": anna, "room": room, "event": item["event"] }),
        )
        .await;
        let path = got["path"].as_str().unwrap();
        assert_eq!(
            std::fs::read_to_string(path).unwrap(),
            "tomatoes by the fence\n"
        );
    });
}

/// Anna and Bea in team Crew's channel Plans, and the service signed in as
/// Anna and connected.
struct Crew {
    anna: Rest,
    bea: Rest,
    channel: String,
    service: std::rc::Rc<Mattermost>,
    notices: tokio::sync::mpsc::UnboundedReceiver<String>,
    /// Anna's account in the service.
    account: String,
}

async fn crew(server: &Server) -> Crew {
    let anna = Rest::login(server, "anna", "Secret-pass1").await;
    let bea = Rest::login(server, "bea", "Secret-pass1").await;
    let team = anna
        .post(
            "teams",
            &json!({ "name": "crew", "display_name": "Crew", "type": "O" }),
        )
        .await;
    let team_id = team["id"].as_str().unwrap();
    anna.post(
        &format!("teams/{team_id}/members"),
        &json!({ "team_id": team_id, "user_id": bea.id }),
    )
    .await;
    let channel = anna
        .post(
            "channels",
            &json!({ "team_id": team_id, "name": "plans", "display_name": "Plans", "type": "O" }),
        )
        .await;
    let channel = channel["id"].as_str().unwrap().to_string();
    bea.post(
        &format!("channels/{channel}/members"),
        &json!({ "user_id": bea.id }),
    )
    .await;
    let (notifier, mut notices) = rpc::notifier();
    let service = Mattermost::new(server.dir.join("data"), notifier);
    let account = sign_in(&service, server, "anna", "Secret-pass1").await;
    heard(&mut notices, |n| {
        n["method"] == "account.changed" && n["params"]["state"]["state"] == "ready"
    })
    .await;
    Crew {
        anna,
        bea,
        channel,
        service,
        notices,
        account,
    }
}

#[test]
fn posts_for_you_are_alerts() {
    let Some(server) = Server::start("alerts", &[]) else {
        return;
    };
    server.user("anna", "Secret-pass1");
    server.user("bea", "Secret-pass1");
    run(async {
        let Crew {
            anna: anna_rest,
            bea,
            channel: channel_id,
            service: _service,
            mut notices,
            ..
        } = crew(&server).await;
        let direct = bea
            .post("channels/direct", &json!([anna_rest.id, bea.id]))
            .await;

        // A post in a channel is one only when it mentions Anna.
        let post =
            |channel: &str, message: &str| json!({ "channel_id": channel, "message": message });
        bea.post("posts", &post(&channel_id, "anyone?")).await;
        bea.post("posts", &post(&channel_id, "@anna lunch?")).await;
        let named = heard(&mut notices, |n| n["method"] == "alert").await;
        assert_eq!(named["body"], "@anna lunch?", "{named}");
        assert_eq!(named["mention"], true);
        assert_eq!(named["room"], channel_id.as_str());
        assert_eq!(named["room_name"], "Plans");
        assert_eq!(named["sender"]["name"], "bea");
        assert_eq!(named["direct"], false);

        // Every direct message is.
        bea.post("posts", &post(direct["id"].as_str().unwrap(), "noon"))
            .await;
        let dm = heard(&mut notices, |n| n["method"] == "alert").await;
        assert_eq!(dm["body"], "noon", "{dm}");
        assert_eq!(dm["mention"], false);
        assert_eq!(dm["direct"], true);
    });
}

#[test]
fn slash_commands_run_and_buttons_press() {
    let settings = [(
        "MM_SERVICESETTINGS_ALLOWEDUNTRUSTEDINTERNALCONNECTIONS",
        "127.0.0.1 localhost".to_string(),
    )];
    let Some(server) = Server::start("commands", &settings) else {
        return;
    };
    server.user("anna", "Secret-pass1");
    server.user("bea", "Secret-pass1");
    run(async {
        let Crew {
            bea,
            channel: channel_id,
            service,
            mut notices,
            account: anna,
            ..
        } = crew(&server).await;
        let params = json!({ "account": anna, "room": channel_id });
        call(&service, "timeline", params.clone()).await;

        // The commands there are, and running one.
        let commands = call(&service, "commands", params.clone()).await;
        let triggers: Vec<&str> = commands
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|c| c["trigger"].as_str())
            .collect();
        assert!(triggers.contains(&"shrug"), "{commands}");
        let shrug = json!({ "account": anna, "room": channel_id, "text": "/shrug fine" });
        call(&service, "send", shrug).await;
        heard(&mut notices, |n| {
            n["method"] == "timeline.changed"
                && item_with(&n["params"]["changes"], "fine ¯\\\\\\_(ツ)\\_/¯").is_some()
        })
        .await;
        // What answers only you shows in the room, as a notice.
        let away = json!({ "account": anna, "room": channel_id, "text": "/away" });
        let answered = call(&service, "send", away).await;
        let notice = heard(&mut notices, |n| {
            n["params"]["changes"]
                .as_array()
                .is_some_and(|changes| changes.iter().any(|c| c["item"]["kind"] == "notice"))
        })
        .await;
        assert_eq!(answered["text"], "You are now away");
        let said = item_with(&notice["changes"], "You are now away").expect("the notice");
        assert!(said["event"].is_null(), "{said}");

        // An integration's post, with a button and a menu.
        let integration = json_service(|target, asked| {
            let picked = asked["context"]["selected_option"].as_str().unwrap_or("");
            json!({ "update": { "message": format!("{target} {picked}").trim() } })
        });
        let action = |id: &str, extra: Value| {
            let mut action = json!({ "id": id, "name": id, "integration": { "url": format!("{integration}/{id}"), "context": {} } });
            for (key, value) in extra.as_object().unwrap() {
                action[key] = value.clone();
            }
            action
        };
        let attachment = json!({
            "title": "Release 1.2",
            "text": "Deploy it?",
            "fields": [{ "title": "Where", "value": "prod" }],
            "actions": [
                action("approve", json!({})),
                action("place", json!({ "type": "select", "options": [{ "text": "Prod", "value": "prod" }] })),
            ],
        });
        let release = bea
            .post(
                "posts",
                &json!({ "channel_id": channel_id, "message": "", "props": { "attachments": [attachment] } }),
            )
            .await;
        // The item of the release post, once its text starts with `start`.
        let release_id = release["id"].clone();
        let release_now = |n: &Value, start: &str| -> Option<Value> {
            n["params"]["changes"].as_array()?.iter().find_map(|c| {
                let item = &c["item"];
                (item["event"] == release_id
                    && item["text"].as_str().is_some_and(|t| t.starts_with(start)))
                .then(|| item.clone())
            })
        };
        let shown = heard(&mut notices, |n| release_now(n, "**Release").is_some()).await;
        let item = release_now(&json!({ "params": shown }), "**Release").unwrap();
        assert_eq!(
            item["text"], "**Release 1.2**\n\nDeploy it?\n\n**Where**: prod",
            "{item}"
        );
        assert_eq!(item["actions"][0]["name"], "approve", "{item}");
        assert_eq!(item["actions"][1]["options"][0]["value"], "prod", "{item}");

        let press = json!({ "account": anna, "room": channel_id, "event": release["id"],
                            "action": item["actions"][0]["id"] });
        call(&service, "press", press).await;
        heard(&mut notices, |n| release_now(n, "/approve").is_some()).await;
        let pick = json!({ "account": anna, "room": channel_id, "event": release["id"],
                           "action": item["actions"][1]["id"], "option": "prod" });
        call(&service, "press", pick).await;
        heard(&mut notices, |n| release_now(n, "/place prod").is_some()).await;
    });
}
