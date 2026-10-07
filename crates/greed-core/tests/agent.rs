use std::path::{Path, PathBuf};

use greed_core::Editor;
use greed_core::control::{self, Client};
use greed_core::luau::Host;
use greed_core::server::{self, Connection, Input};
use greed_text::{ClientId, Selection};
use serde_json::{Value, json};

mod sessions;

fn plugin(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../runtime/plugins")
        .join(name)
}

/// An editor with the agent plugin, showing `text` with "two" selected, and a
/// client connected to its session.
fn start(label: &str, text: &'static str) -> (Connection, Client) {
    sessions::private();
    let name = format!("agent-{label}-{}", std::process::id());
    let session = control::listen(&name, None).unwrap();
    let conn = server::spawn_with_session(
        move || {
            let mut editor = Editor::new(ClientId(1));
            let (_, view) = editor.open("file", text, Some("notes.md".into()));
            editor.view_mut(view).selection = Selection::single(4, 7);
            let host = Host::new(editor)?;
            host.load_dirs(&[
                plugin("core"),
                plugin("picker"),
                plugin("terminal"),
                plugin("multibuffer"),
                plugin("operations"),
                plugin("approvals"),
                plugin("describe"),
                plugin("markdown"),
                plugin("models"),
                plugin("agent"),
            ])?;
            Ok(host)
        },
        Some(session),
    );
    (conn, connect(label))
}

/// Another client connected to the session `start(label, ..)` made.
fn connect(label: &str) -> Client {
    let name = format!("agent-{label}-{}", std::process::id());
    let (socket, token_file) = control::session_files(&name);
    let token = std::fs::read_to_string(token_file).unwrap();
    Client::connect(&socket, &token).unwrap()
}

/// The text a tools/call answered with, and whether it was an error.
fn call(client: &mut Client, tool: &str, arguments: &Value) -> (String, bool) {
    let result = client
        .call(
            "tools/call",
            &json!({ "name": tool, "arguments": arguments }),
        )
        .unwrap()
        .unwrap();
    (
        result["content"][0]["text"].as_str().unwrap().to_owned(),
        result["isError"].as_bool().unwrap(),
    )
}

#[test]
fn agents_get_mcp_answers_and_the_tools_list() {
    let (conn, mut client) = start("list", "one two three");
    let init = client
        .call("initialize", &json!({ "protocolVersion": "2025-06-18" }))
        .unwrap()
        .unwrap();
    assert_eq!(init["serverInfo"]["name"], "greed");
    assert_eq!(
        init["capabilities"]["tools"],
        json!({ "listChanged": true })
    );
    assert_eq!(
        client
            .call("notifications/initialized", &Value::Null)
            .unwrap(),
        Ok(Value::Null)
    );
    let tools = client.call("tools/list", &Value::Null).unwrap().unwrap();
    let names: Vec<&str> = tools["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    for expected in ["buffers", "diagnostics", "eval", "focus", "open", "read"] {
        assert!(names.contains(&expected), "{expected} in {names:?}");
    }
    assert_eq!(tools["tools"][0]["inputSchema"]["type"], "object");
    conn.input.send(Input::Quit).unwrap();
}

#[test]
fn tools_read_the_editor_including_unsaved_text_and_selections() {
    let (conn, mut client) = start("tools", "one two three\nfour");
    let (focus, _) = call(&mut client, "focus", &json!({}));
    let focus: Value = serde_json::from_str(&focus).unwrap();
    // Buffers know their files by full path, however they were opened.
    let full = std::env::current_dir().unwrap().join("notes.md");
    assert_eq!(focus["path"], full.to_str().unwrap());
    assert_eq!(focus["selections"][0]["text"], "two");
    assert_eq!(
        focus["selections"][0]["from"],
        json!({ "line": 1, "column": 5 })
    );

    assert_eq!(
        call(&mut client, "read", &json!({})).0,
        "one two three\nfour"
    );
    assert_eq!(
        call(
            &mut client,
            "read",
            &json!({ "path": "notes.md", "from_line": 2 })
        )
        .0,
        "four"
    );
    assert_eq!(
        call(&mut client, "eval", &json!({ "code": "return 1 + 1" })).0,
        "2"
    );
    let (message, is_error) = call(&mut client, "nope", &json!({}));
    assert!(
        is_error && message.contains("no tool called nope"),
        "{message}"
    );
    conn.input.send(Input::Quit).unwrap();
}

/// What a bridge wrote, shared with the thread that writes it.
#[derive(Clone, Default)]
struct Written(std::sync::Arc<std::sync::Mutex<Vec<u8>>>);

