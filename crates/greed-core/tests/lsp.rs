mod support;

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
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
    // A folder of its own: one a test saving into appears under another's
    // file, and moves that one's server to it.
    static SETUPS: AtomicUsize = AtomicUsize::new(0);
    let n = SETUPS.fetch_add(1, Ordering::Relaxed);
    let path = std::env::temp_dir()
        .join(format!("greed-lsp-test-{}-{n}", std::process::id()))
        .join("main.rs");
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

impl Drop for Setup {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(self.path.parent().unwrap());
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
fn fake_servers_differ_by_their_program_to_tell_several_apart() {
    let mut s = setup("let x = bad;\n");
    let lint = support::Options {
        source: "lint",
        lacks: &["textDocument/hover"],
        ..support::Options::default()
    };
    let (launcher, started) =
        support::launcher_by(vec![("lint", lint)], support::Options::default());
    s.lsp.set_launcher(launcher);
    s.started = started;
    s.lsp.configure(greed_core::lsp::ServerConfig {
        commands: vec![vec!["lint".into()]],
        ..support::rust_server()
    });
    s.lsp.sync(&s.editor);
    let buffer = s.editor.buffers().next().unwrap().id();
    assert_eq!(s.next(), Handled::Diagnostics(buffer));
    let found = diagnostics(s.editor.buffer(buffer));
    assert_eq!(found[0].source.as_deref(), Some("lint"));
    let capabilities = s.lsp.capabilities(s.editor.buffer(buffer)).unwrap();
    assert!(capabilities["hoverProvider"].is_null(), "{capabilities}");
    assert_eq!(capabilities["definitionProvider"], json!(true));
    let (_, id) = s
        .lsp
        .request(s.editor.buffer(buffer), "textDocument/hover", &json!({}))
        .unwrap();
    loop {
        if let Handled::Response {
            id: got, result, ..
        } = s.next()
            && got == id
        {
            assert!(result.is_err(), "{result:?}");
            break;
        }
    }
}

#[test]
fn a_server_gets_its_settings_and_init_options_and_each_section_it_asks_for() {
    let settings = json!({ "rust-analyzer": { "cargo": { "features": "all" } } });
    let mut s = setup("let x = 1;\n");
    s.lsp.configure(greed_core::lsp::ServerConfig {
        settings: settings.clone(),
        init_options: json!({ "checkOnSave": true }),
        ..support::rust_server()
    });
    s.lsp.sync(&s.editor);
    let buffer = s.editor.buffers().next().unwrap().id();
    // Its question about its settings is answered before its first diagnostics.
    assert_eq!(s.next(), Handled::Diagnostics(buffer));
    let probe = s.probe(buffer);
    assert_eq!(
        probe["initialize"]["initializationOptions"],
        json!({ "checkOnSave": true })
    );
    assert_eq!(probe["changed"], json!({ "settings": settings }));
    assert_eq!(
        probe["configured"],
        json!([{ "features": "all" }, null, settings]),
        "a section, one there isn't, and all of them"
    );
}

#[test]
fn a_server_that_wants_its_folder_in_its_settings_gets_it_there() {
    let mut s = setup("let x = 1;\n");
    s.lsp.configure(greed_core::lsp::ServerConfig {
        settings: json!({ "validate": "on" }),
        folder_setting: Some("workspaceFolder".into()),
        ..support::rust_server()
    });
    s.lsp.sync(&s.editor);
    let buffer = s.editor.buffers().next().unwrap().id();
    assert_eq!(s.next(), Handled::Diagnostics(buffer));
    let root = s.lsp.running()[0].root.clone();
    let name = root.file_name().unwrap().to_string_lossy().into_owned();
    let settings = json!({
        "validate": "on",
        "workspaceFolder": { "uri": file_uri(&root), "name": name },
    });
    let probe = s.probe(buffer);
    assert_eq!(probe["configured"][2], settings, "asked for");
    assert_eq!(
        probe["changed"],
        json!({ "settings": settings }),
        "and told"
    );
}

#[test]
fn a_server_without_settings_is_told_none() {
    let mut s = setup("let x = 1;\n");
    s.lsp.sync(&s.editor);
    let buffer = s.editor.buffers().next().unwrap().id();
    assert_eq!(s.next(), Handled::Diagnostics(buffer));
    let probe = s.probe(buffer);
    assert!(probe["initialize"].get("initializationOptions").is_none());
    assert_eq!(probe["changed"], Value::Null, "no didChangeConfiguration");
    assert_eq!(probe["configured"], json!([null, null, null]));
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

/// Rust's server for linting, which runs beside its main one and doesn't
/// do hover.
fn lint_server(when: &[&str]) -> greed_core::lsp::ServerConfig {
    greed_core::lsp::ServerConfig {
        name: "lint".into(),
        commands: vec![vec!["lint".into()]],
        when: when.iter().map(|w| (*w).to_owned()).collect(),
        ..support::rust_server()
    }
}

/// Fake servers whose `lint` doesn't do hover and names its diagnostics so.
fn with_lint() -> (greed_core::lsp::Launcher, support::Started) {
    let lint = support::Options {
        source: "lint",
        lacks: &["textDocument/hover"],
        ..support::Options::default()
    };
    support::launcher_by(vec![("lint", lint)], support::Options::default())
}

#[test]
fn a_named_server_runs_beside_the_main_one_and_both_hear_of_the_document() {
    let mut s = setup("let x = bad;\n");
    let (launcher, started) = with_lint();
    s.lsp.set_launcher(launcher);
    s.started = started;
    s.lsp.configure(lint_server(&[]));
    assert!(s.lsp.sync(&s.editor).is_empty());
    assert_eq!(s.starts(), 2);
    let buffer = s.editor.buffers().next().unwrap().id();
    // Each opens it once it's started, and reports on it.
    for _ in 0..2 {
        assert_eq!(s.next(), Handled::Diagnostics(buffer));
    }
    for n in 0..2 {
        assert_eq!(s.documents_of(n), ["textDocument/didOpen"], "server {n}");
    }
    // The main one first.
    let servers = s.lsp.servers_of(s.editor.buffer(buffer));
    assert_eq!(servers.len(), 2);
    let hovers = |s: &Setup, n: usize| {
        !s.lsp.capabilities_of(servers[n]).unwrap()["hoverProvider"].is_null()
    };
    assert!(hovers(&s, 0) && !hovers(&s, 1));
    let names: Vec<String> = s.lsp.running().into_iter().map(|r| r.name).collect();
    assert_eq!(names, ["lint", "rust"]);

    let view = s.editor.focus();
    let changes = greed_text::ChangeSet::from_changes(13, [(13, 13, Some("ok"))]).unwrap();
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
    for n in 0..2 {
        assert_eq!(s.documents_of(n), ["textDocument/didChange"], "server {n}");
    }

    // A request goes to the server it's for.
    let (to, id) = s
        .lsp
        .request_to(
            servers[1],
            s.editor.buffer(buffer),
            "textDocument/hover",
            &json!({}),
        )
        .unwrap();
    assert_eq!(to, servers[1]);
    loop {
        if let Handled::Response {
            id: got, result, ..
        } = s.next()
            && got == id
        {
            assert!(result.is_err(), "lint doesn't hover: {result:?}");
            break;
        }
    }

    // Set up no more, the document closes there only. The main one started
    // first.
    s.lsp.remove("rust", Some("lint"));
    s.lsp.sync(&s.editor);
    assert!(s.documents_of(0).is_empty(), "the main one keeps it");
    assert_eq!(s.documents_of(1), ["textDocument/didClose"]);
}

#[test]
fn a_server_with_when_runs_only_under_a_folder_that_has_one_of_its_files() {
    let dir = two_projects("when");
    std::fs::write(dir.join("a/lint.toml"), "").unwrap();
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", "let x = bad;", Some(dir.join("a/src/main.rs")));
    editor.open("file", "let y = bad;", Some(dir.join("b/src/main.rs")));
    let mut s = Setup {
        lsp: Lsp::default(),
        editor,
        started: support::Started::default(),
        path: dir.join("a/src/main.rs"),
    };
    let (launcher, started) = with_lint();
    s.lsp.set_launcher(launcher);
    s.started = started;
    s.lsp.configure(support::rust_server());
    s.lsp.configure(lint_server(&["lint.toml"]));
    assert!(s.lsp.sync(&s.editor).is_empty());
    let running: Vec<(String, PathBuf)> = s
        .lsp
        .running()
        .into_iter()
        .map(|r| (r.name, r.root))
        .collect();
    assert_eq!(
        running,
        [
            ("lint".to_owned(), dir.join("a")),
            ("rust".to_owned(), dir.join("a")),
            ("rust".to_owned(), dir.join("b")),
        ]
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_named_server_that_isnt_installed_leaves_the_main_one_working() {
    let mut s = setup("let x = bad;\n");
    let (mut inner, started) = support::launcher();
    let launcher: greed_core::lsp::Launcher = Box::new(move |config, root| {
        if config.name == "lint" {
            Ok(None)
        } else {
            inner(config, root)
        }
    });
    s.lsp.set_launcher(launcher);
    s.started = started;
    s.lsp.configure(lint_server(&[]));
    assert!(s.lsp.sync(&s.editor).is_empty());
    let buffer = s.editor.buffers().next().unwrap().id();
    assert_eq!(s.next(), Handled::Diagnostics(buffer));
    assert_eq!(s.lsp.servers_of(s.editor.buffer(buffer)).len(), 1);
    assert_eq!(s.probe(buffer)["text"], "let x = bad;\n");
}

/// Rust's main server and `lint` beside it, both having reported on
/// `text`: the buffer and its two servers, the main one first.
fn two_reported(text: &str) -> (Setup, greed_core::BufferId, Vec<greed_core::lsp::ServerId>) {
    let mut s = setup(text);
    let (launcher, started) = with_lint();
    s.lsp.set_launcher(launcher);
    s.started = started;
    s.lsp.configure(lint_server(&[]));
    s.lsp.sync(&s.editor);
    let buffer = s.editor.buffers().next().unwrap().id();
    for _ in 0..2 {
        assert_eq!(s.next(), Handled::Diagnostics(buffer));
    }
    let servers = s.lsp.servers_of(s.editor.buffer(buffer));
    (s, buffer, servers)
}

#[test]
fn each_servers_diagnostics_show_together_saying_whose_they_are() {
    let (s, buffer, servers) = two_reported("let x = bad;\n");
    let found = diagnostics(s.editor.buffer(buffer));
    let whose: Vec<(Option<&str>, Option<greed_core::lsp::ServerId>)> = found
        .iter()
        .map(|d| (d.source.as_deref(), d.server))
        .collect();
    assert_eq!(whose.len(), 2, "{found:?}");
    assert!(
        whose.contains(&(Some("fake"), Some(servers[0]))),
        "{whose:?}"
    );
    assert!(
        whose.contains(&(Some("lint"), Some(servers[1]))),
        "{whose:?}"
    );
    // In every file's problems too, from both.
    let uri = file_uri(&s.path);
    let mut sources: Vec<Option<String>> = (s.lsp.problems(&s.editor).into_iter())
        .filter(|p| p.uri == uri)
        .map(|p| p.source)
        .collect();
    sources.sort();
    assert_eq!(sources, [Some("fake".to_owned()), Some("lint".to_owned())]);
}

#[test]
fn a_server_clearing_its_diagnostics_leaves_the_others() {
    let (mut s, buffer, servers) = two_reported("let x = bad;\n");
    let uri = file_uri(&s.path);
    let cleared = Event::Notification {
        server: servers[1],
        method: "textDocument/publishDiagnostics".into(),
        params: json!({ "uri": uri, "diagnostics": [] }),
    };
    assert_eq!(
        s.lsp.handle(cleared, &mut s.editor),
        Handled::Diagnostics(buffer)
    );
    let left: Vec<Option<String>> = diagnostics(s.editor.buffer(buffer))
        .into_iter()
        .map(|d| d.source)
        .collect();
    assert_eq!(left, [Some("fake".to_owned())]);
    let problems = s.lsp.problems(&s.editor);
    assert!(
        problems
            .iter()
            .all(|p| p.uri != uri || p.source.as_deref() == Some("fake")),
        "{problems:?}"
    );
}

#[test]
fn a_server_reporting_again_replaces_only_its_own_after_an_edit_moved_the_others() {
    let (mut s, buffer, servers) = two_reported("let x = bad;\n");
    // Text typed before both: the main one's moves with it, unanswered.
    let view = s.editor.focus();
    let changes = greed_text::ChangeSet::from_changes(13, [(0, 0, Some("// \n"))]).unwrap();
    s.editor
        .apply(
            view,
            changes,
            greed_text::Author::User(ClientId(1)),
            None,
            None,
        )
        .unwrap();
    let text = s.editor.buffer(buffer).text().to_string();
    let uri = file_uri(&s.path);
    let reported = Event::Notification {
        server: servers[1],
        method: "textDocument/publishDiagnostics".into(),
        params: json!({ "uri": uri, "diagnostics": [{
            "range": { "start": { "line": 0, "character": 0 }, "end": { "line": 0, "character": 2 } },
            "severity": 2, "message": "a comment", "source": "lint",
        }] }),
    };
    s.lsp.handle(reported, &mut s.editor);
    let found = diagnostics(s.editor.buffer(buffer));
    let shown: Vec<(&str, &str)> = found
        .iter()
        .map(|d| (&text[d.from..d.to], d.message.as_str()))
        .collect();
    assert_eq!(shown, [("//", "a comment"), ("bad", "bad word")]);
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

    // Before the line break, whichever it is.
    let text = Rope::from_str("ab\r\ncd\ref");
    let at = |line: u64| {
        offset(
            &text,
            &json!({ "line": line, "character": 99 }),
            Encoding::Utf8,
        )
    };
    assert_eq!((at(0), at(1), at(2)), (Some(2), Some(6), Some(9)));
}

#[test]
fn a_restart_finds_the_root_again_so_a_marker_made_since_counts() {
    let dir = std::env::temp_dir().join(format!("greed-restart-root-{}", std::process::id()));
    std::fs::create_dir_all(dir.join("crate/src")).unwrap();
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", "let x = 1;\n", Some(dir.join("crate/src/main.rs")));
    let mut lsp = Lsp::default();
    lsp.configure(support::rust_server());
    let (launcher, _started) = support::launcher();
    lsp.set_launcher(launcher);
    let roots = |lsp: &Lsp| -> Vec<PathBuf> { lsp.running().into_iter().map(|r| r.root).collect() };
    lsp.sync(&editor);
    assert_eq!(roots(&lsp), [dir.join("crate/src")]);
    // A Cargo.toml made after the file opened, as setup writes a .luaurc.
    std::fs::write(dir.join("crate/Cargo.toml"), "").unwrap();
    lsp.restart(None);
    lsp.sync(&editor);
    assert_eq!(roots(&lsp), [dir.join("crate")]);
    std::fs::remove_dir_all(&dir).unwrap();
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
        ..Default::default()
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
        ..Default::default()
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

/// Saves the first buffer of `s` to its file.
fn save(s: &mut Setup) {
    std::fs::create_dir_all(s.path.parent().unwrap()).unwrap();
    let buffer = s.editor.buffers().next().unwrap().id();
    s.editor.save(buffer).unwrap();
}

#[test]
fn a_server_that_reports_only_when_asked_is_asked_on_open_after_edits_and_when_it_says() {
    let options = support::Options {
        pull: true,
        ..support::Options::default()
    };
    let mut s = setup_with("let x = bad;\n", options);
    s.lsp.sync(&s.editor);
    let buffer = s.editor.buffers().next().unwrap().id();
    // Asked once it said how it reports, the document open.
    assert_eq!(s.next(), Handled::Diagnostics(buffer));
    assert_eq!(diagnostics(s.editor.buffer(buffer)).len(), 1);
    let methods = s.methods();
    assert!(
        methods.contains(&"textDocument/diagnostic".to_string()),
        "{methods:?}"
    );
    assert!(!methods.contains(&"textDocument/publishDiagnostics".to_string()));

    // After an edit, asked again, for the new text.
    let view = s.editor.focus();
    let changes = greed_text::ChangeSet::from_changes(13, [(13, 13, Some("bad"))]).unwrap();
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
    assert_eq!(s.next(), Handled::Diagnostics(buffer));
    assert_eq!(diagnostics(s.editor.buffer(buffer)).len(), 2);

    // Saying its diagnostics changed, it's asked again, and answered first.
    let server = s.lsp.servers_of(s.editor.buffer(buffer))[0];
    let refresh = Event::Request {
        server,
        id: json!("refresh"),
        method: "workspace/diagnostic/refresh".into(),
        params: Value::Null,
    };
    assert_eq!(s.lsp.handle(refresh, &mut s.editor), Handled::Nothing);
    assert_eq!(s.next(), Handled::Diagnostics(buffer));
    let methods = s.methods();
    let answered = methods.iter().position(|m| m == "(response)");
    let asked = methods.iter().rposition(|m| m == "textDocument/diagnostic");
    assert!(answered.is_some() && answered < asked, "{methods:?}");
}

#[test]
fn what_a_server_publishes_and_what_it_answers_when_asked_both_stay() {
    let options = support::Options {
        pull: true,
        ..support::Options::default()
    };
    let mut s = setup_with("let x = bad;\n", options);
    s.lsp.sync(&s.editor);
    let buffer = s.editor.buffers().next().unwrap().id();
    assert_eq!(s.next(), Handled::Diagnostics(buffer));
    // It also publishes, as rust-analyzer does what `cargo check` found.
    let server = s.lsp.servers_of(s.editor.buffer(buffer))[0];
    let checked = Event::Notification {
        server,
        method: "textDocument/publishDiagnostics".into(),
        params: json!({ "uri": file_uri(&s.path), "diagnostics": [{
            "range": { "start": { "line": 0, "character": 4 }, "end": { "line": 0, "character": 5 } },
            "severity": 2, "message": "unused variable", "source": "cargo",
        }] }),
    };
    s.lsp.handle(checked, &mut s.editor);
    // An edit asks again: the answer replaces what it answered, not what it
    // published.
    let view = s.editor.focus();
    let changes = greed_text::ChangeSet::from_changes(13, [(13, 13, Some("bad"))]).unwrap();
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
    assert_eq!(s.next(), Handled::Diagnostics(buffer));
    let messages: Vec<String> = diagnostics(s.editor.buffer(buffer))
        .into_iter()
        .map(|d| d.message)
        .collect();
    assert_eq!(messages, ["unused variable", "bad word", "bad word"]);
    let sources: Vec<Option<String>> = s
        .lsp
        .problems(&s.editor)
        .into_iter()
        .map(|p| p.source)
        .collect();
    assert_eq!(
        sources
            .iter()
            .filter(|s| s.as_deref() == Some("cargo"))
            .count(),
        1
    );
}

#[test]
fn a_save_tells_a_server_that_asks_after_the_edit_with_the_text_it_wants() {
    let options = support::Options {
        save: Some(true),
        ..support::Options::default()
    };
    let mut s = setup_with("ok", options);
    s.lsp.sync(&s.editor);
    s.next();
    s.methods();
    s.edit(0, 0, "// ");
    save(&mut s);
    s.lsp.sync(&s.editor);
    assert_eq!(
        s.documents_of(0),
        ["textDocument/didChange", "textDocument/didSave"]
    );
    // Once for each save, not again with nothing new.
    s.lsp.sync(&s.editor);
    assert!(s.documents_of(0).is_empty());
    let buffer = s.editor.buffers().next().unwrap().id();
    assert_eq!(s.probe(buffer)["saved"], json!(["// ok"]));
}

#[test]
fn a_save_says_nothing_to_a_server_that_doesnt_ask_and_no_text_unless_asked() {
    let mut s = setup("ok");
    s.lsp.sync(&s.editor);
    s.next();
    s.methods();
    save(&mut s);
    s.lsp.sync(&s.editor);
    assert!(s.documents_of(0).is_empty(), "it didn't ask");

    let options = support::Options {
        save: Some(false),
        ..support::Options::default()
    };
    let mut s = setup_with("ok", options);
    s.lsp.sync(&s.editor);
    s.next();
    save(&mut s);
    s.lsp.sync(&s.editor);
    let buffer = s.editor.buffers().next().unwrap().id();
    assert_eq!(s.probe(buffer)["saved"], json!([null]), "without the text");
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
    let tagged: Vec<(String, Vec<String>)> = greed_core::render::grid::screen_rows(&frame)
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
        ..support::Options::default()
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
        ..support::Options::default()
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
        ..support::Options::default()
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
        ..support::Options::default()
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
fn a_forgotten_history_sends_the_whole_text() {
    let options = support::Options {
        incremental: true,
        utf8: false,
        ..support::Options::default()
    };
    let mut s = setup_with("ab\ncd", options);
    s.lsp.sync(&s.editor);
    s.compare();
    s.edit(1, 1, "x");
    s.lsp.sync(&s.editor);
    assert_eq!(s.compare()["whole"], 0);
    // Lines break where a server breaks them, so any text goes as ranges.
    s.edit(0, 0, "\u{2028}\u{85}\u{0C}\r");
    s.edit(0, 0, "y");
    s.lsp.sync(&s.editor);
    assert_eq!(s.compare()["whole"], 0);

    // Without the transactions, there's nothing to make ranges from.
    let buffer = s.editor.buffers().next().unwrap().id();
    s.editor.forget_history(buffer);
    s.edit(0, 0, "w");
    s.edit(0, 0, "v");
    s.lsp.sync(&s.editor);
    let probe = s.compare();
    assert_eq!(probe["whole"], 1, "{probe}");
}

#[test]
fn diagnostics_past_the_end_or_inside_characters_are_kept_in_the_text() {
    use greed_core::render::{CellWidth, Plain, Renderer, Size, Status};
    let options = support::Options {
        incremental: false,
        utf8: false,
        ..support::Options::default()
    };
    let mut s = setup_with("a😀é\nbad\n", options);
    s.lsp.sync(&s.editor);
    s.next();
    let at = |line: Value, character: Value| json!({ "line": line, "character": character });
    let range = |start: Value, end: Value| json!({ "range": { "start": start, "end": end }, "message": "odd" });
    s.publish(
        None,
        json!([
            // Past the last line, past a line's end, and huge.
            range(at(json!(9), json!(0)), at(json!(99), json!(5))),
            range(at(json!(0), json!(500)), at(json!(1), json!(u64::MAX))),
            // Inside the surrogate pair of the emoji, and ending before it starts.
            range(at(json!(0), json!(2)), at(json!(0), json!(1))),
            // Not numbers at all, and no range.
            range(at(json!(-1), json!(0.5)), at(json!("x"), json!(null))),
            json!({ "message": "no range" }),
            json!("not even an object"),
        ]),
    );
    let buffer = s.editor.buffers().next().unwrap();
    let len = buffer.text().len_bytes();
    for d in diagnostics(buffer) {
        assert!(d.from <= d.to && d.to <= len, "{d:?}");
        assert!(buffer.text().to_string().is_char_boundary(d.from), "{d:?}");
    }
    // Every byte, even those inside a character, has a position.
    let text = buffer.text().clone();
    for pos in 0..len + 3 {
        for encoding in [Encoding::Utf8, Encoding::Utf16] {
            let p = position(&text, pos, encoding);
            assert!(offset(&text, &p, encoding).is_some(), "{pos}: {p}");
        }
    }
    assert_eq!(
        position(&text, 2, Encoding::Utf16),
        json!({ "line": 0, "character": 1 })
    );
    s.lsp.problems(&s.editor);
    Renderer::new(CellWidth).frame(
        &mut s.editor,
        Size {
            width: 6,
            height: 3,
        },
        &Status::Default { message: None },
        &Plain,
    );
}

#[test]
fn servers_start_only_in_trusted_folders_and_one_held_back_starts_once_trusted() {
    let mut s = setup("fn main() {}");
    s.lsp.trust(Some(vec![PathBuf::from("/somewhere/else")]));
    assert!(s.lsp.sync(&s.editor).is_empty(), "held back quietly");
    assert_eq!(s.starts(), 0, "nothing started");
    let held = s.lsp.held();
    assert_eq!(held.len(), 1, "{held:?}");
    let (language, name, root) = held[0].clone();
    assert!(
        language == "rust" && name.is_empty() && s.path.starts_with(&root),
        "{root:?}"
    );
    // A folder holding the server's trusts it too.
    s.lsp
        .trust(Some(vec![root.parent().unwrap().to_path_buf()]));
    s.lsp.sync(&s.editor);
    assert_eq!(s.starts(), 1, "it starts once its folder is trusted");
    assert!(s.lsp.held().is_empty());
}
