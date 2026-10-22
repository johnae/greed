//! Catching the browser coming back from a sign-in: a listener on
//! 127.0.0.1 that takes the first request's path and query, tells the
//! browser it can close the tab, and stops. Where the browser is on another
//! machine (Greed over ssh) the redirect can't reach it; the link the
//! browser ends on can be pasted instead, which `query` reads the same way.

use std::collections::HashMap;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;
use url::Url;

const PAGE: &str = "<!doctype html><meta charset=utf-8><title>Greed</title>\
<body style=\"font-family:sans-serif;margin:3em\"><p>Signed in. You can close this tab \
and go back to Greed.</p>";

/// A listener waiting for the browser.
pub struct Loopback {
    listener: TcpListener,
    /// Where to send the browser: `http://127.0.0.1:PORT/`.
    pub url: String,
}

impl Loopback {
    /// Listens on a free port.
    pub async fn new() -> std::io::Result<Self> {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
        let url = format!("http://127.0.0.1:{}/", listener.local_addr()?.port());
        Ok(Self { listener, url })
    }

    /// Waits for the browser, and gives the URL it asked for.
    pub async fn wait(self) -> std::io::Result<Url> {
        loop {
            let (stream, _) = self.listener.accept().await?;
            let mut stream = BufReader::new(stream);
            let mut line = String::new();
            stream.read_line(&mut line).await?;
            // GET /path?query HTTP/1.1
            let target = line.split_whitespace().nth(1).unwrap_or("/");
            let Ok(url) = Url::parse(&self.url).and_then(|base| base.join(target)) else {
                continue;
            };
            // Browsers ask for a favicon too; only the redirect counts.
            if url.query().is_none() {
                let _ = stream
                    .get_mut()
                    .write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
                    .await;
                continue;
            }
            let reply = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\
                 Content-Length: {}\r\nConnection: close\r\n\r\n{PAGE}",
                PAGE.len()
            );
            let _ = stream.get_mut().write_all(reply.as_bytes()).await;
            return Ok(url);
        }
    }
}

/// The query of a link pasted or caught, as names and values. Takes any
/// scheme (`https:`, `http:`, `mattermost:`), and a bare query too.
pub fn query(link: &str) -> HashMap<String, String> {
    let link = link.trim();
    let query = match Url::parse(link) {
        Ok(url) => url.query().unwrap_or_default().to_string(),
        Err(_) => link.trim_start_matches('?').to_string(),
    };
    url::form_urlencoded::parse(query.as_bytes())
        .into_owned()
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn links_of_any_kind_give_their_query() {
        let mm =
            query("mattermost://mm.example.com/login/desktop?client_token=a&server_token=b%20c");
        assert_eq!(mm["client_token"], "a");
        assert_eq!(mm["server_token"], "b c");
        let local = query(" http://127.0.0.1:4000/?loginToken=xyz\n");
        assert_eq!(local["loginToken"], "xyz");
        assert_eq!(query("?code=1&state=2")["state"], "2");
    }

    #[test]
    fn the_browser_coming_back_is_caught() {
        crate::program::run(async {
            let loopback = Loopback::new().await.unwrap();
            let url = loopback.url.clone();
            let caught = tokio::task::spawn_local(loopback.wait());
            let address = url
                .trim_start_matches("http://")
                .trim_end_matches('/')
                .to_string();
            let mut stream = tokio::net::TcpStream::connect(&address).await.unwrap();
            stream
                .write_all(b"GET /?loginToken=xyz HTTP/1.1\r\nHost: x\r\n\r\n")
                .await
                .unwrap();
            let mut reply = String::new();
            tokio::io::AsyncReadExt::read_to_string(&mut stream, &mut reply)
                .await
                .unwrap();
            assert!(reply.starts_with("HTTP/1.1 200"), "{reply}");
            let url = caught.await.unwrap().unwrap();
            assert_eq!(url.query(), Some("loginToken=xyz"));
        })
        .unwrap();
    }
}
