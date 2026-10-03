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
local kern = require("@kern")
kern.on("control.request", function(req)
  if req.method == "echo" then
    kern.control.reply(req.id, { got = req.params, text = kern.view():buffer():text() })
  elseif req.method == "later" then
    kern.sleep(10)
    kern.control.reply(req.id, "done")
  else
    kern.control.reply(req.id, nil, "unknown method " .. req.method)
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
