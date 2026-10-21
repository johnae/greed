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
    /// Who new mail is from: one of the accounts' addresses or aliases;
    /// the first account's own without it.
    pub from: Option<String>,
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
    /// How mail goes out from it, unless an identity says otherwise.
    display_name: Option<String>,
    signature: Option<String>,
    signature_file: Option<String>,
    reply_to: Option<String>,
    bcc: Option<String>,
    /// How mail goes out from one of its addresses, each its own way.
    #[serde(default, rename = "identity")]
    identities: Vec<Identity>,
}

/// How mail goes out from one of an account's addresses: the name its
/// From line shows, a signature (written here, or in a file), where
/// replies go, and a copy to yourself. What it leaves out, the account
/// says.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Identity {
    pub address: String,
    display_name: Option<String>,
    signature: Option<String>,
    signature_file: Option<String>,
    reply_to: Option<String>,
    bcc: Option<String>,
}

/// An identity settled: what writing from `address` puts in, the
/// account's own where the identity says nothing; the signature read
/// from its file when it's in one.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize)]
pub struct Settled {
    pub address: String,
    pub display_name: Option<String>,
    pub signature: Option<String>,
    pub reply_to: Option<String>,
    pub bcc: Option<String>,
    /// Whether new mail is from it, as mail.toml's `from` says
    /// (`Config::identities`).
    pub default: bool,
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

