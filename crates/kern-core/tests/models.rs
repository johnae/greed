//! The models plugin against a fake server that streams the way the
//! Anthropic and `OpenAI` APIs do.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::time::Duration;

use kern_core::Editor;
use kern_core::luau::Host;
use kern_text::ClientId;

fn plugin(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../runtime/plugins")
        .join(name)
}

/// Streams "Hello" from `/v1/messages` and "Hi there" from
/// `/v1/chat/completions`, events cut across pieces, and refuses the model
/// "refuse" as a bad key would be.
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
    let body = String::from_utf8(body).unwrap();
    let mut out = stream;
    if body.contains("\"refuse\"") {
        let refused = r#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#;
        write!(
            out,
            "HTTP/1.1 401 Unauthorized\r\nContent-Length: {}\r\n\r\n{refused}",
            refused.len()
        )
        .unwrap();
        return;
    }
    assert!(body.contains("\"stream\":true"), "{body}");
    let pieces: Vec<&str> = if first.contains("/v1/messages") {
        vec![
            "event: message_start\ndata: {\"type\":\"message_start\"}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_",
            "delta\",\"text\":\"Hel\"}}\n\nevent: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"lo\"}}\n\n",
            "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
        ]
    } else {
        vec![
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\" there\"}}]}\n\ndata: [DONE]\n\n",
        ]
    };
    write!(
        out,
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
    )
    .unwrap();
    for piece in pieces {
        write!(out, "{:x}\r\n{piece}\r\n", piece.len()).unwrap();
        out.flush().unwrap();
        std::thread::sleep(Duration::from_millis(20));
    }
    write!(out, "0\r\n\r\n").unwrap();
    out.flush().unwrap();
}

/// Finishes jobs until `count` messages were echoed, and returns them.
fn messages(host: &Host, count: usize) -> Vec<String> {
    let jobs = host.finished_jobs();
    let mut got = Vec::new();
    loop {
        got.extend(host.with_editor_mut(Editor::take_messages));
        if got.len() >= count {
            return got;
        }
        let done = jobs
            .recv_timeout(Duration::from_secs(5))
            .expect("a job finished");
        host.finish_job(done).unwrap();
    }
}

fn host(address: &str) -> Host {
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", "", None);
    let host = Host::new(editor).unwrap();
    host.load_dirs(&[plugin("core"), plugin("models")]).unwrap();
    host.load_str(
        "config",
        &format!(
            r#"
            local kern = require("@kern")
            local models = require("@models")
            models.providers.fake = {{ kind = "anthropic", url = "{address}" }}
            models.providers.compat = {{ kind = "openai", url = "{address}/v1" }}
            models.roles.fast = {{ provider = "fake", model = "m1" }}
            models.roles["local"] = {{ provider = "compat", model = "m2" }}
            models.roles.locked = {{ provider = "fake", model = "refuse" }}
            local hi = {{ messages = {{ {{ role = "user", content = "hi" }} }} }}
            kern.command {{ name = "ask-fast", run = function()
                local stream = assert(models.stream("fast", hi))
                while true do
                    local piece, err = stream.next()
                    if piece == nil then kern.echo("end " .. tostring(err)) break end
                    kern.echo(piece)
                end
                kern.echo("all " .. stream.text)
            end }}
            kern.command {{ name = "ask-local", run = function()
                kern.echo((assert(models.ask("local", hi))))
            end }}
            kern.command {{ name = "ask-locked", run = function()
                local _, err = models.ask("locked", hi)
                kern.echo(err)
            end }}
            "#
        ),
    )
    .unwrap();
    host
}

#[test]
fn anthropic_streams_its_answer_piece_by_piece() {
    let host = host(&serve());
    host.run("ask-fast").unwrap();
    assert_eq!(messages(&host, 4), ["Hel", "lo", "end nil", "all Hello"]);
}

#[test]
fn openai_compatible_servers_answer_too() {
    let host = host(&serve());
    host.run("ask-local").unwrap();
    assert_eq!(messages(&host, 1), ["Hi there"]);
}

#[test]
fn a_refused_request_says_what_the_server_said() {
    let host = host(&serve());
    host.run("ask-locked").unwrap();
    assert_eq!(
        messages(&host, 1),
        ["the model's server said 401: invalid x-api-key"]
    );
}
