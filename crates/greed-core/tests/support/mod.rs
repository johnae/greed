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

/// How the fake server says it works.
#[derive(Debug, Clone, Copy)]
pub struct Options {
    /// Whether it takes changes as ranges, or the whole text each time.
    pub incremental: bool,
    /// Whether it counts positions in UTF-8 bytes, or UTF-16 code units.
    pub utf8: bool,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            incremental: false,
            utf8: true,
        }
    }
}

/// The documents the client has open in the fake server, kept as LSP says
/// to from what it's told, and how it was told.
#[derive(Default)]
struct Documents {
    texts: std::collections::HashMap<String, String>,
    /// How many changes came as ranges, and as the whole text.
    ranged: usize,
    whole: usize,
    /// What the client got wrong, like a position that isn't one.
    errors: Vec<String>,
}

impl Documents {
    /// Takes in `didOpen`, `didChange` or `didClose` parameters, and returns
    /// the document as it is now.
    fn update(&mut self, method: &str, params: &Value, options: Options) -> Opened {
        let uri = params["textDocument"]["uri"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        match method {
            "textDocument/didOpen" => {
                let text = params["textDocument"]["text"].as_str().unwrap_or_default();
                self.texts.insert(uri.clone(), text.to_owned());
            }
            "textDocument/didClose" => {
                self.texts.remove(&uri);
            }
            _ => {
                let mut text = self.texts.remove(&uri).unwrap_or_default();
                for change in params["contentChanges"].as_array().into_iter().flatten() {
                    let new = change["text"].as_str().unwrap_or_default();
                    if change.get("range").is_none() {
                        self.whole += 1;
                        new.clone_into(&mut text);
                        continue;
                    }
                    self.ranged += 1;
                    if !options.incremental {
                        self.errors
                            .push("a range to a server that wants it all".into());
                    }
                    let range = &change["range"];
                    match (
                        lsp_offset(&text, &range["start"], options.utf8),
                        lsp_offset(&text, &range["end"], options.utf8),
                    ) {
                        (Ok(from), Ok(to)) if from <= to => text.replace_range(from..to, new),
                        (from, to) => self.errors.push(format!("{range}: {from:?} {to:?}")),
                    }
                }
                self.texts.insert(uri.clone(), text);
            }
        }
        let text = self.texts.get(&uri).cloned().unwrap_or_default();
        Opened {
            uri: json!(uri),
            text,
        }
    }
}

/// Where an LSP position is in `text`, strictly: lines end at `\n`, `\r\n`
/// or `\r`, and a position past its line's end or inside a character is an
/// error, since the client shouldn't send one.
fn lsp_offset(text: &str, position: &Value, utf8: bool) -> Result<usize, String> {
    let line = usize::try_from(position["line"].as_u64().ok_or("no line")?).unwrap();
    let character = usize::try_from(position["character"].as_u64().ok_or("no character")?).unwrap();
    let bytes = text.as_bytes();
    let line_end = |from: usize| {
        bytes[from..]
            .iter()
            .position(|b| matches!(b, b'\n' | b'\r'))
            .map(|at| from + at)
    };
    let mut start = 0;
    for _ in 0..line {
        let Some(at) = line_end(start) else {
            return Err(format!("no line {line}"));
        };
        start = if bytes[at] == b'\r' && bytes.get(at + 1) == Some(&b'\n') {
            at + 2
        } else {
            at + 1
        };
    }
    let end = line_end(start).unwrap_or(text.len());
    let mut units = 0;
    for (at, c) in text[start..end].char_indices() {
        if units == character {
            return Ok(start + at);
        }
        if units > character {
            return Err(format!("character {character} is inside a character"));
        }
        units += if utf8 { c.len_utf8() } else { c.len_utf16() };
    }
    match units.cmp(&character) {
        std::cmp::Ordering::Equal => Ok(end),
        std::cmp::Ordering::Greater => Err(format!("character {character} is inside a character")),
        std::cmp::Ordering::Less => Err(format!(
            "character {character} is past the end of line {line}"
        )),
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
fn fake_server(
    input: impl Read,
    mut output: impl Write,
    log: &crossbeam_channel::Sender<String>,
    options: Options,
) {
    let mut input = BufReader::new(input);
    let mut opened = Opened::default();
    let mut documents = Documents::default();
    // How it was started, the workspace folders the client said it has, and
    // the settings it was told and answered when it asked.
    let (mut started, mut folders) = (Value::Null, Value::Null);
    let (mut changed, mut configured) = (Value::Null, Value::Null);
    while let Some(message) = read(&mut input) {
        let method = message["method"]
            .as_str()
            .unwrap_or("(response)")
            .to_owned();
        let _ = log.send(method.clone());
        let id = message.get("id").cloned();
        match method.as_str() {
            "initialize" => {
                started = message["params"].clone();
                write(
                    &mut output,
                    &json!({ "jsonrpc": "2.0", "id": id, "result": { "capabilities": capabilities(options) } }),
                );
            }
            "initialized" => initialized(&mut output),
            "(response)" if id == Some(json!("folders")) => folders = message["result"].clone(),
            "(response)" if id == Some(json!("ask")) => configured = message["result"].clone(),
            "workspace/didChangeConfiguration" => changed = message["params"].clone(),
            // What the client started it with and told it since.
            "probe" => write(
                &mut output,
                &json!({ "jsonrpc": "2.0", "id": id, "result": {
                    "initialize": started, "folders": folders, "text": opened.text,
                    "ranged": documents.ranged, "whole": documents.whole,
                    "errors": documents.errors,
                    "changed": changed, "configured": configured,
                } }),
            ),
            "textDocument/didOpen" | "textDocument/didChange" => {
                opened = documents.update(&method, &message["params"], options);
                publish_diagnostics(&mut output, &opened);
            }
            "textDocument/didClose" => {
                documents.update(&method, &message["params"], options);
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
            "fail" => write(
                &mut output,
                &json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32601, "message": "nope" } }),
            ),
            "shutdown" => write(
                &mut output,
                &json!({ "jsonrpc": "2.0", "id": id, "result": null }),
            ),
            // "die" stops without answering, as a server that crashes.
            "exit" | "die" => return,
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

fn capabilities(options: Options) -> Value {
    json!({
        "positionEncoding": if options.utf8 { "utf-8" } else { "utf-16" },
        "textDocumentSync": { "openClose": true, "change": if options.incremental { 2 } else { 1 } },
        "renameProvider": { "prepareProvider": true },
        "codeActionProvider": { "resolveProvider": true },
        "referencesProvider": true,
        "signatureHelpProvider": { "triggerCharacters": ["(", ","] },
    })
}

/// What the server does once started: asks for its settings, and reports
/// some work, begun and done, as servers report indexing.
fn initialized(output: &mut impl Write) {
    write(
        output,
        &json!({ "jsonrpc": "2.0", "id": "ask", "method": "workspace/configuration", "params": { "items": [
            { "section": "rust-analyzer.cargo" }, { "section": "nobody" }, {},
        ] } }),
    );
    write(
        output,
        &json!({ "jsonrpc": "2.0", "id": "folders", "method": "workspace/workspaceFolders" }),
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

/// Answers that are only a result: hover, definitions, completion,
/// formatting, and changing "bad" with rename, references and code actions.
/// `opened` is the document opened or changed last.
fn answer(method: &str, params: &Value, opened: &Opened) -> Option<Value> {
    let uri = params["textDocument"]["uri"].as_str().unwrap_or_default();
    let position = &params["position"];
    // Past column 10 there's nothing to say, as servers often answer: no
    // hover text, and an empty list of definitions.
    let far = position["character"].as_u64() > Some(10);
    let answer = match method {
        // As rust-analyzer: types only, unless asked for every kind.
        "workspace/symbol" => {
            let at = |line: u32| {
                json!({ "uri": "file:///project/src/main.rs", "range": {
                    "start": { "line": line, "character": 0 },
                    "end": { "line": line, "character": 1 },
                } })
            };
            let mut symbols = vec![json!({ "name": "Parser", "kind": 23, "location": at(0) })];
            if params["searchKind"] == "allSymbols" {
                symbols.push(json!({ "name": "parse_line", "kind": 12, "location": at(4) }));
                symbols.push(json!({ "name": "next", "kind": 6, "location": at(8) }));
            }
            Value::Array(symbols)
        }
        "textDocument/hover" if far => json!({ "contents": "" }),
        "textDocument/hover" => json!({
            "contents": format!("hover at {}:{}", position["line"], position["character"]),
        }),
        "textDocument/definition" if far => json!([]),
        "textDocument/definition" => json!({ "uri": uri, "range": word_range() }),
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
fn start(
    options: Options,
) -> (
    std::io::PipeWriter,
    std::io::PipeReader,
    crossbeam_channel::Receiver<String>,
) {
    let (server_in, client_out) = std::io::pipe().unwrap();
    let (client_in, server_out) = std::io::pipe().unwrap();
    let (log_tx, log) = crossbeam_channel::unbounded();
    std::thread::spawn(move || fake_server(server_in, server_out, &log_tx, options));
    (client_out, client_in, log)
}

/// The fake servers a [`launcher`] started, in order: the root each runs
/// in and the log of the methods it got.
pub type Started = std::sync::Arc<
    std::sync::Mutex<Vec<(std::path::PathBuf, crossbeam_channel::Receiver<String>)>>,
>;

/// Starts a fake server whenever the editor starts a language server.
pub fn launcher() -> (greed_core::lsp::Launcher, Started) {
    launcher_with(Options::default())
}

/// Starts a fake server that works as `options` say whenever the editor
/// starts a language server.
pub fn launcher_with(options: Options) -> (greed_core::lsp::Launcher, Started) {
    let started = Started::default();
    let list = started.clone();
    let launcher: greed_core::lsp::Launcher = Box::new(move |_, root| {
        let (input, output, log) = start(options);
        list.lock().unwrap().push((root.to_owned(), log));
        Ok(Some(greed_core::rpc::Transport::pipes(input, output)))
    });
    (launcher, started)
}

/// Has `host` start fake servers for Rust files.
#[allow(dead_code)]
pub fn serve_rust(host: &greed_core::luau::Host) -> Started {
    let (launcher, started) = launcher();
    host.set_lsp_launcher(launcher);
    // In any folder: these test talking to servers, not trusting projects.
    host.eval(
        "local lsp = require('@greed').lsp\nlsp.trust(nil)\nlsp.server({ language = 'rust', command = { 'sh' }, root_markers = { 'Cargo.toml' } })",
    )
    .unwrap();
    started
}

/// A Rust server, started by a [`launcher`], in the folder with
/// `Cargo.toml`. Its command is `sh`, so it counts as installed.
#[allow(dead_code)]
pub fn rust_server() -> greed_core::lsp::ServerConfig {
    greed_core::lsp::ServerConfig {
        language: "rust".into(),
        commands: vec![vec!["sh".into()]],
        root_markers: vec!["Cargo.toml".into()],
        ..Default::default()
    }
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
