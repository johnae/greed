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

/// The document the client opened or changed last.
#[derive(Default)]
struct Opened {
    uri: Value,
    text: String,
}

impl From<&Value> for Opened {
    /// From `didOpen` or `didChange` parameters, with the whole text.
    fn from(params: &Value) -> Self {
        let text = params["textDocument"]["text"]
            .as_str()
            .or_else(|| params["contentChanges"][0]["text"].as_str())
            .unwrap_or_default();
        Opened {
            uri: params["textDocument"]["uri"].clone(),
            text: text.to_owned(),
        }
    }
}

/// Signature help for `add(a, b)`: the parameter being typed, or nothing
/// outside a call, from the text before `position`.
fn signature_help(doc: &Opened, position: &Value) -> Value {
    let at = |key: &str| {
        position[key]
            .as_u64()
            .and_then(|n| usize::try_from(n).ok())
            .unwrap_or_default()
    };
    let line = doc.text.lines().nth(at("line")).unwrap_or_default();
    let before = &line[..at("character").min(line.len())];
    let Some(call) = before.rfind('(') else {
        return Value::Null;
    };
    if before[call..].contains(')') {
        return Value::Null;
    }
    let active = before[call..].matches(',').count();
    json!({
        "signatures": [{ "label": "fn add(a: i32, b: i32)", "parameters": [
            { "label": [7, 13] },
            { "label": "b: i32" },
        ] }],
        "activeSignature": 0,
        "activeParameter": active,
    })
}

/// Where "bad" is in "let x = bad;".
fn word_range() -> Value {
    json!({ "start": { "line": 0, "character": 8 }, "end": { "line": 0, "character": 11 } })
}

/// A tiny language server: reports every "bad" as an error, answers hover
/// with the position it was asked about, and logs every method it gets.
fn fake_server(input: impl Read, mut output: impl Write, log: &crossbeam_channel::Sender<String>) {
    let mut input = BufReader::new(input);
    let mut opened = Opened::default();
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
                &json!({ "jsonrpc": "2.0", "id": id, "result": { "capabilities": {
                    "positionEncoding": "utf-8",
                    "renameProvider": { "prepareProvider": true },
                    "codeActionProvider": { "resolveProvider": true },
                    "referencesProvider": true,
                    "signatureHelpProvider": { "triggerCharacters": ["(", ","] },
                } } }),
            ),
            "initialized" => initialized(&mut output),
            "textDocument/didOpen" | "textDocument/didChange" => {
                opened = Opened::from(&message["params"]);
                publish_diagnostics(&mut output, &opened);
            }
            // "ask" asks the user to pick, then writes their answer over
            // the first word once it comes back.
            "workspace/executeCommand" if message["params"]["command"] == "ask" => {
                ask(&mut output, id.as_ref(), &message, &opened);
            }
            "(response)" if id == Some(json!("pick")) => {
                ask(&mut output, id.as_ref(), &message, &opened);
            }
            // Shouting asks the editor to apply an edit, as servers do for
            // commands, then answers.
            "workspace/executeCommand" => {
                let uri = message["params"]["arguments"][0].clone();
                write(
                    &mut output,
                    &json!({ "jsonrpc": "2.0", "id": "apply", "method": "workspace/applyEdit", "params": { "edit": {
                        "documentChanges": [{
                            "textDocument": { "uri": uri, "version": null },
                            "edits": [{ "range": { "start": { "line": 0, "character": 0 }, "end": { "line": 0, "character": 3 } }, "newText": "LET" }],
                        }],
                    } } }),
                );
                write(
                    &mut output,
                    &json!({ "jsonrpc": "2.0", "id": id, "result": null }),
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
                    "range": word_range(),
                } }),
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
            other => {
                if let Some(result) = answer(other, &message["params"], &opened) {
                    write(
                        &mut output,
                        &json!({ "jsonrpc": "2.0", "id": id, "result": result }),
                    );
                }
            }
        }
    }
}

/// What the server does once started: asks for its settings, and reports
/// some work, begun and done, as servers report indexing.
fn initialized(output: &mut impl Write) {
    write(
        output,
        &json!({ "jsonrpc": "2.0", "id": "ask", "method": "workspace/configuration", "params": { "items": [{}, {}] } }),
    );
    for value in [
        json!({ "kind": "begin", "title": "Indexing", "percentage": 0 }),
        json!({ "kind": "end" }),
    ] {
        write(
            output,
            &json!({ "jsonrpc": "2.0", "method": "$/progress", "params": { "token": "index", "value": value } }),
        );
    }
}

