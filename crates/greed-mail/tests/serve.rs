//! `greed-mail serve` without a mail server: what it does while an
//! account's password command keeps it waiting.

use std::io::{BufRead, Write};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[test]
fn a_password_command_that_waits_is_told_and_doesnt_stop_answering_or_quitting() {
    let dir = std::env::temp_dir().join(format!("greed-mail-serve-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let config = dir.join("mail.toml");
    // A password manager waiting to be unlocked, for a server never reached.
    std::fs::write(
        &config,
        "[[account]]\nname = \"home\"\naddress = \"anna@example.com\"\n\
         imap = { host = \"127.0.0.1\", port = 9, tls = \"none\" }\n\
         password = [\"sleep\", \"60\"]\n",
    )
    .unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_greed-mail"))
        .arg("--config")
        .arg(&config)
        .arg("--store")
        .arg(dir.join("store"))
        .arg("serve")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let output = child.stdout.take().unwrap();
    let (send, lines) = std::sync::mpsc::channel::<serde_json::Value>();
    std::thread::spawn(move || {
        for line in std::io::BufReader::new(output)
            .lines()
            .map_while(Result::ok)
        {
            if send.send(serde_json::from_str(&line).unwrap()).is_err() {
                break;
            }
        }
    });
    let next = || {
        lines
            .recv_timeout(Duration::from_secs(10))
            .expect("greed-mail serve said nothing")
    };

    // Waiting is told; asked meanwhile, it answers.
    let waiting = loop {
        let message = next();
        if message["method"] == "waiting" {
            break message["params"].clone();
        }
    };
    assert_eq!(waiting["account"], "home");
    assert_eq!(waiting["program"], "sleep");
    writeln!(
        input,
        r#"{{"jsonrpc":"2.0","id":1,"method":"hello","params":{{}}}}"#
    )
    .unwrap();
    let hello = loop {
        let message = next();
        if message["id"] == 1 {
            break message;
        }
    };
    assert!(hello["result"]["protocol"].is_number(), "{hello}");

    // Its input closed, as when its session goes, it quits.
    drop(input);
    let deadline = Instant::now() + Duration::from_secs(10);
    while child.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "it kept running");
        std::thread::sleep(Duration::from_millis(20));
    }
    let _ = std::fs::remove_dir_all(&dir);
}
