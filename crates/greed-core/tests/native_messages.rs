use std::time::Duration;

use greed_core::luau::Host;
use greed_core::render::grid::screen_rows;
use greed_core::render::{Frame, Size};
use greed_core::server::{self, Connection, Input, Output};
use greed_core::{Editor, FIRST_CLIENT};
use greed_text::ClientId;

fn host() -> Host {
    let mut editor = Editor::new(FIRST_CLIENT);
    editor.open("file", "", None);
    Host::new(editor).unwrap()
}

#[test]
fn echoes_deliver_every_duplicate_and_whole_multiline_message_in_order() {
    let h = host();
    h.with_editor_mut(|ed| assert!(ed.add_client(ClientId(2))));
    h.eval(
        r"
        g = require('@greed')
        seen = {}
        g.on('message', function(event)
            assert(event.client == 2 and g.client.id() == 2)
            assert(event.level == nil)
            table.insert(seen, event.text)
            -- Exercise APIs borrowing the editor from inside the handler.
            assert(g.view():buffer():text() == '')
        end)
        ",
    )
    .unwrap();
    h.with_editor_mut(|ed| {
        ed.echo("native\nsecond line");
        ed.echo("duplicate");
    });
    h.eval("g.echo('duplicate'); g.echo('Lua', 42)").unwrap();
    let messages = h.with_editor_mut(Editor::take_messages);
    h.report_messages(Some(ClientId(2)), &messages).unwrap();
    assert_eq!(h.with_editor(Editor::client), FIRST_CLIENT);
    assert_eq!(
        h.eval("table.concat(seen, '|')").unwrap(),
        "native\nsecond line|duplicate|duplicate|Lua 42"
    );
    assert_eq!(
        h.with_editor(|ed| ed.recent_messages().map(str::to_owned).collect::<Vec<_>>()),
        messages
    );
    assert!(h.with_editor(|ed| ed.messages().is_empty()));
}

#[test]
fn failed_handlers_do_not_skip_other_handlers_or_later_messages() {
    let h = host();
    h.eval(
        r"
        g = require('@greed')
        seen = {}
        g.on('message', function(event)
            table.insert(seen, 'first:' .. event.text)
            error('broken observer')
        end)
        g.on('message', function(event)
            table.insert(seen, 'second:' .. event.text)
        end)
        ",
    )
    .unwrap();
    let messages = vec!["one".to_owned(), "two".to_owned()];
    let err = h
        .report_messages(Some(FIRST_CLIENT), &messages)
        .unwrap_err();
    assert!(err.to_string().contains("broken observer"), "{err}");
    assert_eq!(
        h.eval("table.concat(seen, '|')").unwrap(),
        "first:one|second:one|first:two|second:two"
    );
}

#[test]
fn handler_echoes_are_a_separate_batch_and_unsubscription_stops_delivery() {
    let h = host();
    h.eval(
        r"
        g = require('@greed')
        seen = {}
        handler = function(event)
            table.insert(seen, event.text)
            if event.text == 'first' then g.echo('deferred') end
        end
        g.on('message', handler)
        g.echo('first')
        ",
    )
    .unwrap();
    let first = h.with_editor_mut(Editor::take_messages);
    h.report_messages(Some(FIRST_CLIENT), &first).unwrap();
    assert_eq!(h.eval("table.concat(seen, '|')").unwrap(), "first");
    let deferred = h.with_editor_mut(Editor::take_messages);
    assert_eq!(deferred, ["deferred"]);
    h.report_messages(Some(FIRST_CLIENT), &deferred).unwrap();
    assert_eq!(h.eval("table.concat(seen, '|')").unwrap(), "first|deferred");
    h.eval("g.off('message', handler)").unwrap();
    h.report_message(Some(FIRST_CLIENT), "not heard", None)
        .unwrap();
    assert_eq!(h.eval("#seen").unwrap(), "2");
}

