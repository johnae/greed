mod support;

use std::path::{Path, PathBuf};
use std::time::Duration;

use kern_core::Editor;
use kern_core::lsp::{Encoding, Handled, Lsp, file_uri, offset, position};
use kern_text::{ClientId, Rope};
use serde_json::{Value, json};

struct Setup {
    lsp: Lsp,
    editor: Editor,
    log: crossbeam_channel::Receiver<String>,
    path: PathBuf,
}

fn setup(text: &str) -> Setup {
    let (client_out, client_in, log) = support::start();

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

#[test]
fn project_roots_come_from_markers_or_the_files_directory() {
    use kern_core::lsp::project_root;
    let dir = std::env::temp_dir().join(format!("kern-root-{}", std::process::id()));
    std::fs::create_dir_all(dir.join("crate/src")).unwrap();
    std::fs::write(dir.join("crate/Cargo.toml"), "").unwrap();

    let markers = vec!["Cargo.toml".to_string()];
    assert_eq!(
        project_root(&dir.join("crate/src/main.rs"), &markers),
        dir.join("crate")
    );
    assert_eq!(
        project_root(&dir.join("crate/src/main.rs"), &[]),
        dir.join("crate/src")
    );
    // A bare file name is in the current directory.
    assert_eq!(
        project_root(Path::new("notes.md"), &[]),
        std::env::current_dir().unwrap()
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn servers_start_the_first_installed_command_and_skip_missing_ones_quietly() {
    use kern_core::lsp::ServerConfig;
    let command = |parts: &[&str]| parts.iter().map(|p| (*p).to_owned()).collect::<Vec<_>>();
    let config = ServerConfig {
        language: "rust".into(),
        commands: vec![
            command(&["no-such-server-kern"]),
            command(&["sh", "-c", "true"]),
        ],
        root_markers: Vec::new(),
    };
    assert_eq!(
        config.installed_command(),
        Some(&command(&["sh", "-c", "true"]))
    );

    let mut editor = Editor::new(ClientId(1));
    editor.open("file", "fn main() {}", Some("main.rs".into()));
    let mut lsp = Lsp::default();
    lsp.configure(ServerConfig {
        language: "rust".into(),
        commands: vec![command(&["no-such-server-kern"])],
        root_markers: Vec::new(),
    });
    assert!(
        lsp.sync(&editor).is_empty(),
        "nothing installed is not an error"
    );
    let err = lsp
        .request(editor.buffers().next().unwrap(), "x", &Value::Null)
        .unwrap_err();
    assert!(err.to_string().contains("no language server"), "{err}");
}

#[test]
fn a_request_goes_after_the_edit_made_just_before_it() {
    let mut s = setup("ok");
    s.lsp.sync(&s.editor);
    s.next();
    s.methods();
    let view = s.editor.focus();
    let changes = kern_text::ChangeSet::from_changes(2, [(2, 2, Some("("))]).unwrap();
    s.editor
        .apply(
            view,
            changes,
            kern_text::Author::User(ClientId(1)),
            None,
            None,
        )
        .unwrap();
    let buffer = s.editor.buffers().next().unwrap();
    let params = json!({ "textDocument": { "uri": file_uri(&s.path) }, "position": { "line": 0, "character": 3 } });
    s.lsp
        .request(buffer, "textDocument/hover", &params)
        .unwrap();
    let methods = s.methods();
    let change = methods.iter().position(|m| m == "textDocument/didChange");
    let hover = methods.iter().position(|m| m == "textDocument/hover");
    assert!(change.is_some() && change < hover, "{methods:?}");
}
