//! greed-mail against a real IMAP server: Dovecot, started for each test in
//! a folder of its own as the user running the tests. Skipped, saying so,
//! when there's no `dovecot` (devenv has it; `GREED_MAIL_DOVECOT` names
//! another), and on macOS, where Dovecot can't start as a user: it limits
//! each of its processes' memory with `setrlimit(RLIMIT_DATA)`, which macOS
//! refuses whatever the size, and its log process stops at that.

use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use greed_mail::config::Config;
use greed_mail::imap::{Changes, Connection, Role};

/// A Dovecot running for one test, stopped when dropped.
struct Dovecot {
    child: Child,
    port: u16,
    dir: PathBuf,
    /// The port of an SMTP server for the account to send with.
    smtp: Option<u16>,
    /// The provider the account says it's at, as if it were.
    provider: Option<&'static str>,
    /// Whether the account sets labels (`labels = true`).
    labels: bool,
}

impl Dovecot {
    /// Starts one, or None when there's no Dovecot to start.
    fn start(name: &str) -> Option<Dovecot> {
        if cfg!(target_os = "macos") {
            eprintln!("skipped: Dovecot can't set its memory limits on macOS");
            return None;
        }
        let program = std::env::var_os("GREED_MAIL_DOVECOT")
            .map(PathBuf::from)
            .or_else(|| find("dovecot"));
        let Some(program) = program else {
            eprintln!("skipped: no dovecot on PATH (devenv has it)");
            return None;
        };
        let dir = std::env::temp_dir().join(format!("gm-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        for sub in ["run", "state", "home"] {
            std::fs::create_dir_all(dir.join(sub)).unwrap();
        }
        let port = free_port();
        std::fs::write(dir.join("dovecot.conf"), config(&dir, port, name)).unwrap();
        let child = Command::new(program)
            .arg("-F")
            .arg("-c")
            .arg(dir.join("dovecot.conf"))
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let dovecot = Dovecot {
            child,
            port,
            dir,
            smtp: None,
            provider: None,
            labels: false,
        };
        let started = Instant::now();
        while TcpStream::connect(("127.0.0.1", port)).is_err() {
            assert!(
                started.elapsed() < Duration::from_secs(10),
                "dovecot didn't start: {}",
                std::fs::read_to_string(dovecot.dir.join("log")).unwrap_or_default()
            );
            std::thread::sleep(Duration::from_millis(50));
        }
        Some(dovecot)
    }

    /// An account for user `anna`, whose password is "secret".
    fn account(&self) -> Config {
        Config::parse(&self.account_toml()).unwrap()
    }

    /// That account as `mail.toml` says it.
    fn account_toml(&self) -> String {
        let smtp = self.smtp.map_or(String::new(), |port| {
            format!(r#"smtp = {{ host = "127.0.0.1", port = {port}, tls = "none" }}"#)
        });
        let provider = self
            .provider
            .map_or(String::new(), |p| format!(r#"provider = "{p}""#));
        let labels = if self.labels { "labels = true" } else { "" };
        format!(
            r#"
            [[account]]
            name = "test"
            address = "anna@localhost"
            user = "anna"
            imap = {{ host = "127.0.0.1", port = {}, tls = "none" }}
            {smtp}
            {provider}
            {labels}
            password = ["echo", "secret"]
            "#,
            self.port
        )
    }
}

impl Drop for Dovecot {
    fn drop(&mut self) {
        // TERM, so the master stops the processes it started too.
        let _ = Command::new("kill")
            .arg(self.child.id().to_string())
            .status();
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

fn id(flag: &str) -> String {
    let out = Command::new("id").arg(flag).output().unwrap();
    String::from_utf8(out.stdout).unwrap().trim().to_string()
}

/// A Dovecot 2.4 config for `dir`: IMAP without TLS on `port`, every user
/// with the password "secret", maildirs under `dir`.
fn config(dir: &Path, port: u16, name: &str) -> String {
    let dir = dir.display();
    let (user, group, uid, gid) = (id("-un"), id("-gn"), id("-u"), id("-g"));
    format!(
        r"dovecot_config_version = 2.4.0
dovecot_storage_version = 2.4.0
base_dir = {dir}/run
state_dir = {dir}/state
log_path = {dir}/log
instance_name = gm-{name}
default_internal_user = {user}
default_internal_group = {group}
default_login_user = {user}
protocols {{
  imap = yes
}}
listen = 127.0.0.1
ssl = no
auth_allow_cleartext = yes
service imap-login {{
  chroot =
  inet_listener imap {{
    port = {port}
  }}
  inet_listener imaps {{
    port = 0
  }}
}}
service anvil {{
  chroot =
}}
passdb static {{
  password = secret
}}
userdb static {{
  fields {{
    uid = {uid}
    gid = {gid}
    home = {dir}/home/%{{user}}
  }}
}}
mail_driver = maildir
mail_path = ~/Maildir
namespace inbox {{
  inbox = yes
  separator = /
  mailbox Sent {{
    special_use = \Sent
    auto = create
  }}
  mailbox Trash {{
    special_use = \Trash
    auto = create
  }}
  mailbox Archive {{
    special_use = \Archive
    auto = create
  }}
}}
"
    )
}

/// Puts a message in `anna`'s INBOX the way a delivery would, read when
/// `seen`.
fn deliver(dovecot: &Dovecot, n: u32, seen: bool) {
    let maildir = dovecot.dir.join("home/anna/Maildir");
    for sub in ["cur", "new", "tmp"] {
        std::fs::create_dir_all(maildir.join(sub)).unwrap();
    }
    let message = format!(
        "From: Zoë <zoe@example.com>\r\nTo: anna@localhost\r\nSubject: note {n}\r\n\
         Date: Sun, 19 Oct 2026 10:{n:02}:00 +0200\r\nMessage-ID: <{n}@example.com>\r\n\r\nbody {n}\r\n"
    );
    let (sub, flags) = if seen { ("cur", ":2,S") } else { ("new", "") };
    std::fs::write(
        maildir
            .join(sub)
            .join(format!("17600{n:05}.M{n}P1.test{flags}")),
        message,
    )
    .unwrap();
}

#[test]
fn a_mailbox_syncs_into_the_store_and_then_only_what_arrives() {
    use greed_mail::store::Store;
    use greed_mail::sync::{self, Options, Synced};

    let Some(dovecot) = Dovecot::start("sync") else {
        return;
    };
    for n in 1..=12 {
        deliver(&dovecot, n, n % 2 == 0);
    }
    let config = dovecot.account();
    let account = &config.accounts[0];
    let mut store = Store::open(&dovecot.dir.join("store")).unwrap();
    let id = store.account(&account.name, &account.address).unwrap();
    let options = Options {
        batch: 5,
        ..Options::default()
    };
    run(async {
        let mut connection = Connection::open(&account.imap(), account.user(), "secret")
            .await
            .unwrap();
        let first = sync::mailbox(
            &mut connection,
            &mut store,
            id,
            "INBOX",
            Some(Role::Inbox),
            options,
        )
        .await
        .unwrap();
        assert_eq!(
            first,
            Synced {
                fetched: 12,
                done: true,
                ..Synced::default()
            }
        );
        deliver(&dovecot, 13, false);
        let next = sync::mailbox(
            &mut connection,
            &mut store,
            id,
            "INBOX",
            Some(Role::Inbox),
            options,
        )
        .await
        .unwrap();
        assert_eq!(
            next,
            Synced {
                fetched: 1,
                done: true,
                ..Synced::default()
            }
        );
        // Read on another device, and one deleted there.
        maildir(&dovecot, 3, Some("S"));
        maildir(&dovecot, 4, None);
        let after = sync::mailbox(
            &mut connection,
            &mut store,
            id,
            "INBOX",
            Some(Role::Inbox),
            options,
        )
        .await
        .unwrap();
        assert_eq!((after.fetched, after.changed, after.gone), (0, 1, 1));
        let bodies = sync::bodies(&mut connection, &mut store, id, "INBOX", options)
            .await
            .unwrap();
        assert_eq!(bodies, 12, "one for each message there");
        connection.close().await.unwrap();
    });
    assert_eq!(store.counts(id).unwrap(), (12, 12));
    let mut index = greed_index::index::Index::open(&dovecot.dir.join("index.db")).unwrap();
    assert_eq!(
        greed_mail::indexing::catch_up(&mut store, &mut index).unwrap(),
        12
    );
    assert_eq!(
        index.count().unwrap(),
        24,
        "each message, and its own thread"
    );
    let inbox = store.mailbox(id, "INBOX", None).unwrap();
    let left: Vec<u32> = (1..=13).filter(|&uid| uid != 4).collect();
    assert_eq!(store.uids(inbox.id).unwrap(), left);
}

/// Changes message `n` in `anna`'s maildir as another client would: gives
/// it the maildir flags `flags` ("S" read), or deletes it without.
fn maildir(dovecot: &Dovecot, n: u32, flags: Option<&str>) {
    let maildir = dovecot.dir.join("home/anna/Maildir");
    let prefix = format!("17600{n:05}.");
    let file = ["cur", "new"]
        .iter()
        .flat_map(|sub| std::fs::read_dir(maildir.join(sub)).unwrap())
        .map(|entry| entry.unwrap().path())
        .find(|path| {
            path.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with(&prefix)
        })
        .unwrap();
    match flags {
        Some(flags) => {
            let name = file.file_name().unwrap().to_string_lossy().to_string();
            let base = name.split(':').next().unwrap();
            std::fs::rename(&file, maildir.join("cur").join(format!("{base}:2,{flags}"))).unwrap();
        }
        None => std::fs::remove_file(&file).unwrap(),
    }
}

fn run<F: Future>(future: F) -> F::Output {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap()
        .block_on(future)
}

#[test]
fn logs_in_and_lists_mailboxes_with_their_roles() {
    let Some(dovecot) = Dovecot::start("list") else {
        return;
    };
    let config = dovecot.account();
    let account = &config.accounts[0];
    run(async {
        let password = account.password().unwrap();
        let mut connection = Connection::open(&account.imap(), account.user(), &password)
            .await
            .unwrap();
        assert_eq!(connection.tracking(), Changes::Qresync);
        assert!(connection.capabilities().iter().any(|c| c == "IDLE"));
        let mut roles: Vec<(String, Option<Role>)> = connection
            .mailboxes()
            .await
            .unwrap()
            .into_iter()
            .map(|m| (m.name, m.role))
            .collect();
        roles.sort();
        assert_eq!(
            roles,
            [
                ("Archive".into(), Some(Role::Archive)),
                ("INBOX".into(), Some(Role::Inbox)),
                ("Sent".into(), Some(Role::Sent)),
                ("Trash".into(), Some(Role::Trash)),
            ]
        );
        let inbox = connection.status("INBOX").await.unwrap();
        assert_eq!(inbox.messages, 0);
        assert!(inbox.uid_validity.is_some() && inbox.highest_modseq.is_some());
        connection.close().await.unwrap();
    });
}

#[test]
fn a_wrong_password_says_who_couldnt_log_in() {
    let Some(dovecot) = Dovecot::start("wrong") else {
        return;
    };
    let config = dovecot.account();
    let account = &config.accounts[0];
    run(async {
        let Err(trouble) = Connection::open(&account.imap(), account.user(), "wrong").await else {
            panic!("logged in with the wrong password");
        };
        assert!(trouble.0.contains("logging in as anna"), "{trouble}");
    });
}

/// A `greed-mail serve` to talk to, line by line.
struct Served {
    child: Child,
    input: std::process::ChildStdin,
    lines: std::sync::mpsc::Receiver<String>,
    next: u64,
}

impl Served {
    fn start(dovecot: &Dovecot) -> Served {
        let config = dovecot.dir.join("mail.toml");
        std::fs::write(&config, dovecot.account_toml()).unwrap();
        let mut child = Command::new(env!("CARGO_BIN_EXE_greed-mail"))
            .arg("--config")
            .arg(&config)
            .arg("--store")
            .arg(dovecot.dir.join("store"))
            .arg("serve")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let input = child.stdin.take().unwrap();
        let output = child.stdout.take().unwrap();
        let (send, lines) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            use std::io::BufRead;
            for line in std::io::BufReader::new(output)
                .lines()
                .map_while(Result::ok)
            {
                if send.send(line).is_err() {
                    break;
                }
            }
        });
        Served {
            child,
            input,
            lines,
            next: 0,
        }
    }

    /// The next message it sends, as JSON.
    fn read(&self) -> serde_json::Value {
        let line = self
            .lines
            .recv_timeout(Duration::from_secs(30))
            .expect("greed-mail serve said nothing");
        serde_json::from_str(&line).unwrap()
    }

    /// Waits for the notification `method`.
    fn wait_for(&self, method: &str) -> serde_json::Value {
        loop {
            let message = self.read();
            if message["method"] == method {
                return message["params"].clone();
            }
        }
    }

    /// Asks `method` and gives the result, passing over notifications.
    fn ask(&mut self, method: &str, params: &serde_json::Value) -> serde_json::Value {
        let answer = self.answer(method, params);
        assert!(answer["error"].is_null(), "{answer}");
        answer["result"].clone()
    }

    /// Asks `method` and gives the whole answer, an error or a result.
    fn answer(&mut self, method: &str, params: &serde_json::Value) -> serde_json::Value {
        use std::io::Write;
        self.next += 1;
        let request = serde_json::json!({
            "jsonrpc": "2.0", "id": self.next, "method": method, "params": params,
        });
        writeln!(self.input, "{request}").unwrap();
        loop {
            let message = self.read();
            if message["id"] == self.next {
                return message;
            }
        }
    }
}

#[test]
fn serve_syncs_in_the_background_and_answers_the_client() {
    use greed_index::index::{Index, View};
    use greed_index::query::{Node, Schema};

    let Some(dovecot) = Dovecot::start("serve") else {
        return;
    };
    for n in 1..=3 {
        deliver(&dovecot, n, n == 1);
    }
    let mut served = Served::start(&dovecot);
    served.wait_for("changed");
    let path = served.ask("index", &serde_json::json!({}));
    let index = Index::open_read(Path::new(path["path"].as_str().unwrap())).unwrap();
    let word = Node {
        kind: "word".into(),
        text: Some("note".into()),
        ..Node::default()
    };
    let keys = index
        .search(Some(&word), &Schema::default(), &View::default())
        .unwrap()
        .keys;
    assert_eq!(keys.len(), 3, "{keys:?}");
    let summaries = served.ask("summaries", &serde_json::json!({ "keys": keys }));
    let mut subjects: Vec<&str> = summaries
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["subject"].as_str().unwrap())
        .collect();
    subjects.sort_unstable();
    assert_eq!(subjects, ["note 1", "note 2", "note 3"]);
    let read = summaries
        .as_array()
        .unwrap()
        .iter()
        .filter(|s| s["unread"] == false)
        .count();
    assert_eq!(read, 1);
    let thread = served.ask("thread", &serde_json::json!({ "key": keys[0] }));
    let text = thread["messages"][0]["text"].as_str().unwrap_or("");
    assert!(text.starts_with("body "), "{thread}");
    let status = served.ask("status", &serde_json::json!({}));
    assert_eq!(status["accounts"][0]["messages"], 3, "{status}");
    drop(served.input);
    let started = Instant::now();
    loop {
        if served.child.try_wait().unwrap().is_some() {
            break;
        }
        assert!(
            started.elapsed() < Duration::from_secs(10),
            "it didn't stop when its input closed"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn new_mail_comes_at_once_through_idle() {
    let Some(dovecot) = Dovecot::start("idle") else {
        return;
    };
    deliver(&dovecot, 1, false);
    let mut served = Served::start(&dovecot);
    served.wait_for("changed");
    // Until it has nothing left to do and waits in IDLE.
    let started = Instant::now();
    loop {
        let status = served.ask("status", &serde_json::json!({}));
        if status["accounts"][0]["done"] == true {
            break;
        }
        assert!(started.elapsed() < Duration::from_secs(20), "{status}");
        std::thread::sleep(Duration::from_millis(100));
    }
    std::thread::sleep(Duration::from_millis(500));
    deliver(&dovecot, 2, false);
    let arrived = Instant::now();
    served.wait_for("changed");
    assert!(
        arrived.elapsed() < Duration::from_secs(15),
        "new mail took {:?}; without IDLE it waits twenty minutes",
        arrived.elapsed()
    );
    let status = served.ask("status", &serde_json::json!({}));
    assert_eq!(status["accounts"][0]["messages"], 2, "{status}");
}

/// The names of the message files in `anna`'s `folder` (INBOX for "").
fn files(dovecot: &Dovecot, folder: &str) -> Vec<String> {
    let mut maildir = dovecot.dir.join("home/anna/Maildir");
    if !folder.is_empty() {
        maildir = maildir.join(format!(".{folder}"));
    }
    let mut names = Vec::new();
    for sub in ["cur", "new"] {
        for entry in std::fs::read_dir(maildir.join(sub)).into_iter().flatten() {
            names.push(entry.unwrap().file_name().to_string_lossy().into_owned());
        }
    }
    names
}

/// Waits until `done` holds, saying `what` if it doesn't in time.
fn wait_until(what: &str, mut done: impl FnMut() -> bool) {
    let started = Instant::now();
    while !done() {
        assert!(started.elapsed() < Duration::from_secs(20), "{what}");
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[test]
fn mail_marked_moved_and_deleted_here_is_so_on_the_server() {
    let Some(dovecot) = Dovecot::start("act") else {
        return;
    };
    deliver(&dovecot, 1, false);
    deliver(&dovecot, 2, false);
    let mut served = Served::start(&dovecot);
    served.wait_for("changed");
    let mut keys = Vec::new();
    wait_until("both in the index", || {
        keys = message_keys(&mut served);
        keys.len() == 2
    });
    let summaries = served.ask("summaries", &serde_json::json!({ "keys": keys }));
    let key = |subject: &str| -> String {
        let found = summaries.as_array().unwrap().iter();
        let mut found = found.filter(|s| s["subject"] == subject);
        found.next().unwrap()["key"].as_str().unwrap().to_string()
    };
    let (one, two) = (key("note 1"), key("note 2"));
    assert_eq!(act(&mut served, "read", &one), 1);
    assert_eq!(act(&mut served, "read", &one), 0, "read already");
    let shown = served.ask("summaries", &serde_json::json!({ "keys": [one] }));
    assert_eq!(shown[0]["unread"], false, "read here at once: {shown}");
    wait_until("read on the server", || {
        files(&dovecot, "")
            .iter()
            .any(|f| f.contains("M1P1") && f.ends_with('S'))
    });
    assert_eq!(act(&mut served, "archive", &two), 1);
    wait_until("in the archive on the server", || {
        files(&dovecot, "Archive").len() == 1 && files(&dovecot, "").len() == 1
    });
    act(&mut served, "trash", &two);
    wait_until("in the trash", || files(&dovecot, "Trash").len() == 1);
    // The sync finds it in the trash under its UID there; then it can go
    // for good.
    wait_until("found in the trash", || {
        let thread = served.ask("thread", &serde_json::json!({ "key": two }));
        !thread.is_null() && {
            let status = served.ask("status", &serde_json::json!({}));
            status["accounts"][0]["done"] == true
        }
    });
    // Only when asked for: it can't be undone.
    let asked = served.ask(
        "act",
        &serde_json::json!({ "action": "trash", "keys": [two] }),
    );
    assert_eq!(
        (asked["changed"].clone(), asked["in_trash"].clone()),
        (0.into(), 1.into())
    );
    let params = serde_json::json!({ "action": "trash", "keys": [two], "for_good": true });
    assert_eq!(served.ask("act", &params)["changed"], 1);
    wait_until("gone for good", || files(&dovecot, "Trash").is_empty());
    let thread = served.ask("thread", &serde_json::json!({ "key": two }));
    assert!(thread.is_null(), "gone here too: {thread}");
}

/// Asks `served` to make `action` on the message `key`, giving how many
/// it changed.
fn act(served: &mut Served, action: &str, key: &str) -> serde_json::Value {
    let params = serde_json::json!({ "action": action, "keys": [key] });
    served.ask("act", &params)["changed"].clone()
}

/// What a fake SMTP server was given: each message's recipients and text.
type Mailed = std::sync::Arc<std::sync::Mutex<Vec<(Vec<String>, String)>>>;

/// An SMTP server on this machine that takes every message, logging in
/// anyone, and keeps them in `Mailed`; gives its port.
fn fake_smtp() -> (u16, Mailed) {
    use std::io::{BufRead, BufReader, Write};

    let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let port = listener.local_addr().unwrap().port();
    let mailed = Mailed::default();
    let keep = mailed.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { break };
            let mut out = stream.try_clone().unwrap();
            let mut lines = BufReader::new(stream);
            let mut say = |s: &str| out.write_all(format!("{s}\r\n").as_bytes()).unwrap();
            say("220 fake ESMTP");
            let mut recipients = Vec::new();
            let mut line = String::new();
            while lines.read_line(&mut line).unwrap_or(0) > 0 {
                let command = line.trim_end().to_uppercase();
                if command.starts_with("EHLO") {
                    say("250-fake");
                    say("250 AUTH PLAIN LOGIN");
                } else if command.starts_with("AUTH") {
                    say("235 2.7.0 in");
                } else if command.starts_with("RCPT TO:") {
                    recipients.push(line.trim_end()[8..].trim_matches(['<', '>']).to_string());
                    say("250 ok");
                } else if command == "DATA" {
                    say("354 go on");
                    let mut text = String::new();
                    let mut data = String::new();
                    while lines.read_line(&mut data).unwrap() > 0 && data != ".\r\n" {
                        text.push_str(&data);
                        data.clear();
                    }
                    keep.lock()
                        .unwrap()
                        .push((std::mem::take(&mut recipients), text));
                    say("250 2.0.0 queued");
                } else if command == "QUIT" {
                    say("221 bye");
                    break;
                } else {
                    say("250 ok");
                }
                line.clear();
            }
        }
    });
    (port, mailed)
}

#[test]
fn a_reply_is_sent_filed_in_sent_and_its_original_marked_answered() {
    let Some(mut dovecot) = Dovecot::start("send") else {
        return;
    };
    let (port, mailed) = fake_smtp();
    dovecot.smtp = Some(port);
    deliver(&dovecot, 1, true);
    let mut served = Served::start(&dovecot);
    served.wait_for("changed");
    let path = served.ask("index", &serde_json::json!({}));
    let index =
        greed_index::index::Index::open_read(Path::new(path["path"].as_str().unwrap())).unwrap();
    let key = index
        .search(
            None,
            &greed_index::query::Schema::default(),
            &greed_index::index::View::default(),
        )
        .unwrap()
        .keys
        .into_iter()
        .find(|k| k.starts_with("m:"))
        .unwrap();
    let mut draft = served.ask("draft", &serde_json::json!({ "key": key }));
    assert_eq!(draft["to"], "Zoë <zoe@example.com>", "{draft}");
    assert_eq!(draft["subject"], "Re: note 1");
    let quoted = draft["text"].as_str().unwrap().to_string();
    assert!(quoted.contains("Zoë wrote:\n> body 1"), "{quoted}");
    draft["text"] = format!("Thanks!{quoted}").into();
    served.ask("send", &draft);
    served.wait_for("sent");
    let got = mailed.lock().unwrap().clone();
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].0, ["zoe@example.com"]);
    assert!(
        got[0].1.contains("In-Reply-To: <1@example.com>"),
        "{}",
        got[0].1
    );
    assert!(got[0].1.contains("Thanks!"), "{}", got[0].1);
    wait_until("a copy in Sent", || files(&dovecot, "Sent").len() == 1);
    wait_until("the original answered", || {
        files(&dovecot, "")
            .iter()
            .any(|f| f.contains("M1P1") && f.contains('R'))
    });
}

/// The keys of the messages `served`'s index has.
fn message_keys(served: &mut Served) -> Vec<String> {
    let path = served.ask("index", &serde_json::json!({}));
    let index =
        greed_index::index::Index::open_read(Path::new(path["path"].as_str().unwrap())).unwrap();
    index
        .search(
            None,
            &greed_index::query::Schema::default(),
            &greed_index::index::View::default(),
        )
        .unwrap()
        .keys
        .into_iter()
        .filter(|k| k.starts_with("m:"))
        .collect()
}

#[test]
fn a_tag_is_a_keyword_on_the_server_and_comes_off_again() {
    let Some(dovecot) = Dovecot::start("tags") else {
        return;
    };
    deliver(&dovecot, 1, true);
    let mut served = Served::start(&dovecot);
    served.wait_for("changed");
    let key = message_keys(&mut served).remove(0);
    let tag = |served: &mut Served, action: &str| {
        let params = serde_json::json!({ "action": action, "tag": "garden", "keys": [key] });
        served.ask("act", &params)["changed"].clone()
    };
    assert_eq!(tag(&mut served, "tag"), 1);
    let shown = served.ask("summaries", &serde_json::json!({ "keys": [key] }));
    assert_eq!(
        shown[0]["tags"],
        serde_json::json!(["Inbox", "garden"]),
        "{shown}"
    );
    let keywords = dovecot.dir.join("home/anna/Maildir/dovecot-keywords");
    // Dovecot keeps a keyword as a letter among the flags at the end of the
    // file's name, a for the first it was told of.
    let tagged = || {
        std::fs::read_to_string(&keywords).is_ok_and(|k| k.contains("garden"))
            && files(&dovecot, "").iter().any(|f| {
                f.contains("M1P1")
                    && f.rsplit_once(":2,")
                        .is_some_and(|(_, flags)| flags.contains('a'))
            })
    };
    wait_until("tagged on the server", tagged);
    assert_eq!(tag(&mut served, "untag"), 1);
    wait_until("untagged on the server", || !tagged());
    let refused = served.answer(
        "act",
        &serde_json::json!({ "action": "tag", "tag": "two words", "keys": [key] }),
    );
    assert!(
        refused["error"]["message"]
            .as_str()
            .unwrap_or("")
            .contains("can't be a tag"),
        "{refused}"
    );
}

#[test]
fn tags_on_proton_wait_until_labels_are_checked_against_bridge() {
    let Some(mut dovecot) = Dovecot::start("proton-tags") else {
        return;
    };
    dovecot.provider = Some("proton-bridge");
    deliver(&dovecot, 1, true);
    let mut served = Served::start(&dovecot);
    served.wait_for("changed");
    let key = message_keys(&mut served).remove(0);
    let refused = served.answer(
        "act",
        &serde_json::json!({ "action": "tag", "tag": "garden", "keys": [key] }),
    );
    assert!(
        refused["error"]["message"]
            .as_str()
            .unwrap_or("")
            .contains("Proton"),
        "{refused}"
    );
    std::thread::sleep(Duration::from_millis(500));
    let keywords = dovecot.dir.join("home/anna/Maildir/dovecot-keywords");
    assert!(
        !std::fs::read_to_string(keywords).is_ok_and(|k| k.contains("garden")),
        "nothing went to the server"
    );
}

#[test]
fn an_attachment_is_fetched_whole_and_saved_or_kept() {
    let Some(dovecot) = Dovecot::start("attached") else {
        return;
    };
    let maildir = dovecot.dir.join("home/anna/Maildir");
    for sub in ["cur", "new", "tmp"] {
        std::fs::create_dir_all(maildir.join(sub)).unwrap();
    }
    // Big enough that the first fetch, capped, doesn't have all of it.
    let plan = "step: dig, sow, water\r\n".repeat(16_000);
    let message = format!(
        "From: Zoë <zoe@example.com>\r\nTo: anna@localhost\r\nSubject: the plan\r\n\
         Date: Sun, 19 Oct 2020 10:00:00 +0200\r\nMessage-ID: <plan@example.com>\r\n\
         MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"b\"\r\n\r\n\
         --b\r\nContent-Type: text/plain\r\n\r\nsee attached\r\n\
         --b\r\nContent-Type: text/plain; name=\"../plan.txt\"\r\n\
         Content-Disposition: attachment; filename=\"../plan.txt\"\r\n\r\n{plan}\r\n--b--\r\n"
    );
    std::fs::write(maildir.join("cur/1760000001.M1P1.test:2,S"), message).unwrap();
    let mut served = Served::start(&dovecot);
    served.wait_for("changed");
    let key = message_keys(&mut served).remove(0);
    let shown = served.ask("summaries", &serde_json::json!({ "keys": [key] }));
    assert_eq!(shown[0]["attached"], 1, "a list says it: {shown}");
    let asked = served.ask("attachment", &serde_json::json!({ "key": key, "index": 0 }));
    assert_eq!(asked["waiting"], true, "{asked}");
    let got = served.wait_for("attachment");
    let kept = std::path::PathBuf::from(got["path"].as_str().unwrap_or_else(|| panic!("{got}")));
    assert_eq!(
        kept.file_name().unwrap(),
        "plan.txt",
        "no folders from its name"
    );
    assert!(
        kept.starts_with(dovecot.dir.join("store")),
        "{}",
        kept.display()
    );
    assert_eq!(
        std::fs::read(&kept).unwrap(),
        plan.as_bytes(),
        "all of it, though the first fetch had only the start"
    );
    let again = served.ask("attachment", &serde_json::json!({ "key": key, "index": 0 }));
    assert_eq!(again["path"], got["path"], "kept: given at once");
    let to = dovecot.dir.join("saved/the plan.txt");
    served.ask(
        "attachment",
        &serde_json::json!({ "key": key, "index": 0, "to": to }),
    );
    let saved = served.wait_for("attachment");
    assert_eq!(saved["path"], serde_json::json!(to), "{saved}");
    assert_eq!(std::fs::read(&to).unwrap(), plan.as_bytes());
    served.ask(
        "attachment",
        &serde_json::json!({ "key": key, "index": 0, "to": to }),
    );
    let over = served.wait_for("attachment");
    assert!(
        over["error"]
            .as_str()
            .unwrap_or("")
            .contains("is there already"),
        "nothing written over: {over}"
    );
}

#[test]
fn what_is_attached_to_recent_mail_is_fetched_ahead_and_given_at_once() {
    let Some(dovecot) = Dovecot::start("ahead") else {
        return;
    };
    let maildir = dovecot.dir.join("home/anna/Maildir");
    for sub in ["cur", "new", "tmp"] {
        std::fs::create_dir_all(maildir.join(sub)).unwrap();
    }
    // Today's, and one from long ago that waits until it's asked for.
    let today = jiff::Zoned::now()
        .strftime("%a, %d %b %Y %H:%M:%S %z")
        .to_string();
    for (n, date) in [(1, today.as_str()), (2, "Sun, 19 Oct 2020 10:00:00 +0200")] {
        let message = format!(
            "From: Zoë <zoe@example.com>\r\nTo: anna@localhost\r\nSubject: seeds {n}\r\n\
             Date: {date}\r\nMessage-ID: <seeds{n}@example.com>\r\n\
             MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"b\"\r\n\r\n\
             --b\r\nContent-Type: text/plain\r\n\r\nsee attached\r\n\
             --b\r\nContent-Type: text/plain; name=\"seeds.txt\"\r\n\
             Content-Disposition: attachment; filename=\"seeds.txt\"\r\n\r\ntomato, bean\r\n--b--\r\n"
        );
        std::fs::write(
            maildir.join(format!("cur/176000000{n}.M{n}P1.test:2,S")),
            message,
        )
        .unwrap();
    }
    let mut served = Served::start(&dovecot);
    wait_until("synced", || {
        let status = served.ask("status", &serde_json::json!({}));
        status["accounts"][0]["done"] == true
    });
    let keys = message_keys(&mut served);
    let shown = served.ask("summaries", &serde_json::json!({ "keys": keys }));
    let key_of = |subject: &str| {
        shown
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["subject"] == subject)
            .map(|s| s["key"].as_str().unwrap().to_string())
            .unwrap()
    };
    let recent = served.ask(
        "attachment",
        &serde_json::json!({ "key": key_of("seeds 1"), "index": 0 }),
    );
    let kept = recent["path"]
        .as_str()
        .unwrap_or_else(|| panic!("at once: {recent}"));
    assert_eq!(
        std::fs::read_to_string(kept).unwrap().trim(),
        "tomato, bean"
    );
    let old = served.ask(
        "attachment",
        &serde_json::json!({ "key": key_of("seeds 2"), "index": 0 }),
    );
    assert_eq!(old["waiting"], true, "old mail's waits to be asked: {old}");
}

#[test]
fn mail_coming_after_the_first_sync_is_said_to_have_arrived() {
    let Some(dovecot) = Dovecot::start("arrived") else {
        return;
    };
    for n in 1..=3 {
        deliver(&dovecot, n, true);
    }
    let mut served = Served::start(&dovecot);
    let started = Instant::now();
    loop {
        let status = served.ask("status", &serde_json::json!({}));
        if status["accounts"][0]["done"] == true {
            break;
        }
        assert!(started.elapsed() < Duration::from_secs(20), "{status}");
        std::thread::sleep(Duration::from_millis(100));
    }
    deliver(&dovecot, 4, false);
    served.ask("sync", &serde_json::json!({}));
    // What the first sync brought never counts as arrived, so the first
    // word of it is only the new one.
    let arrived = served.wait_for("arrived");
    let keys = arrived["keys"].as_array().unwrap();
    assert_eq!(keys.len(), 1, "{arrived}");
    let shown = served.ask("summaries", &serde_json::json!({ "keys": keys }));
    assert_eq!(shown[0]["subject"], "note 4", "{shown}");
}

#[test]
fn an_invite_shows_in_its_thread_and_is_answered_to_its_organizer() {
    let Some(mut dovecot) = Dovecot::start("invite") else {
        return;
    };
    let (port, mailed) = fake_smtp();
    dovecot.smtp = Some(port);
    let maildir = dovecot.dir.join("home/anna/Maildir");
    for sub in ["cur", "new", "tmp"] {
        std::fs::create_dir_all(maildir.join(sub)).unwrap();
    }
    let calendar = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\n\
        UID:plans@example.com\r\nSEQUENCE:0\r\nSUMMARY:Garden plans\r\n\
        DTSTART:20261024T080000Z\r\nDTEND:20261024T090000Z\r\n\
        ORGANIZER;CN=Bob:mailto:bob@example.com\r\n\
        ATTENDEE;CN=Anna;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:anna@localhost\r\n\
        END:VEVENT\r\nEND:VCALENDAR\r\n";
    let message = format!(
        "From: Bob <bob@example.com>\r\nTo: anna@localhost\r\nSubject: Invitation: Garden plans\r\n\
         Date: Sun, 19 Oct 2026 10:00:00 +0200\r\nMessage-ID: <invite@example.com>\r\n\
         MIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary=\"b\"\r\n\r\n\
         --b\r\nContent-Type: text/plain\r\n\r\nYou're invited.\r\n\
         --b\r\nContent-Type: text/calendar; charset=utf-8; method=REQUEST\r\n\r\n{calendar}\
         --b--\r\n"
    );
    std::fs::write(maildir.join("new/1760000001.M1P1.test"), message).unwrap();
    let mut served = Served::start(&dovecot);
    served.wait_for("changed");
    let key = message_keys(&mut served).remove(0);
    let thread = served.ask("thread", &serde_json::json!({ "key": key }));
    let invite = if thread["messages"][0]["invite"].is_null() {
        served.wait_for("changed");
        let thread = served.ask("thread", &serde_json::json!({ "key": key }));
        thread["messages"][0]["invite"].clone()
    } else {
        thread["messages"][0]["invite"].clone()
    };
    assert_eq!(invite["summary"], "Garden plans", "{invite}");
    assert_eq!(invite["answer"], "NEEDS-ACTION", "{invite}");
    served.ask(
        "respond",
        &serde_json::json!({ "key": key, "answer": "accepted" }),
    );
    served.wait_for("sent");
    let got = mailed.lock().unwrap().clone();
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].0, ["bob@example.com"]);
    let sent = greed_mail::body::Body::of(got[0].1.as_bytes(), got[0].1.len());
    let reply = sent.calendar.expect("the answer carries its calendar");
    assert!(reply.contains("METHOD:REPLY"), "{reply}");
    assert!(
        reply.contains("PARTSTAT=ACCEPTED:mailto:anna@localhost"),
        "{reply}"
    );
    assert!(
        got[0].1.contains("Subject: Accepted: Garden plans"),
        "{}",
        got[0].1
    );
}