#[test]
fn unloaded_plugins_stop_receiving_messages_and_levels_are_not_invented() {
    let h = host();
    h.load_str(
        "observer",
        r"
        local g = require('@greed')
        g.on('message', function(event)
            assert(event.client == nil and event.level == 'error')
            g.view():buffer():edit(function(e) e:insert(0, event.text) end)
        end)
        ",
    )
    .unwrap();
    h.report_message(None, "failure", Some("error")).unwrap();
    h.unload("observer").unwrap();
    h.report_message(None, "not heard", Some("error")).unwrap();
    assert_eq!(
        h.with_editor(|ed| ed.buffer(ed.view(ed.focus()).buffer).text().to_string()),
        "failure"
    );
}

#[test]
fn cli_dispatches_messages_without_a_recipient_and_drains_deferred_echoes() {
    let h = host();
    h.load_str(
        "cli-observer",
        r"
        local g = require('@greed')
        g.on('message', function(event)
            assert(event.client == nil and event.level == nil)
            if event.text == 'first' then g.echo('second') end
        end)
        g.cli { name = 'messages', run = function() g.echo('first') return 'done' end }
        ",
    )
    .unwrap();
    let mut said = Vec::new();
    let returned = h
        .run_cli("messages", Vec::new(), &mut |text| {
            said.push(text.to_owned());
        })
        .unwrap();
    assert_eq!(returned.as_deref(), Some("done"));
    assert_eq!(said, ["first", "second"]);
}

fn next_frame(conn: &Connection) -> Frame {
    match conn
        .output
        .recv_timeout(Duration::from_secs(5))
        .expect("server answered")
    {
        Output::Frame(frame) => frame,
        other => panic!("expected frame, got {other:?}"),
    }
}

fn resize(conn: &Connection) {
    conn.input
        .send(Input::Resize(Size {
            width: 60,
            height: 2,
        }))
        .unwrap();
    next_frame(conn);
}

fn stop(conn: Connection) {
    conn.input.send(Input::Quit).unwrap();
    while conn.output.recv_timeout(Duration::from_secs(5)).unwrap() != Output::Exit {}
    conn.server.join().unwrap().unwrap();
}

#[test]
fn server_delivers_handler_echo_next_turn_without_more_input() {
    let conn = server::spawn(|| {
        let h = host();
        h.load_str(
            "deferred",
            r"
            local g = require('@greed')
            g.on('message', function(event)
                assert(event.client == g.client.id())
                if event.text == 'first' then
                    g.echo('second')
                elseif event.text == 'second' then
                    g.view():buffer():edit(function(e) e:insert(0, 'delivered') end)
                end
            end)
            g.command { name = 'begin', run = function() g.echo('first') end }
            ",
        )?;
        Ok(h)
    });
    resize(&conn);
    conn.input.send(Input::Run("begin".to_owned())).unwrap();
    loop {
        let frame = next_frame(&conn);
        if screen_rows(&frame)[0].text().contains("delivered") {
            break;
        }
    }
    stop(conn);
}

#[test]
fn server_preserves_ordinary_status_when_observer_fails() {
    let conn = server::spawn(|| {
        let h = host();
        h.load_str(
            "broken-observer",
            r"
            local g = require('@greed')
            g.on('message', function() error('observer failure') end)
            g.command { name = 'say', run = function() g.echo('ordinary status') end }
            ",
        )?;
        Ok(h)
    });
    resize(&conn);
    conn.input.send(Input::Run("say".to_owned())).unwrap();
    assert!(
        screen_rows(&next_frame(&conn))[1]
            .text()
            .contains("ordinary status")
    );
    stop(conn);
}

#[test]
fn server_direct_errors_report_known_level_and_recipient() {
    let conn = server::spawn(|| {
        let h = host();
        h.load_str(
            "errors",
            r"
            local g = require('@greed')
            g.on('message', function(event)
                assert(event.level == 'error' and event.client == g.client.id())
                assert(event.text == 'client failure')
                g.view():buffer():edit(function(e) e:insert(0, 'heard') end)
            end)
            ",
        )?;
        Ok(h)
    });
    resize(&conn);
    conn.input
        .send(Input::Problem("client failure".to_owned()))
        .unwrap();
    let frame = next_frame(&conn);
    assert!(screen_rows(&frame)[0].text().contains("heard"));
    assert!(screen_rows(&frame)[1].text().contains("client failure"));
    stop(conn);
}
