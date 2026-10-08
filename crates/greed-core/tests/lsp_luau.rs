//! Language servers through the Luau API, against the fake server.

mod support;

use std::time::Duration;

use greed_core::Editor;
use greed_core::luau::Host;
use greed_text::ClientId;

fn host() -> Host {
    let mut editor = Editor::new(ClientId(1));
    editor.open(
        "file",
        "let x = bad;",
        Some(std::env::temp_dir().join("greed-lsp-luau/main.rs")),
    );
    let host = Host::new(editor).unwrap();
    support::serve_rust(&host);
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
        "local greed = require('@greed')\ngreed.on('lsp.diagnostics', function(ev)\n  local d = greed.lsp.diagnostics(ev.buffer)[1]\n  greed.echo(ev.buffer:slice(d.from, d.to) .. ': ' .. d.message)\nend)",
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
        local greed = require("@greed")
        greed.command { name = "hover", run = function(ctx)
            local params = {
                textDocument = { uri = greed.lsp.uri(ctx.buffer) },
                position = greed.lsp.position(ctx.buffer, 4),
            }
            local result = greed.lsp.request(ctx.buffer, "textDocument/hover", params)
            greed.echo(result.contents)
            local _, err = greed.lsp.request(ctx.buffer, "fail", {})
            greed.echo("error: " .. err.message)
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
fn a_command_waiting_on_a_server_that_stops_gets_an_error() {
    let h = host();
    h.load_str(
        "ask",
        r#"
        local greed = require("@greed")
        greed.command { name = "ask", run = function(ctx)
            local result, err = greed.lsp.request(ctx.buffer, "die", {})
            greed.echo(`{result} {err.code} {err.message}`)
        end }
        "#,
    )
    .unwrap();
    h.sync_lsp();
    h.run("ask").unwrap();
    let mut messages = Vec::new();
    pump(&h, |h| {
        messages.extend(h.with_editor_mut(Editor::take_messages));
        !messages.is_empty()
    });
    assert_eq!(messages, ["nil -32603 the language server stopped"]);
}

#[test]
fn requests_need_a_server_and_a_command() {
    let h = host();
    let err = h
        .eval("require('@greed').lsp.request(require('@greed').view():buffer(), 'x', {})")
        .unwrap_err()
        .to_string();
    assert!(err.contains("can only be used in a command"), "{err}");

    h.with_editor_mut(|ed| {
        ed.open("file", "", Some("notes.txt".into()));
    });
    h.load_str(
        "ask",
        "local greed = require('@greed')\ngreed.command { name = 'ask', run = function(ctx) greed.lsp.request(ctx.buffer, 'x', {}) end }",
    )
    .unwrap();
    let err = h.run("ask").unwrap_err().to_string();
    assert!(err.contains("no language server"), "{err}");
}

#[test]
fn server_settings_need_a_command() {
    let h = host();
    let err = h
        .eval("require('@greed').lsp.server({ language = 'rust', command = {} })")
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
    h.load_dirs(&[
        plugin("core"),
        plugin("helix"),
        plugin("picker"),
        plugin("multibuffer"),
        plugin("statusline"),
        plugin("lsp"),
    ])
    .unwrap();
    h.sync_lsp();
    // Wait for the first diagnostics.
    pump(&h, support::has_diagnostics);
    // What loading said, like that it took a while on a busy machine, isn't
    // what the tests look at.
    h.with_editor_mut(Editor::take_messages);
    h
}

fn cursor(h: &Host) -> usize {
    h.with_editor(|ed| ed.view(ed.main()).selection.primary().head)
}

fn move_cursor(h: &Host, pos: usize) {
    h.with_editor_mut(|ed| {
        let main = ed.main();
        ed.view_mut(main).selection = greed_text::Selection::point(pos);
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
    use greed_core::render::{CellWidth, Plain, Renderer, Size, Status};
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
        let frame = Renderer::new(CellWidth).frame(ed, size, &status, &Plain);
        greed_core::render::grid::text_rows(&frame).swap_remove(0)
    });
    assert_eq!(row, "E 1 let x = bad; bad word");

    h.eval("require('@greed').option.set('diagnostic-messages', false)")
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
    assert!(right.trim_start().starts_with("E1 "), "{right}");
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
    assert_eq!(h.with_editor(|ed| ed.mode().to_owned()), "helix-insert");
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
        "helix",
        "esc also leaves insert"
    );
    assert!(main_text(&h).ends_with(" b"), "nothing was put in: {first}");
}

#[test]
fn without_a_formatter_the_language_server_formats() {
    let h = with_plugin();
    h.load_dirs(&[plugin("languages"), plugin("format")])
        .unwrap();
    // No formatter program for Rust here, so the server's turn.
    h.eval("require('@languages').set('rust', { formatter = {} })")
        .unwrap();
    h.run("format").unwrap();
    pump(&h, |h| main_text(h).starts_with("// formatted\n"));
    assert_eq!(main_text(&h), "// formatted\nlet x = bad;");
}

/// The items of the open picker, if there is one.
fn picker_items(h: &Host) -> Option<Vec<String>> {
    h.with_editor(|ed| {
        ed.floats().iter().find_map(|f| {
            let buffer = ed.buffer(ed.view(f.view).buffer);
            (buffer.kind() == "picker").then(|| {
                buffer
                    .text()
                    .to_string()
                    .lines()
                    .skip(1)
                    .map(|l| l.trim().to_owned())
                    .collect()
            })
        })
    })
}

#[test]
fn rename_starts_from_the_name_and_changes_it_where_the_server_says() {
    let h = with_plugin();
    move_cursor(&h, 9);
    press_and_wait(&h, "space r", |h| {
        h.with_editor(|ed| {
            ed.floats()
                .iter()
                .any(|f| ed.buffer(ed.view(f.view).buffer).kind() == "prompt")
        })
    });
    let prompt = h.with_editor(|ed| {
        let float = ed.floats()[0].view;
        ed.buffer(ed.view(float).buffer).text().to_string()
    });
    assert_eq!(prompt, "bad", "it starts from the server's name");
    press_and_wait(&h, "backspace backspace backspace g o o d enter", |h| {
        main_text(h) == "let x = good;"
    });
}

#[test]
fn references_are_listed_and_taken_to() {
    let h = with_plugin();
    move_cursor(&h, 9);
    press_and_wait(&h, "g r", |h| picker_items(h).is_some());
    let items = picker_items(&h).unwrap();
    assert_eq!(items.len(), 2, "{items:?}");
    assert!(
        items.iter().all(|i| i.ends_with("main.rs:1: let x = bad;")),
        "{items:?}"
    );
    h.press_keys("enter").unwrap();
    assert_eq!(cursor(&h), 4, "the first, in order");
}

#[test]
fn code_actions_apply_edits_run_commands_and_resolve() {
    let h = with_plugin();
    move_cursor(&h, 9);
    press_and_wait(&h, "space a", |h| picker_items(h).is_some());
    let items = picker_items(&h).unwrap();
    assert_eq!(
        items,
        ["Make it good (1 known)", "Shout", "Add a comment"],
        "the preferred one first; the problem here goes along"
    );
    h.press_keys("enter").unwrap();
    assert_eq!(main_text(&h), "let x = good;");

    // A command: the server sends the edit back to apply.
    press_and_wait(&h, "space a", |h| picker_items(h).is_some());
    press_and_wait(&h, "s h o u t enter", |h| main_text(h) == "LET x = good;");

    // An action without its edit yet: it's asked for.
    press_and_wait(&h, "space a", |h| picker_items(h).is_some());
    press_and_wait(&h, "c o m m e n t enter", |h| {
        main_text(h) == "// resolved\nLET x = good;"
    });
}

#[test]
fn the_problems_list_has_files_that_are_not_open() {
    let h = with_plugin();
    pump(&h, |h| {
        h.eval("return #require('@greed').lsp.problems()").unwrap() == "2"
    });
    h.press_keys("space D").unwrap();
    let items = picker_items(&h).unwrap();
    assert_eq!(items.len(), 2, "{items:?}");
    assert!(
        items[0].ends_with("main.rs:1: error: bad word"),
        "errors first: {items:?}"
    );
    assert!(
        items[1].ends_with("other.rs:3: warning: unused thing"),
        "{items:?}"
    );
}

/// The open multibuffer's text, the text its found marks cover with their
/// styles, and its header notes, as Luau sees them.
fn multibuffer(h: &Host) -> String {
    h.eval(
        r#"
        local greed = require("@greed")
        for _, b in greed.buffers() do
            if b:kind() == "multibuffer" then
                local text = b:text()
                local out = { text }
                for _, m in b:decorations("multibuffer.found") do
                    table.insert(out, `{string.sub(text, m.from + 1, m.to)}={m.style}`)
                end
                for _, m in b:decorations("multibuffer.headers") do
                    local pieces = (m.lines :: { any })[2]
                    table.insert(out, if pieces[2] then pieces[2].text else "-")
                end
                return table.concat(out, "|")
            end
        end
        return "none"
        "#,
    )
    .unwrap()
}

#[test]
fn ctrl_e_puts_references_in_a_multibuffer() {
    let h = with_plugin();
    move_cursor(&h, 9);
    press_and_wait(&h, "g r", |h| picker_items(h).is_some());
    h.press_keys("ctrl-e").unwrap();
    assert_eq!(
        multibuffer(&h),
        "2 references\nlet x = bad;\n|x=ui.search.match|bad=ui.search.match|-"
    );
}

#[test]
fn ctrl_e_puts_problems_in_a_multibuffer_with_their_messages() {
    // The other file's problem is read from disk.
    let dir = std::env::temp_dir().join("greed-lsp-luau");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("other.rs"), "fn a() {}\n\nunused();\n").unwrap();
    let h = with_plugin();
    pump(&h, |h| {
        h.eval("return #require('@greed').lsp.problems()").unwrap() == "2"
    });
    h.press_keys("space D ctrl-e").unwrap();
    assert_eq!(
        multibuffer(&h),
        "2 problems\nlet x = bad;\nunused();\n\
         |bad=diagnostic.error|unuse=diagnostic.warning\
         |  error: bad word|  warning: unused thing"
    );
}

