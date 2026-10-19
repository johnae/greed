//! `greed-mail`: keeps mail accounts synced into a store and an index for
//! Greed's mail client, and sends mail. The mail session runs it; it runs
//! on its own too:
//!
//! ```text
//! greed-mail check [ACCOUNT]    log in and say what each server can do
//! ```

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Instant;

use greed_mail::config::{Account, Config};
use greed_mail::imap::{Connection, Role};

const USAGE: &str = "usage: greed-mail [--config FILE] check [ACCOUNT]";

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let mut path: Option<PathBuf> = None;
    let mut rest = Vec::new();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--config" => match args.next() {
                Some(file) => path = Some(file.into()),
                None => return fail(USAGE),
            },
            "-h" | "--help" | "help" => {
                println!("{USAGE}");
                return ExitCode::SUCCESS;
            }
            _ => rest.push(arg),
        }
    }
    let Some(path) = path.or_else(Config::path) else {
        return fail("can't tell where Greed's config folder is: set HOME or GREED_CONFIG_DIR");
    };
    let config = match Config::read(&path) {
        Ok(config) => config,
        Err(e) => return fail(&e),
    };
    let accounts: Vec<&Account> = match rest.as_slice() {
        [command] if command == "check" => config.accounts.iter().collect(),
        [command, name] if command == "check" => match config.account(name) {
            Some(account) => vec![account],
            None => return fail(&format!("no account called {name} in {}", path.display())),
        },
        _ => return fail(USAGE),
    };
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(e) => return fail(&format!("couldn't start: {e}")),
    };
    let mut failed = false;
    for account in accounts {
        if let Err(e) = runtime.block_on(check(account)) {
            eprintln!("{}: {e}", account.name);
            failed = true;
        }
    }
    if failed {
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    }
}

fn fail(message: &str) -> ExitCode {
    eprintln!("greed-mail: {message}");
    ExitCode::FAILURE
}

/// Logs in to `account` and says what its server can do and which
/// mailboxes it has, with counts for those that have a role.
async fn check(account: &Account) -> Result<(), String> {
    let at = account.imap();
    let password = account.password()?;
    let started = Instant::now();
    let mut connection = Connection::open(&at, account.user(), &password)
        .await
        .map_err(|e| e.0)?;
    println!(
        "{}: {}:{} logged in in {} ms",
        account.name,
        at.host,
        at.port,
        started.elapsed().as_millis()
    );
    if let Some(smtp) = account.smtp() {
        println!(
            "  sends through {}:{} ({:?})",
            smtp.host, smtp.port, smtp.tls
        );
    }
    println!("  changes: {:?}", connection.changes());
    println!("  can: {}", connection.capabilities().join(" "));
    let mailboxes = connection.mailboxes().await.map_err(|e| e.0)?;
    println!("  mailboxes: {}", mailboxes.len());
    for mailbox in mailboxes.iter().filter(|m| m.selectable) {
        let Some(role) = mailbox.role.map(Role::name) else {
            continue;
        };
        let status = connection.status(&mailbox.name).await.map_err(|e| e.0)?;
        let modseq = status
            .highest_modseq
            .map_or(String::new(), |m| format!(", modseq {m}"));
        println!(
            "  {role:8} {}: {} messages, {} unseen{modseq}",
            mailbox.name,
            status.messages,
            status.unseen.map_or("?".into(), |u| u.to_string()),
        );
    }
    connection.close().await.map_err(|e| e.0)
}
