//! The accounts to sync, from `mail.toml` in Greed's config folder:
//!
//! ```toml
//! [[account]]
//! name = "proton"
//! address = "anna@proton.me"
//! imap = { host = "bridge.example.ts.net", port = 1143, tls = "implicit" }
//! password = ["rbw", "get", "proton-bridge"]
//! ```
//!
//! A password is a command's output, run when a connection needs it and
//! kept in memory only.

use std::path::{Path, PathBuf};
use std::process::Command;

use serde::Deserialize;

/// Every account, in the order the file has them.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    #[serde(rename = "account", default)]
    pub accounts: Vec<Account>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Account {
    /// What it's called here, unique among the accounts.
    pub name: String,
    pub address: String,
    /// Other addresses it gets mail at and sends from, like Proton's.
    #[serde(default)]
    pub aliases: Vec<String>,
    /// Whether tags set here are Bridge's labels, put on and taken off on
    /// the server; off until you've tried it on a message you can lose.
    #[serde(default)]
    pub labels: bool,
    /// Known hosts and quirks; plain IMAP without one.
    pub provider: Option<Provider>,
    imap: Option<Server>,
    smtp: Option<Server>,
    /// Who logs in, when it isn't the address.
    user: Option<String>,
    /// The command printing the password, and its arguments.
    #[serde(default)]
    password: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Provider {
    Gmail,
    ProtonBridge,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
struct Server {
    host: String,
    port: Option<u16>,
    #[serde(default)]
    tls: Tls,
}

/// How a connection is encrypted: from the start, after STARTTLS, or not
/// at all (only to this machine).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Tls {
    #[default]
    Implicit,
    Starttls,
    None,
}

/// Where a connection goes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Endpoint {
    pub host: String,
    pub port: u16,
    pub tls: Tls,
}

impl Account {
    /// Where its IMAP server is: as written, or the provider's.
    pub fn imap(&self) -> Endpoint {
        let server = self.imap.clone().unwrap_or_else(|| Server {
            host: "imap.gmail.com".into(),
            port: None,
            tls: Tls::Implicit,
        });
        let port = match server.tls {
            Tls::Implicit => 993,
            Tls::Starttls | Tls::None => 143,
        };
        endpoint(server, port)
    }

    /// Where it sends mail, when it can.
    pub fn smtp(&self) -> Option<Endpoint> {
        let server = self.smtp.clone().or_else(|| {
            (self.provider == Some(Provider::Gmail)).then(|| Server {
                host: "smtp.gmail.com".into(),
                port: None,
                tls: Tls::Implicit,
            })
        })?;
        let port = match server.tls {
            Tls::Implicit => 465,
            Tls::Starttls | Tls::None => 587,
        };
        Some(endpoint(server, port))
    }

    /// Who logs in: `user`, or else the address.
    pub fn user(&self) -> &str {
        self.user.as_deref().unwrap_or(&self.address)
    }

    /// The password, from its command. What the command prints is never
    /// put in an error, in case it printed the password and then failed.
    pub fn password(&self) -> Result<String, String> {
        let (program, args) = self
            .password
            .split_first()
            .ok_or_else(|| format!("{}: no password command", self.name))?;
        let out = Command::new(program)
            .args(args)
            .output()
            .map_err(|e| format!("{}: couldn't run {program}: {e}", self.name))?;
        if !out.status.success() {
            return Err(format!("{}: {program} failed ({})", self.name, out.status));
        }
        let text = String::from_utf8(out.stdout)
            .map_err(|_| format!("{}: {program} printed something that isn't text", self.name))?;
        let password = text.trim_end_matches(['\n', '\r']);
        if password.is_empty() {
            return Err(format!("{}: {program} printed no password", self.name));
        }
        Ok(password.to_string())
    }
}

fn endpoint(server: Server, port: u16) -> Endpoint {
    Endpoint {
        port: server.port.unwrap_or(port),
        host: server.host,
        tls: server.tls,
    }
}

impl Config {
    /// Where it's read from: `mail.toml` in Greed's config folder.
    pub fn path() -> Option<PathBuf> {
        greed_dirs::dir(greed_dirs::Kind::Config).map(|dir| dir.join("mail.toml"))
    }

