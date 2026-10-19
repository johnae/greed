//! A connection to an IMAP server: TLS from the start or after STARTTLS (or
//! none, to this machine), logged in, with what the server can do and its
//! mailboxes. Built on async-imap; the rest of greed-mail sees only what's
//! here, so the crate under it can change.

use std::fmt;
use std::sync::Arc;
use std::time::Duration;

use async_imap::imap_proto::NameAttribute;
use async_imap::types::Capability;
use async_imap::{Client, Session};
use futures::TryStreamExt;
use rustls_platform_verifier::ConfigVerifierExt;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpStream;
use tokio::time::timeout;
use tokio_rustls::TlsConnector;
use tokio_rustls::rustls::ClientConfig;
use tokio_rustls::rustls::pki_types::ServerName;

use crate::config::{Endpoint, Tls};

/// How long connecting and logging in may take.
const CONNECTING: Duration = Duration::from_secs(30);

/// A stream an IMAP session goes over, encrypted or not.
pub trait Wire: AsyncRead + AsyncWrite + Unpin + fmt::Debug + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + fmt::Debug + Send> Wire for T {}

/// What went wrong talking to a server, in words.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Trouble(pub String);

impl fmt::Display for Trouble {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl From<async_imap::error::Error> for Trouble {
    fn from(error: async_imap::error::Error) -> Trouble {
        Trouble(error.to_string())
    }
}

impl From<std::io::Error> for Trouble {
    fn from(error: std::io::Error) -> Trouble {
        Trouble(error.to_string())
    }
}

/// How a mailbox's changes can be found, from what the server can do:
/// everything that changed and went since a point (QRESYNC); what changed,
/// with what went found by comparing UIDs (CONDSTORE); or every flag
/// fetched and UIDs compared.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Changes {
    Qresync,
    Condstore,
    Plain,
}

impl Changes {
    pub fn of(capabilities: &[String]) -> Changes {
        let has = |name: &str| capabilities.iter().any(|c| c.eq_ignore_ascii_case(name));
        if has("QRESYNC") {
            Changes::Qresync
        } else if has("CONDSTORE") {
            Changes::Condstore
        } else {
            Changes::Plain
        }
    }
}

/// What a mailbox is for, from its special use (RFC 6154), or INBOX by name.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Role {
    Inbox,
    All,
    Archive,
    Drafts,
    Flagged,
    Junk,
    Sent,
    Trash,
}

impl Role {
    pub fn name(self) -> &'static str {
        match self {
            Role::Inbox => "inbox",
            Role::All => "all",
            Role::Archive => "archive",
            Role::Drafts => "drafts",
            Role::Flagged => "flagged",
            Role::Junk => "junk",
            Role::Sent => "sent",
            Role::Trash => "trash",
        }
    }
}

/// A mailbox the server lists.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Mailbox {
    pub name: String,
    pub role: Option<Role>,
    /// Whether it holds messages, rather than only other mailboxes.
    pub selectable: bool,
}

/// How many messages a mailbox holds, and where its UIDs and changes are.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Status {
    pub messages: u32,
    pub unseen: Option<u32>,
    pub uid_validity: Option<u32>,
    pub uid_next: Option<u32>,
    pub highest_modseq: Option<u64>,
}

/// A logged-in connection.
pub struct Connection {
    session: Session<Box<dyn Wire>>,
    capabilities: Vec<String>,
}

impl Connection {
    /// Connects to `at` and logs in as `user`.
    pub async fn open(at: &Endpoint, user: &str, password: &str) -> Result<Connection, Trouble> {
        let opening = async {
            let client = client(at).await?;
            let mut session = client
                .login(user, password)
                .await
                .map_err(|(e, _)| Trouble(format!("logging in as {user}: {e}")))?;
            let capabilities = capabilities(&mut session).await?;
            Ok(Connection {
                session,
                capabilities,
            })
        };
        timeout(CONNECTING, opening)
            .await
            .map_err(|_| Trouble(format!("{}:{} didn't answer in time", at.host, at.port)))?
    }

    /// What the server can do, as it says after logging in, sorted.
    pub fn capabilities(&self) -> &[String] {
        &self.capabilities
    }

    /// How changes are found on this server.
    pub fn changes(&self) -> Changes {
        Changes::of(&self.capabilities)
    }

    /// Every mailbox the server has.
    pub async fn mailboxes(&mut self) -> Result<Vec<Mailbox>, Trouble> {
        let names: Vec<_> = self
            .session
            .list(Some(""), Some("*"))
            .await?
            .try_collect()
            .await?;
        Ok(names
            .iter()
            .map(|n| {
                let attributes = n.attributes();
                let role = attributes.iter().find_map(role_of).or_else(|| {
                    n.name()
                        .eq_ignore_ascii_case("INBOX")
                        .then_some(Role::Inbox)
                });
                Mailbox {
                    name: n.name().to_string(),
                    role,
                    selectable: !attributes.contains(&NameAttribute::NoSelect),
                }
            })
            .collect())
    }