#[test]
fn undo_moves_back_what_the_server_has_and_takes_back_mail_just_sent() {
    let Some(mut dovecot) = Dovecot::start("undo") else {
        return;
    };
    let (port, mailed) = fake_smtp();
    dovecot.smtp = Some(port);
    deliver(&dovecot, 1, false);
    let mut served = Served::start(&dovecot);
    served.wait_for("changed");
    let key = message_keys(&mut served).remove(0);
    assert_eq!(act(&mut served, "archive", &key), 1);
    wait_until("in the archive on the server", || {
        files(&dovecot, "Archive").len() == 1 && files(&dovecot, "").is_empty()
    });
    let undone = served.ask("undo", &serde_json::json!({}));
    assert_eq!(undone["undone"], "changes", "{undone}");
    wait_until("back in the inbox on the server", || {
        files(&dovecot, "Archive").is_empty() && files(&dovecot, "").len() == 1
    });
    let again = served.answer("undo", &serde_json::json!({}));
    assert_eq!(again["error"]["message"], "nothing to undo", "{again}");
    let draft = serde_json::json!({ "to": "zoe@example.com", "subject": "hi", "text": "x" });
    let posted = served.ask("send", &draft);
    assert_eq!(posted["seconds"], 10, "{posted}");
    let undone = served.ask("undo", &serde_json::json!({}));
    assert_eq!(undone["undone"], "sent", "{undone}");
    std::thread::sleep(Duration::from_secs(11));
    served.ask("sync", &serde_json::json!({}));
    std::thread::sleep(Duration::from_secs(1));
    assert!(mailed.lock().unwrap().is_empty(), "never sent");
}

