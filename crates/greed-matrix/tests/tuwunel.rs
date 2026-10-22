//! greed-matrix against a real homeserver: Tuwunel, started for each test in
//! a folder of its own. Skipped, saying so, when there's no `tuwunel` (devenv
//! has it; `GREED_MATRIX_TUWUNEL` names another).

use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use greed_chat::rpc::{self, Service};
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
    /// Starts one, or None when there's no Tuwunel to start.
    fn start(name: &str) -> Option<Tuwunel> {
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
"#,
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
        let session = match client.matrix_auth().register(request.clone()).await {
            Ok(_) => return,
            Err(e) => e
                .as_uiaa_response()
                .and_then(|info| info.session.clone())
                .expect("the server asks for the registration token"),
        };
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
    let Some(server) = Tuwunel::start("password") else {
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
        assert_eq!(restored["state"]["state"], "ready");

        call(&matrix, "logout", json!({ "account": "@anna:localhost" })).await;
        assert_eq!(call(&matrix, "accounts", Value::Null).await, json!([]));
        let stores = std::fs::read_dir(&data).unwrap().count();
        assert_eq!(stores, 0, "the store is gone with the account");
    });
}

#[test]
fn a_cancelled_sign_in_leaves_no_store() {
    let Some(server) = Tuwunel::start("cancel") else {
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