    /// The accounts in the file at `path`.
    pub fn read(path: &Path) -> Result<Config, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("couldn't read {}: {e}", path.display()))?;
        Config::parse(&text).map_err(|e| format!("{}: {e}", path.display()))
    }

    /// The accounts `text` says, checked.
    pub fn parse(text: &str) -> Result<Config, String> {
        let config: Config = toml::from_str(text).map_err(|e| e.message().to_string())?;
        let mut names = std::collections::HashSet::new();
        for account in &config.accounts {
            let name = &account.name;
            if name.is_empty() {
                return Err("an account needs a name".into());
            }
            if !names.insert(name.as_str()) {
                return Err(format!("two accounts are called {name}"));
            }
            if account.password.is_empty() {
                return Err(format!(
                    "{name} needs a password command, like password = [\"rbw\", \"get\", \"{name}\"]"
                ));
            }
            if account.imap.is_none() && account.provider != Some(Provider::Gmail) {
                return Err(format!(
                    "{name} needs its IMAP server, like imap = {{ host = \"imap.example.com\" }}"
                ));
            }
            for (what, server) in [("imap", &account.imap), ("smtp", &account.smtp)] {
                if let Some(server) = server
                    && server.tls == Tls::None
                    && !local(&server.host)
                {
                    return Err(format!(
                        "{name}: {what} without TLS goes only to this machine, not {}",
                        server.host
                    ));
                }
            }
        }
        Ok(config)
    }

    /// The account called `name`.
    pub fn account(&self, name: &str) -> Option<&Account> {
        self.accounts.iter().find(|a| a.name == name)
    }

    /// The account that sends as `from` ("Anna <anna@x>" or the address),
    /// its own address or one of its aliases.
    pub fn sending_as(&self, from: &str) -> Option<&Account> {
        let address = crate::addresses::bare(from);
        self.accounts
            .iter()
            .find(|a| crate::addresses::own(&a.address, &a.aliases).contains(&address))
    }
}

/// Whether `host` is this machine.
fn local(host: &str) -> bool {
    matches!(host, "localhost" | "127.0.0.1" | "::1")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_account_reads_with_its_servers_and_who_logs_in() {
        let config = Config::parse(
            r#"
            [[account]]
            name = "proton"
            address = "anna@proton.me"
            imap = { host = "bridge.example", port = 1143 }
            smtp = { host = "bridge.example", port = 1025, tls = "starttls" }
            password = ["echo", "secret"]
            "#,
        )
        .unwrap();
        let proton = config.account("proton").unwrap();
        assert_eq!(
            proton.imap(),
            Endpoint {
                host: "bridge.example".into(),
                port: 1143,
                tls: Tls::Implicit
            }
        );
        assert_eq!(proton.smtp().unwrap().tls, Tls::Starttls);
        assert_eq!(proton.user(), "anna@proton.me");
    }

    #[test]
    fn gmail_needs_no_servers_and_ports_follow_tls() {
        let config = Config::parse(
            r#"
            [[account]]
            name = "gmail"
            address = "anna@gmail.com"
            provider = "gmail"
            password = ["true"]

            [[account]]
            name = "local"
            address = "anna@localhost"
            user = "anna"
            imap = { host = "localhost", tls = "none" }
            password = ["true"]
            "#,
        )
        .unwrap();
        let gmail = config.account("gmail").unwrap();
        assert_eq!(gmail.imap().host, "imap.gmail.com");
        assert_eq!(gmail.imap().port, 993);
        assert_eq!(gmail.smtp().unwrap().port, 465);
        let local = config.account("local").unwrap();
        assert_eq!(local.imap().port, 143);
        assert_eq!(local.user(), "anna");
        assert_eq!(local.smtp(), None, "no SMTP without one given");
    }

    #[test]
    fn mistakes_say_what_to_write() {
        let says = |text: &str| Config::parse(text).unwrap_err();
        let base = "name = \"a\"\naddress = \"a@b\"\n";
        assert!(
            says(&format!("[[account]]\n{base}imap = {{ host = \"h\" }}"))
                .contains("needs a password command")
        );
        assert!(
            says(&format!("[[account]]\n{base}password = [\"x\"]"))
                .contains("needs its IMAP server")
        );
        assert!(says(&format!(
            "[[account]]\n{base}password = [\"x\"]\nimap = {{ host = \"mail.example\", tls = \"none\" }}"
        ))
        .contains("without TLS goes only to this machine"));
        let one = format!("[[account]]\n{base}password = [\"x\"]\nprovider = \"gmail\"\n");
        assert!(says(&format!("{one}{one}")).contains("two accounts are called a"));
        assert!(says("[[account]]\nname = \"a\"\nadress = \"x\"").contains("adress"));
    }

    #[test]
    fn the_password_comes_from_its_command_without_the_newline() {
        let config = Config::parse(
            "[[account]]\nname = \"a\"\naddress = \"a@b\"\nprovider = \"gmail\"\npassword = [\"echo\", \"hunter2\"]",
        )
        .unwrap();
        assert_eq!(config.accounts[0].password().unwrap(), "hunter2");
        let failing = Config::parse(
            "[[account]]\nname = \"a\"\naddress = \"a@b\"\nprovider = \"gmail\"\npassword = [\"sh\", \"-c\", \"echo hunter2; exit 1\"]",
        )
        .unwrap();
        let err = failing.accounts[0].password().unwrap_err();
        assert!(err.contains("failed"), "{err}");
        assert!(!err.contains("hunter2"), "never what it printed");
    }
}
