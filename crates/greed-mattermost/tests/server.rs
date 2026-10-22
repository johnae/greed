//! greed-mattermost against a real Mattermost, started for each test with a
//! PostgreSQL of its own in a temporary folder. Skipped, saying so, when
//! `mattermost`, `initdb` or `pg_ctl` isn't on PATH (devenv has them).

use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use greed_chat::rpc::{self, Service};
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
    fn start(name: &str) -> Option<Server> {
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
        let mattermost = Command::new(mattermost)
            .arg("server")
            .current_dir(&dir)
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

fn find(program: &str) -> Option<PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH")?)
        .map(|dir| dir.join(program))
        .find(|path| path.is_file())
}

fn free_port() -> u16 {
    TcpListener::bind(("127.0.0.1", 0))
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
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
    let Some(server) = Server::start("password") else {
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
