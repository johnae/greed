use greed_core::Editor;
use greed_core::control::{self, Client};
use greed_core::luau::Host;
use greed_core::server::{self, Connection, Input};
use greed_text::ClientId;
use serde_json::json;

/// A server answering requests on a session socket with `plugin`.
fn start(name: &str, plugin: &'static str) -> (Connection, std::path::PathBuf, String) {
    let session = control::listen(name, None).unwrap();
    let socket = session.socket.clone();
    let (_, token_file) = control::session_files(name);
    let token = std::fs::read_to_string(token_file).unwrap();
    let conn = server::spawn_with_session(
        move || {
            let mut editor = Editor::new(ClientId(1));
            editor.open("file", "hello", None);
            let host = Host::new(editor)?;
            if !plugin.is_empty() {
                host.load_str("answers", plugin)?;
            }
            Ok(host)
        },
        Some(session),
    );
    (conn, socket, token)
}

const ECHO: &str = r#"
local greed = require("@greed")
greed.on("control.request", function(req)
  if req.method == "echo" then
    greed.control.reply(req.id, { got = req.params, text = greed.view():buffer():text() })
  elseif req.method == "who" then
    greed.control.reply(req.id, req.client)
  elseif req.method == "later" then
    greed.sleep(10)
    greed.control.reply(req.id, "done")
  else
    greed.control.reply(req.id, nil, "unknown method " .. req.method)
  end
end)
"#;

fn name(test: &str) -> String {
    format!("test-{test}-{}", std::process::id())
}

#[test]
fn plugins_answer_requests_from_the_session_socket() {
    let (conn, socket, token) = start(&name("echo"), ECHO);
    let mut client = Client::connect(&socket, &token).unwrap();
    assert_eq!(
        client.call("echo", &json!({ "n": 1 })).unwrap(),
        Ok(json!({ "got": { "n": 1 }, "text": "hello" }))
    );
    assert_eq!(
        client.call("later", &json!(null)).unwrap(),
        Ok(json!("done"))
    );
    assert_eq!(
        client.call("nope", &json!(null)).unwrap(),
        Err("unknown method nope".to_owned())
    );
    conn.input.send(Input::Quit).unwrap();
    conn.server.join().unwrap().unwrap();
    assert!(!socket.exists(), "the socket goes when the editor stops");
}

#[test]
fn connections_need_the_sessions_token() {
    let (conn, socket, _) = start(&name("token"), ECHO);
    let err = Client::connect(&socket, "wrong").err().unwrap();
    assert!(err.to_string().contains("wrong token"), "{err}");
    conn.input.send(Input::Quit).unwrap();
}

#[test]
fn requests_fail_clearly_when_no_plugin_answers() {
    let (conn, socket, token) = start(&name("unanswered"), "");
    let mut client = Client::connect(&socket, &token).unwrap();
    let answer = client.call("echo", &json!(null)).unwrap();
    assert!(answer.unwrap_err().contains("no plugin answers"));
    conn.input.send(Input::Quit).unwrap();
}

#[test]
fn starting_a_session_clears_what_crashed_ones_left() {
    let stale = name("stale");
    let (socket, token) = control::session_files(&stale);
    std::fs::create_dir_all(control::sessions_dir()).unwrap();
    // A socket nothing listens on any more, as a crash leaves it.
    drop(std::os::unix::net::UnixListener::bind(&socket).unwrap());
    std::fs::write(&token, "x").unwrap();
    let session = control::listen(&name("fresh"), None).unwrap();
    assert!(!socket.exists() && !token.exists());
    drop(session);
}

#[test]
fn a_session_name_too_long_for_a_socket_is_refused_clearly() {
    let name = "x".repeat(200);
    let err = control::listen(&name, None).err().expect("refused");
    assert!(err.to_string().contains("too long"), "{err}");
}

#[test]
fn a_session_says_which_project_it_is_for_as_soon_as_it_listens() {
    let name = format!("described-{}", std::process::id());
    let root = std::path::Path::new("/some/project");
    let session = control::listen(&name, Some(root)).unwrap();
    let found = control::sessions().unwrap();
    let info = found.iter().find(|s| s.name == name).expect("listed");
    assert_eq!(info.root.as_deref(), Some(root));
    drop(session);
    assert!(
        !control::sessions().unwrap().iter().any(|s| s.name == name),
        "gone with the session"
    );
}

#[test]
fn greed_ctls_connections_are_a_shells_and_nothing_else_can_become_one() {
    let (conn, socket, token) = start(&name("shell"), ECHO);
    let mut shell = Client::connect_as(&socket, &token, true).unwrap();
    assert_eq!(shell.call("who", &json!(null)).unwrap(), Ok(json!("shell")));
    // A plain connection, like greed mcp's, stays one even if what comes
    // through it says otherwise later.
    let mut plain = Client::connect(&socket, &token).unwrap();
    assert_eq!(
        plain.call("who", &json!(null)).unwrap(),
        Ok(json!("socket"))
    );
    plain
        .call("auth", &json!({ "token": token, "shell": true }))
        .unwrap()
        .unwrap();
    assert_eq!(
        plain.call("who", &json!(null)).unwrap(),
        Ok(json!("socket"))
    );
    conn.input.send(Input::Quit).unwrap();
    conn.server.join().unwrap().unwrap();
}

const NOTIFY: &str = r#"
local greed = require("@greed")
local last
greed.on("control.request", function(req)
  if req.method == "tell" then
    last = req.connection
    local sent = greed.control.send(req.connection, "notifications/tools/list_changed", { n = 1 })
    greed.control.reply(req.id, sent)
  elseif req.method == "tell-last" then
    greed.control.reply(req.id, greed.control.send(last, "notifications/hello", nil))
  end
end)
"#;

#[test]
fn plugins_send_notifications_to_the_connection_a_request_came_on() {
    let (conn, socket, token) = start(&name("notify"), NOTIFY);
    let mut client = Client::connect(&socket, &token).unwrap();
    assert_eq!(client.call("tell", &json!(null)).unwrap(), Ok(json!(true)));
    assert_eq!(
        client.take_notifications(),
        [
            json!({ "jsonrpc": "2.0", "method": "notifications/tools/list_changed", "params": { "n": 1 } })
        ],
        "it came before the answer, and the answer still came"
    );
    // Once that connection is gone, sending to it says so.
    drop(client);
    let mut other = Client::connect(&socket, &token).unwrap();
    let mut gone = Ok(json!(true));
    for _ in 0..50 {
        gone = other.call("tell-last", &json!(null)).unwrap();
        if gone == Ok(json!(false)) {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert_eq!(gone, Ok(json!(false)));
    assert!(
        other.take_notifications().is_empty(),
        "nothing went to another connection"
    );
    conn.input.send(Input::Quit).unwrap();
    conn.server.join().unwrap().unwrap();
}