/// The signature help window's text and the part picked out, if it's open.
fn signature(h: &Host) -> Option<(String, String)> {
    h.with_editor(|ed| {
        ed.floats().iter().find_map(|f| {
            let buffer = ed.buffer(ed.view(f.view).buffer);
            (buffer.kind() == "signature").then(|| {
                let text = buffer.text().to_string();
                let active = buffer
                    .marks("signature")
                    .first()
                    .map(|m| text[m.range.clone()].to_owned())
                    .unwrap_or_default();
                (text, active)
            })
        })
    })
}

#[test]
fn signature_help_follows_the_parameter_being_typed_and_closes_after_the_call() {
    let h = with_plugin();
    move_cursor(&h, 12);
    press_and_wait(&h, "i space a d d (", |h| signature(h).is_some());
    assert_eq!(
        signature(&h).unwrap(),
        ("fn add(a: i32, b: i32)".to_owned(), "a: i32".to_owned())
    );
    press_and_wait(&h, "1 ,", |h| {
        signature(h).is_some_and(|(_, active)| active == "b: i32")
    });
    press_and_wait(&h, "space 2 )", |h| signature(h).is_none());

    press_and_wait(&h, "space f (", |h| signature(h).is_some());
    h.press_keys("esc").unwrap();
    assert!(signature(&h).is_none(), "leaving insert mode closes it");
}

