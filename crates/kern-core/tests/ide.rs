use std::net::TcpStream;
use std::path::PathBuf;
use std::time::Duration;

use kern_core::Editor;
use kern_core::control;
use kern_core::luau::Host;
use kern_core::server::{self, Connection, Input};
use kern_text::ClientId;
use serde_json::{Value, json};
use tungstenite::client::IntoClientRequest;
use tungstenite::{Message, WebSocket, stream::MaybeTlsStream};

/// Starts the IDE connection with the lock file in `dir`, echoes requests
/// back with the client they came from, and sends a notification on
/// "poke".
const PLUGIN: &str = r#"
local kern = require("@kern")
kern.control.serve_ide({ "/project" }, LOCK_DIR)
kern.on("control.request", function(req)
  if req.method == "poke" then
    kern.control.notify("selection_changed", { text = "hi" })
  end
  kern.control.reply(req.id, { client = req.client, method = req.method })
end)
"#;

fn start(label: &str) -> (Connection, PathBuf) {
    let name = format!("ide-{label}-{}", std::process::id());
    let dir = std::env::temp_dir().join(format!("kern-{name}"));
    let session = control::listen(&name).unwrap();
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
fn lock(dir: &PathBuf) -> (u16, Value) {
    for _ in 0..100 {
        if let Some(entry) = std::fs::read_dir(dir).ok().and_then(|mut d| d.next()) {
            let path = entry.unwrap().path();
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
    assert_eq!(lock["ideName"], "Kern");
    assert_eq!(lock["transport"], "ws");
    assert_eq!(lock["workspaceFolders"], json!(["/project"]));
    assert_eq!(lock["pid"], std::process::id());
    let token = lock["authToken"].as_str().unwrap().to_owned();
    assert!(connect(port, "wrong").is_err(), "the token is checked");

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
