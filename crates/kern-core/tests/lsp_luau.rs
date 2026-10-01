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

#[test]
fn the_lsp_plugin_marks_problems_with_signs_and_messages() {
    use kern_core::render::{CellWidth, Plain, Renderer, Size, Status};
    let h = with_plugin();
    let marks = |h: &Host| -> Vec<(Option<String>, Option<String>)> {
        h.with_editor(|ed| {
            ed.buffer(ed.view(ed.main()).buffer)
                .marks("lsp")
                .iter()
                .map(|m| {
                    (
                        m.sign.as_deref().map(str::to_owned),
                        m.text.as_deref().map(str::to_owned),
                    )
                })
                .collect()
        })
    };
    assert_eq!(
        marks(&h),
        [
            (Some("E".to_owned()), None),
            (None, Some("bad word".to_owned()))
        ]
    );
    let row = h.with_editor_mut(|ed| {
        let size = Size {
            width: 40,
            height: 2,
        };
        let status = Status::Default { message: None };
        Renderer::new(CellWidth)
            .frame(ed, size, &status, &Plain)
            .rows[0]
            .text()
    });
    assert_eq!(row, "E 1 let x = bad; bad word");

    h.eval("require('@kern').option.set('diagnostic-messages', false)")
        .unwrap();
    assert_eq!(
        marks(&h),
        [(Some("E".to_owned()), None)],
        "turning messages off takes them away at once"
    );
}

#[test]
fn empty_answers_from_the_server_say_so_instead_of_failing() {
    let h = with_plugin();
    let said = |h: &Host| h.with_editor_mut(Editor::take_messages);
    // The end of the line: past the "bad word" problem, where the server
    // has nothing to say.
    move_cursor(&h, 12);
    press_and_wait(&h, "g d", |h| h.with_editor(|ed| !ed.messages().is_empty()));
    assert_eq!(
        said(&h).last().map(String::as_str),
        Some("no definition found")
    );
    assert_eq!(cursor(&h), 12, "it stays where it was");

    press_and_wait(&h, "space k", |h| {
        h.with_editor(|ed| !ed.messages().is_empty())
    });
    assert_eq!(
        said(&h).last().map(String::as_str),
        Some("nothing to show here")
    );
    assert!(
        h.with_editor(|ed| ed.floats().is_empty()),
        "no empty window"
    );
}

#[test]
fn the_status_line_counts_errors_and_warnings() {
    let h = with_plugin();
    h.load_dirs(&[plugin("statusline")]).unwrap();
    let line = h
        .status_line(None, 80)
        .unwrap()
        .expect("the plugin builds one");
    let right: String = line.right.iter().map(|s| s.text.as_str()).collect();
    assert!(right.starts_with("E1 "), "{right}");
    assert!(!right.contains('W'), "no warnings: {right}");
}

/// The lines of the completion menu, if it's open.
fn completion_menu(h: &Host) -> Option<Vec<String>> {
    h.with_editor(|ed| {
        ed.floats().iter().find_map(|f| {
            let buffer = ed.buffer(ed.view(f.view).buffer);
            (buffer.kind() == "completion").then(|| {
                buffer
                    .text()
                    .to_string()
                    .lines()
                    .map(str::trim)
                    .map(str::to_owned)
                    .collect()
            })
        })
    })
}

fn main_text(h: &Host) -> String {
    h.with_editor(|ed| ed.buffer(ed.view(ed.main()).buffer).text().to_string())
}

/// Lets the typing pause run out, then waits for the server's answer.
fn pause_and_wait(h: &Host) {
    while let Some(due) = h.next_timer() {
        h.fire_timers(due).unwrap();
    }
    pump(h, |h| completion_menu(h).is_some());
}

#[test]
fn completions_show_as_you_type_and_narrow_as_you_go() {
    let h = with_plugin();
    move_cursor(&h, 12);
    h.press_keys("i space b a").unwrap();
    pause_and_wait(&h);
    let menu = completion_menu(&h).unwrap();
    assert!(
        menu.iter()
            .any(|l| l.starts_with("bad_thing") && l.ends_with("fn()")),
        "items show their detail: {menu:?}"
    );
    assert!(menu.iter().any(|l| l == "badge"), "{menu:?}");
    assert!(
        !menu.iter().any(|l| l.starts_with("other")),
        "only what matches: {menu:?}"
    );
    h.press_keys("d g").unwrap();
    assert_eq!(
        completion_menu(&h).unwrap()[0],
        "badge",
        "typing narrows it"
    );
    h.press_keys("enter").unwrap();
    assert_eq!(main_text(&h), "let x = bad; badge");
    assert!(completion_menu(&h).is_none(), "taking one closes the menu");
    assert_eq!(h.with_editor(|ed| ed.mode().to_owned()), "insert");
}

#[test]
fn tab_moves_through_completions_and_esc_closes_them_and_insert_mode() {
    let h = with_plugin();
    move_cursor(&h, 12);
    h.press_keys("i space s n").unwrap();
    pause_and_wait(&h);
    h.press_keys("enter").unwrap();
    assert_eq!(
        main_text(&h),
        "let x = bad; snip(x)",
        "snippets go in as plain text"
    );

    h.press_keys("space b").unwrap();
    pause_and_wait(&h);
    let first = completion_menu(&h).unwrap()[0].clone();
    h.press_keys("tab shift-tab tab").unwrap();
    h.press_keys("esc").unwrap();
    assert!(completion_menu(&h).is_none());
    assert_eq!(
        h.with_editor(|ed| ed.mode().to_owned()),
        "normal",
        "esc also leaves insert"
    );
    assert!(main_text(&h).ends_with(" b"), "nothing was put in: {first}");
}
