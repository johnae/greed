mod support;

use std::path::{Path, PathBuf};
use std::time::Duration;

use greed_core::Editor;
use greed_core::lsp::{Encoding, Event, Handled, Lsp, diagnostics, file_uri, offset, position};
use greed_text::{ClientId, Rope};
use serde_json::{Value, json};

struct Setup {
    lsp: Lsp,
    editor: Editor,
    log: crossbeam_channel::Receiver<String>,
    path: PathBuf,
}

fn setup(text: &str) -> Setup {
    let (client_out, client_in, log) = support::start();

    let path = std::env::temp_dir().join("greed-lsp-test/main.rs");
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
    /// Handles events until one is handled as something other than nothing
    /// or a notification for plugins.
    fn next(&mut self) -> Handled {
        loop {
            let event = self
                .lsp
                .events()
                .recv_timeout(Duration::from_secs(5))
                .expect("server answered");
            match self.lsp.handle(event, &mut self.editor) {
                Handled::Nothing | Handled::Notification { .. } => {}
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

    let found = diagnostics(s.editor.buffer(buffer));
    assert_eq!(found.len(), 1);
    let text = s.editor.buffer(buffer).text().to_string();
    let d = &found[0];
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
    let changes = greed_text::ChangeSet::from_changes(2, [(2, 2, Some(" bad"))]).unwrap();
    s.editor
        .apply(
            view,
            changes,
            greed_text::Author::User(ClientId(1)),
            None,
            None,
        )
        .unwrap();
    s.lsp.sync(&s.editor);
    let buffer = s.editor.buffers().next().unwrap().id();
    assert_eq!(s.next(), Handled::Diagnostics(buffer));
    assert_eq!(diagnostics(s.editor.buffer(buffer)).len(), 1);
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
    use greed_core::lsp::project_root;
    let dir = std::env::temp_dir().join(format!("greed-root-{}", std::process::id()));
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
    // A new file in folders not made yet: the nearest one there is, and its
    // markers.
    assert_eq!(
        project_root(&dir.join("crate/src/new/deeper/a.rs"), &markers),
        dir.join("crate")
    );
    assert_eq!(
        project_root(&dir.join("crate/src/new/deeper/a.rs"), &[]),
        dir.join("crate/src")
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn servers_start_the_first_installed_command_and_skip_missing_ones_quietly() {
    use greed_core::lsp::ServerConfig;
    let command = |parts: &[&str]| parts.iter().map(|p| (*p).to_owned()).collect::<Vec<_>>();
    let config = ServerConfig {
        language: "rust".into(),
        commands: vec![
            command(&["no-such-server-greed"]),
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
        commands: vec![command(&["no-such-server-greed"])],
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
    let changes = greed_text::ChangeSet::from_changes(2, [(2, 2, Some("("))]).unwrap();
    s.editor
        .apply(
            view,
            changes,
            greed_text::Author::User(ClientId(1)),
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

#[test]
fn closed_buffers_are_closed_in_the_server_and_their_diagnostics_go() {
    let mut s = setup("bad");
    s.lsp.sync(&s.editor);
    let buffer = s.editor.buffers().next().unwrap().id();
    assert_eq!(s.next(), Handled::Diagnostics(buffer));

    let view = s.editor.focus();
    let other = s.editor.create_buffer("file", "");
    assert!(s.editor.close_buffer(buffer).is_err(), "a view shows it");
    s.editor.show(view, other);
    s.editor.close_buffer(buffer).unwrap();
    s.lsp.sync(&s.editor);
    assert!(s.methods().contains(&"textDocument/didClose".to_string()));
    // The file's problems are as the server sent them again.
    assert_eq!(
        s.problem_range()["end"],
        json!({ "line": 0, "character": 3 })
    );
}

impl Setup {
    fn edit(&mut self, from: usize, to: usize, text: &str) {
        let view = self.editor.focus();
        let len = self
            .editor
            .buffer(self.editor.view(view).buffer)
            .text()
            .len_bytes();
        let changes = greed_text::ChangeSet::from_changes(len, [(from, to, Some(text))]).unwrap();
        self.editor
            .apply(
                view,
                changes,
                greed_text::Author::User(ClientId(1)),
                None,
                None,
            )
            .unwrap();
    }

    /// Hands the client a `publishDiagnostics` for the file, as if the
    /// server had sent it.
    fn publish(&mut self, version: Option<usize>, diagnostics: Value) -> Handled {
        let mut params = json!({ "uri": file_uri(&self.path) });
        params["diagnostics"] = diagnostics;
        if let Some(version) = version {
            params["version"] = json!(version);
        }
        let event = Event::Notification {
            server: 0,
            method: "textDocument/publishDiagnostics".into(),
            params,
        };
        self.lsp.handle(event, &mut self.editor)
    }

    fn found(&self) -> Vec<String> {
        let buffer = self.editor.buffers().next().unwrap();
        let text = buffer.text().to_string();
        diagnostics(buffer)
            .iter()
            .map(|d| text[d.from..d.to].to_owned())
            .collect()
    }

    /// The range of this file's problem in the project's problem list.
    fn problem_range(&self) -> Value {
        self.lsp
            .problems(&self.editor)
            .into_iter()
            .find(|p| p.uri == file_uri(&self.path))
            .unwrap()
            .range
    }
}

fn problem(line: u64, from: u64, to: u64, severity: u8) -> Value {
    json!({
        "range": { "start": { "line": line, "character": from }, "end": { "line": line, "character": to } },
        "severity": severity, "message": "here",
    })
}

#[test]
fn diagnostics_move_with_edits_before_them() {
    let mut s = setup("let x = bad;\n");
    s.lsp.sync(&s.editor);
    s.next();
    s.edit(0, 0, "// note\n");
    assert_eq!(s.found(), ["bad"]);
    let buffer = s.editor.buffers().next().unwrap().id();
    assert_eq!(diagnostics(s.editor.buffer(buffer))[0].from, 16);
    // Problems in open files are where they are now, too.
    assert_eq!(
        s.problem_range(),
        json!({ "start": { "line": 1, "character": 8 }, "end": { "line": 1, "character": 11 } })
    );

    // Deleting a problem's text deletes the problem.
    s.edit(16, 19, "");
    assert!(s.found().is_empty());
}

#[test]
fn a_publish_for_an_older_version_is_dropped() {
    let mut s = setup("bad bad");
    s.lsp.sync(&s.editor);
    s.next();
    let version = s.editor.buffers().next().unwrap().history().applied();
    s.edit(0, 0, "x");

    let stale = s.publish(Some(version), json!([problem(0, 0, 3, 1)]));
    assert_eq!(stale, Handled::Nothing);
    assert_eq!(s.found(), ["bad", "bad"], "the earlier ones stay, moved");

    let buffer = s.editor.buffers().next().unwrap().id();
    let current = s.editor.buffer(buffer).history().applied();
    let fresh = s.publish(Some(current), json!([problem(0, 1, 4, 1)]));
    assert_eq!(fresh, Handled::Diagnostics(buffer));
    assert_eq!(s.found(), ["bad"]);
    // Without a version, a publish is taken as being about the text now.
    s.publish(None, json!([]));
    assert!(s.found().is_empty());
}

#[test]
fn an_empty_diagnostic_covers_a_character_so_it_shows() {
    let mut s = setup("ab\n\n");
    s.lsp.sync(&s.editor);
    s.next();
    s.publish(
        None,
        json!([
            problem(0, 1, 1, 1),
            problem(0, 2, 2, 2),
            problem(1, 0, 0, 3)
        ]),
    );
    // The one on an empty line stays empty.
    assert_eq!(s.found(), ["b", "b", ""]);
}

#[test]
fn diagnostics_underline_their_text_and_color_the_line_number() {
    use greed_core::render::{CellWidth, Plain, Renderer, Size, Status, Tag};
    let mut s = setup("ok bad\nfine\n");
    s.lsp.sync(&s.editor);
    s.next();
    s.publish(
        None,
        json!([
            problem(0, 3, 6, 2),
            problem(0, 4, 5, 1),
            problem(1, 0, 4, 4)
        ]),
    );
    let frame = Renderer::new(CellWidth).frame(
        &mut s.editor,
        Size {
            width: 20,
            height: 4,
        },
        &Status::Default { message: None },
        &Plain,
    );
    let tagged: Vec<(String, Vec<String>)> = frame
        .rows
        .iter()
        .flat_map(|r| &r.spans)
        .map(|span| {
            let names = span
                .tags
                .iter()
                .map(Tag::name)
                .filter(|n| n.contains("diagnostic"))
                .map(str::to_owned);
            (span.text.clone(), names.collect::<Vec<_>>())
        })
        .filter(|(_, names)| !names.is_empty())
        .collect();
    // The worst problem is drawn on top: last.
    let expected = [
        (
            "1 ",
            vec!["ui.gutter.diagnostic.warning", "ui.gutter.diagnostic.error"],
        ),
        ("b", vec!["diagnostic.warning"]),
        ("a", vec!["diagnostic.warning", "diagnostic.error"]),
        ("d", vec!["diagnostic.warning"]),
        ("2 ", vec!["ui.gutter.diagnostic.hint"]),
        ("fine", vec!["diagnostic.hint"]),
    ]
    .map(|(text, names)| {
        (
            text.to_owned(),
            names.into_iter().map(str::to_owned).collect(),
        )
    });
    assert_eq!(tagged, expected);
}
