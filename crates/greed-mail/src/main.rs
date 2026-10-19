//! `greed-mail`: keeps mail accounts synced into a store and an index for
//! Greed's mail client, and sends mail. The mail session runs it; it runs
//! on its own too:
//!
//! ```text
//! greed-mail check [ACCOUNT]    log in and say what each server can do
//! greed-mail sync [ACCOUNT]     sync the headers into the store
//! ```
//!
//! `--config FILE` reads accounts from FILE instead of Greed's `mail.toml`,
//! `--store DIR` keeps the store in DIR instead of Greed's data folder, and
//! `--limit N` stops a sync after about N messages a mailbox.

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Instant;

use greed_mail::config::{Account, Config};
use greed_mail::imap::{Connection, Role};
use greed_mail::store::Store;
use greed_mail::sync::{self, Options};

const USAGE: &str =
    "usage: greed-mail [--config FILE] [--store DIR] [--limit N] (check | sync) [ACCOUNT]";

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let mut path: Option<PathBuf> = None;
    let mut store_dir: Option<PathBuf> = None;
    let mut options = Options::default();
    let mut rest = Vec::new();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--config" | "--store" | "--limit" => {
                let Some(value) = args.next() else {
                    return fail(USAGE);
                };
                match arg.as_str() {
                    "--config" => path = Some(value.into()),
                    "--store" => store_dir = Some(value.into()),
                    _ => match value.parse() {
                        Ok(n) => options.limit = Some(n),
                        Err(_) => return fail("--limit takes a number of messages"),
                    },
                }
            }
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
    let (command, accounts): (&str, Vec<&Account>) = match rest.as_slice() {
        [command] => (command, config.accounts.iter().collect()),
        [command, name] => match config.account(name) {
            Some(account) => (command, vec![account]),
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
    let mut store = match command {
        "check" => None,
        "sync" => {
            let dir = store_dir
                .or_else(|| greed_dirs::dir(greed_dirs::Kind::Data).map(|dir| dir.join("mail")));
            let Some(dir) = dir else {
                return fail("can't tell where Greed's data folder is: set HOME or GREED_DATA_DIR");
            };
            match Store::open(&dir) {
                Ok(store) => Some(store),
                Err(e) => return fail(&e.0),
            }
        }
        _ => return fail(USAGE),
    };
    let mut failed = false;
    for account in accounts {
        let done = match &mut store {
            Some(store) => runtime.block_on(sync_account(account, store, options)),
            None => runtime.block_on(check(account)),
        };
        if let Err(e) = done {
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

async fn connect(account: &Account) -> Result<Connection, String> {
    let password = account.password()?;
    Connection::open(&account.imap(), account.user(), &password)
        .await
        .map_err(|e| e.0)
}

/// Logs in to `account` and says what its server can do and which
/// mailboxes it has, with counts for those that have a role.
async fn check(account: &Account) -> Result<(), String> {
    let at = account.imap();
    let started = Instant::now();
    let mut connection = connect(account).await?;
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
    println!("  changes: {:?}", connection.tracking());
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

/// Syncs the headers of `account`'s mailboxes into `store`, saying how
/// many came and how fast.
async fn sync_account(
    account: &Account,
    store: &mut Store,
    options: Options,
) -> Result<(), String> {
    let mut connection = connect(account).await?;
    let id = store
        .account(&account.name, &account.address)
        .map_err(|e| e.0)?;
    let mailboxes = connection.mailboxes().await.map_err(|e| e.0)?;
    for mailbox in sync::chosen(account.provider, &mailboxes) {
        let started = Instant::now();
        let synced = sync::mailbox(
            &mut connection,
            store,
            id,
            &mailbox.name,
            mailbox.role,
            options,
        )
        .await
        .map_err(|e| format!("{}: {e}", mailbox.name))?;
        let seconds = started.elapsed().as_secs_f64();
        #[expect(
            clippy::cast_precision_loss,
            reason = "a message count, shown as a rate"
        )]
        let rate = synced.fetched as f64 / seconds.max(0.001);
        println!(
            "{} {}: {} fetched in {seconds:.1} s ({rate:.0} a second), {} changed, {} gone{}",
            account.name,
            mailbox.name,
            synced.fetched,
            synced.changed,
            synced.gone,
            if synced.done { "" } else { ", more to come" },
        );
    }
    let (messages, places) = store.counts(id).map_err(|e| e.0)?;
    println!("{}: {messages} messages in {places} places", account.name);
    connection.close().await.map_err(|e| e.0)
}
