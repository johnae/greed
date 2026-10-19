//! greed-mail against a real IMAP server: Dovecot, started for each test in
//! a folder of its own as the user running the tests. Skipped, saying so,
//! when there's no `dovecot` (devenv has it; `GREED_MAIL_DOVECOT` names
//! another).

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
}

impl Dovecot {
    /// Starts one, or None when there's no Dovecot to start.
    fn start(name: &str) -> Option<Dovecot> {
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
        let dovecot = Dovecot { child, port, dir };
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
        Config::parse(&format!(
            r#"
            [[account]]
            name = "test"
            address = "anna@localhost"
            user = "anna"
            imap = {{ host = "127.0.0.1", port = {}, tls = "none" }}
            password = ["echo", "secret"]
            "#,
            self.port
        ))
        .unwrap()
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
        limit: None,
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
                done: true
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
                done: true
            }
        );
        connection.close().await.unwrap();
    });
    assert_eq!(store.counts(id).unwrap(), (13, 13));
    let inbox = store.mailbox(id, "INBOX", None).unwrap();
    assert_eq!(
        store.uids(inbox.id).unwrap(),
        (1..=13).collect::<Vec<u32>>()
    );
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
        assert_eq!(connection.changes(), Changes::Qresync);
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
