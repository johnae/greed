use std::net::TcpStream;
use std::path::PathBuf;
use std::time::Duration;

use greed_core::Editor;
use greed_core::control;
use greed_core::luau::Host;
use greed_core::server::{self, Connection, Input};
use greed_text::ClientId;
use serde_json::{Value, json};
use tungstenite::client::IntoClientRequest;
use tungstenite::{Message, WebSocket, stream::MaybeTlsStream};

mod sessions;

/// Starts the IDE connection with the lock file in `dir`, echoes requests
/// back with the client they came from, and sends a notification on
/// "poke".
const PLUGIN: &str = r#"
local greed = require("@greed")
greed.control.serve_ide({ "/project" }, LOCK_DIR)
greed.on("control.request", function(req)
  if req.method == "poke" then
    greed.control.notify("selection_changed", { text = "hi" })
  end
  greed.control.reply(req.id, { client = req.client, method = req.method })
end)
"#;

fn start(label: &str) -> (Connection, PathBuf) {
    sessions::private();
    let name = format!("ide-{label}-{}", std::process::id());
    let dir = std::env::temp_dir().join(format!("greed-{name}"));
    let session = control::listen(&name, None).unwrap();
    let requests = session.sender().clone();
    let plugin = PLUGIN.replace("LOCK_DIR", &format!("{:?}", dir.to_str().unwrap()));
    let conn = server::spawn_with_session(
        move || {
            let mut editor = Editor::new(ClientId(1));
            editor.open("file", "", None);
            let host = Host::new(editor)?;
            host.set_request_sender(requests);
            host.load_str("ide", &plugin)?;
            Ok(host)
        },
        Some(session),
    );
    (conn, dir)
}