    /// How many messages `mailbox` holds, and where its UIDs and changes
    /// are, without opening it.
    pub async fn status(&mut self, mailbox: &str) -> Result<Status, Trouble> {
        let items = if self.changes() == Changes::Plain {
            "(MESSAGES UNSEEN UIDVALIDITY UIDNEXT)"
        } else {
            "(MESSAGES UNSEEN UIDVALIDITY UIDNEXT HIGHESTMODSEQ)"
        };
        let found = self.session.status(mailbox, items).await?;
        Ok(Status {
            messages: found.exists,
            unseen: found.unseen,
            uid_validity: found.uid_validity,
            uid_next: found.uid_next,
            highest_modseq: found.highest_modseq,
        })
    }

    /// Logs out and closes the connection.
    pub async fn close(mut self) -> Result<(), Trouble> {
        self.session.logout().await?;
        Ok(())
    }
}

fn role_of(attribute: &NameAttribute<'_>) -> Option<Role> {
    Some(match attribute {
        NameAttribute::All => Role::All,
        NameAttribute::Archive => Role::Archive,
        NameAttribute::Drafts => Role::Drafts,
        NameAttribute::Flagged => Role::Flagged,
        NameAttribute::Junk => Role::Junk,
        NameAttribute::Sent => Role::Sent,
        NameAttribute::Trash => Role::Trash,
        _ => return None,
    })
}

async fn capabilities(session: &mut Session<Box<dyn Wire>>) -> Result<Vec<String>, Trouble> {
    let mut names: Vec<String> = session
        .capabilities()
        .await?
        .iter()
        .map(|c| match c {
            Capability::Imap4rev1 => "IMAP4rev1".to_string(),
            Capability::Auth(mechanism) => format!("AUTH={mechanism}"),
            Capability::Atom(atom) => atom.clone(),
        })
        .collect();
    names.sort();
    Ok(names)
}

/// A client for `at`, past the server's greeting and encrypted as `at`
/// says.
async fn client(at: &Endpoint) -> Result<Client<Box<dyn Wire>>, Trouble> {
    let tcp = TcpStream::connect((at.host.as_str(), at.port))
        .await
        .map_err(|e| Trouble(format!("connecting to {}:{}: {e}", at.host, at.port)))?;
    tcp.set_nodelay(true)?;
    let wire: Box<dyn Wire> = match at.tls {
        Tls::Implicit => Box::new(encrypt(tcp, &at.host).await?),
        Tls::None => Box::new(tcp),
        Tls::Starttls => {
            let mut plain = Client::new(tcp);
            greeting(&mut plain).await?;
            plain
                .run_command_and_check_ok("STARTTLS", None)
                .await
                .map_err(|e| Trouble(format!("STARTTLS: {e}")))?;
            let tls = encrypt(plain.into_inner(), &at.host).await?;
            return Ok(Client::new(Box::new(tls)));
        }
    };
    let mut client = Client::new(wire);
    greeting(&mut client).await?;
    Ok(client)
}

async fn greeting<T: Wire>(client: &mut Client<T>) -> Result<(), Trouble> {
    client
        .read_response()
        .await?
        .ok_or_else(|| Trouble("the server closed the connection before greeting".into()))?;
    Ok(())
}

/// `tcp` encrypted for `host`, its certificate checked as the system checks
/// one.
async fn encrypt(
    tcp: TcpStream,
    host: &str,
) -> Result<tokio_rustls::client::TlsStream<TcpStream>, Trouble> {
    let config = ClientConfig::with_platform_verifier()
        .map_err(|e| Trouble(format!("setting up TLS: {e}")))?;
    let name = ServerName::try_from(host.to_string())
        .map_err(|_| Trouble(format!("{host} isn't a host name")))?;
    TlsConnector::from(Arc::new(config))
        .connect(name, tcp)
        .await
        .map_err(|e| Trouble(format!("TLS with {host}: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn changes_are_found_the_best_way_the_server_has() {
        let caps = |list: &[&str]| list.iter().map(|s| (*s).to_string()).collect::<Vec<_>>();
        assert_eq!(
            Changes::of(&caps(&["IMAP4rev1", "CONDSTORE", "QRESYNC"])),
            Changes::Qresync
        );
        assert_eq!(
            Changes::of(&caps(&["IMAP4rev1", "condstore"])),
            Changes::Condstore
        );
        assert_eq!(Changes::of(&caps(&["IMAP4rev1", "IDLE"])), Changes::Plain);
    }
}