/// Reports every "bad" in the document as an error, and a warning in a
/// file next to it that isn't open.
fn publish_diagnostics(output: &mut impl Write, doc: &Opened) {
    let diagnostics: Vec<Value> = doc
        .text
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
        output,
        &json!({ "jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": { "uri": doc.uri, "diagnostics": diagnostics } }),
    );
    let other = doc
        .uri
        .as_str()
        .unwrap_or_default()
        .replace("main.rs", "other.rs");
    write(
        output,
        &json!({ "jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": { "uri": other, "diagnostics": [{
            "range": { "start": { "line": 2, "character": 0 }, "end": { "line": 2, "character": 5 } },
            "severity": 2, "message": "unused thing",
        }] } }),
    );
}

/// Answers that are only a result: completion, formatting, and changing
/// "bad" with rename, references and code actions.
/// `opened` is the document opened or changed last.
fn answer(method: &str, params: &Value, opened: &Opened) -> Option<Value> {
    let uri = params["textDocument"]["uri"].as_str().unwrap_or_default();
    let answer = match method {
        "textDocument/completion" => json!({ "isIncomplete": false, "items": [
            { "label": "bad_thing", "kind": 3, "detail": "fn()" },
            { "label": "badge", "kind": 6 },
            { "label": "other", "kind": 6 },
            { "label": "snippet", "insertText": "snip(${1:x})$0", "insertTextFormat": 2 },
        ] }),
        "textDocument/formatting" => json!([
            { "range": { "start": { "line": 0, "character": 0 }, "end": { "line": 0, "character": 0 } }, "newText": "// formatted\n" },
        ]),
        "textDocument/signatureHelp" => signature_help(opened, &params["position"]),
        "textDocument/prepareRename" => json!({ "range": word_range(), "placeholder": "bad" }),
        "textDocument/rename" => json!({ "changes": {
            uri: [{ "range": word_range(), "newText": params["newName"] }],
        } }),
        "textDocument/references" => {
            let x = json!({ "start": { "line": 0, "character": 4 }, "end": { "line": 0, "character": 5 } });
            json!([{ "uri": uri, "range": word_range() }, { "uri": uri, "range": x }])
        }
        "textDocument/codeAction" => {
            let known = params["context"]["diagnostics"]
                .as_array()
                .map_or(0, Vec::len);
            json!([
                { "title": "Shout", "command": { "title": "Shout", "command": "shout", "arguments": [uri] } },
                { "title": format!("Make it good ({known} known)"), "kind": "quickfix", "isPreferred": true,
                  "edit": { "changes": { uri: [{ "range": word_range(), "newText": "good" }] } } },
                { "title": "Add a comment", "data": 7 },
            ])
        }
        "codeAction/resolve" => {
            let mut action = params.clone();
            action["edit"] = json!({ "documentChanges": [{
                "textDocument": { "uri": opened.uri, "version": null },
                "edits": [{ "range": { "start": { "line": 0, "character": 0 }, "end": { "line": 0, "character": 0 } }, "newText": "// resolved\n" }],
            }] });
            action
        }
        _ => return None,
    };
    Some(answer)
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

/// Whether any buffer has diagnostic marks yet.
#[allow(dead_code)]
pub fn has_diagnostics(host: &greed_core::luau::Host) -> bool {
    host.with_editor(|ed| {
        ed.buffers()
            .any(|b| !b.marks(greed_core::lsp::DIAGNOSTICS).is_empty())
    })
}

/// The "ask" command: sends the user a choice, and once the answer (the
/// response with id "pick") comes back, writes its title over the first word.
fn ask(output: &mut impl Write, id: Option<&Value>, message: &Value, opened: &Opened) {
    if message.get("method").is_some() {
        write(
            output,
            &json!({ "jsonrpc": "2.0", "id": "pick", "method": "window/showMessageRequest", "params": {
                "type": 3, "message": "Which word?", "actions": [{ "title": "Yes" }, { "title": "No" }],
            } }),
        );
        write(
            output,
            &json!({ "jsonrpc": "2.0", "id": id, "result": null }),
        );
        return;
    }
    let title = message["result"]["title"].as_str().unwrap_or("nothing");
    write(
        output,
        &json!({ "jsonrpc": "2.0", "id": "apply", "method": "workspace/applyEdit", "params": { "edit": {
            "documentChanges": [{
                "textDocument": { "uri": opened.uri, "version": null },
                "edits": [{ "range": { "start": { "line": 0, "character": 0 }, "end": { "line": 0, "character": 3 } }, "newText": title }],
            }],
        } } }),
    );
}
