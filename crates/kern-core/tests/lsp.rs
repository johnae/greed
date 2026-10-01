use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

use kern_core::Editor;
use kern_core::lsp::{Encoding, Handled, Lsp, file_uri, offset, position};
use kern_text::{ClientId, Rope};
use serde_json::{Value, json};

fn read(reader: &mut impl BufRead) -> Option<Value> {
    let mut length = 0;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).ok()? == 0 {
            return None;
        }
        if line.trim().is_empty() {
            break;
        }
        if let Some(n) = line.strip_prefix("Content-Length:") {
            length = n.trim().parse().ok()?;
        }
    }
    let mut body = vec![0; length];
    reader.read_exact(&mut body).ok()?;
    serde_json::from_slice(&body).ok()
}

fn write(writer: &mut impl Write, message: &Value) {
    let body = message.to_string();
    write!(writer, "Content-Length: {}\r\n\r\n{body}", body.len()).unwrap();
    writer.flush().unwrap();
}

/// A tiny language server: reports every "bad" as an error, answers hover
/// with the position it was asked about, and logs every method it gets.
fn fake_server(input: impl Read, mut output: impl Write, log: &crossbeam_channel::Sender<String>) {
    let mut input = BufReader::new(input);
    while let Some(message) = read(&mut input) {
        let method = message["method"]
            .as_str()
            .unwrap_or("(response)")
            .to_owned();
        let _ = log.send(method.clone());
        let id = message.get("id").cloned();
        match method.as_str() {
            "initialize" => write(
                &mut output,
                &json!({ "jsonrpc": "2.0", "id": id, "result": { "capabilities": { "positionEncoding": "utf-8" } } }),
            ),
            "initialized" => write(
                &mut output,
                &json!({ "jsonrpc": "2.0", "id": "ask", "method": "workspace/configuration", "params": { "items": [{}, {}] } }),
            ),
            "textDocument/didOpen" | "textDocument/didChange" => {
                let doc = &message["params"]["textDocument"];
                let text = doc["text"]
                    .as_str()
                    .or_else(|| message["params"]["contentChanges"][0]["text"].as_str())
                    .unwrap_or_default();
                let diagnostics: Vec<Value> = text
                    .lines()
                    .enumerate()
                    .flat_map(|(line, content)| {
                        content.match_indices("bad").map(move |(col, _)| {
                            json!({
                                "range": { "start": { "line": line, "character": col }, "end": { "line": line, "character": col + 3 } },
                                "severity": 1, "message": "bad word", "source": "fake",
                            })
                        })
                    })
                    .collect();
                write(
                    &mut output,
                    &json!({ "jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": { "uri": doc["uri"], "diagnostics": diagnostics } }),
                );
            }
            "textDocument/hover" => {
                let p = &message["params"]["position"];
                let text = format!("hover at {}:{}", p["line"], p["character"]);
                write(
                    &mut output,
                    &json!({ "jsonrpc": "2.0", "id": id, "result": { "contents": text } }),
                );
            }
            "fail" => write(
                &mut output,
                &json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32601, "message": "nope" } }),
            ),
            "shutdown" => write(
                &mut output,
                &json!({ "jsonrpc": "2.0", "id": id, "result": null }),
            ),
            "exit" => return,
            _ => {}
        }
    }
}

struct Setup {
    lsp: Lsp,
    editor: Editor,
    log: crossbeam_channel::Receiver<String>,
    path: PathBuf,
}

fn setup(text: &str) -> Setup {
    let (server_in, client_out) = std::io::pipe().unwrap();
    let (client_in, server_out) = std::io::pipe().unwrap();
    let (log_tx, log) = crossbeam_channel::unbounded();
    std::thread::spawn(move || fake_server(server_in, server_out, &log_tx));

    let path = std::env::temp_dir().join("kern-lsp-test/main.rs");
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", text, Some(path.clone()));
    let mut lsp = Lsp::default();
    lsp.connect("rust", Box::new(client_out), client_in, Path::new("/tmp"))
        .unwrap();
    Setup {
        lsp,
        editor,
        log,
        path,
    }
}

impl Setup {
    /// Handles events until one is handled as something other than nothing.
    fn next(&mut self) -> Handled {
        loop {
            let event = self
                .lsp
                .events()
                .recv_timeout(Duration::from_secs(5))
                .expect("server answered");
            match self.lsp.handle(event, &self.editor) {
                Handled::Nothing => {}
                handled => return handled,
            }
        }
    }

    fn methods(&self) -> Vec<String> {
        std::thread::sleep(Duration::from_millis(50));
        self.log.try_iter().collect()
    }
}