#[test]
fn a_server_asking_to_pick_waits_for_the_picker_and_hears_the_answer() {
    let h = with_plugin();
    h.load_str(
        "ask",
        r#"
        local greed = require("@greed")
        greed.command { name = "ask-server", run = function(ctx)
            greed.lsp.request(ctx.buffer, "workspace/executeCommand", { command = "ask" })
        end }
        "#,
    )
    .unwrap();
    h.run("ask-server").unwrap();
    pump(&h, |h| picker_items(h).is_some());
    assert_eq!(picker_items(&h).unwrap(), ["Yes", "No"]);
    h.press_keys("down enter").unwrap();
    pump(&h, |h| main_text(h).starts_with("No"));
    assert_eq!(main_text(&h), "No x = bad;");
}

#[test]
fn notifications_reach_the_plugins_listening_with_the_servers_language_and_root() {
    let h = host();
    h.load_str(
        "listen",
        "local greed = require('@greed')\ngreed.lsp.on_notification('$/progress', function(params, language, root)\n  greed.echo(`{language} {params.token} {params.value.kind} {root == greed.lsp.root(greed.view():buffer())}`)\nend)",
    )
    .unwrap();
    h.sync_lsp();
    let mut messages = Vec::new();
    pump(&h, |h| {
        messages.extend(h.with_editor_mut(Editor::take_messages));
        messages.len() == 2
    });
    assert_eq!(messages, ["rust index begin true", "rust index end true"]);
}

