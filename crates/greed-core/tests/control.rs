use greed_core::Editor;
use greed_core::control::{self, Client};
use greed_core::luau::Host;
use greed_core::server::{self, Connection, Input};
use greed_text::ClientId;
use serde_json::json;

mod sessions;

/// A server answering requests on a session socket with `plugin`.
fn start(name: &str, plugin: &'static str) -> (Connection, std::path::PathBuf, String) {
    sessions::private();
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
    sessions::private();
    let stale = name("stale");
    let (socket, token) = control::session_files(&stale);
    std::fs::create_dir_all(control::sessions_dir()).unwrap();
    // A socket nothing listens on any more, as a crash leaves it. The token
    // goes first: another test's session starting may clear the socket as
    // soon as it's there.
    std::fs::write(&token, "x").unwrap();
    drop(std::os::unix::net::UnixListener::bind(&socket).unwrap());
    let session = control::listen(&name("fresh"), None).unwrap();
    assert!(!socket.exists() && !token.exists());
    drop(session);
}

#[test]
fn a_second_session_with_a_running_ones_name_is_refused() {
    sessions::private();
    let name = name("twice");
    let first = control::listen(&name, None).unwrap();
    let (_, token_file) = control::session_files(&name);
    let token = std::fs::read_to_string(&token_file).unwrap();
    assert_eq!(token.len(), 32, "the token is there once it listens");
    let err = control::listen(&name, None).err().expect("refused");
    assert!(err.to_string().contains("already running"), "{err}");
    assert!(
        std::os::unix::net::UnixStream::connect(&first.socket).is_ok(),
        "the first one still answers"
    );
    assert_eq!(
        std::fs::read_to_string(&token_file).unwrap(),
        token,
        "and its token is untouched"
    );
}

#[test]
fn a_session_name_too_long_for_a_socket_is_refused_clearly() {
    sessions::private();
    let name = "x".repeat(200);
    let err = control::listen(&name, None).err().expect("refused");
    assert!(err.to_string().contains("too long"), "{err}");
}

#[test]
fn a_session_says_which_project_it_is_for_as_soon_as_it_listens() {
    sessions::private();
    let name = format!("described-{}", std::process::id());
    let root = std::path::Path::new("/some/project");
    let session = control::listen(&name, Some(root)).unwrap();
    assert!(
        session.socket.starts_with(control::socket_temp_dir()),
        "a test's sessions stay out of the user's folder: {}",
        session.socket.display()
    );
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
    // Nor after a wrong token, which leaves it unauthed for a moment.
    plain
        .call("auth", &json!({ "token": "wrong" }))
        .unwrap()
        .unwrap_err();
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

const CLOSED: &str = r#"
local greed = require("@greed")
local waiting, closed = {}, {}
greed.on("control.request", function(req)
  if req.method == "me" then
    greed.control.reply(req.id, req.connection)
  elseif req.method == "waiting" then
    greed.control.reply(req.id, waiting)
  elseif req.method == "closed" then
    greed.control.reply(req.id, closed)
  elseif req.method == "wait" then
    -- No answer, like a proposal nobody has decided on.
    table.insert(waiting, req.connection)
  end
end)
greed.on("control.closed", function(event)
  table.insert(closed, event.connection)
end)
"#;

/// The connections the plugin lists for `method`, asked through `client`
/// until `id` is among them.
fn listed(client: &mut Client, method: &str, id: &serde_json::Value) -> Vec<serde_json::Value> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        let ids = client
            .call(method, &json!(null))
            .unwrap()
            .unwrap()
            .as_array()
            .cloned()
            .unwrap_or_default();
        if ids.contains(id) {
            return ids;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "{id} not {method}: {ids:?}"
        );
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

#[test]
fn plugins_hear_when_a_connection_closes_even_with_a_request_waiting() {
    use std::io::{BufRead, BufReader, Write};
    let (conn, socket, token) = start(&name("closed"), CLOSED);
    let mut watcher = Client::connect(&socket, &token).unwrap();

    let mut idle = Client::connect(&socket, &token).unwrap();
    let idle_id = idle.call("me", &json!(null)).unwrap().unwrap();
    drop(idle);
    listed(&mut watcher, "closed", &idle_id);

    // One that goes while the editor still owes it an answer.
    let mut waiting = std::os::unix::net::UnixStream::connect(&socket).unwrap();
    let mut answers = BufReader::new(waiting.try_clone().unwrap());
    let mut line = String::new();
    for (id, method, params) in [
        (1, "auth", json!({ "token": token })),
        (2, "me", json!(null)),
    ] {
        let request = json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params });
        writeln!(waiting, "{request}").unwrap();
        line.clear();
        answers.read_line(&mut line).unwrap();
    }
    let waiting_id = serde_json::from_str::<serde_json::Value>(&line).unwrap()["result"].clone();
    writeln!(
        waiting,
        "{}",
        json!({ "jsonrpc": "2.0", "id": 3, "method": "wait", "params": null })
    )
    .unwrap();
    listed(&mut watcher, "waiting", &waiting_id);
    drop(answers);
    drop(waiting);
    let closed = listed(&mut watcher, "closed", &waiting_id);
    assert!(
        !closed.contains(&watcher.call("me", &json!(null)).unwrap().unwrap()),
        "one still open isn't closed"
    );
    conn.input.send(Input::Quit).unwrap();
    conn.server.join().unwrap().unwrap();
}