#[test]
fn documents_open_after_initialize_and_report_diagnostics() {
    let mut s = setup("fn main() {\n    let é = bad;\n}\n");
    assert!(s.lsp.sync(&s.editor).is_empty());
    let buffer = s.editor.buffers().next().unwrap().id();
    assert_eq!(s.next(), Handled::Diagnostics(buffer));

    let diagnostics = s.lsp.diagnostics(buffer);
    assert_eq!(diagnostics.len(), 1);
    let text = s.editor.buffer(buffer).text().to_string();
    let d = &diagnostics[0];
    assert_eq!(&text[d.from..d.to], "bad");
    assert_eq!(
        (d.severity, d.message.as_str(), d.source.as_deref()),
        (1, "bad word", Some("fake"))
    );

    let methods = s.methods();
    assert_eq!(
        methods[..3],
        ["initialize", "initialized", "textDocument/didOpen"]
    );
    // The server's question was answered.
    assert!(methods.contains(&"(response)".to_string()), "{methods:?}");
    assert_eq!(
        s.lsp.encoding(s.editor.buffer(buffer)).unwrap(),
        Encoding::Utf8
    );
}

#[test]
fn changes_are_sent_once_per_version() {
    let mut s = setup("ok");
    s.lsp.sync(&s.editor);
    s.next();
    s.lsp.sync(&s.editor);
    assert!(!s.methods().contains(&"textDocument/didChange".to_string()));

    let view = s.editor.focus();
    let changes = kern_text::ChangeSet::from_changes(2, [(2, 2, Some(" bad"))]).unwrap();
    s.editor
        .apply(
            view,
            changes,
            kern_text::Author::User(ClientId(1)),
            None,
            None,
        )
        .unwrap();
    s.lsp.sync(&s.editor);
    let buffer = s.editor.buffers().next().unwrap().id();
    assert_eq!(s.next(), Handled::Diagnostics(buffer));
    assert_eq!(s.lsp.diagnostics(buffer).len(), 1);
    assert!(s.methods().contains(&"textDocument/didChange".to_string()));
}

#[test]
fn requests_get_their_responses() {
    let mut s = setup("ok");
    s.lsp.sync(&s.editor);
    s.next();
    let buffer = s.editor.buffers().next().unwrap();
    let params = json!({ "textDocument": { "uri": file_uri(&s.path) }, "position": { "line": 0, "character": 1 } });
    let (server, id) = s
        .lsp
        .request(buffer, "textDocument/hover", &params)
        .unwrap();
    assert_eq!(
        s.next(),
        Handled::Response {
            server,
            id,
            result: Ok(json!({ "contents": "hover at 0:1" })),
        }
    );
    let buffer = s.editor.buffers().next().unwrap();
    let (_, id) = s.lsp.request(buffer, "fail", &Value::Null).unwrap();
    match s.next() {
        Handled::Response {
            id: got,
            result: Err(err),
            ..
        } => {
            assert_eq!(got, id);
            assert_eq!(err["message"], "nope");
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn buffers_without_a_server_say_so() {
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", "", Some("notes.txt".into()));
    let mut lsp = Lsp::default();
    assert!(lsp.sync(&editor).is_empty());
    let err = lsp
        .request(editor.buffers().next().unwrap(), "x", &Value::Null)
        .unwrap_err();
    assert!(err.to_string().contains("no language server"), "{err}");
}

#[test]
fn positions_count_in_the_servers_encoding() {
    let text = Rope::from_str("aé😀b\nx");
    // byte 7 is "b": 1 (a) + 2 (é) + 4 (😀)
    assert_eq!(
        position(&text, 7, Encoding::Utf8),
        json!({ "line": 0, "character": 7 })
    );
    assert_eq!(
        position(&text, 7, Encoding::Utf16),
        json!({ "line": 0, "character": 4 })
    );
    assert_eq!(
        position(&text, 9, Encoding::Utf16),
        json!({ "line": 1, "character": 0 })
    );

    let at = |line: u64, character: u64, e| {
        offset(&text, &json!({ "line": line, "character": character }), e)
    };
    assert_eq!(at(0, 7, Encoding::Utf8), Some(7));
    assert_eq!(at(0, 4, Encoding::Utf16), Some(7));
    // Past the end of a line clamps to the line's end; past the last line to the buffer's end.
    assert_eq!(at(0, 99, Encoding::Utf16), Some(8));
    assert_eq!(at(9, 0, Encoding::Utf16), Some(10));
}