    /// How mail goes out from each of its addresses, its own first, then
    /// its aliases in order.
    pub fn identities(&self) -> Vec<Settled> {
        std::iter::once(&self.address)
            .chain(&self.aliases)
            .map(|address| {
                let own = self
                    .identities
                    .iter()
                    .find(|i| i.address.eq_ignore_ascii_case(address));
                let pick = |mine: Option<&Option<String>>, account: &Option<String>| {
                    mine.and_then(Option::clone).or_else(|| account.clone())
                };
                // The identity's own signature, written or in a file, and
                // else the account's.
                let signature = own
                    .and_then(|i| signature(i.signature.as_deref(), i.signature_file.as_deref()))
                    .or_else(|| {
                        signature(self.signature.as_deref(), self.signature_file.as_deref())
                    });
                Settled {
                    address: address.clone(),
                    display_name: pick(own.map(|i| &i.display_name), &self.display_name),
                    signature,
                    reply_to: pick(own.map(|i| &i.reply_to), &self.reply_to),
                    bcc: pick(own.map(|i| &i.bcc), &self.bcc),
                    default: false,
                }
            })
            .collect()
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

/// A signature as written, or read from its file (`~` for your home
/// folder), its end trimmed; none when neither says one, or the file
/// can't be read.
fn signature(written: Option<&str>, file: Option<&str>) -> Option<String> {
    written.map(str::to_string).or_else(|| {
        let text = std::fs::read_to_string(crate::files::expand_home(file?)).ok()?;
        Some(text.trim_end().to_string())
    })
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
            for identity in &account.identities {
                let theirs = identity.address.eq_ignore_ascii_case(&account.address)
                    || account
                        .aliases
                        .iter()
                        .any(|a| a.eq_ignore_ascii_case(&identity.address));
                if !theirs {
                    return Err(format!(
                        "{name}: an identity for {} needs it among the account's aliases",
                        identity.address
                    ));
                }
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
        if let Some(from) = &config.from
            && config.sending_as(from).is_none()
        {
            return Err(format!(
                "from = \"{from}\" isn't an address of an account's, nor an alias of one"
            ));
        }
        Ok(config)
    }

    /// The account called `name`.
    pub fn account(&self, name: &str) -> Option<&Account> {
        self.accounts.iter().find(|a| a.name == name)
    }

    /// How mail goes out from each of `account`'s addresses, the one new
    /// mail is from (`from`) marked: else the first account's own.
    pub fn identities(&self, account: &Account) -> Vec<Settled> {
        let default = match &self.from {
            Some(from) => crate::addresses::bare(from),
            None => self
                .accounts
                .first()
                .map(|a| crate::addresses::bare(&a.address))
                .unwrap_or_default(),
        };
        let mut identities = account.identities();
        for identity in &mut identities {
            identity.default = crate::addresses::bare(&identity.address) == default;
        }
        identities
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
    fn new_mail_is_from_from_else_the_first_account_and_from_must_be_yours() {
        let two = |from: &str| {
            format!(
                "{from}\n[[account]]\nname = \"a\"\naddress = \"a@x\"\naliases = [\"desk@x\"]\nprovider = \"gmail\"\npassword = [\"echo\", \"p\"]\n\
                 [[account]]\nname = \"b\"\naddress = \"b@y\"\nprovider = \"gmail\"\npassword = [\"echo\", \"p\"]"
            )
        };
        let defaults = |config: &Config| -> Vec<String> {
            config
                .accounts
                .iter()
                .flat_map(|a| config.identities(a))
                .filter(|i| i.default)
                .map(|i| i.address)
                .collect()
        };
        let set = Config::parse(&two("from = \"Desk <DESK@x>\"")).unwrap();
        assert_eq!(defaults(&set), ["desk@x"], "an alias, however it's written");
        let unset = Config::parse(&two("")).unwrap();
        assert_eq!(defaults(&unset), ["a@x"], "the first account's own");
        let stranger = Config::parse(&two("from = \"c@z\"")).unwrap_err();
        assert!(
            stranger.contains("isn't an address of an account's"),
            "{stranger}"
        );
    }

    #[test]
    fn each_address_goes_out_as_its_identity_says_and_the_account_fills_the_rest() {
        let dir = std::env::temp_dir().join(format!("gm-sig-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("support.sig");
        std::fs::write(&file, "Hyperspool support\nspool.example\n\n").unwrap();
        let config = Config::parse(&format!(
            r#"
            [[account]]
            name = "proton"
            address = "anna@proton.me"
            aliases = ["support@spool.example", "anna@pm.me"]
            imap = {{ host = "127.0.0.1", port = 1143, tls = "none" }}
            password = ["echo", "x"]
            display_name = "Anna Berg"
            signature = "-- Anna"
            bcc = "anna@proton.me"

            [[account.identity]]
            address = "support@spool.example"
            display_name = "Hyperspool Support"
            signature_file = "{}"
            reply_to = "help@spool.example"
            "#,
            file.display()
        ))
        .unwrap();
        let identities = config.accounts[0].identities();
        assert_eq!(
            identities
                .iter()
                .map(|i| i.address.as_str())
                .collect::<Vec<_>>(),
            ["anna@proton.me", "support@spool.example", "anna@pm.me"],
            "its own first, then its aliases"
        );
        assert_eq!(identities[0].display_name.as_deref(), Some("Anna Berg"));
        assert_eq!(identities[0].signature.as_deref(), Some("-- Anna"));
        let support = &identities[1];
        assert_eq!(support.display_name.as_deref(), Some("Hyperspool Support"));
        assert_eq!(
            support.signature.as_deref(),
            Some("Hyperspool support\nspool.example"),
            "from its file, its end trimmed"
        );
        assert_eq!(support.reply_to.as_deref(), Some("help@spool.example"));
        assert_eq!(
            support.bcc.as_deref(),
            Some("anna@proton.me"),
            "the account's"
        );
        assert_eq!(
            identities[2].signature.as_deref(),
            Some("-- Anna"),
            "the account's"
        );
        let stranger = Config::parse(
            "[[account]]\nname = \"a\"\naddress = \"a@b\"\nprovider = \"gmail\"\npassword = [\"echo\", \"x\"]\n[[account.identity]]\naddress = \"c@d\"",
        )
        .unwrap_err();
        assert!(
            stranger.contains("among the account's aliases"),
            "{stranger}"
        );
        let _ = std::fs::remove_dir_all(&dir);
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
