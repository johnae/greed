//! The models plugin against a fake server that streams the way the
//! Anthropic and `OpenAI` APIs do.

mod support;

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::time::Duration;

use greed_core::Editor;
use greed_core::luau::Host;
use greed_text::ClientId;

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
            local greed = require("@greed")
            local models = require("@models")
            models.providers.fake = {{ kind = "anthropic", url = "{address}" }}
            models.providers.compat = {{ kind = "openai", url = "{address}/v1" }}
            models.roles.fast = {{ provider = "fake", model = "m1" }}
            models.roles["local"] = {{ provider = "compat", model = "m2" }}
            models.roles.locked = {{ provider = "fake", model = "refuse" }}
            local hi = {{ messages = {{ {{ role = "user", content = "hi" }} }} }}
            greed.command {{ name = "ask-fast", run = function()
                local stream = assert(models.stream("fast", hi))
                while true do
                    local piece, err = stream.next()
                    if piece == nil then greed.echo("end " .. tostring(err)) break end
                    greed.echo(piece)
                end
                greed.echo("all " .. stream.text)
            end }}
            greed.command {{ name = "ask-local", run = function()
                greed.echo((assert(models.ask("local", hi))))
            end }}
            greed.command {{ name = "ask-locked", run = function()
                local _, err = models.ask("locked", hi)
                greed.echo(err)
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

#[test]
fn a_model_pipe_rewrites_the_selection_as_one_operation() {
    let address = serve();
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", "hi there", None);
    let host = Host::new(editor).unwrap();
    host.load_dirs(&[
        plugin("core"),
        plugin("picker"),
        plugin("multibuffer"),
        plugin("operations"),
        plugin("models"),
        plugin("pipe"),
    ])
    .unwrap();
    host.load_str(
        "config",
        &format!(
            r#"
            local greed = require("@greed")
            local models = require("@models")
            models.providers.fake = {{ kind = "anthropic", url = "{address}" }}
            models.roles.fast = {{ provider = "fake", model = "m1" }}
            greed.command {{ name = "pipe-test", run = function(ctx)
                ctx.view:set_selection({{ ranges = {{ {{ anchor = 0, head = 8 }} }}, primary = 1 }})
                local ok, err = require("@pipe").pipe(ctx.view, "model: shout it")
                greed.echo(if ok then "piped" else tostring(err))
                greed.echo(require("@operations").list()[1].name)
            end }}
            "#
        ),
    )
    .unwrap();
    host.run("pipe-test").unwrap();
    let said = messages(&host, 3);
    assert_eq!(said[1..], ["piped", "model: shout it"], "{said:?}");
    let text = host.with_editor(|ed| ed.buffer(ed.view(ed.focus()).buffer).text().to_string());
    assert_eq!(text, "Hello");
}

/// A host with the assist plugin and what it needs, the fake model server as
/// the `fast` role, and `text` open as `path`.
fn assist_host(address: &str, text: &str, path: Option<PathBuf>) -> Host {
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", text, path);
    let host = Host::new(editor).unwrap();
    load_assist(&host, address);
    host
}

/// Loads the assist plugin and what it needs, with the fake model server at
/// `address` as the `fast` role.
fn load_assist(host: &Host, address: &str) {
    host.load_dirs(&[
        plugin("core"),
        plugin("picker"),
        plugin("terminal"),
        plugin("multibuffer"),
        plugin("operations"),
        plugin("approvals"),
        plugin("agent"),
        plugin("vcs"),
        plugin("context"),
        plugin("models"),
        plugin("assist"),
    ])
    .unwrap();
    host.load_str(
        "config",
        &format!(
            r#"
            local models = require("@models")
            models.providers.fake = {{ kind = "anthropic", url = "{address}" }}
            models.roles.fast = {{ provider = "fake", model = "m1" }}
            "#
        ),
    )
    .unwrap();
}

/// Finishes jobs until `done` says so.
fn until(host: &Host, mut done: impl FnMut(&Host) -> bool) {
    let jobs = host.finished_jobs();
    while !done(host) {
        let job = jobs
            .recv_timeout(Duration::from_secs(5))
            .expect("a job finished");
        host.finish_job(job).unwrap();
    }
}

fn buffer_of_kind(host: &Host, kind: &str) -> Option<String> {
    host.with_editor(|ed| {
        ed.buffers()
            .find(|b| b.kind() == kind)
            .map(|b| b.text().to_string())
    })
}

#[test]
fn explain_writes_the_answer_into_a_panel_as_it_arrives() {
    let host = assist_host(&serve(), "let x = 1;", None);
    host.run("explain").unwrap();
    until(&host, |h| {
        buffer_of_kind(h, "answer").as_deref() == Some("Hello")
    });
}

#[test]
fn a_drafted_description_commits_what_is_staged() {
    let dir = std::env::temp_dir().join(format!("greed-assist-git-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let git = |args: &[&str]| {
        let out = std::process::Command::new("git")
            .args(["-c", "user.name=t", "-c", "user.email=t@t"])
            .args(args)
            .current_dir(&dir)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).into_owned()
    };
    std::fs::write(dir.join("a.txt"), "one\n").unwrap();
    git(&["init", "-q"]);
    git(&["add", "."]);
    git(&["commit", "-q", "-m", "first"]);
    std::fs::write(dir.join("a.txt"), "two\n").unwrap();
    git(&["add", "."]);
    let host = assist_host(&serve(), "two\n", Some(dir.join("a.txt")));
    host.run("commit-message").unwrap();
    until(&host, |h| {
        buffer_of_kind(h, "commit-message").as_deref() == Some("Hello")
    });
    // a, in the description buffer.
    host.load_str(
        "press-a",
        r#"
        local greed = require("@greed")
        greed.command { name = "press-a", run = function()
            for _, buffer in greed.buffers() do
                if buffer:kind() == "commit-message" then
                    buffer:views()[1]:focus()
                end
            end
            greed.run("commit-message-apply")
        end }
        "#,
    )
    .unwrap();
    host.run("press-a").unwrap();
    until(&host, |_| git(&["log", "-1", "--format=%s"]) == "Hello\n");
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_fix_comes_as_a_proposal_to_review() {
    let address = serve();
    let mut editor = Editor::new(ClientId(1));
    editor.open(
        "file",
        "let x = bad;",
        Some(std::env::temp_dir().join("greed-assist-fix/main.rs")),
    );
    let host = Host::new(editor).unwrap();
    let (input, output, _log) = support::start();
    host.connect_lsp("rust", Box::new(input), output).unwrap();
    load_assist(&host, &address);
    host.sync_lsp();
    // Drive both servers: the language server's events and the model's job.
    let lsp = host.lsp_events();
    let jobs = host.finished_jobs();
    let step = |host: &Host| {
        crossbeam_channel::select! {
            recv(lsp) -> event => host.handle_lsp(event.unwrap()).unwrap(),
            recv(jobs) -> job => host.finish_job(job.unwrap()).unwrap(),
            default(Duration::from_secs(5)) => panic!("nothing happened"),
        }
    };
    while !host.diagnostic_marks().values().any(|d| !d.is_empty()) {
        step(&host);
    }
    host.run("fix").unwrap();
    let pending = |host: &Host| host.eval("require('@agent').pending()").unwrap();
    while pending(&host) == "0" {
        step(&host);
    }
    host.press_keys("space o A").unwrap();
    let text = host.with_editor(|ed| ed.buffer(ed.view(ed.focus()).buffer).text().to_string());
    assert_eq!(text, "Hello");
}
