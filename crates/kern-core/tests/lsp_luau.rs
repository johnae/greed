//! Language servers through the Luau API, against the fake server.

mod support;

use std::time::Duration;

use kern_core::Editor;
use kern_core::luau::Host;
use kern_text::ClientId;

fn host() -> Host {
    let mut editor = Editor::new(ClientId(1));
    editor.open(
        "file",
        "let x = bad;",
        Some(std::env::temp_dir().join("kern-lsp-luau/main.rs")),
    );
    let host = Host::new(editor).unwrap();
    let (input, output, _log) = support::start();
    host.connect_lsp("rust", Box::new(input), output).unwrap();
    host
}

/// Handles server events until `done` says to stop.
fn pump(host: &Host, mut done: impl FnMut(&Host) -> bool) {
    let events = host.lsp_events();
    while !done(host) {
        let event = events
            .recv_timeout(Duration::from_secs(5))
            .expect("server answered");
        host.handle_lsp(event).unwrap();
    }
}

#[test]
fn diagnostics_arrive_and_are_announced() {
    let h = host();
    h.load_str(
        "watch",
        "local kern = require('@kern')\nkern.on('lsp.diagnostics', function(ev)\n  local d = kern.lsp.diagnostics(ev.buffer)[1]\n  kern.echo(ev.buffer:slice(d.from, d.to) .. ': ' .. d.message)\nend)",
    )
    .unwrap();
    assert!(h.sync_lsp().is_empty());
    let mut messages = Vec::new();
    pump(&h, |h| {
        messages.extend(h.with_editor_mut(Editor::take_messages));
        !messages.is_empty()
    });
    assert_eq!(messages, ["bad: bad word"]);
}

#[test]
fn commands_wait_for_answers() {
    let h = host();
    h.load_str(
        "ask",
        r#"
        local kern = require("@kern")
        kern.command { name = "hover", run = function(ctx)
            local params = {
                textDocument = { uri = kern.lsp.uri(ctx.buffer) },
                position = kern.lsp.position(ctx.buffer, 4),
            }
            local result = kern.lsp.request(ctx.buffer, "textDocument/hover", params)
            kern.echo(result.contents)
            local _, err = kern.lsp.request(ctx.buffer, "fail", {})
            kern.echo("error: " .. err.message)
        end }
        "#,
    )
    .unwrap();
    h.sync_lsp();
    h.run("hover").unwrap();
    let mut messages = Vec::new();
    pump(&h, |h| {
        messages.extend(h.with_editor_mut(Editor::take_messages));
        messages.len() == 2
    });
    assert_eq!(messages, ["hover at 0:4", "error: nope"]);
}

#[test]
fn requests_need_a_server_and_a_command() {
    let h = host();
    let err = h
        .eval("require('@kern').lsp.request(require('@kern').view():buffer(), 'x', {})")
        .unwrap_err()
        .to_string();
    assert!(err.contains("can only be used in a command"), "{err}");

    h.with_editor_mut(|ed| {
        ed.open("file", "", Some("notes.txt".into()));
    });
    h.load_str(
        "ask",
        "local kern = require('@kern')\nkern.command { name = 'ask', run = function(ctx) kern.lsp.request(ctx.buffer, 'x', {}) end }",
    )
    .unwrap();
    let err = h.run("ask").unwrap_err().to_string();
    assert!(err.contains("no language server"), "{err}");
}

#[test]
fn server_settings_need_a_command() {
    let h = host();
    let err = h
        .eval("require('@kern').lsp.server({ language = 'rust', command = {} })")
        .unwrap_err()
        .to_string();
    assert!(err.contains("needs a command"), "{err}");
}

fn plugin(name: &str) -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../runtime/plugins")
        .join(name)
}

/// A host with the default lsp plugin loaded and the fake server connected.
fn with_plugin() -> Host {
    let h = host();
    h.load_dirs(&[plugin("core"), plugin("picker"), plugin("lsp")])
        .unwrap();
    h.sync_lsp();
    // Wait for the first diagnostics.
    pump(&h, |h| h.diagnostic_marks().values().any(|d| !d.is_empty()));
    h
}

fn cursor(h: &Host) -> usize {
    h.with_editor(|ed| ed.view(ed.main()).selection.primary().head)
}

fn move_cursor(h: &Host, pos: usize) {
    h.with_editor_mut(|ed| {
        let main = ed.main();
        ed.view_mut(main).selection = kern_text::Selection::point(pos);
    });
}

/// Presses keys, then handles server events until `done`.
fn press_and_wait(h: &Host, keys: &str, done: impl FnMut(&Host) -> bool) {
    h.press_keys(keys).unwrap();
    pump(h, done);
}

#[test]
fn the_lsp_plugin_shows_hover_text() {
    let h = with_plugin();
    move_cursor(&h, 4);
    press_and_wait(&h, "space k", |h| {
        h.with_editor(|ed| !ed.floats().is_empty())
    });
    let text = h.with_editor(|ed| {
        let float = ed.floats()[0].view;
        ed.buffer(ed.view(float).buffer).text().to_string()
    });
    assert_eq!(text, "hover at 0:4");
    h.press_keys("esc").unwrap();
    assert!(h.with_editor(|ed| ed.floats().is_empty()));
}

#[test]
fn the_lsp_plugin_goes_to_definitions_and_problems() {
    let h = with_plugin();
    press_and_wait(&h, "g d", |h| cursor(h) == 8);

    move_cursor(&h, 0);
    h.press_keys("] d").unwrap();
    assert_eq!(cursor(&h), 8);
    assert_eq!(
        h.with_editor_mut(Editor::take_messages)
            .last()
            .map(String::as_str),
        Some("error: bad word")
    );
    h.press_keys("] d").unwrap();
    assert_eq!(
        h.with_editor_mut(Editor::take_messages)
            .last()
            .map(String::as_str),
        Some("no more problems")
    );
    h.press_keys("[ d").unwrap();
    assert_eq!(cursor(&h), 8);
}
