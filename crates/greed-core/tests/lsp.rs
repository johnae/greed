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
    started: support::Started,
    path: PathBuf,
}

/// An editor with `text` in a Rust file, and fake servers started for it.
fn setup(text: &str) -> Setup {
    setup_with(text, support::Options::default())
}

/// An editor with `text` in a Rust file, and fake servers that work as
/// `options` say started for it.
fn setup_with(text: &str, options: support::Options) -> Setup {
    let path = std::env::temp_dir().join("greed-lsp-test/main.rs");
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", text, Some(path.clone()));
    let mut lsp = Lsp::default();
    lsp.configure(support::rust_server());
    let (launcher, started) = support::launcher_with(options);
    lsp.set_launcher(launcher);
    Setup {
        lsp,
        editor,
        started,
        path,
    }
}

impl Setup {
    /// How many servers were started.
    fn starts(&self) -> usize {
        self.started.lock().unwrap().len()
    }

    /// The methods server `n` (counting from 0, in the order they started)
    /// got since the last look.
    fn methods_of(&self, n: usize) -> Vec<String> {
        std::thread::sleep(Duration::from_millis(50));
        self.started.lock().unwrap()[n].1.try_iter().collect()
    }

    /// Asks `buffer`'s server what it was started with and knows, and waits
    /// for the answer.
    fn probe(&mut self, buffer: greed_core::BufferId) -> Value {
        let (_, id) = self
            .lsp
            .request(self.editor.buffer(buffer), "probe", &Value::Null)
            .unwrap();
        loop {
            match self.next() {
                Handled::Response {
                    id: got,
                    result: Ok(result),
                    ..
                } if got == id => return result,
                Handled::Response { .. } | Handled::Diagnostics(_) => {}
                other => panic!("{other:?}"),
            }
        }
    }

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

    /// What server `n` heard about documents since the last look.
    fn documents_of(&self, n: usize) -> Vec<String> {
        let mut methods = self.methods_of(n);
        methods.retain(|m| m.starts_with("textDocument/did"));
        methods
    }