#[test]
fn a_label_on_proton_is_a_copy_in_its_mailbox_and_comes_off_leaving_the_message() {
    let Some(mut dovecot) = Dovecot::start("proton-labels") else {
        return;
    };
    dovecot.provider = Some("proton-bridge");
    dovecot.labels = true;
    // Bridge's label, as a mailbox under Labels/.
    let label = dovecot.dir.join("home/anna/Maildir/.Labels.Work");
    for sub in ["cur", "new", "tmp"] {
        std::fs::create_dir_all(label.join(sub)).unwrap();
    }
    deliver(&dovecot, 1, true);
    let mut served = Served::start(&dovecot);
    served.wait_for("changed");
    let key = message_keys(&mut served).remove(0);
    let missing = served.answer(
        "act",
        &serde_json::json!({ "action": "tag", "tag": "Garden", "keys": [key] }),
    );
    let said = missing["error"]["message"].as_str().unwrap_or("");
    assert!(said.contains("no label Garden"), "{missing}");
    let tag = serde_json::json!({ "action": "tag", "tag": "Work", "keys": [key] });
    assert_eq!(served.ask("act", &tag)["changed"], 1);
    wait_until("a copy in the label", || {
        files(&dovecot, "Labels.Work").len() == 1 && files(&dovecot, "").len() == 1
    });
    let shown = served.ask("summaries", &serde_json::json!({ "keys": [key] }));
    assert!(
        shown[0]["tags"]
            .as_array()
            .unwrap()
            .iter()
            .any(|t| t == "Work"),
        "{shown}"
    );
    // Found there by the next sync, under its UID there; then it can come off.
    wait_until("synced", || {
        let status = served.ask("status", &serde_json::json!({}));
        status["accounts"][0]["done"] == true
    });
    std::thread::sleep(Duration::from_millis(500));
    let untag = serde_json::json!({ "action": "untag", "tag": "Work", "keys": [key] });
    assert_eq!(served.ask("act", &untag)["changed"], 1);
    wait_until("out of the label, still in the inbox", || {
        files(&dovecot, "Labels.Work").is_empty() && files(&dovecot, "").len() == 1
    });
}
