//! For the services' tests against real servers: finding the servers'
//! programs, a free port, a browser that follows redirects (curl), and a
//! stand-in OAuth provider to sign in through.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde_json::json;

use crate::loopback;

/// `program` on PATH.
pub fn find(program: &str) -> Option<PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH")?)
        .map(|dir| dir.join(program))
        .find(|path| path.is_file())
}

/// A port nothing listens on, for a server to take.
pub fn free_port() -> u16 {
    TcpListener::bind(("127.0.0.1", 0))
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

/// Goes where a browser would from `url`, following redirects and keeping
/// cookies in `jar`, and gives the address it ends on. With `stop`, it
/// doesn't go to an address starting with that, as when the browser is on
/// another machine than the one listening.
pub fn browse(url: &str, jar: &Path, stop: Option<&str>) -> String {
    let mut at = url.to_string();
    for _ in 0..20 {
        let out = Command::new("curl")
            .args(["-s", "-w", "\n%{http_code} %{redirect_url}", "-c"])
            .arg(jar)
            .arg("-b")
            .arg(jar)
            .arg(&at)
            .output()
            .unwrap();
        let out = String::from_utf8(out.stdout).unwrap();
        let (body, last) = out.rsplit_once('\n').unwrap_or_default();
        let (status, next) = last.split_once(' ').unwrap_or_default();
        assert!(!status.starts_with(['4', '5']), "{at}: {status} {body}");
        if next.is_empty() {
            return at;
        }
        if stop.is_some_and(|stop| next.starts_with(stop)) {
            return next.to_string();
        }
        at = next.to_string();
    }
    panic!("too many redirects from {url}");
}

/// A stand-in OAuth 2.0 provider that signs in anyone who comes as `bea`
/// (Bea Berg), answering on a thread until the test ends: as GitLab does
/// (`/oauth/authorize`, `/oauth/token`, `/api/v4/user`), and as an `OpenID`
/// Connect provider found by discovery. Gives its address.
pub fn oauth_provider() -> String {
    let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let address = format!("http://{}", listener.local_addr().unwrap());
    let issuer = address.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let target = read_request(&mut stream);
            let reply = if target.starts_with("/oauth/authorize") {
                let query = loopback::query(&format!("http://x{target}"));
                let state: String =
                    url::form_urlencoded::byte_serialize(query["state"].as_bytes()).collect();
                let back = format!("{}?code=granted&state={state}", query["redirect_uri"]);
                format!(
                    "HTTP/1.1 302 Found\r\nLocation: {back}\r\nContent-Length: 0\r\n\
                     Connection: close\r\n\r\n"
                )
            } else {
                let body = if target.starts_with("/.well-known/openid-configuration") {
                    json!({ "issuer": issuer,
                            "authorization_endpoint": format!("{issuer}/oauth/authorize"),
                            "token_endpoint": format!("{issuer}/oauth/token"),
                            "userinfo_endpoint": format!("{issuer}/userinfo"),
                            "response_types_supported": ["code"],
                            "subject_types_supported": ["public"],
                            "id_token_signing_alg_values_supported": ["RS256"] })
                } else if target.starts_with("/oauth/token") {
                    json!({ "access_token": "t", "token_type": "bearer", "expires_in": 3600 })
                } else if target.starts_with("/userinfo") {
                    json!({ "sub": "42", "preferred_username": "bea", "name": "Bea Berg",
                            "email": "bea@example.com", "email_verified": true })
                } else {
                    json!({ "id": 42, "username": "bea", "email": "bea@example.com",
                            "name": "Bea Berg" })
                }
                .to_string();
                format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\
                     Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
            };
            let _ = stream.write_all(reply.as_bytes());
        }
    });
    address
}

/// Reads a request off `stream`, body and all, and gives its target.
fn read_request(stream: &mut std::net::TcpStream) -> String {
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut line = String::new();
    let _ = reader.read_line(&mut line);
    let mut length = 0;
    loop {
        let mut header = String::new();
        if reader.read_line(&mut header).unwrap_or(0) == 0 || header.trim().is_empty() {
            break;
        }
        if let Some(n) = header.to_ascii_lowercase().strip_prefix("content-length:") {
            length = n.trim().parse().unwrap_or(0);
        }
    }
    let _ = reader.read_exact(&mut vec![0; length]);
    line.split_whitespace().nth(1).unwrap_or("/").to_string()
}
