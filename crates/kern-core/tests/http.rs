//! `kern.http` against a tiny server on localhost.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::Duration;

use kern_core::Editor;
use kern_core::luau::Host;
use kern_text::ClientId;

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

/// Finishes jobs until `count` messages were echoed, and returns them.
fn messages(host: &Host, count: usize) -> Vec<String> {
    let jobs = host.finished_jobs();
    let mut got = Vec::new();
    while got.len() < count {
        got.extend(host.with_editor_mut(Editor::take_messages));
        if got.len() >= count {
            break;
        }
        let done = jobs
            .recv_timeout(Duration::from_secs(5))
            .expect("a job finished");
        host.finish_job(done).unwrap();
    }
    got
}

#[test]
fn requests_wait_for_the_whole_response() {
    let address = serve();
    let host = host();
    host.load_str(
        "fetch",
        &format!(
            r#"
            local kern = require("@kern")
            kern.command {{ name = "fetch", run = function()
                local r = assert(kern.http.request({{ url = "{address}/hello" }}))
                kern.echo(`{{r.status}} {{r.headers["x-kind"]}} {{r.body}}`)
                local e = assert(kern.http.request({{ url = "{address}/echo", body = "sent" }}))
                kern.echo(`{{e.status}} {{e.body}}`)
                local _, err = kern.http.request({{ url = "http://127.0.0.1:1/" }})
                kern.echo(if err then "refused" else "connected")
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
fn streams_give_each_piece_as_it_arrives() {
    let address = serve();
    let host = host();
    host.load_str(
        "stream",
        &format!(
            r#"
            local kern = require("@kern")
            kern.command {{ name = "stream", run = function()
                local s = assert(kern.http.stream({{ url = "{address}/stream" }}))
                kern.echo("status " .. s.status)
                while true do
                    local piece = s.read()
                    if piece == nil then break end
                    kern.echo(piece)
                end
                kern.echo("end")
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
    let dir = std::env::temp_dir().join(format!("kern-http-net-{}", std::process::id()));
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
            local kern = require("@kern")
            kern.command {{ name = "fetcher-go", run = function()
                local ok, err = pcall(kern.http.request, {{ url = "{address}/hello" }})
                kern.echo(if ok then "fetched" else tostring(err))
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