/// The lock file Claude Code would find, once the editor has written it.
/// Only `.lock` files count, as for Claude Code: the editor writes one
/// through a temporary file beside it.
fn lock(dir: &PathBuf) -> (u16, Value) {
    for _ in 0..100 {
        let found = std::fs::read_dir(dir).ok().and_then(|entries| {
            entries
                .flatten()
                .map(|entry| entry.path())
                .find(|path| path.extension().is_some_and(|ext| ext == "lock"))
        });
        if let Some(path) = found {
            let port = path.file_stem().unwrap().to_str().unwrap().parse().unwrap();
            let lock = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
            return (port, lock);
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("no lock file in {}", dir.display());
}

fn connect(port: u16, token: &str) -> tungstenite::Result<WebSocket<MaybeTlsStream<TcpStream>>> {
    let mut request = format!("ws://127.0.0.1:{port}").into_client_request()?;
    request
        .headers_mut()
        .insert("x-claude-code-ide-authorization", token.parse().unwrap());
    Ok(tungstenite::connect(request)?.0)
}

fn next(socket: &mut WebSocket<MaybeTlsStream<TcpStream>>) -> Value {
    loop {
        if let Message::Text(text) = socket.read().unwrap() {
            return serde_json::from_str(&text).unwrap();
        }
    }
}

#[test]
fn claude_code_finds_the_editor_and_talks_mcp_over_a_websocket() {
    let (conn, dir) = start("talk");
    let (port, lock) = lock(&dir);
    assert_eq!(lock["ideName"], "Greed");
    assert_eq!(lock["transport"], "ws");
    assert_eq!(lock["workspaceFolders"], json!(["/project"]));
    assert_eq!(lock["pid"], std::process::id());
    let token = lock["authToken"].as_str().unwrap().to_owned();
    assert!(connect(port, "wrong").is_err(), "the token is checked");

    // Claude Code asks for the "mcp" subprotocol, and gives up on a server
    // that doesn't agree to it.
    let mut request = format!("ws://127.0.0.1:{port}")
        .into_client_request()
        .unwrap();
    let headers = request.headers_mut();
    headers.insert("x-claude-code-ide-authorization", token.parse().unwrap());
    headers.insert("sec-websocket-protocol", "mcp".parse().unwrap());
    let (_, response) = tungstenite::connect(request).unwrap();
    assert_eq!(response.headers()["sec-websocket-protocol"], "mcp");

    let mut socket = connect(port, &token).unwrap();
    let request = json!({ "jsonrpc": "2.0", "id": 7, "method": "tools/list", "params": {} });
    socket.send(Message::text(request.to_string())).unwrap();
    assert_eq!(
        next(&mut socket),
        json!({ "jsonrpc": "2.0", "id": 7, "result": { "client": "ide", "method": "tools/list" } })
    );
    let poke = json!({ "jsonrpc": "2.0", "id": 8, "method": "poke" });
    socket.send(Message::text(poke.to_string())).unwrap();
    let (first, second) = (next(&mut socket), next(&mut socket));
    let notification = if first.get("id").is_none() {
        first
    } else {
        second
    };
    assert_eq!(notification["method"], "selection_changed");
    assert_eq!(notification["params"]["text"], "hi");

    conn.input.send(Input::Quit).unwrap();
    conn.server.join().unwrap().unwrap();
    assert_eq!(
        std::fs::read_dir(&dir).unwrap().count(),
        0,
        "the lock file goes when the editor stops"
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

/// The default plugins with the agent's IDE tools, the lock file in a
/// temporary directory, and `file` open.
fn start_agent(label: &str, file: &std::path::Path) -> (Connection, PathBuf) {
    sessions::private();
    let name = format!("ide-{label}-{}", std::process::id());
    let dir = std::env::temp_dir().join(format!("greed-{name}"));
    let session = control::listen(&name, None).unwrap();
    let requests = session.sender().clone();
    let plugins = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../runtime/plugins");
    let start = format!(
        "require('@greed').control.serve_ide({{ '/project' }}, {:?})",
        dir.to_str().unwrap()
    );
    let file = file.to_owned();
    let conn = server::spawn_with_session(
        move || {
            let mut editor = Editor::new(ClientId(1));
            editor.open("file", &std::fs::read_to_string(&file).unwrap(), Some(file));
            let host = Host::new(editor)?;
            host.load_dirs(&[
                plugins.join("core"),
                plugins.join("picker"),
                plugins.join("terminal"),
                plugins.join("multibuffer"),
                plugins.join("operations"),
                plugins.join("approvals"),
                plugins.join("describe"),
                plugins.join("markdown"),
                plugins.join("models"),
                plugins.join("agent"),
            ])?;
            // Only now, so the agent plugin's own start (into ~/.claude/ide)
            // finds no session and this test's start is the one that counts.
            host.set_request_sender(requests);
            host.load_str("start", &start)?;
            Ok(host)
        },
        Some(session),
    );
    (conn, dir)
}

/// The response to request `id`, skipping notifications.
fn response(socket: &mut WebSocket<MaybeTlsStream<TcpStream>>, id: u64) -> Value {
    loop {
        let message = next(socket);
        if message["id"] == id {
            return message;
        }
    }
}

fn call(socket: &mut WebSocket<MaybeTlsStream<TcpStream>>, id: u64, tool: &str, arguments: &Value) {
    let request = json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/call",
        "params": { "name": tool, "arguments": arguments },
    });
    socket.send(Message::text(request.to_string())).unwrap();
}

#[test]
fn claude_codes_diffs_become_proposals_and_come_back_saved() {
    let work = std::env::temp_dir().join(format!("greed-ide-work-{}", std::process::id()));
    std::fs::create_dir_all(&work).unwrap();
    let file = work.join("a.txt");
    std::fs::write(&file, "one\ntwo\nthree\n").unwrap();
    let (conn, dir) = start_agent("diff", &file);
    let (port, lock) = lock(&dir);
    let mut socket = connect(port, lock["authToken"].as_str().unwrap()).unwrap();

    let list = json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list" });
    socket.send(Message::text(list.to_string())).unwrap();
    let tools = response(&mut socket, 1);
    let names: Vec<&str> = tools["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    assert!(
        names.contains(&"openDiff") && names.contains(&"getDiagnostics"),
        "{names:?}"
    );
    assert!(
        !names.contains(&"propose"),
        "the IDE gets its own tools: {names:?}"
    );

    let path = file.to_str().unwrap();
    call(
        &mut socket,
        2,
        "openDiff",
        &json!({
            "old_file_path": path,
            "new_file_path": path,
            "new_file_contents": "one\nTWO\nthree\n",
            "tab_name": "edit a.txt",
        }),
    );
    wait_for_proposal("diff");
    for key in greed_core::keymap::Key::parse_sequence("space o A").unwrap() {
        conn.input.send(Input::Key(key)).unwrap();
    }
    let saved = response(&mut socket, 2);
    let content = &saved["result"]["content"];
    assert_eq!(content[0]["text"], "FILE_SAVED", "{saved}");
    assert_eq!(content[1]["text"], "one\nTWO\nthree\n");
    assert_eq!(std::fs::read_to_string(&file).unwrap(), "one\nTWO\nthree\n");

    call(
        &mut socket,
        3,
        "checkDocumentDirty",
        &json!({ "filePath": path }),
    );
    let dirty: Value = serde_json::from_str(
        response(&mut socket, 3)["result"]["content"][0]["text"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(dirty["isDirty"], false, "saved after accepting");

    conn.input.send(Input::Quit).unwrap();
    conn.server.join().unwrap().unwrap();
    std::fs::remove_dir_all(&dir).unwrap();
    std::fs::remove_dir_all(&work).unwrap();
}

/// The next notification called `method`, skipping others.
fn notification(socket: &mut WebSocket<MaybeTlsStream<TcpStream>>, method: &str) -> Value {
    loop {
        let message = next(socket);
        if message["method"] == method {
            return message["params"].clone();
        }
    }
}

#[test]
fn mentioning_whole_lines_names_just_those_lines() {
    let work = std::env::temp_dir().join(format!("greed-ide-mention-work-{}", std::process::id()));
    std::fs::create_dir_all(&work).unwrap();
    let file = work.join("a.txt");
    std::fs::write(&file, "one\ntwo\nthree\n").unwrap();
    let (conn, dir) = start_agent("mention", &file);
    let (port, lock) = lock(&dir);
    let mut socket = connect(port, lock["authToken"].as_str().unwrap()).unwrap();

    let press = |keys: &str| {
        for key in greed_core::keymap::Key::parse_sequence(keys).unwrap() {
            conn.input.send(Input::Key(key)).unwrap();
        }
    };
    press("j x space o m");
    let one = notification(&mut socket, "at_mentioned");
    assert_eq!(
        (&one["lineStart"], &one["lineEnd"]),
        (&json!(1), &json!(1)),
        "{one}"
    );
    press("x space o m");
    let two = notification(&mut socket, "at_mentioned");
    assert_eq!(
        (&two["lineStart"], &two["lineEnd"]),
        (&json!(1), &json!(2)),
        "{two}"
    );
    assert_eq!(two["filePath"], file.to_str().unwrap());

    conn.input.send(Input::Quit).unwrap();
    conn.server.join().unwrap().unwrap();
    std::fs::remove_dir_all(&dir).unwrap();
    std::fs::remove_dir_all(&work).unwrap();
}

#[test]
fn claude_code_hears_the_selection_whatever_moved_it() {
    let work = std::env::temp_dir().join(format!("greed-ide-select-work-{}", std::process::id()));
    std::fs::create_dir_all(&work).unwrap();
    let file = work.join("a.txt");
    std::fs::write(&file, "one\ntwo\nthree\n").unwrap();
    let (conn, dir) = start_agent("select", &file);
    let (port, lock) = lock(&dir);
    let mut socket = connect(port, lock["authToken"].as_str().unwrap()).unwrap();
    if let MaybeTlsStream::Plain(stream) = socket.get_ref() {
        stream
            .set_read_timeout(Some(Duration::from_secs(10)))
            .unwrap();
    }
    let mut selected = |text: &str| loop {
        let params = notification(&mut socket, "selection_changed");
        if params["text"] == text {
            return params;
        }
    };

    for key in greed_core::keymap::Key::parse_sequence("j x").unwrap() {
        conn.input.send(Input::Key(key)).unwrap();
    }
    let keys = selected("two\n");
    assert_eq!(keys["selection"]["start"]["line"], 1, "{keys}");
    assert_eq!(keys["filePath"], file.to_str().unwrap());

    // An agent moving it, with no key pressed.
    let name = format!("ide-select-{}", std::process::id());
    let (session, token) = control::session_files(&name);
    let token = std::fs::read_to_string(token).unwrap();
    let mut client = control::Client::connect_as(&session, &token, true).unwrap();
    let set = json!({
        "name": "eval",
        "arguments": {
            "code": "require('@greed').view():set_selection({ ranges = { { anchor = 0, head = 3 } } })",
        },
    });
    let answer = client.call("tools/call", &set).unwrap().unwrap();
    assert_eq!(answer["isError"], false, "{answer}");
    let agent = selected("one");
    assert_eq!(agent["selection"]["start"]["line"], 0, "{agent}");

    conn.input.send(Input::Quit).unwrap();
    conn.server.join().unwrap().unwrap();
    std::fs::remove_dir_all(&dir).unwrap();
    std::fs::remove_dir_all(&work).unwrap();
}

/// Waits until the editor started by `start_agent(label, ..)` has a proposal
/// waiting for the user, asking over its session socket.
fn wait_for_proposal(label: &str) {
    let name = format!("ide-{label}-{}", std::process::id());
    let (socket, token) = control::session_files(&name);
    let token = std::fs::read_to_string(token).unwrap();
    let mut client = control::Client::connect_as(&socket, &token, true).unwrap();
    let ask = json!({
        "name": "eval",
        "arguments": { "code": "return require('@agent').pending()" },
    });
    for _ in 0..250 {
        let answer = client.call("tools/call", &ask).unwrap().unwrap();
        assert_eq!(answer["isError"], false, "{answer}");
        if answer["content"][0]["text"] != "0" {
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("no proposal showed up");
}

#[test]
fn a_rejected_diff_leaves_the_file_alone_and_says_so() {
    let work = std::env::temp_dir().join(format!("greed-ide-reject-work-{}", std::process::id()));
    std::fs::create_dir_all(&work).unwrap();
    let file = work.join("a.txt");
    std::fs::write(&file, "one\ntwo\n").unwrap();
    let (conn, dir) = start_agent("reject", &file);
    let (port, lock) = lock(&dir);
    let mut socket = connect(port, lock["authToken"].as_str().unwrap()).unwrap();
    let path = file.to_str().unwrap();
    call(
        &mut socket,
        1,
        "openDiff",
        &json!({
            "old_file_path": path,
            "new_file_path": path,
            "new_file_contents": "one\nTWO\nthree\n",
            "tab_name": "edit a.txt",
        }),
    );
    wait_for_proposal("reject");
    for key in greed_core::keymap::Key::parse_sequence("space o R").unwrap() {
        conn.input.send(Input::Key(key)).unwrap();
    }
    let answer = response(&mut socket, 1);
    let content = &answer["result"]["content"];
    assert_eq!(content[0]["text"], "DIFF_REJECTED", "{answer}");
    assert_eq!(std::fs::read_to_string(&file).unwrap(), "one\ntwo\n");

    conn.input.send(Input::Quit).unwrap();
    conn.server.join().unwrap().unwrap();
    std::fs::remove_dir_all(&dir).unwrap();
    std::fs::remove_dir_all(&work).unwrap();
}