impl std::io::Write for Written {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[test]
fn a_bridge_passes_lines_through_and_notifications_get_no_answer() {
    let (conn, client) = start("pipe", "text");
    let input = [
        r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
        r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read","arguments":{}}}"#,
    ]
    .join("\n");
    let written = Written::default();
    client
        .pipe(std::io::Cursor::new(input.into_bytes()), written.clone())
        .unwrap();
    let output = String::from_utf8(written.0.lock().unwrap().clone()).unwrap();
    let answers: Vec<Value> = output
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(answers.len(), 2, "{output}");
    assert_eq!(answers[0]["id"], 1);
    assert_eq!(answers[1]["result"]["content"][0]["text"], "text");
    conn.input.send(Input::Quit).unwrap();
}

#[test]
fn a_proposal_waits_for_the_user_and_tells_the_agent_what_happened() {
    let dir = std::env::temp_dir().join(format!("greed-propose-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("a.txt");
    std::fs::write(&file, "let x = 1;\n").unwrap();
    let (conn, mut client) = start("propose", "");
    let path = file.to_str().unwrap().to_owned();
    call(&mut client, "open", &json!({ "path": path }));

    let agent = std::thread::spawn(move || {
        let edits = json!([{ "old_text": "1", "new_text": "2" }]);
        call(
            &mut client,
            "propose",
            &json!({ "path": path, "edits": edits }),
        )
    });
    // Once the proposal shows, accept everything in the file. The agent's
    // client is waiting for the answer, so another one looks.
    wait_for_proposal(&mut connect("propose"), 8, true);
    for key in greed_core::keymap::Key::parse_sequence("space o A").unwrap() {
        conn.input.send(Input::Key(key)).unwrap();
    }
    let (answer, is_error) = agent.join().unwrap();
    assert!(!is_error, "{answer}");
    assert!(answer.starts_with("accepted 1 of 1 changes"), "{answer}");
    conn.input.send(Input::Quit).unwrap();
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_proposal_from_a_connection_that_closes_is_withdrawn() {
    use std::io::{BufRead, Write};
    let dir = std::env::temp_dir().join(format!("greed-dropped-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("a.txt");
    std::fs::write(&file, "let x = 1;\n").unwrap();
    let (conn, mut client) = start("dropped", "");
    let path = file.to_str().unwrap().to_owned();
    call(&mut client, "open", &json!({ "path": path }));

    // An agent proposes a change, then goes away without waiting for it.
    let name = format!("agent-dropped-{}", std::process::id());
    let (socket, token_file) = control::session_files(&name);
    let token = std::fs::read_to_string(token_file).unwrap();
    let mut agent = std::os::unix::net::UnixStream::connect(socket).unwrap();
    let mut answers = std::io::BufReader::new(agent.try_clone().unwrap());
    writeln!(
        agent,
        "{}",
        json!({ "jsonrpc": "2.0", "id": 1, "method": "auth", "params": { "token": token } })
    )
    .unwrap();
    answers.read_line(&mut String::new()).unwrap();
    let edits = json!([{ "old_text": "1", "new_text": "2" }]);
    let propose = json!({ "name": "propose", "arguments": { "path": path, "edits": edits } });
    writeln!(
        agent,
        "{}",
        json!({ "jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": propose })
    )
    .unwrap();
    // Wait for the proposal, go, and wait for the editor to withdraw it.
    // Accepting everything in the file then finds nothing to accept.
    wait_for_proposal(&mut client, 8, true);
    drop(answers);
    drop(agent);
    wait_for_proposal(&mut client, 8, false);
    for key in greed_core::keymap::Key::parse_sequence("space o A").unwrap() {
        conn.input.send(Input::Key(key)).unwrap();
    }
    assert_eq!(
        call(&mut client, "read", &json!({ "path": path })).0,
        "let x = 1;\n"
    );
    conn.input.send(Input::Quit).unwrap();
    std::fs::remove_dir_all(&dir).unwrap();
}

/// Waits until the focused buffer does or doesn't show a proposed change at
/// `pos`.
fn wait_for_proposal(client: &mut Client, pos: usize, shown: bool) {
    let code = format!(
        "for _, mark in require(\"@greed\").view():buffer():marks_at({pos}) do \
         if string.find(mark.ns, \"^proposal%-\") then return true end end \
         return false"
    );
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        let answer = call(client, "eval", &json!({ "code": code })).0;
        if answer == shown.to_string() {
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "proposal shown: {answer}"
        );
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

fn tool_names(client: &mut Client) -> Vec<String> {
    let tools = client.call("tools/list", &Value::Null).unwrap().unwrap();
    tools["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn an_agent_switches_on_a_group_of_tools_and_hears_its_list_changed() {
    let (conn, mut client) = start("groups", "one two three");
    let names = tool_names(&mut client);
    assert!(names.contains(&"tools".to_owned()), "{names:?}");
    assert!(!names.contains(&"history_recent".to_owned()), "{names:?}");
    let (listing, _) = call(&mut client, "tools", &json!({}));
    assert!(
        listing.contains("history: How code came to be"),
        "{listing}"
    );
    let (said, failed) = call(&mut client, "tools", &json!({ "group": "history" }));
    assert!(!failed && said.contains("history_recent"), "{said}");
    assert_eq!(
        client.take_notifications(),
        [json!({ "jsonrpc": "2.0", "method": "notifications/tools/list_changed" })]
    );
    assert!(tool_names(&mut client).contains(&"history_recent".to_owned()));
    conn.input.send(Input::Quit).unwrap();
}
