mod support;

use std::time::Duration;

use greed_core::Editor;
use greed_core::luau::Host;
use greed_text::ClientId;

#[test]
fn current_background_parse_emits_once_without_input() {
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", "fn main() {}", Some("main.rs".into()));
    let host = Host::new(editor).unwrap();
    host.load_str(
        "syntax-listener",
        r#"
local greed = require("@greed")
greed.on("syntax.updated", function(event)
    assert(event.buffer:id() == greed.view():buffer():id())
    greed.echo("syntax current")
end)
"#,
    )
    .unwrap();
    host.update_syntax();
    let parsed = host.parses().recv_timeout(Duration::from_secs(5)).unwrap();
    assert!(host.receive_parse(parsed));
    assert_eq!(
        host.with_editor_mut(greed_core::Editor::take_messages),
        vec!["syntax current"]
    );
    host.update_syntax();
    assert!(host.parses().try_recv().is_err());
}

#[test]
fn obsolete_background_parse_does_not_report_current_syntax() {
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", "fn main() {}", Some("main.rs".into()));
    let host = Host::new(editor).unwrap();
    host.load_str(
        "syntax-listener",
        r#"
local greed = require("@greed")
greed.on("syntax.updated", function() greed.echo("unexpected") end)
"#,
    )
    .unwrap();
    host.update_syntax();
    let parsed = host.parses().recv_timeout(Duration::from_secs(5)).unwrap();
    host.eval(
        "require('@greed').view():buffer():edit(function(e) e:insert(0, '// changed\\n') end)",
    )
    .unwrap();
    assert!(!host.receive_parse(parsed));
    assert!(
        host.with_editor_mut(greed_core::Editor::take_messages)
            .is_empty()
    );
}

#[test]
fn host_dispatches_readiness_and_attachment_for_each_open_document() {
    let path = std::env::temp_dir().join("greed-event-test/main.rs");
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", "fn main() {}", Some(path.clone()));
    let host = Host::new(editor).unwrap();
    let (launcher, _) = support::launcher_with(support::Options::default());
    host.set_lsp_launcher(launcher);
    host.eval(
        r"
        local g = require('@greed')
        ready = 0
        attached = {}
        g.lsp.server { language = 'rust', command = {'fake'}, reads_only = true }
        g.on('lsp.ready', function(event)
            assert(event.language == 'rust')
            ready += 1
        end)
        g.on('lsp.attached', function(event)
            table.insert(attached, event.buffer:id())
        end)
    ",
    )
    .unwrap();
    assert!(host.sync_lsp().is_empty());
    while host.eval("ready").unwrap() == "0" {
        let event = host
            .lsp_events()
            .recv_timeout(Duration::from_secs(5))
            .unwrap();
        host.handle_lsp(event).unwrap();
    }
    assert!(host.sync_lsp().is_empty());
    assert_eq!(host.eval("#attached").unwrap(), "1");
    host.with_editor_mut(|editor| {
        editor.open(
            "file",
            "fn second() {}",
            Some(path.with_file_name("second.rs")),
        );
    });
    assert!(host.sync_lsp().is_empty());
    assert_eq!(host.eval("#attached").unwrap(), "2");
    assert_eq!(host.eval("ready").unwrap(), "1");
    assert_eq!(host.eval("attached[1] ~= attached[2]").unwrap(), "true");
    assert!(host.sync_lsp().is_empty());
    assert_eq!(host.eval("#attached").unwrap(), "2");
}

#[test]
fn attachment_callback_nested_coroutine_is_budgeted_and_host_recovers() {
    let mut editor = Editor::new(ClientId(1));
    editor.open(
        "file",
        "fn main() {}",
        Some(std::env::temp_dir().join("greed-budget/main.rs")),
    );
    let host = Host::new(editor).unwrap();
    host.set_budget(Duration::from_millis(50));
    let (launcher, _) = support::launcher_with(support::Options::default());
    host.set_lsp_launcher(launcher);
    host.eval(
        r"
        local g = require('@greed')
        ready = false
        g.lsp.server { language = 'rust', command = {'fake'}, reads_only = true }
        g.on('lsp.ready', function() ready = true end)
        g.on('lsp.attached', function()
            local ok, err = coroutine.resume(coroutine.create(function()
                while true do end
            end))
            assert(ok, err)
        end)
    ",
    )
    .unwrap();
    host.sync_lsp();
    while host.eval("ready").unwrap() == "false" {
        let event = host
            .lsp_events()
            .recv_timeout(Duration::from_secs(5))
            .unwrap();
        host.handle_lsp(event).unwrap();
    }
    let started = std::time::Instant::now();
    let errors = host.sync_lsp();
    assert!(!errors.is_empty(), "the callback must report its deadline");
    assert!(started.elapsed() < Duration::from_secs(5));
    assert_eq!(host.eval("1 + 1").unwrap(), "2");
    assert!(host.sync_lsp().is_empty(), "attachment is not retried");
}

#[test]
fn parse_without_handlers_remains_parse_only() {
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", "fn main() {}", Some("main.rs".into()));
    let host = Host::new(editor).unwrap();
    host.update_syntax();
    let parsed = host.parses().recv_timeout(Duration::from_secs(5)).unwrap();
    assert!(!host.receive_parse(parsed));
}

#[test]
fn idle_attachment_edit_and_parse_status_reach_frames_without_more_input() {
    use greed_core::render::{Size, grid::screen_rows};
    use greed_core::server::{self, Input, Output};
    let conn = server::spawn(|| {
        let mut editor = Editor::new(ClientId(1));
        editor.open(
            "file",
            "fn main() {}",
            Some(std::env::temp_dir().join("greed-idle/main.rs")),
        );
        let host = Host::new(editor)?;
        let (launcher, _) = support::launcher_with(support::Options::default());
        host.set_lsp_launcher(launcher);
        host.load_str(
            "idle-events",
            r"
            local g = require('@greed')
            local status = 'before'
            g.statusline(function() return { left = {status}, right = {} } end)
            g.command { name = 'attach-now', run = function()
                g.on('syntax.updated', function() status = 'parsed attachment' end)
                g.on('lsp.attached', function(event)
                    status = 'attached'
                    event.buffer:edit(function(e) e:insert(0, '// attached\n') end)
                end)
                g.lsp.server { language = 'rust', command = {'fake'}, reads_only = true }
            end }
        ",
        )?;
        Ok(host)
    });
    conn.input
        .send(Input::Resize(Size {
            width: 60,
            height: 5,
        }))
        .unwrap();
    loop {
        if let Output::Frame(_) = conn.output.recv_timeout(Duration::from_secs(5)).unwrap() {
            break;
        }
    }
    conn.input.send(Input::Run("attach-now".into())).unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        let output = conn
            .output
            .recv_timeout(deadline.saturating_duration_since(std::time::Instant::now()))
            .unwrap();
        if let Output::Frame(frame) = output {
            let rows = screen_rows(&frame);
            if rows[0].text().contains("// attached")
                && rows
                    .iter()
                    .any(|row| row.text().contains("parsed attachment"))
            {
                break;
            }
        }
    }
    conn.input.send(Input::Quit).unwrap();
}