/// A folder with two Rust projects, `a` and `b`, each with a Cargo.toml.
fn two_projects(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("greed-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    for project in ["a", "b"] {
        std::fs::create_dir_all(dir.join(project)).unwrap();
        std::fs::write(dir.join(project).join("Cargo.toml"), "").unwrap();
    }
    dir
}

#[test]
fn each_projects_buffers_show_their_own_servers_root_and_work() {
    let dir = two_projects("lsp-status");
    let mut editor = Editor::new(ClientId(1));
    for project in ["a", "b"] {
        editor.open(
            "file",
            "let x = bad;",
            Some(dir.join(project).join("main.rs")),
        );
    }
    let h = Host::new(editor).unwrap();
    support::serve_rust(&h);
    h.load_dirs(&[
        plugin("core"),
        plugin("helix"),
        plugin("picker"),
        plugin("multibuffer"),
        plugin("statusline"),
        plugin("lsp"),
    ])
    .unwrap();
    // Before any server runs, where they would.
    let roots = r#"
        local greed = require("@greed")
        local status = require("@lsp").status
        local out = {}
        for _, b in greed.buffers() do
            local project = b:path() and string.match(b:path(), "/(%w)/main.rs$")
            if project then
                table.insert(out, `{project} {greed.lsp.root(b)} {status.text(b)}`)
            end
        end
        table.sort(out)
        return table.concat(out, ", ")
    "#;
    let (a, b) = (
        dir.join("a").display().to_string(),
        dir.join("b").display().to_string(),
    );
    assert_eq!(
        h.eval(roots).unwrap(),
        format!("a {a} sh starting, b {b} sh starting")
    );
    h.sync_lsp();
    pump(&h, |h| {
        h.with_editor(|ed| {
            ed.buffers()
                .filter(|b| !b.marks(greed_core::lsp::DIAGNOSTICS).is_empty())
                .count()
                == 2
        })
    });
    assert_eq!(h.eval(roots).unwrap(), format!("a {a} sh, b {b} sh"));
    let running = h
        .eval("local out = {}\nfor _, s in require('@greed').lsp.running() do table.insert(out, `{s.language} {s.root} {s.command[1]} {s.ready}`) end\nreturn table.concat(out, ', ')")
        .unwrap();
    assert_eq!(running, format!("rust {a} sh true, rust {b} sh true"));

    // Work a's server reports shows on a's buffers only.
    h.eval(&format!(
        "local status = require('@lsp').status\nstatus.progress(status.key('rust', '{a}'), {{ token = 1, value = {{ kind = 'begin', title = 'Indexing' }} }})"
    ))
    .unwrap();
    assert_eq!(
        h.eval(roots).unwrap(),
        format!("a {a} sh: indexing, b {b} sh")
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

/// A host with the lsp and agent plugins, and a "probe" plugin whose
/// `call(tool, args)` runs an agent tool in the background and keeps what
/// it said in `out`.
fn with_agent() -> Host {
    let h = host();
    h.load_dirs(&[
        plugin("core"),
        plugin("helix"),
        plugin("picker"),
        plugin("terminal"),
        plugin("multibuffer"),
        plugin("operations"),
        plugin("approvals"),
        plugin("describe"),
        plugin("markdown"),
        plugin("models"),
        plugin("agent"),
        plugin("statusline"),
        plugin("lsp"),
    ])
    .unwrap();
    // The file is outside the project, so the agent names it in full.
    let dir = std::env::temp_dir().join("greed-lsp-luau");
    let dir = dir.display().to_string();
    h.load_str(
        "probe",
        &format!(
            r#"
        local greed = require("@greed")
        local agent = require("@agent")
        local probe = {{}}
        function probe.call(name, args)
            if args.path then
                args.path = "{dir}/" .. args.path
            end
            for _, tool in agent.tools() do
                if tool.name == name then
                    greed.spawn(function()
                        local ok, out = pcall(tool.run, args, agent.caller())
                        probe.out = if ok then out else "error: " .. tostring(out)
                    end)
                end
            end
        end
        return probe
        "#
        ),
    )
    .unwrap();
    h.sync_lsp();
    pump(&h, support::has_diagnostics);
    h
}

fn probe_out(h: &Host) -> Option<String> {
    let out = h.eval("require('@probe').out").unwrap();
    (out != "nil").then_some(out)
}

fn pending(h: &Host) -> String {
    h.eval("require('@agent').pending()").unwrap()
}

#[test]
fn an_agent_renames_through_the_server_as_a_proposal() {
    let h = with_agent();
    h.eval(r#"require("@probe").call("rename", { path = "main.rs", line = 1, name = "bad", new_name = "good" })"#)
        .unwrap();
    pump(&h, |h| pending(h) != "0");
    assert_eq!(
        main_text(&h),
        "let x = bad;",
        "nothing changes before it's accepted"
    );
    accept_and_wait(&h);
    assert_eq!(main_text(&h), "let x = good;");
    let out = probe_out(&h).unwrap();
    assert!(out.starts_with("accepted 1 of 1 changes"), "{out}");
    assert!(
        out.ends_with("the language server reports no errors or warnings in main.rs"),
        "it heard what the server made of it: {out}"
    );
}

#[test]
fn an_agent_hears_the_errors_its_accepted_change_made() {
    let h = with_agent();
    h.eval(r#"require("@probe").call("propose", { path = "main.rs", edits = { { old_text = "let x", new_text = "let bad" } } })"#)
        .unwrap();
    pump(&h, |h| pending(h) != "0" || probe_out(h).is_some());
    accept_and_wait(&h);
    let out = probe_out(&h).unwrap();
    assert!(out.contains("\nmain.rs:1: error: bad word"), "{out}");
}

#[test]
fn an_agent_rename_needs_the_name_on_that_line() {
    let h = with_agent();
    h.eval(r#"require("@probe").call("rename", { path = "main.rs", line = 1, name = "ba", new_name = "x" })"#)
        .unwrap();
    let out = probe_out(&h).unwrap();
    assert!(out.contains("ba isn't on line 1"), "{out}");
}

#[test]
fn an_agent_lists_code_actions_and_proposes_one_by_title() {
    let h = with_agent();
    h.eval(r#"require("@probe").call("code_actions", { path = "main.rs", line = 1 })"#)
        .unwrap();
    pump(&h, |h| probe_out(h).is_some());
    assert_eq!(
        probe_out(&h).unwrap(),
        "Shout\nMake it good (1 known) (quickfix), preferred\nAdd a comment"
    );

    // One that needs resolving first.
    h.eval(r#"require("@probe").out = nil; require("@probe").call("code_action", { path = "main.rs", line = 1, title = "Add a comment" })"#)
        .unwrap();
    pump(&h, |h| pending(h) != "0" || probe_out(h).is_some());
    assert_eq!(probe_out(&h), None, "it waits for the user");
    accept_and_wait(&h);
    assert_eq!(main_text(&h), "// resolved\nlet x = bad;");
    assert!(probe_out(&h).unwrap().starts_with("accepted 1 of 1"));
}

#[test]
fn an_agent_code_action_that_runs_a_command_is_refused() {
    let h = with_agent();
    h.eval(
        r#"require("@probe").call("code_action", { path = "main.rs", line = 1, title = "Shout" })"#,
    )
    .unwrap();
    pump(&h, |h| probe_out(h).is_some());
    let out = probe_out(&h).unwrap();
    assert!(
        out.contains("runs a command in the language server"),
        "{out}"
    );
    assert_eq!(main_text(&h), "let x = bad;");
}

/// Accepts every proposed change, sends the edit to the server, and waits
/// for the tool, which waits for what the server makes of it.
fn accept_and_wait(h: &Host) {
    h.press_keys("space o A").unwrap();
    h.sync_lsp();
    pump(h, |h| probe_out(h).is_some());
}