    /// The methods the first server got since the last look.
    fn methods(&self) -> Vec<String> {
        self.methods_of(0)
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
fn answers_nobody_asked_for_are_dropped() {
    let mut s = setup("ok");
    s.lsp.sync(&s.editor);
    s.next();
    let stray = Event::Response {
        server: 0,
        id: 999,
        result: Ok(Value::Null),
    };
    assert_eq!(s.lsp.handle(stray, &mut s.editor), Handled::Nothing);
    let unknown = Event::Response {
        server: 42,
        id: 1,
        result: Ok(Value::Null),
    };
    assert_eq!(s.lsp.handle(unknown, &mut s.editor), Handled::Nothing);
}

#[test]
fn a_server_that_stops_says_so_and_its_late_answers_are_dropped() {
    let mut s = setup("ok");
    s.lsp.sync(&s.editor);
    s.next();
    let buffer = s.editor.buffers().next().unwrap();
    let (server, id) = s.lsp.request(buffer, "die", &Value::Null).unwrap();
    assert_eq!(s.next(), Handled::Exited { server });
    let late = Event::Response {
        server,
        id,
        result: Ok(Value::Null),
    };
    assert_eq!(s.lsp.handle(late, &mut s.editor), Handled::Nothing);
    let buffer = s.editor.buffers().next().unwrap();
    let err = s.lsp.request(buffer, "x", &Value::Null).unwrap_err();
    assert!(err.to_string().contains("no language server"), "{err}");
    // Answering a request from it is quietly nothing.
    s.lsp.respond(server, &json!(1), &Value::Null);
}

#[test]
fn a_server_that_stops_starts_again_with_its_documents_until_it_keeps_stopping() {
    let mut s = setup("ok");
    assert!(s.lsp.sync(&s.editor).is_empty());
    s.next();
    let buffer = s.editor.buffers().next().unwrap().id();
    let mut servers = Vec::new();
    for start in 1..=4 {
        assert_eq!(s.starts(), start);
        let (server, _) = s
            .lsp
            .request(s.editor.buffer(buffer), "die", &Value::Null)
            .unwrap();
        servers.push(server);
        assert_eq!(s.next(), Handled::Exited { server });
        let errors = s.lsp.sync(&s.editor);
        if start < 4 {
            assert!(errors.is_empty(), "{errors:?}");
            // The new one has the file open, and answers.
            assert_eq!(s.probe(buffer)["text"], "ok");
            let methods = s.methods_of(start);
            assert_eq!(
                methods[..3],
                ["initialize", "initialized", "textDocument/didOpen"]
            );
        } else {
            // The fourth stop in a row soon after starting is the last.
            let errors: Vec<String> = errors.iter().map(ToString::to_string).collect();
            assert_eq!(errors.len(), 1, "{errors:?}");
            assert!(errors[0].starts_with("sh keeps stopping in"), "{errors:?}");
        }
    }
    // Each was a server of its own.
    servers.dedup();
    assert_eq!(servers.len(), 4);
    assert!(s.lsp.sync(&s.editor).is_empty(), "said once");
    assert_eq!(s.starts(), 4);
    assert!(
        s.lsp
            .request(s.editor.buffer(buffer), "x", &Value::Null)
            .is_err()
    );

    // Setting the language up again tries again.
    s.lsp.configure(support::rust_server());
    assert!(s.lsp.sync(&s.editor).is_empty());
    assert_eq!(s.starts(), 5);
}

#[test]
fn a_server_that_cant_start_says_so_once_and_one_not_installed_says_nothing() {
    for installed in [false, true] {
        let mut s = setup("ok");
        let tries = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counted = tries.clone();
        s.lsp.set_launcher(Box::new(move |_, _| {
            counted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            if installed {
                Err(std::io::Error::other("can't run sh: broken"))
            } else {
                Ok(None)
            }
        }));
        let errors: Vec<String> = s
            .lsp
            .sync(&s.editor)
            .iter()
            .map(ToString::to_string)
            .collect();
        if installed {
            assert_eq!(
                errors,
                ["no language server for rust: can't run sh: broken"]
            );
        } else {
            assert!(errors.is_empty(), "{errors:?}");
        }
        assert!(s.lsp.sync(&s.editor).is_empty());
        assert_eq!(tries.load(std::sync::atomic::Ordering::SeqCst), 1);
    }
}

/// A folder with two Rust projects, `a` and `b`, each with a file.
fn two_projects(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("greed-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    for project in ["a", "b"] {
        std::fs::create_dir_all(dir.join(project).join("src")).unwrap();
        std::fs::write(dir.join(project).join("Cargo.toml"), "").unwrap();
        std::fs::write(dir.join(project).join("src/main.rs"), "let x = bad;").unwrap();
    }
    dir
}

#[test]
fn each_project_gets_a_server_of_its_own_in_its_root() {
    let dir = two_projects("roots");
    let mut editor = Editor::new(ClientId(1));
    let a = editor
        .open("file", "let x = bad;", Some(dir.join("a/src/main.rs")))
        .0;
    let (b, b_view) = editor.open("file", "let y = bad;", Some(dir.join("b/src/main.rs")));
    // A second file in a goes to a's server.
    let a2 = editor.open("file", "ok", Some(dir.join("a/src/lib.rs"))).0;
    let mut s = Setup {
        lsp: Lsp::default(),
        editor,
        started: support::Started::default(),
        path: dir.join("a/src/main.rs"),
    };
    s.lsp.configure(support::rust_server());
    let (launcher, started) = support::launcher();
    s.lsp.set_launcher(launcher);
    s.started = started;
    assert!(s.lsp.sync(&s.editor).is_empty());
    let roots: Vec<PathBuf> = s
        .started
        .lock()
        .unwrap()
        .iter()
        .map(|(r, _)| r.clone())
        .collect();
    assert_eq!(roots, [dir.join("a"), dir.join("b")]);

    // Each was started in its root, with it as its one workspace folder,
    // and has its own files.
    for (buffer, project) in [(a, "a"), (b, "b"), (a2, "a")] {
        let probe = s.probe(buffer);
        let root = dir.join(project);
        let folders = json!([{ "uri": file_uri(&root), "name": project }]);
        assert_eq!(probe["initialize"]["rootUri"], file_uri(&root));
        assert_eq!(probe["initialize"]["rootPath"], root.display().to_string());
        assert_eq!(probe["initialize"]["workspaceFolders"], folders);
        // Asked after starting, by the time a second probe is answered.
        assert_eq!(s.probe(buffer)["folders"], folders);
    }
    assert_eq!(
        s.documents_of(0),
        ["textDocument/didOpen", "textDocument/didOpen"]
    );
    assert_eq!(s.documents_of(1), ["textDocument/didOpen"]);
    // Problems arrived for each, where they are.
    let found = |s: &Setup, buffer| diagnostics(s.editor.buffer(buffer)).len();
    assert_eq!((found(&s, a), found(&s, b)), (1, 1));
    for (buffer, root) in [(a, "a"), (b, "b")] {
        let found = s.lsp.root(s.editor.buffer(buffer), &s.editor);
        assert_eq!(found, Some(dir.join(root)));
    }

    // Closing b's file closes it in b's server only.
    s.editor.show(b_view, a);
    s.editor.close_buffer(b).unwrap();
    s.lsp.sync(&s.editor);
    assert_eq!(s.documents_of(1), ["textDocument/didClose"]);
    assert_eq!(s.documents_of(0), [""; 0]);
    let running: Vec<(String, PathBuf)> = s
        .lsp
        .running()
        .into_iter()
        .map(|r| (r.language, r.root))
        .collect();
    assert_eq!(
        running,
        [
            ("rust".to_owned(), dir.join("a")),
            ("rust".to_owned(), dir.join("b"))
        ],
        "a server stays while it runs"
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_file_saved_into_another_project_moves_to_its_server() {
    let dir = two_projects("moves");
    let mut s = setup("let x = bad;");
    let buffer = s.editor.buffers().next().unwrap().id();
    s.editor
        .save_as(buffer, &dir.join("a/src/main.rs"))
        .unwrap();
    s.lsp.sync(&s.editor);
    s.probe(buffer);
    s.editor
        .save_as(buffer, &dir.join("a/src/other.rs"))
        .unwrap();
    s.lsp.sync(&s.editor);
    s.probe(buffer);
    // A new name is a new document for the same server.
    assert_eq!(
        s.documents_of(0),
        [
            "textDocument/didOpen",
            "textDocument/didClose",
            "textDocument/didOpen"
        ]
    );
    s.editor
        .save_as(buffer, &dir.join("b/src/main.rs"))
        .unwrap();
    s.lsp.sync(&s.editor);
    assert_eq!(
        s.probe(buffer)["initialize"]["rootUri"],
        file_uri(&dir.join("b"))
    );
    assert_eq!(s.documents_of(0), ["textDocument/didClose"]);
    assert_eq!(s.documents_of(1), ["textDocument/didOpen"]);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn servers_run_in_the_topmost_root_inside_a_project_or_the_project_itself() {
    use greed_core::lsp::server_root;
    let dir = std::env::temp_dir().join(format!("greed-server-root-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let repo = dir.join("repo");
    std::fs::create_dir_all(repo.join(".git")).unwrap();
    std::fs::create_dir_all(repo.join("crates/a/src")).unwrap();
    std::fs::create_dir_all(dir.join("loose/src")).unwrap();
    for marker in [
        "repo/Cargo.toml",
        "repo/crates/a/Cargo.toml",
        "Cargo.toml",
        "loose/Cargo.toml",
    ] {
        std::fs::write(dir.join(marker), "").unwrap();
    }
    let cargo = vec!["Cargo.toml".to_owned()];
    let file = repo.join("crates/a/src/lib.rs");
    // In a repository: the workspace at its top, not the member crate, and
    // nothing above the repository.
    assert_eq!(server_root(&file, &cargo, &[]), repo);
    // Without markers, the repository's root.
    assert_eq!(server_root(&file, &[], &[]), repo);
    let none = vec!["none.toml".to_owned()];
    assert_eq!(server_root(&file, &none, &[]), repo);
    // An open project inside it bounds it too: the deepest one counts.
    let crates = repo.join("crates");
    assert_eq!(
        server_root(&file, &cargo, &[dir.clone(), crates.clone()]),
        repo.join("crates/a")
    );
    assert_eq!(
        server_root(&file, &[], std::slice::from_ref(&crates)),
        crates
    );
    // An open project around a folder with no repository.
    let loose = dir.join("loose/src/main.rs");
    assert_eq!(
        server_root(&loose, &cargo, &[dir.join("loose")]),
        dir.join("loose")
    );
    // Outside any project: the nearest marker, or the file's folder.
    assert_eq!(server_root(&loose, &cargo, &[]), dir.join("loose"));
    assert_eq!(server_root(&loose, &[], &[]), dir.join("loose/src"));
    std::fs::remove_dir_all(&dir).unwrap();
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

/// Numbers that look random but are the same every run.
struct Dice(u64);

impl Dice {
    fn roll(&mut self, below: usize) -> usize {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        usize::try_from(self.0 >> 33).unwrap() % below
    }
}

/// Text that makes positions hard: characters of every UTF-8 length, one
/// that's two UTF-16 units, and every kind of line break.
const PIECES: [&str; 10] = [
    "a", "é", "😀", "\r\n", "\n", "\r", "x😀y", "", "\r\n\r\n", "€\r",
];

impl Setup {
    /// Replaces up to `cuts` characters at each of up to three random places
    /// at once, as several cursors typing do.
    fn edit_randomly(&mut self, dice: &mut Dice) {
        let view = self.editor.focus();
        let text = self
            .editor
            .buffer(self.editor.view(view).buffer)
            .text()
            .clone();
        let chars = text.len_chars();
        let mut places: Vec<usize> = (0..=dice.roll(3)).map(|_| dice.roll(chars + 1)).collect();
        places.sort_unstable();
        places.dedup();
        let mut edits = Vec::new();
        for (i, &at) in places.iter().enumerate() {
            let next = places.get(i + 1).copied().unwrap_or(chars);
            let to = (at + dice.roll(3)).min(next);
            let piece = PIECES[dice.roll(PIECES.len())];
            edits.push((text.char_to_byte(at), text.char_to_byte(to), Some(piece)));
        }
        let changes = greed_text::ChangeSet::from_changes(text.len_bytes(), edits).unwrap();
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

    /// Checks that the server, building its text from what it was sent, has
    /// the buffer's text, and returns what it says about it.
    fn compare(&mut self) -> Value {
        let buffer = self.editor.buffers().next().unwrap().id();
        let probe = self.probe(buffer);
        assert_eq!(probe["errors"], json!([]));
        let text = self.editor.buffer(buffer).text().to_string();
        assert_eq!(probe["text"].as_str(), Some(text.as_str()));
        probe
    }

    /// Edits, undoes and redoes many times, syncing now and then, and
    /// compares after each sync.
    fn edit_and_compare(&mut self, seed: u64) -> Value {
        let mut dice = Dice(seed);
        assert!(self.lsp.sync(&self.editor).is_empty());
        let mut probe = self.compare();
        let view = self.editor.focus();
        for step in 0..300 {
            match dice.roll(8) {
                0 => {
                    self.editor.undo(view).unwrap();
                }
                1 => {
                    self.editor.redo(view).unwrap();
                }
                _ => self.edit_randomly(&mut dice),
            }
            // Several edits between syncs too.
            if step % 3 == 0 {
                assert!(self.lsp.sync(&self.editor).is_empty());
                probe = self.compare();
            }
        }
        probe
    }
}

#[test]
fn incremental_changes_rebuild_the_text_in_utf16_positions() {
    let options = support::Options {
        incremental: true,
        utf8: false,
    };
    let mut s = setup_with("a😀b\r\ncd\r\n\r\né\n", options);
    let probe = s.edit_and_compare(1);
    assert_eq!(probe["whole"], 0, "{probe}");
    assert!(probe["ranged"].as_u64() > Some(100), "{probe}");
    let buffer = s.editor.buffers().next().unwrap();
    assert_eq!(s.lsp.encoding(buffer).unwrap(), Encoding::Utf16);
}

#[test]
fn incremental_changes_rebuild_the_text_in_utf8_positions() {
    let options = support::Options {
        incremental: true,
        utf8: true,
    };
    let mut s = setup_with("€x\r\n😀\r", options);
    let probe = s.edit_and_compare(2);
    assert_eq!(probe["whole"], 0, "{probe}");
    assert!(probe["ranged"].as_u64() > Some(100), "{probe}");
    let buffer = s.editor.buffers().next().unwrap();
    assert_eq!(s.lsp.encoding(buffer).unwrap(), Encoding::Utf8);
}

#[test]
fn a_server_that_wants_the_whole_text_gets_it() {
    let options = support::Options {
        incremental: false,
        utf8: false,
    };
    let mut s = setup_with("a😀b\r\n", options);
    let probe = s.edit_and_compare(3);
    assert_eq!(probe["ranged"], 0, "{probe}");
    assert!(probe["whole"].as_u64() > Some(50), "{probe}");
}

#[test]
fn a_change_inside_a_line_break_takes_in_the_whole_break() {
    let options = support::Options {
        incremental: true,
        utf8: false,
    };
    let mut s = setup_with("ab\r\ncd\r\nef", options);
    s.lsp.sync(&s.editor);
    s.compare();
    // Typing between a \r and its \n, deleting just the \r of one and just
    // the \n of another, all at once.
    s.edit(3, 3, "😀");
    s.compare();
    let changes = greed_text::ChangeSet::from_changes(
        s.editor.buffers().next().unwrap().text().len_bytes(),
        [(2, 3, None::<&str>), (11, 12, None)],
    )
    .unwrap();
    let view = s.editor.focus();
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
    let probe = s.compare();
    assert_eq!(probe["text"], "ab😀\ncd\ref");
    assert_eq!(probe["whole"], 0);
}

#[test]
fn line_breaks_lsp_doesnt_count_or_a_forgotten_history_send_the_whole_text() {
    let options = support::Options {
        incremental: true,
        utf8: false,
    };
    let mut s = setup_with("ab\ncd", options);
    s.lsp.sync(&s.editor);
    s.compare();
    s.edit(1, 1, "x");
    s.lsp.sync(&s.editor);
    assert_eq!(s.compare()["whole"], 0);
    // The editor breaks lines at U+2028; a server doesn't.
    s.edit(0, 0, "\u{2028}");
    s.lsp.sync(&s.editor);
    assert_eq!(s.compare()["whole"], 1);
    s.edit(0, 0, "y");
    s.lsp.sync(&s.editor);
    assert_eq!(s.compare()["whole"], 2, "while the text has one");
    s.edit(1, 4, "");
    s.lsp.sync(&s.editor);
    assert_eq!(s.compare()["whole"], 3);
    s.edit(0, 0, "z");
    s.lsp.sync(&s.editor);
    assert_eq!(s.compare()["whole"], 3, "ranges again once it's gone");

    // Without the transactions, there's nothing to make ranges from.
    let buffer = s.editor.buffers().next().unwrap().id();
    s.editor.forget_history(buffer);
    s.edit(0, 0, "w");
    s.edit(0, 0, "v");
    s.lsp.sync(&s.editor);
    let probe = s.compare();
    assert_eq!(probe["whole"], 4, "{probe}");
}
