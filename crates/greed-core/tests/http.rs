//! `greed.http` against a tiny server on localhost.

mod jobs;

use jobs::messages;

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::Duration;

use greed_core::Editor;
use greed_core::luau::Host;
use greed_text::ClientId;

/// Answers `/hello` with "hello", echoes the body sent to `/echo`, and
/// streams "one", "two" and "three" from `/stream` a moment apart.
fn serve() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = format!("http://{}", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            std::thread::spawn(move || answer(stream));
        }
    });
    address
}

fn answer(stream: TcpStream) {
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut first = String::new();
    reader.read_line(&mut first).unwrap();
    let mut length = 0;
    loop {
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        if line.trim().is_empty() {
            break;
        }
        if let Some(n) = line.to_ascii_lowercase().strip_prefix("content-length:") {
            length = n.trim().parse().unwrap();
        }
    }
    let mut body = vec![0; length];
    reader.read_exact(&mut body).unwrap();
    let mut out = stream;
    let path = first.split(' ').nth(1).unwrap_or_default();
    match path {
        "/hello" => {
            write!(
                out,
                "HTTP/1.1 200 OK\r\nX-Kind: greeting\r\nContent-Length: 5\r\n\r\nhello"
            )
            .unwrap();
        }
        "/echo" => {
            write!(
                out,
                "HTTP/1.1 201 Created\r\nContent-Length: {}\r\n\r\n",
                body.len()
            )
            .unwrap();
            out.write_all(&body).unwrap();
        }
        "/stream" => {
            write!(out, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n").unwrap();
            for piece in ["one", "two", "three"] {
                write!(out, "{:x}\r\n{piece}\r\n", piece.len()).unwrap();
                out.flush().unwrap();
                std::thread::sleep(Duration::from_millis(50));
            }
            write!(out, "0\r\n\r\n").unwrap();
        }
        _ => write!(out, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n").unwrap(),
    }
    out.flush().unwrap();
}

#[test]
fn requests_wait_for_the_whole_response() {
    let address = serve();
    let host = host();
    host.load_str(
        "fetch",
        &format!(
            r#"
            local greed = require("@greed")
            greed.command {{ name = "fetch", run = function()
                local r = assert(greed.http.request({{ url = "{address}/hello" }}))
                greed.echo(`{{r.status}} {{r.headers["x-kind"]}} {{r.body}}`)
                local e = assert(greed.http.request({{ url = "{address}/echo", body = "sent" }}))
                greed.echo(`{{e.status}} {{e.body}}`)
                local _, err = greed.http.request({{ url = "http://127.0.0.1:1/" }})
                greed.echo(if err then "refused" else "connected")
            end }}
            "#
        ),
    )
    .unwrap();
    host.run("fetch").unwrap();
    assert_eq!(
        messages(&host, 3),
        ["200 greeting hello", "201 sent", "refused"]
    );
}

#[test]
fn a_successful_response_can_go_straight_to_a_file() {
    let address = serve();
    let dir = std::env::temp_dir().join(format!("greed-http-save-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let host = host();
    host.load_str(
        "save",
        &format!(
            r#"
            local greed = require("@greed")
            greed.command {{ name = "save", run = function()
                local r = assert(greed.http.request({{ url = "{address}/hello", save = "{saved}" }}))
                greed.echo(`{{r.status}} [{{r.body}}]`)
                local missing = assert(greed.http.request({{ url = "{address}/nope", save = "{missing}" }}))
                greed.echo(`{{missing.status}}`)
            end }}
            "#,
            saved = dir.join("deep/hello.txt").display(),
            missing = dir.join("nope.txt").display(),
        ),
    )
    .unwrap();
    host.run("save").unwrap();
    assert_eq!(messages(&host, 2), ["200 []", "404"]);
    assert_eq!(
        std::fs::read_to_string(dir.join("deep/hello.txt")).unwrap(),
        "hello"
    );
    assert!(!dir.join("nope.txt").exists(), "a failure isn't saved");
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn streams_give_each_piece_as_it_arrives() {
    let address = serve();
    let host = host();
    host.load_str(
        "stream",
        &format!(
            r#"
            local greed = require("@greed")
            greed.command {{ name = "stream", run = function()
                local s = assert(greed.http.stream({{ url = "{address}/stream" }}))
                greed.echo("status " .. s.status)
                while true do
                    local piece = s.read()
                    if piece == nil then break end
                    greed.echo(piece)
                end
                greed.echo("end")
            end }}
            "#
        ),
    )
    .unwrap();
    host.run("stream").unwrap();
    assert_eq!(
        messages(&host, 5),
        ["status 200", "one", "two", "three", "end"]
    );
}

#[test]
fn a_plugin_reaches_only_the_hosts_it_declares() {
    let address = serve();
    let dir = std::env::temp_dir().join(format!("greed-http-net-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("plugin.toml"),
        "name = \"fetcher\"\ncapabilities = [\"net:example.com\"]\n",
    )
    .unwrap();
    std::fs::write(
        dir.join("init.luau"),
        format!(
            r#"
            local greed = require("@greed")
            greed.command {{ name = "fetcher-go", run = function()
                local ok, err = pcall(greed.http.request, {{ url = "{address}/hello" }})
                greed.echo(if ok then "fetched" else tostring(err))
            end }}
            "#
        ),
    )
    .unwrap();
    let host = host();
    host.load_dir(&dir).unwrap();
    host.run("fetcher-go").unwrap();
    let said = messages(&host, 1);
    assert!(said[0].contains("add \"net:127.0.0.1\""), "{said:?}");
    std::fs::remove_dir_all(&dir).unwrap();
}

fn host() -> Host {
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", "", None);
    Host::new(editor).unwrap()
}