#[test]
fn a_line_too_long_ends_its_connection_and_the_session_goes_on() {
    use std::io::{Read, Write};
    let (conn, socket, token) = start(&name("long"), ECHO);
    let mut stream = std::os::unix::net::UnixStream::connect(&socket).unwrap();
    // Before it says the token, with no line break: more than a session reads.
    let chunk = vec![b'x'; 1 << 20];
    let limit = usize::try_from(control::LINE_LIMIT).unwrap();
    let mut sent = 0;
    while sent <= limit {
        if stream.write_all(&chunk).is_err() {
            break;
        }
        sent += chunk.len();
    }
    // macOS refuses this once the session has closed its end, which is what
    // the test is after.
    let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(10)));
    // Closed (or reset) without an answer.
    let mut rest = Vec::new();
    let _ = stream.read_to_end(&mut rest);
    assert!(rest.is_empty(), "{}", String::from_utf8_lossy(&rest));
    let mut client = Client::connect(&socket, &token).unwrap();
    assert!(client.call("echo", &json!(1)).unwrap().is_ok());
    conn.input.send(Input::Quit).unwrap();
}

#[test]
fn a_sessions_folder_others_can_write_in_or_a_link_is_refused() {
    use std::os::unix::fs::PermissionsExt;
    let base = std::env::temp_dir().join(format!("greed-sessions-dir-{}", std::process::id()));
    let ours = base.join("ours");
    std::fs::create_dir_all(&ours).unwrap();
    std::fs::set_permissions(&ours, std::fs::Permissions::from_mode(0o700)).unwrap();
    control::check_sessions_dir(&ours).unwrap();
    let open = base.join("open");
    std::fs::create_dir_all(&open).unwrap();
    std::fs::set_permissions(&open, std::fs::Permissions::from_mode(0o777)).unwrap();
    assert!(
        control::check_sessions_dir(&open).is_err(),
        "anyone can write in it"
    );
    let link = base.join("link");
    std::os::unix::fs::symlink(&ours, &link).unwrap();
    assert!(control::check_sessions_dir(&link).is_err(), "a link");
    std::fs::remove_dir_all(&base).unwrap();
}

#[test]
fn a_sessions_folder_is_made_closed_to_others_and_one_left_open_is_closed() {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    let base = std::env::temp_dir().join(format!("greed-make-sessions-{}", std::process::id()));
    let mode = |dir: &std::path::Path| std::fs::metadata(dir).unwrap().mode() & 0o777;
    let new = base.join("new/run");
    control::make_sessions_dir(&new).unwrap();
    assert_eq!(mode(&new), 0o700);
    // As greed 0.3.0 left it under a umask of 002, as Ubuntu's is.
    let left = base.join("left");
    std::fs::create_dir_all(&left).unwrap();
    std::fs::set_permissions(&left, std::fs::Permissions::from_mode(0o775)).unwrap();
    control::make_sessions_dir(&left).unwrap();
    assert_eq!(mode(&left), 0o700, "closed again");
    let link = base.join("link");
    std::os::unix::fs::symlink(&new, &link).unwrap();
    assert!(
        control::make_sessions_dir(&link).is_err(),
        "a link stays refused"
    );
    std::fs::remove_dir_all(&base).unwrap();
}
