//! Plugins own what they make: unloading one takes it all away, and
//! reloading one doesn't leave the old copy running.

use std::path::Path;
use std::time::{Duration, Instant};

use greed_core::Editor;
use greed_core::image::ImageId;
use greed_core::luau::Host;
use greed_text::ClientId;

fn host() -> Host {
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", "hello world", None);
    Host::new(editor).unwrap()
}

fn messages(h: &Host) -> Vec<String> {
    h.with_editor_mut(Editor::take_messages)
}

/// Lets `ms` pass on the editor's clock, a timer at a time.
fn pass(h: &Host, start: Instant, ms: u64) {
    let until = start + Duration::from_millis(ms);
    while let Some(at) = h.next_timer().filter(|at| *at <= until) {
        h.fire_timers(at).unwrap();
    }
}

const TICKER: &str = r#"
local greed = require("@greed")
greed.spawn(function()
  while true do
    greed.sleep(100)
    greed.echo("tick")
  end
end)
"#;

#[test]
fn unloading_stops_a_plugins_tasks() {
    let h = host();
    let start = Instant::now();
    h.load_str("ticker", TICKER).unwrap();
    pass(&h, start, 250);
    assert_eq!(messages(&h), ["tick", "tick"]);
    h.unload("ticker").unwrap();
    assert!(h.next_timer().is_none());
    pass(&h, start, 1000);
    assert!(messages(&h).is_empty());
}

#[test]
fn reloading_doesnt_double_a_plugins_tasks() {
    let h = host();
    let start = Instant::now();
    h.load_str("ticker", TICKER).unwrap();
    h.reload("ticker").unwrap();
    h.load_str("ticker", TICKER).unwrap();
    pass(&h, start, 150);
    assert_eq!(messages(&h), ["tick"]);
}

#[test]
fn unloading_stops_commands_and_handlers_mid_wait_and_wakes_their_waiters() {
    let h = host();
    let start = Instant::now();
    h.load_str(
        "slow",
        r#"
        local greed = require("@greed")
        greed.command { name = "slow", run = function()
          greed.sleep(100)
          greed.echo("slow done")
        end }
        greed.on("buffer.changed", function()
          greed.sleep(100)
          greed.echo("handler done")
        end)
        "#,
    )
    .unwrap();
    h.load_str(
        "caller",
        r#"
        local greed = require("@greed")
        greed.command { name = "call-slow", run = function()
          greed.run("slow", { wait = true })
          greed.echo("caller carried on")
        end }
        "#,
    )
    .unwrap();
    h.run("call-slow").unwrap();
    h.eval("require('@greed').view():buffer():edit(function(e) e:insert(0, 'x') end)")
        .unwrap();
    h.unload("slow").unwrap();
    assert_eq!(messages(&h), ["caller carried on"]);
    pass(&h, start, 1000);
    assert!(messages(&h).is_empty());
}

#[test]
fn a_command_that_unloads_its_own_plugin_stops_when_it_next_waits() {
    let h = host();
    let start = Instant::now();
    h.load_str(
        "suicidal",
        r#"
        local greed = require("@greed")
        greed.command { name = "go", run = function()
          greed.plugin.unload("suicidal")
          greed.echo("still here")
          greed.sleep(10)
          greed.echo("never")
        end }
        "#,
    )
    .unwrap();
    h.run("go").unwrap();
    pass(&h, start, 100);
    assert_eq!(messages(&h), ["still here"]);
}

fn marks(h: &Host, ns: &str) -> usize {
    h.with_editor(|ed| ed.buffer(ed.view(ed.focus()).buffer).marks(ns).len())
}

const MARKER: &str = r#"
local greed = require("@greed")
greed.view():buffer():decorate("mine", { { from = 0, to = 5, style = "match" } })
"#;

#[test]
fn unloading_clears_the_marks_a_plugin_set() {
    let h = host();
    h.load_str("marker", MARKER).unwrap();
    h.load_str(
        "other",
        r#"require("@greed").view():buffer():decorate("theirs", { { from = 0, to = 1, style = "match" } })"#,
    )
    .unwrap();
    assert_eq!(marks(&h, "mine"), 1);
    h.unload("marker").unwrap();
    assert_eq!(marks(&h, "mine"), 0);
    assert_eq!(marks(&h, "theirs"), 1);
}

#[test]
fn the_last_plugin_to_set_a_namespace_owns_it() {
    let h = host();
    h.load_str("marker", MARKER).unwrap();
    h.load_str("taker", &MARKER.replace("to = 5", "to = 3"))
        .unwrap();
    h.unload("marker").unwrap();
    assert_eq!(marks(&h, "mine"), 1, "the taker's marks stay");
    h.unload("taker").unwrap();
    assert_eq!(marks(&h, "mine"), 0);
}

