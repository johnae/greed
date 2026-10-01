//! A tiny language server for tests, spoken to over pipes.

use std::io::{BufRead, BufReader, Read, Write};

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
                // Past column 10 there is nothing to say, as servers often answer.
                let text = if p["character"].as_u64() > Some(10) {
                    String::new()
                } else {
                    format!("hover at {}:{}", p["line"], p["character"])
                };
                write(
                    &mut output,
                    &json!({ "jsonrpc": "2.0", "id": id, "result": { "contents": text } }),
                );
            }
            // Past column 10 there's no definition: an empty list, as servers answer.
            "textDocument/definition"
                if message["params"]["position"]["character"].as_u64() > Some(10) =>
            {
                write(
                    &mut output,
                    &json!({ "jsonrpc": "2.0", "id": id, "result": [] }),
                );
            }
            "textDocument/definition" => write(
                &mut output,
                &json!({ "jsonrpc": "2.0", "id": id, "result": {
                    "uri": message["params"]["textDocument"]["uri"],
                    "range": { "start": { "line": 0, "character": 8 }, "end": { "line": 0, "character": 11 } },
                } }),
            ),
            "textDocument/completion" => write(
                &mut output,
                &json!({ "jsonrpc": "2.0", "id": id, "result": { "isIncomplete": false, "items": [
                    { "label": "bad_thing", "kind": 3, "detail": "fn()" },
                    { "label": "badge", "kind": 6 },
                    { "label": "other", "kind": 6 },
                    { "label": "snippet", "insertText": "snip(${1:x})$0", "insertTextFormat": 2 },
                ] } }),
            ),
            "textDocument/formatting" => write(
                &mut output,
                &json!({ "jsonrpc": "2.0", "id": id, "result": [
                    { "range": { "start": { "line": 0, "character": 0 }, "end": { "line": 0, "character": 0 } }, "newText": "// formatted\n" },
                ] }),
            ),
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

/// Starts the fake server on a thread. Returns the pipe ends for the client
/// (what to write to, what to read from) and a log of the methods it got.
pub fn start() -> (
    std::io::PipeWriter,
    std::io::PipeReader,
    crossbeam_channel::Receiver<String>,
) {
    let (server_in, client_out) = std::io::pipe().unwrap();
    let (client_in, server_out) = std::io::pipe().unwrap();
    let (log_tx, log) = crossbeam_channel::unbounded();
    std::thread::spawn(move || fake_server(server_in, server_out, &log_tx));
    (client_out, client_in, log)
}