#[test]
fn marks_set_through_another_plugins_function_belong_to_that_plugin() {
    let h = host();
    h.load_str(
        "lib",
        r#"
        return { mark = function(buffer)
          buffer:decorate("lib", { { from = 0, to = 5, style = "match" } })
        end }
        "#,
    )
    .unwrap();
    h.load_str(
        "user",
        r#"require("@lib").mark(require("@greed").view():buffer())"#,
    )
    .unwrap();
    h.unload("user").unwrap();
    assert_eq!(marks(&h, "lib"), 1);
    h.unload("lib").unwrap();
    assert_eq!(marks(&h, "lib"), 0);
}

#[test]
fn unloading_closes_a_plugins_floats_and_panels() {
    let h = host();
    let main = h.with_editor(Editor::focus);
    h.load_str(
        "watcher",
        r#"require("@greed").on("view.closed", function() require("@greed").echo("closed") end)"#,
    )
    .unwrap();
    h.load_str(
        "windows",
        r#"
        local greed = require("@greed")
        greed.float(greed.create_buffer("scratch", "float"))
        greed.panel(greed.create_buffer("scratch", "panel"), { focus = false })
        "#,
    )
    .unwrap();
    h.with_editor(|ed| {
        assert_eq!(ed.floats().len(), 1);
        assert_eq!(ed.panels().len(), 1);
    });
    h.unload("windows").unwrap();
    h.with_editor(|ed| {
        assert!(ed.floats().is_empty());
        assert!(ed.panels().is_empty());
        assert_eq!(ed.focus(), main);
    });
    assert_eq!(messages(&h), ["closed", "closed"]);
}

#[test]
fn unloading_forgets_a_plugins_images() {
    let h = host();
    let path = std::env::temp_dir().join(format!("greed-dot-{}.png", std::process::id()));
    let image = greed_core::image::Image::from_pixels(1, 1, 3, &[255, 0, 0]).unwrap();
    std::fs::write(&path, &*image.png).unwrap();
    h.load_str(
        "pictures",
        &format!(
            r#"local greed = require("@greed") greed.echo(tostring(assert(greed.image.load({path:?}))))"#
        ),
    )
    .unwrap();
    std::fs::remove_file(&path).unwrap();
    let id = ImageId(messages(&h)[0].parse().unwrap());
    assert!(h.with_editor(|ed| ed.images().contains(id)));
    h.unload("pictures").unwrap();
    assert!(!h.with_editor(|ed| ed.images().contains(id)));
}

#[test]
fn unloading_stops_a_plugins_watches() {
    let h = host();
    h.load_str("a", r#"require("@greed").fs.watch("/tmp/greed-watched")"#)
        .unwrap();
    h.load_str("b", r#"require("@greed").fs.watch("/tmp/greed-watched")"#)
        .unwrap();
    h.unload("a").unwrap();
    assert!(h.watching(), "b still watches it");
    h.unload("b").unwrap();
    assert!(!h.watching());
}

#[test]
fn unloading_puts_back_the_file_types_a_plugin_replaced() {
    let h = host();
    let lang = |h: &Host, path: &str| {
        h.with_editor(|ed| ed.file_type(Path::new(path)).map(|l| l.to_string()))
    };
    assert_eq!(lang(&h, "a.rs").as_deref(), Some("rust"));
    h.load_str(
        "first",
        r#"require("@greed").filetype("thing", { extensions = { "thing" } })"#,
    )
    .unwrap();
    h.load_str(
        "second",
        r#"
        require("@greed").filetype("thing", { extensions = { "thing2" } })
        require("@greed").filetype("oxide", { extensions = { "rs" } })
        "#,
    )
    .unwrap();
    assert_eq!(lang(&h, "a.rs").as_deref(), Some("oxide"));
    assert_eq!(lang(&h, "a.thing"), None);
    h.unload("second").unwrap();
    assert_eq!(lang(&h, "a.rs").as_deref(), Some("rust"));
    assert_eq!(lang(&h, "a.thing").as_deref(), Some("thing"));
    assert_eq!(lang(&h, "a.thing2"), None);
    h.unload("first").unwrap();
    assert_eq!(lang(&h, "a.thing"), None);
}

#[test]
fn unloading_puts_back_the_language_servers_a_plugin_replaced() {
    let h = host();
    let servers = |h: &Host| {
        h.eval(
            "local s = require('@greed').lsp.servers() return (s.rust and s.rust[1][1] or '-') .. ' ' .. (s.go and s.go[1][1] or '-')",
        )
        .unwrap()
    };
    h.load_str(
        "base",
        r#"require("@greed").lsp.server { language = "rust", command = { "rust-analyzer" } }"#,
    )
    .unwrap();
    h.load_str(
        "mine",
        r#"
        local lsp = require("@greed").lsp
        lsp.server { language = "rust", command = { "my-ra" } }
        lsp.server { language = "go", command = { "gopls" } }
        "#,
    )
    .unwrap();
    assert_eq!(servers(&h), "my-ra gopls");
    h.unload("mine").unwrap();
    assert_eq!(servers(&h), "rust-analyzer -");
    h.unload("base").unwrap();
    assert_eq!(servers(&h), "- -");
}
