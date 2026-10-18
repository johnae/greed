use std::os::unix::fs::PermissionsExt;
use std::time::Duration;

use greed_core::luau::{Host, HostError};
use greed_core::registry::Value;
use greed_core::{Editor, FIRST_CLIENT, ViewId};
use greed_text::{Author, ClientId, Range, Selection};

fn host(text: &str) -> Host {
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", text, None);
    Host::new(editor).unwrap()
}

fn text(host: &Host) -> String {
    host.with_editor(|ed| ed.buffer(ed.view(ed.focus()).buffer).text().to_string())
}

fn selection(host: &Host) -> Selection {
    host.with_editor(|ed| ed.view(ed.focus()).selection.clone())
}

fn focus(host: &Host) -> ViewId {
    host.with_editor(Editor::focus)
}

const WRAP: &str = r#"
local greed = require("@greed")
greed.command {
  name = "wrap-in-some",
  doc = "Wrap each selection in Some(...)",
  run = function(ctx)
    ctx.buffer:edit(function(e)
      for _, range in ctx.view:selection().ranges do
        e:insert(math.min(range.anchor, range.head), "Some(")
        e:insert(math.max(range.anchor, range.head), ")")
      end
    end)
  end,
}
greed.keymap.bind("helix", { ["m s"] = "wrap-in-some" })
"#;

#[test]
fn commands_edit_through_transactions() {
    let h = host("let x = 1;");
    h.load_str("wrap", WRAP).unwrap();
    h.with_editor_mut(|ed| {
        let v = ed.focus();
        ed.view_mut(v).selection = Selection::single(8, 9);
    });
    h.press_keys("m s").unwrap();
    assert_eq!(text(&h), "let x = Some(1);");
    assert_eq!(selection(&h).primary(), Range::new(13, 14));

    let author = h.with_editor(|ed| {
        let buffer = ed.buffer(ed.view(ed.focus()).buffer);
        buffer.history().log()[0].meta.author.clone()
    });
    assert_eq!(author, Author::User(ClientId(1)));

    let view = focus(&h);
    assert!(h.with_editor_mut(|ed| ed.undo(view)).unwrap());
    assert_eq!(text(&h), "let x = 1;");
}

#[test]
fn commands_record_where_they_were_defined() {
    let h = host("");
    h.load_str("wrap", WRAP).unwrap();
    h.with_registry(|reg| {
        let cmd = reg.command("wrap-in-some").unwrap();
        assert_eq!(&*cmd.doc, "Wrap each selection in Some(...)");
        assert_eq!(&*cmd.owner, "wrap");
        let source = cmd.source.as_ref().unwrap();
        assert_eq!(source.line, 3);
        assert!(source.file.contains("wrap"), "{source:?}");
    });
}

#[test]
fn insert_mode_fallback_gets_the_typed_char() {
    let h = host("");
    h.load_str(
        "insert",
        r#"
        local greed = require("@greed")
        greed.command { name = "insert-char", run = function(ctx)
          local pos = ctx.view:selection().ranges[1].head
          ctx.buffer:edit(function(e) e:insert(pos, ctx.char) end)
        end }
        greed.command { name = "insert-mode", run = function() greed.mode.set("insert") end }
        greed.keymap.bind("helix", { i = "insert-mode" })
        greed.keymap.fallback("insert", "insert-char")
        "#,
    )
    .unwrap();
    h.press_keys("i h é y").unwrap();
    assert_eq!(text(&h), "héy");
    assert_eq!(selection(&h).primary(), Range::point(4));
}

#[test]
fn plugins_have_separate_globals_and_a_read_only_stdlib() {
    let h = host("");
    h.load_str("a", "shared = 1").unwrap();
    h.load_str("b", "assert(shared == nil, 'leaked')").unwrap();
    let err = h.load_str("c", "string.len = nil").unwrap_err();
    assert!(err.to_string().contains("readonly"), "{err}");
}

#[test]
fn errors_name_the_plugin_and_line() {
    let h = host("");
    h.load_str(
        "broken",
        "local greed = require('@greed')\ngreed.command { name = 'boom', run = function()\n  error('nope')\nend }",
    )
    .unwrap();
    let err = h.run(FIRST_CLIENT, "boom").unwrap_err().to_string();
    assert!(err.contains("broken:3"), "{err}");
    assert!(err.contains("nope"), "{err}");
}

#[test]
fn runaway_code_is_stopped() {
    let h = host("");
    h.set_budget(Duration::from_millis(50));
    let err = h.load_str("spin", "while true do end").unwrap_err();
    assert!(err.to_string().contains("stopped after running"), "{err}");
    // The host still works afterwards.
    assert_eq!(h.eval("1 + 1").unwrap(), "2");
}

#[test]
fn unknown_commands_are_reported() {
    let h = host("");
    assert!(matches!(
        h.run(FIRST_CLIENT, "nope"),
        Err(HostError::UnknownCommand(_))
    ));
    h.load_str(
        "k",
        "require('@greed').keymap.bind('helix', { x = 'missing' })",
    )
    .unwrap();
    assert!(matches!(
        h.press_keys("x"),
        Err(HostError::UnknownCommand(_))
    ));
}

#[test]
fn reloading_replaces_registrations() {
    let h = host("");
    h.load_str("p", WRAP).unwrap();
    h.load_str(
        "p",
        "require('@greed').command { name = 'other', run = function() end }",
    )
    .unwrap();
    h.with_registry(|reg| {
        assert!(reg.command("wrap-in-some").is_none());
        assert!(reg.command("other").is_some());
    });
    h.with_editor(|ed| {
        assert!(ed.keymap().fallback("helix").is_none());
    });
    h.reload("p").unwrap();
    assert_eq!(h.with_registry(|reg| reg.definitions("other").len()), 1);
    assert!(matches!(h.reload("nope"), Err(HostError::UnknownPlugin(_))));
}

#[test]
fn plugin_directories_load_with_local_requires() {
    let dir = std::env::temp_dir().join(format!("greed-plugin-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("plugin.toml"), "name = \"greeter\"\n").unwrap();
    std::fs::write(dir.join("words.luau"), "return { hello = 'hi there' }\n").unwrap();
    std::fs::write(
        dir.join("init.luau"),
        "local greed = require('@greed')\nlocal words = require('@self/words')\ngreed.command { name = 'greet', run = function() greed.echo(words.hello) end }\n",
    )
    .unwrap();

    let h = host("");
    let name = h.load_dir(&dir).unwrap();
    assert_eq!(&*name, "greeter");
    h.run(FIRST_CLIENT, "greet").unwrap();
    assert_eq!(h.with_editor_mut(Editor::take_messages), ["hi there"]);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn evaluating_again_and_again_keeps_no_memory() {
    // What 1000 evals may grow Luau's memory by: pages of its heap that the
    // garbage left half used, nothing like a copy of what each eval made.
    // Sandboxed code gets a whole `@greed` of its own each time.
    for (code, allowed) in [
        ("return loadstring('return 1')()", 64 * 1024),
        (
            "require('@greed').eval('1 + 1', { sandbox = true })",
            4 * 1024 * 1024,
        ),
    ] {
        let h = host("hello");
        let run = |times| {
            for _ in 0..times {
                h.eval(code).unwrap();
            }
        };
        run(200);
        let before = h.luau_memory();
        run(1000);
        let grew = h.luau_memory().saturating_sub(before);
        assert!(grew < allowed, "1000 evals of {code} kept {grew} bytes");
    }
}

#[test]
fn an_open_file_is_not_copied_into_luau() {
    let dir = std::env::temp_dir().join(format!("greed-copied-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("big.txt");
    let text = "a line of text that is long enough to add up\n".repeat(200_000);
    std::fs::write(&path, &text).unwrap();
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", &text, Some(path));
    let h = Host::new(editor).unwrap();
    let core = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../runtime/plugins/core");
    h.load_dir(&core).unwrap();
    let before = h.luau_memory();
    h.announce_open_files().unwrap();
    let grew = h.luau_memory().saturating_sub(before);
    std::fs::remove_dir_all(&dir).unwrap();
    assert!(
        grew < text.len() / 4,
        "opening kept {grew} bytes of a {} byte file",
        text.len()
    );
}

#[test]
fn eval_returns_values_and_keeps_globals() {
    let h = host("hello");
    assert_eq!(h.eval("x = 40").unwrap(), "");
    assert_eq!(h.eval("x + 2").unwrap(), "42");
    assert_eq!(
        h.eval("require('@greed').view():buffer():text()").unwrap(),
        "hello"
    );
}

#[test]
fn mode_changes_emit_an_event() {
    let h = host("");
    h.load_str(
        "watch",
        r#"
        local greed = require("@greed")
        greed.keymap.fallback("insert", "insert-char")
        greed.on("mode.changed", function(ev) greed.echo(ev.from .. "->" .. ev.to) end)
        "#,
    )
    .unwrap();
    h.eval("require('@greed').mode.set('insert')").unwrap();
    h.eval("require('@greed').mode.set('insert')").unwrap();
    assert_eq!(h.with_editor_mut(Editor::take_messages), ["helix->insert"]);
    let err = h
        .eval("require('@greed').mode.set('inserd')")
        .unwrap_err()
        .to_string();
    assert!(
        err.contains("no mode called inserd; modes: insert"),
        "{err}"
    );
    assert!(h.with_editor_mut(Editor::take_messages).is_empty());
}

#[test]
fn options_round_trip_through_luau() {
    let h = host("");
    h.load_str(
        "opts",
        "local o = require('@greed').option\no.define { name = 'tab-width', doc = 'Spaces per tab', default = 4 }",
    )
    .unwrap();
    assert_eq!(
        h.eval("require('@greed').option.get('tab-width')").unwrap(),
        "4"
    );
    h.eval("require('@greed').option.set('tab-width', 2)")
        .unwrap();
    assert_eq!(
        h.with_registry(|reg| reg.option("tab-width").cloned()),
        Some(Value::Int(2))
    );
    assert!(
        h.eval("require('@greed').option.set('tab-width', 'x')")
            .is_err()
    );
}

#[test]
fn buffer_helpers_use_byte_offsets_and_zero_based_lines() {
    let h = host("aé\nb\r\nlast");
    let eval = |s: &str| {
        h.eval(&format!(
            "(function() local b = require('@greed').view():buffer(); return {s} end)()"
        ))
        .unwrap()
    };
    assert_eq!(eval("b:len()"), "11");
    assert_eq!(eval("b:line_count()"), "3");
    assert_eq!(eval("b:line_of(4)"), "1");
    assert_eq!(eval("b:line_start(2)"), "7");
    assert_eq!(eval("b:line_end(0)"), "3");
    assert_eq!(eval("b:line_end(1)"), "5");
    assert_eq!(eval("b:line_end(2)"), "11");
    assert_eq!(eval("b:char_at(1)"), "é");
    assert_eq!(eval("b:next_char(1)"), "3");
    assert_eq!(eval("b:prev_char(3)"), "1");
    assert_eq!(eval("b:slice(0, 3)"), "aé");
    assert_eq!(eval("b:line_text(0)"), "aé");
    assert_eq!(eval("b:line_text(1)"), "b");
    assert_eq!(eval("b:line_text(2)"), "last");
    assert!(
        h.eval("require('@greed').view():buffer():line_text(3)")
            .is_err()
    );
    assert!(
        h.eval("require('@greed').view():buffer():char_at(2)")
            .is_err()
    );
    assert!(
        h.eval("require('@greed').view():buffer():slice(0, 99)")
            .is_err()
    );
}

#[test]
fn display_columns_count_wide_characters_and_tabs() {
    // "\t" reaches column 4, "界" takes two columns, "é" one.
    let h = host("\t界é|\nab\tc\n");
    let eval = |s: &str| {
        h.eval(&format!(
            "(function() local b = require('@greed').view():buffer(); return {s} end)()"
        ))
        .unwrap()
    };
    assert_eq!(eval("b:display_column(0)"), "0");
    assert_eq!(eval("b:display_column(1)"), "4");
    assert_eq!(eval("b:display_column(4)"), "6");
    assert_eq!(eval("b:display_column(6)"), "7");
    assert_eq!(eval("b:display_column(1, 8)"), "8");
    // A tab after two characters only reaches the next stop.
    assert_eq!(eval("b:display_column(11)"), "4");
    assert_eq!(eval("b:display_column(11, 3)"), "3");

    assert_eq!(eval("b:at_display_column(0, 0)"), "0");
    assert_eq!(eval("b:at_display_column(0, 2)"), "0");
    assert_eq!(eval("b:at_display_column(0, 4)"), "1");
    assert_eq!(eval("b:at_display_column(0, 5)"), "1");
    assert_eq!(eval("b:at_display_column(0, 6)"), "4");
    assert_eq!(eval("b:at_display_column(0, 99)"), "7");
    assert_eq!(eval("b:at_display_column(1, 3)"), "10");
    assert_eq!(eval("b:at_display_column(2, 3)"), "13");
    assert_eq!(eval("b:at_display_column(0, 4, 8)"), "0");

    for bad in [
        "display_column(2)",
        "display_column(99)",
        "display_column(0, 0)",
        "at_display_column(3, 0)",
    ] {
        assert!(
            h.eval(&format!("require('@greed').view():buffer():{bad}"))
                .is_err(),
            "{bad}"
        );
    }
}

#[test]
fn the_cursor_is_the_primary_head() {
    let h = host("hello world");
    h.eval("require('@greed').view():set_selection({ ranges = { { anchor = 0, head = 2 }, { anchor = 9, head = 6 } }, primary = 2 })")
        .unwrap();
    assert_eq!(h.eval("require('@greed').view():cursor()").unwrap(), "6");
    h.eval("require('@greed').view():set_cursor(3)").unwrap();
    assert_eq!(selection(&h), Selection::point(3));
    assert!(h.eval("require('@greed').view():set_cursor(50)").is_err());
}

#[test]
fn selections_round_trip_and_are_validated() {
    let h = host("hello world");
    h.eval("require('@greed').view():set_selection({ ranges = { { anchor = 0, head = 5 }, { anchor = 6, head = 11 } }, primary = 2 })")
        .unwrap();
    let sel = selection(&h);
    assert_eq!(sel.ranges(), &[Range::new(0, 5), Range::new(6, 11)]);
    assert_eq!(sel.primary(), Range::new(6, 11));
    assert_eq!(
        h.eval("require('@greed').view():selection().primary")
            .unwrap(),
        "2"
    );
    assert!(
        h.eval(
            "require('@greed').view():set_selection({ ranges = { { anchor = 0, head = 50 } } })"
        )
        .is_err()
    );
}

#[test]
fn overlapping_edits_are_rejected_without_changing_anything() {
    let h = host("hello");
    let err = h
        .eval(
            "require('@greed').view():buffer():edit(function(e) e:delete(0, 3) e:delete(2, 4) end)",
        )
        .unwrap_err();
    assert!(err.to_string().contains("overlap"), "{err}");
    assert_eq!(text(&h), "hello");
}

#[test]
fn plugin_edits_are_attributed_to_the_plugin() {
    let h = host("");
    h.load_str(
        "bot",
        "require('@greed').view():buffer():edit(function(e) e:insert(0, 'hi') end)",
    )
    .unwrap();
    let author = h.with_editor(|ed| {
        ed.buffer(ed.view(ed.focus()).buffer).history().log()[0]
            .meta
            .author
            .clone()
    });
    assert_eq!(author, Author::Plugin("bot".into()));
}

#[test]
fn views_undo_and_redo() {
    let h = host("");
    h.eval("require('@greed').view():buffer():edit(function(e) e:insert(0, 'x') end)")
        .unwrap();
    assert_eq!(h.eval("require('@greed').view():undo()").unwrap(), "true");
    assert_eq!(text(&h), "");
    assert_eq!(h.eval("require('@greed').view():undo()").unwrap(), "false");
    assert_eq!(h.eval("require('@greed').view():redo()").unwrap(), "true");
    assert_eq!(text(&h), "x");
}

/// Writes a plugin called `name` with `files` into a fresh temp directory.
fn plugin_dir(name: &str, files: &[(&str, &str)]) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("greed-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    for (path, source) in files {
        let path = dir.join(path);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, source).unwrap();
    }
    std::fs::write(dir.join("plugin.toml"), format!("name = \"{name}\"\n")).unwrap();
    dir
}

#[test]
fn requires_resolve_like_luau_tooling() {
    let dir = plugin_dir(
        "requires",
        &[
            (
                "init.luau",
                "local a = require('@self/lib/a')\nrequire('@greed').echo(a.name, a.b)",
            ),
            ("lib/a.luau", "return { name = 'a', b = require('./b') }"),
            ("lib/b.luau", "return 'b'"),
        ],
    );
    let h = host("");
    h.load_dir(&dir).unwrap();
    assert_eq!(h.with_editor_mut(Editor::take_messages), ["a b"]);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn bad_requires_explain_themselves() {
    let cases = [
        ("bare", "require('greed')", "use \"@greed\""),
        (
            "self-outside-init",
            "require('./lib/x')",
            "init.luau stands for its folder, so \"./\" there is outside it; use \"@self/lib/x\"",
        ),
        ("parent", "require('../x')", "outside the plugin"),
        (
            "test-api",
            "require('@greed/test')",
            "only available in test files",
        ),
        ("missing", "require('@self/nope')", "no such file"),
    ];
    for (name, source, expected) in cases {
        let dir = plugin_dir(name, &[("init.luau", source)]);
        let err = host("").load_dir(&dir).unwrap_err().to_string();
        std::fs::remove_dir_all(&dir).unwrap();
        assert!(err.contains(expected), "{name}: {err}");
    }

    let dir = plugin_dir(
        "self-in-module",
        &[
            ("init.luau", "require('@self/a')"),
            ("a.luau", "return require('@self/b')"),
        ],
    );
    let err = host("").load_dir(&dir).unwrap_err().to_string();
    std::fs::remove_dir_all(&dir).unwrap();
    assert!(err.contains("@self is for init.luau"), "{err}");
}

#[test]
fn handles_compare_by_what_they_refer_to_and_outlive_it() {
    let h = host("main");
    h.eval("greed = require('@greed')").unwrap();
    assert_eq!(h.eval("greed.view() == greed.view()").unwrap(), "true");
    assert_eq!(
        h.eval("greed.view():buffer() == greed.view():buffer()")
            .unwrap(),
        "true"
    );
    h.eval("b = greed.create_buffer('scratch', 'x'); v = greed.float(b)")
        .unwrap();
    assert_eq!(h.eval("v == greed.view()").unwrap(), "true");
    assert_eq!(h.eval("b == greed.view():buffer()").unwrap(), "true");
    assert_eq!(h.eval("b == v").unwrap(), "false");
    assert_eq!(h.eval("v == b").unwrap(), "false");
    assert_eq!(h.eval("b == b:id()").unwrap(), "false");
    assert_eq!(h.eval("v:valid() and b:valid()").unwrap(), "true");
    h.eval("ids = { v:id(), b:id() }; v:close()").unwrap();
    assert_eq!(h.eval("v:valid() or b:valid()").unwrap(), "false");
    assert_eq!(
        h.eval("v:id() == ids[1] and b:id() == ids[2]").unwrap(),
        "true"
    );
    assert_eq!(h.eval("v == greed.view()").unwrap(), "false");
}

#[test]
fn handlers_can_be_removed() {
    let h = host("");
    h.load_str(
        "watch",
        r#"
        local greed = require("@greed")
        greed.keymap.fallback("insert", "insert-char")
        greed.keymap.bind("normal", { i = "insert-mode" })
        local function first(ev) greed.echo("first " .. ev.to) end
        greed.on("mode.changed", first)
        greed.on("mode.changed", function(ev) greed.echo("second " .. ev.to) end)
        return { first = first, off = function() greed.off("mode.changed", first) end }
        "#,
    )
    .unwrap();
    // Another plugin can't remove it, even with the function in hand.
    h.load_str(
        "other",
        r#"require("@greed").off("mode.changed", require("@watch").first)"#,
    )
    .unwrap();
    h.eval("require('@greed').mode.set('insert')").unwrap();
    h.eval("require('@watch').off()").unwrap();
    h.eval("require('@watch').off()").unwrap();
    h.eval("require('@greed').mode.set('normal')").unwrap();
    assert_eq!(
        h.with_editor_mut(Editor::take_messages),
        ["first insert", "second insert", "second normal"]
    );
}

#[test]
fn scratch_buffers_float_and_go_away_when_closed() {
    let h = host("main");
    h.eval("b = require('@greed').create_buffer('picker', 'one\\ntwo')")
        .unwrap();
    h.eval("v = require('@greed').float(b, { title = 'Pick', width = 30, height = '50%' })")
        .unwrap();
    assert_eq!(
        h.eval("require('@greed').view():buffer():kind()").unwrap(),
        "picker"
    );
    h.with_editor(|ed| {
        let float = &ed.floats()[0];
        assert_eq!(float.options.title.as_deref(), Some("Pick"));
        assert_eq!(float.options.width, greed_core::Extent::Cells(30));
        assert_eq!(float.options.height, greed_core::Extent::percent(50));
    });
    assert_eq!(h.eval("v:close()").unwrap(), "true");
    assert_eq!(
        h.eval("require('@greed').view():buffer():text()").unwrap(),
        "main"
    );
    let err = h.eval("b:text()").unwrap_err().to_string();
    assert!(err.contains("this buffer was closed"), "{err}");
    let err = h.eval("v:selection()").unwrap_err().to_string();
    assert!(err.contains("this view was closed"), "{err}");
    assert!(
        h.eval(
            "require('@greed').float(require('@greed').create_buffer('x'), { anchor = 'sideways' })"
        )
        .is_err()
    );
}

#[test]
fn edits_and_undo_announce_buffer_changes() {
    let h = host("");
    h.load_str(
        "watch",
        "local greed = require('@greed')\ngreed.on('buffer.changed', function(ev) greed.echo('changed ' .. ev.buffer:text()) end)",
    )
    .unwrap();
    h.eval("require('@greed').view():buffer():edit(function(e) e:insert(0, 'x') end)")
        .unwrap();
    h.eval("require('@greed').view():undo()").unwrap();
    assert_eq!(
        h.with_editor_mut(Editor::take_messages),
        ["changed x", "changed "]
    );
}

#[test]
fn buffers_off_screen_can_be_edited() {
    let h = host("");
    h.eval("s = require('@greed').create_buffer('scratch', 'abc')")
        .unwrap();
    h.eval("s:edit(function(e) e:insert(3, 'd') end)").unwrap();
    assert_eq!(h.eval("s:text()").unwrap(), "abcd");
    assert_eq!(h.eval("#require('@greed').buffers()").unwrap(), "2");
}

#[test]
fn open_shows_a_file_in_the_main_view() {
    let dir = plugin_dir("open-files", &[("notes.md", "# Notes")]);
    let h = host("start");
    h.eval("b = require('@greed').create_buffer('picker')")
        .unwrap();
    h.eval("require('@greed').float(b)").unwrap();
    let path = dir.join("notes.md");
    h.eval(&format!(
        "require('@greed').open({:?})",
        path.to_str().unwrap()
    ))
    .unwrap();
    assert_eq!(h.with_editor(Editor::focus), h.with_editor(Editor::main));
    assert_eq!(text(&h), "# Notes");
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn commands_are_listed_with_docs_and_owners() {
    let h = host("");
    h.load_str("mine", WRAP).unwrap();
    let listed = h
        .eval("(function() local c = require('@greed').commands()[1] return c.name .. '|' .. c.doc .. '|' .. c.owner end)()")
        .unwrap();
    assert_eq!(listed, "wrap-in-some|Wrap each selection in Some(...)|mine");
}

#[test]
fn fuzzy_matching_ranks_best_first() {
    let h = host("");
    let ranked = |q: &str| {
        h.eval(&format!(
            "table.concat(require('@greed').fuzzy({q:?}, {{ 'README.md', 'src/main.rs', 'Cargo.toml', 'src/lib.rs' }}), ',')"
        ))
        .unwrap()
    };
    assert_eq!(ranked("main"), "2");
    assert_eq!(ranked("src"), "2,4");
    assert_eq!(ranked(""), "1,2,3,4");
    assert_eq!(ranked("zzz"), "");
}

#[test]
fn files_skip_hidden_and_ignored_ones() {
    let dir = plugin_dir(
        "list-files",
        &[
            ("src/main.rs", ""),
            ("README.md", ""),
            (".hidden", ""),
            ("target/out", ""),
            (".gitignore", "target/\n"),
        ],
    );
    let h = host("");
    let listed = h
        .eval(&format!(
            "table.concat(require('@greed').files({:?}), ',')",
            dir.to_str().unwrap()
        ))
        .unwrap();
    std::fs::remove_dir_all(&dir).unwrap();
    assert_eq!(listed, "README.md,plugin.toml,src/main.rs");
}

/// Evaluates `source` with `DIR` set to `dir`.
fn eval_in(h: &Host, dir: &std::path::Path, source: &str) -> String {
    h.eval(&format!(
        "local greed = require('@greed')\nlocal DIR = {:?}\n{source}",
        dir.to_str().unwrap()
    ))
    .unwrap()
}

#[test]
fn directories_list_folders_first_and_skip_hidden_and_ignored_entries() {
    let dir = plugin_dir(
        "fs-list",
        &[
            ("src/main.rs", ""),
            ("README.md", ""),
            ("b.txt", ""),
            (".hidden", ""),
            ("target/out", ""),
            (".gitignore", "target/\n"),
        ],
    );
    let h = host("");
    let names = |opts: &str| {
        eval_in(
            &h,
            &dir,
            &format!(
                "local out = {{}}
                 for _, e in greed.fs.list(DIR{opts}) do
                   table.insert(out, if e.dir then e.name .. '/' else e.name)
                 end
                 return table.concat(out, ',')"
            ),
        )
    };
    assert_eq!(names(""), "src/,b.txt,plugin.toml,README.md");
    assert_eq!(
        names(", { hidden = true, ignored = true }"),
        "src/,target/,.gitignore,.hidden,b.txt,plugin.toml,README.md"
    );
    let missing = eval_in(
        &h,
        &dir,
        "local list, err = greed.fs.list(DIR .. '/nope') return tostring(list) .. ' ' .. tostring(err ~= nil)",
    );
    std::fs::remove_dir_all(&dir).unwrap();
    assert_eq!(missing, "nil true");
}

#[test]
fn files_read_whole_or_up_to_a_limit() {
    let dir = plugin_dir("fs-read", &[("a.txt", "héllo\nworld\n")]);
    let h = host("");
    let read = |args: &str| {
        eval_in(
            &h,
            &dir,
            &format!("local text, err = greed.fs.read(DIR .. '/a.txt'{args}) return text or err"),
        )
    };
    assert_eq!(read(""), "héllo\nworld\n");
    // A limit inside "é" stops before it rather than splitting it.
    assert_eq!(read(", 2"), "h");
    assert_eq!(read(", 3"), "hé");
    let missing = eval_in(
        &h,
        &dir,
        "local text, err = greed.fs.read(DIR .. '/nope') return tostring(text) .. ' ' .. err",
    );
    assert!(missing.starts_with("nil "), "{missing}");

    let stat = eval_in(
        &h,
        &dir,
        "local f, d = greed.fs.stat(DIR .. '/a.txt'), greed.fs.stat(DIR)
         return f.kind .. ' ' .. f.size .. ' ' .. d.kind .. ' ' .. tostring(greed.fs.stat(DIR .. '/nope')) \
           .. ' ' .. select('#', greed.fs.stat(DIR .. '/a.txt/inside'))",
    );
    assert_eq!(stat, "file 13 dir nil 1", "nothing there is nil alone");
    // When it last changed, close to now.
    let modified = eval_in(
        &h,
        &dir,
        "return math.abs(greed.fs.stat(DIR .. '/a.txt').modified - os.time()) < 600",
    );
    assert_eq!(modified, "true");
    // A folder that can't be read is another matter.
    std::fs::create_dir(dir.join("locked")).unwrap();
    std::fs::set_permissions(dir.join("locked"), std::fs::Permissions::from_mode(0o000)).unwrap();
    let locked = eval_in(
        &h,
        &dir,
        "local info, err = greed.fs.stat(DIR .. '/locked/x') return tostring(info) .. ' ' .. err",
    );
    std::fs::set_permissions(dir.join("locked"), std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::remove_dir_all(&dir).unwrap();
    assert!(locked.starts_with("nil can't look at "), "{locked}");
}

#[test]
fn grep_finds_matching_lines_in_files_that_arent_ignored() {
    let dir = plugin_dir(
        "fs-grep",
        &[
            ("src/main.rs", "fn main() {\n    let x = foo(foo);\n}\n"),
            ("b.txt", "no match\nfoo\r\n"),
            ("bin.dat", "foo\0"),
            ("target/out", "foo\n"),
            (".gitignore", "target/\n"),
        ],
    );
    let h = host("");
    // In a command, since grep searches in the background and waits.
    let grep = |args: &str| {
        h.load_str(
            "grep-test",
            &format!(
                "local greed = require('@greed')
                 local DIR = {:?}
                 greed.command {{ name = 'grep-test', run = function()
                   local found, err = greed.fs.grep({args})
                   if not found then greed.echo(err) return end
                   local out = {{}}
                   for _, m in found do
                     local spans = {{}}
                     for _, r in m.matches do table.insert(spans, r.from .. '-' .. r.to) end
                     table.insert(out, `{{m.path}}:{{m.line}}:{{m.text}}:{{table.concat(spans, ' ')}}`)
                   end
                   greed.echo(table.concat(out, ','))
                 end }}",
                dir.to_str().unwrap()
            ),
        )
        .unwrap();
        h.run(FIRST_CLIENT, "grep-test").unwrap();
        h.settle().unwrap();
        h.with_editor_mut(Editor::take_messages).join("")
    };
    assert_eq!(
        grep("'foo', DIR"),
        "b.txt:1:foo:0-3,src/main.rs:1:    let x = foo(foo);:12-15 16-19"
    );
    assert_eq!(grep("'foo', DIR, { limit = 1 }").split(',').count(), 1);
    assert_eq!(
        grep("'foo', DIR, { ignored = true }")
            .matches("target/out")
            .count(),
        1
    );
    let bad = grep("'(', DIR");
    assert!(bad.contains("unclosed"), "{bad}");
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn scan_lists_files_with_their_sizes_and_times_and_reads_them_when_asked() {
    let dir = plugin_dir(
        "fs-scan",
        &[
            ("a.md", "# A\n"),
            ("deep/b.md", "b\n"),
            ("c.txt", "c\n"),
            ("bin.md", "x\0"),
            ("target/d.md", "ignored\n"),
            (".gitignore", "target/\n"),
        ],
    );
    let h = host("");
    let scan = |args: &str| {
        h.load_str(
            "scan-test",
            &format!(
                "local greed = require('@greed')
                 local DIR = {:?}
                 greed.command {{ name = 'scan-test', run = function()
                   local out = {{}}
                   for _, f in greed.fs.scan({args}) do
                     table.insert(out, `{{f.path}}:{{f.size}}:{{f.modified > 0}}:{{f.text or '-'}}`)
                   end
                   greed.echo(table.concat(out, ','))
                 end }}",
                dir.to_str().unwrap()
            ),
        )
        .unwrap();
        h.run(FIRST_CLIENT, "scan-test").unwrap();
        h.settle().unwrap();
        h.with_editor_mut(Editor::take_messages).join("")
    };
    assert_eq!(
        scan("DIR, { ext = 'md' }"),
        "a.md:4:true:-,bin.md:2:true:-,deep/b.md:2:true:-"
    );
    assert_eq!(
        scan("DIR, { ext = 'md', read = true }"),
        "a.md:4:true:# A\n,bin.md:2:true:-,deep/b.md:2:true:b\n"
    );
    assert!(scan("DIR, { ignored = true }").contains("target/d.md"));
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn files_can_be_written_with_their_folders_and_the_working_directory_read() {
    let dir = plugin_dir("fs-write", &[("a.txt", "")]);
    let h = host("");
    let written = eval_in(
        &h,
        &dir,
        "local ok = greed.fs.write(DIR .. '/new.txt', 'hi\\n')
         local nested = greed.fs.write(DIR .. '/new/deeper/x.txt', '')
         local _, err = greed.fs.write(DIR .. '/a.txt/x.txt', '')
         return tostring(ok) .. ' ' .. tostring(nested) .. ' ' .. tostring(err ~= nil) .. ' ' .. greed.fs.read(DIR .. '/new.txt')",
    );
    let cwd = eval_in(&h, &dir, "return greed.fs.cwd()");
    std::fs::remove_dir_all(&dir).unwrap();
    assert_eq!(written, "true true true hi\n");
    assert_eq!(cwd, std::env::current_dir().unwrap().to_str().unwrap());
}

#[test]
fn a_private_file_is_only_yours_even_when_it_was_not_before() {
    use std::os::unix::fs::PermissionsExt;
    let dir = plugin_dir("fs-private", &[("open.txt", "")]);
    std::fs::set_permissions(dir.join("open.txt"), std::fs::Permissions::from_mode(0o644)).unwrap();
    let h = host("");
    let modes = eval_in(
        &h,
        &dir,
        "greed.fs.write(DIR .. '/open.txt', 'secret', { private = true })
         greed.fs.write(DIR .. '/new/deeper/x.txt', 'secret', { private = true })
         local function mode(p) return string.format('%o', greed.fs.stat(DIR .. p).mode) end
         return mode('/open.txt') .. ' ' .. mode('/new/deeper/x.txt') .. ' ' .. mode('/new/deeper')
           .. ' ' .. greed.fs.read(DIR .. '/open.txt')",
    );
    std::fs::remove_dir_all(&dir).unwrap();
    assert_eq!(modes, "600 600 700 secret");
}

#[test]
fn folders_are_made_and_files_copied_moved_and_removed() {
    let dir = plugin_dir("fs-tree", &[("a.txt", "a\n"), ("full/b.txt", "b\n")]);
    let h = host("");
    let did = eval_in(
        &h,
        &dir,
        "local out = {}
         local function say(ok, err) table.insert(out, if ok then 'ok' else 'nil:' .. tostring(err ~= nil)) end
         say(greed.fs.mkdir(DIR .. '/x/y/z'))
         say(greed.fs.mkdir(DIR .. '/x/y/z'))
         say(greed.fs.mkdir(DIR .. '/a.txt/inside'))
         say(greed.fs.copy(DIR .. '/a.txt', DIR .. '/copies/a.txt'))
         say(greed.fs.copy(DIR .. '/nope', DIR .. '/copies/nope'))
         say(greed.fs.rename(DIR .. '/copies/a.txt', DIR .. '/moved.txt'))
         say(greed.fs.rename(DIR .. '/nope', DIR .. '/other'))
         table.insert(out, greed.fs.read(DIR .. '/moved.txt') or '-')
         table.insert(out, tostring(greed.fs.stat(DIR .. '/copies/a.txt')))
         say(greed.fs.remove(DIR .. '/moved.txt'))
         say(greed.fs.remove(DIR .. '/moved.txt'))
         say(greed.fs.remove(DIR .. '/full'))
         table.insert(out, greed.fs.stat(DIR .. '/full/b.txt').kind)
         say(greed.fs.remove(DIR .. '/full', { recursive = true }))
         say(greed.fs.remove(DIR .. '/x/y/z'))
         table.insert(out, tostring(greed.fs.stat(DIR .. '/full')) .. ' ' .. tostring(greed.fs.stat(DIR .. '/x/y/z')))
         return table.concat(out, ' ')",
    );
    std::fs::remove_dir_all(&dir).unwrap();
    assert_eq!(
        did,
        "ok ok nil:true ok nil:true ok nil:true a\n nil ok ok nil:true file ok ok nil nil"
    );
}

#[test]
fn removing_refuses_the_root_and_paths_that_climb() {
    let dir = plugin_dir("fs-refuse", &[("keep/a.txt", "")]);
    let h = host("");
    for (call, why) in [
        (
            "greed.fs.remove('/', { recursive = true })",
            "the root folder",
        ),
        (
            "greed.fs.remove('/./', { recursive = true })",
            "the root folder",
        ),
        ("greed.fs.remove('')", "an empty path"),
        (
            "greed.fs.remove(DIR .. '/keep/..', { recursive = true })",
            "it has ..",
        ),
        ("greed.fs.rename(DIR .. '/../x', DIR .. '/y')", "it has .."),
        ("greed.fs.rename('/', DIR .. '/y')", "won't move the root"),
    ] {
        let err = h
            .eval(&format!(
                "local greed = require('@greed')\nlocal DIR = {:?}\n{call}",
                dir.to_str().unwrap()
            ))
            .unwrap_err()
            .to_string();
        assert!(err.contains(why), "{call}: {err}");
    }
    assert!(dir.join("keep/a.txt").exists());
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn hashes_are_sha256_in_hex() {
    let dir = plugin_dir("hash", &[("abc.txt", "abc")]);
    let h = host("");
    let digests = eval_in(
        &h,
        &dir,
        "local _, err = greed.hash.sha256_file(DIR .. '/nope')
         return greed.hash.sha256('abc') .. ' ' .. greed.hash.sha256_file(DIR .. '/abc.txt') .. ' ' .. tostring(err ~= nil)",
    );
    std::fs::remove_dir_all(&dir).unwrap();
    let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    assert_eq!(digests, format!("{abc} {abc} true"));
}

#[test]
fn random_bytes_come_as_hex_and_differ_each_time() {
    let h = host("");
    let drawn = h
        .eval("local greed = require('@greed') return greed.hash.random(16) .. ' ' .. greed.hash.random(16) .. ' ' .. greed.hash.random(1)")
        .unwrap();
    let parts: Vec<&str> = drawn.split(' ').collect();
    assert_eq!(parts.len(), 3, "{drawn}");
    for part in &parts {
        assert!(
            part.chars()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()),
            "{drawn}"
        );
    }
    assert_eq!((parts[0].len(), parts[2].len()), (32, 2), "{drawn}");
    assert_ne!(parts[0], parts[1]);
    let err = h
        .eval("return require('@greed').hash.random(0)")
        .unwrap_err()
        .to_string();
    assert!(err.contains("1 to 1024"), "{err}");
}

#[test]
fn the_machine_has_a_name() {
    let h = host("");
    let name = h.eval("return require('@greed').hostname() or ''").unwrap();
    assert!(!name.is_empty());
}

#[test]
fn status_lines_come_from_the_plugin_that_set_them() {
    let h = host("abc");
    assert_eq!(h.status_line(None, 80).unwrap(), None);
    h.load_str(
        "bar",
        "require('@greed').statusline(function(s) return { left = { { text = s.mode, style = 'ui.statusline.mode' } }, right = { s.message or '-' } } end)",
    )
    .unwrap();
    let line = h.status_line(Some("hi"), 80).unwrap().unwrap();
    let text = |spans: &[greed_core::render::Span]| {
        spans.iter().map(|s| s.text.clone()).collect::<String>()
    };
    assert_eq!(text(&line.left), "helix");
    assert_eq!(text(&line.right), "hi");

    h.load_str("bar", "").unwrap();
    assert_eq!(h.status_line(None, 80).unwrap(), None);

    // Any style name works; it's drawn over the status line's own style.
    h.load_str("loud", "require('@greed').statusline(function() return { left = { { text = 'x', style = 'loud' } } } end)")
        .unwrap();
    let line = h.status_line(None, 80).unwrap().unwrap();
    let names: Vec<&str> = line.left[0]
        .tags
        .iter()
        .map(greed_core::render::Tag::name)
        .collect();
    assert_eq!(names, ["ui.statusline", "loud"]);
}

#[test]
fn plugins_require_the_plugins_they_declare() {
    let lib = plugin_dir(
        "lib",
        &[(
            "init.luau",
            "return { greet = function() return 'hi from lib' end }",
        )],
    );
    let app = plugin_dir(
        "app",
        &[(
            "init.luau",
            "require('@greed').echo(require('@lib').greet())",
        )],
    );
    std::fs::write(
        app.join("plugin.toml"),
        "name = \"app\"\nrequires = [\"lib\"]\n",
    )
    .unwrap();

    // Given in the wrong order, they still load dependencies first.
    let h = host("");
    let loaded = h.load_dirs(&[app.clone(), lib.clone()]).unwrap();
    assert_eq!(
        loaded.iter().map(|n| &**n).collect::<Vec<_>>(),
        ["lib", "app"]
    );
    assert_eq!(h.with_editor_mut(Editor::take_messages), ["hi from lib"]);

    let err = host("")
        .load_dirs(std::slice::from_ref(&app))
        .unwrap_err()
        .to_string();
    assert!(err.contains("requires lib"), "{err}");
    let err = host("").load_dir(&app).unwrap_err().to_string();
    assert!(err.contains("requires plugin \"lib\""), "{err}");

    let undeclared = plugin_dir("undeclared", &[("init.luau", "require('@lib')")]);
    let h = host("");
    h.load_dir(&undeclared).unwrap_err();
    std::fs::remove_dir_all(&undeclared).unwrap();
    std::fs::remove_dir_all(&app).unwrap();
    std::fs::remove_dir_all(&lib).unwrap();
}

#[test]
fn running_a_command_is_announced() {
    let h = host("");
    h.load_str(
        "log",
        "local greed = require('@greed')\ngreed.command { name = 'noop', run = function() end }\ngreed.on('command.run', function(ev) greed.echo('ran ' .. ev.name) end)",
    )
    .unwrap();
    h.run(FIRST_CLIENT, "noop").unwrap();
    assert_eq!(h.with_editor_mut(Editor::take_messages), ["ran noop"]);
}

#[test]
fn a_single_file_loads_as_a_plugin_with_local_requires() {
    let dir = plugin_dir(
        "config",
        &[
            (
                "init.luau",
                "require('@greed').echo(require('@self/helpers').name)",
            ),
            ("helpers.luau", "return { name = 'from helpers' }"),
        ],
    );
    let h = host("");
    h.load_file("user/config", &dir.join("init.luau")).unwrap();
    assert_eq!(h.with_editor_mut(Editor::take_messages), ["from helpers"]);
    std::fs::remove_dir_all(&dir).unwrap();
}

const SLEEPY: &str = r#"
local greed = require("@greed")
greed.command { name = "later", run = function(ctx)
  greed.echo("before")
  greed.sleep(500)
  greed.echo("after")
  ctx.buffer:edit(function(e) e:insert(0, "!") end)
end }
"#;

#[test]
fn commands_can_wait_without_blocking() {
    let h = host("");
    h.load_str("sleepy", SLEEPY).unwrap();
    h.run(FIRST_CLIENT, "later").unwrap();
    assert_eq!(h.with_editor_mut(Editor::take_messages), ["before"]);
    assert!(h.next_timer().is_some());

    // Not due yet: nothing happens.
    h.fire_timers(std::time::Instant::now()).unwrap();
    assert!(h.with_editor_mut(Editor::take_messages).is_empty());

    h.fire_timers(std::time::Instant::now() + Duration::from_secs(1))
        .unwrap();
    assert_eq!(h.with_editor_mut(Editor::take_messages), ["after"]);
    assert_eq!(text(&h), "!");
    assert!(h.next_timer().is_none());
}

#[test]
fn waiting_only_works_inside_commands() {
    let h = host("");
    let err = h
        .eval("require('@greed').sleep(1)")
        .unwrap_err()
        .to_string();
    assert!(err.contains("can only be used in a command"), "{err}");

    h.load_str(
        "raw",
        "local greed = require('@greed')
         greed.command { name = 'raw', run = function() coroutine.yield('x') end }
         greed.command { name = 'turn', run = function() coroutine.yield() greed.echo('carried on') end }",
    )
    .unwrap();
    let err = h.run(FIRST_CLIENT, "raw").unwrap_err().to_string();
    assert!(
        err.contains("can only wait through greed functions"),
        "{err}"
    );
    // A bare yield gives the editor a turn, as a time slice running out
    // does. With no event loop to take it, it carries on at once.
    h.run(FIRST_CLIENT, "turn").unwrap();
    assert_eq!(h.with_editor_mut(Editor::take_messages), ["carried on"]);
    assert!(h.next_timer().is_none());
    // With one, it carries on once the loop fires its timer.
    h.use_event_loop();
    h.run(FIRST_CLIENT, "turn").unwrap();
    assert!(h.with_editor_mut(Editor::take_messages).is_empty());
    h.fire_timers(std::time::Instant::now()).unwrap();
    assert_eq!(h.with_editor_mut(Editor::take_messages), ["carried on"]);
}

#[test]
fn work_carried_on_after_a_turn_reports_its_errors() {
    let h = host("");
    h.load_str(
        "turns",
        "local greed = require('@greed')
         greed.command { name = 'fails-later', run = function() coroutine.yield() error('after the turn') end }
         greed.on('buffer.changed', function() coroutine.yield() greed.echo('handled') end)",
    )
    .unwrap();
    let err = h.run(FIRST_CLIENT, "fails-later").unwrap_err().to_string();
    assert!(err.contains("after the turn"), "{err}");
    // What a call sets off, like an event's handlers, is done when it returns.
    h.eval("require('@greed').view():buffer():edit(function(e) e:insert(0, 'x') end)")
        .unwrap();
    assert_eq!(h.with_editor_mut(Editor::take_messages), ["handled"]);
}

#[test]
fn plugins_make_read_only_buffers_in_a_language() {
    let h = host("");
    h.load_str(
        "viewer",
        r#"
        local greed = require("@greed")
        local buffer = greed.create_buffer("preview", "fn main() {}", { readonly = true, language = "rust" })
        greed.float(buffer)
        greed.command { name = "type-x", run = function(ctx)
          ctx.buffer:edit(function(e) e:insert(0, "x") end)
        end }
        greed.command { name = "comment-out", run = function()
          buffer:edit(function(e) e:insert(0, "// ") end)
        end }
        greed.command { name = "describe", run = function()
          greed.echo(tostring(buffer:readonly()) .. " " .. tostring(buffer:language()))
        end }
        greed.command { name = "unlock", run = function()
          buffer:set_readonly(false)
          buffer:set_language(nil)
        end }
        "#,
    )
    .unwrap();
    let err = h.run(FIRST_CLIENT, "type-x").unwrap_err().to_string();
    assert!(err.contains("read-only"), "{err}");
    h.run(FIRST_CLIENT, "comment-out").unwrap();
    assert_eq!(text(&h), "// fn main() {}");
    h.run(FIRST_CLIENT, "describe").unwrap();
    h.run(FIRST_CLIENT, "unlock").unwrap();
    h.run(FIRST_CLIENT, "describe").unwrap();
    h.run(FIRST_CLIENT, "type-x").unwrap();
    assert_eq!(text(&h), "x// fn main() {}");
    assert_eq!(
        h.with_editor_mut(Editor::take_messages),
        ["true rust", "false nil"]
    );
    assert_eq!(
        h.eval(
            "require('@greed').language_of('src/a.rs'), require('@greed').language_of('Makefile')"
        )
        .unwrap(),
        "rust\tnil"
    );
}

#[test]
fn commands_get_arguments_and_force() {
    let h = host("");
    h.load_str(
        "greeter",
        r#"
        local greed = require("@greed")
        greed.command {
          name = "greet",
          doc = "Say hello",
          args = { { name = "who", doc = "Who to greet", complete = "buffer" } },
          run = function(ctx)
            greed.echo(table.concat(ctx.args, "+") .. " " .. tostring(ctx.force))
          end,
        }
        greed.keymap.bind("helix", { g = "greet" })
        "#,
    )
    .unwrap();
    h.eval("require('@greed').run('greet', { args = { 'a', 'b' }, force = true })")
        .unwrap();
    h.press_keys("g").unwrap();
    assert_eq!(
        h.with_editor_mut(Editor::take_messages),
        ["a+b true", " false"]
    );
    let args = h
        .eval(
            "local a = require('@greed').commands()[1].args[1]
             return a.name .. ' ' .. a.doc .. ' ' .. a.complete",
        )
        .unwrap();
    assert_eq!(args, "who Who to greet buffer");
}

const TYPED: &str = r#"
local greed = require("@greed")
local function show(v)
  return if v == nil then "nil" else tostring(v)
end
greed.command {
  name = "typed",
  args = {
    { name = "n", type = "number" },
    { name = "flag", type = "boolean" },
    { name = "pick", type = "choice", choices = { "a", "b" } },
    { name = "more", type = "rest", optional = true },
  },
  run = function(ctx)
    local v = ctx.values
    greed.echo(`{show(v.n)} {show(v.flag)} {show(v.pick)} {show(v.more)} {#ctx.args}`)
  end,
}
greed.command {
  name = "two",
  args = { { name = "first", type = "string" }, { name = "second", type = "string", optional = true } },
  run = function(ctx)
    greed.echo(`{ctx.values.first} {show(ctx.values.second)}`)
  end,
}
greed.command {
  name = "paths",
  args = { { name = "file", type = "file", optional = true }, { name = "dir", type = "folder", optional = true } },
  run = function(ctx)
    greed.echo(`{show(ctx.values.file)} {show(ctx.values.dir)}`)
  end,
}
greed.command {
  name = "loose",
  args = { { name = "a" }, { name = "b" } },
  run = function(ctx)
    greed.echo(`{show(ctx.values.a)} {show(ctx.values.b)} {#ctx.args}`)
  end,
}
"#;

/// Runs `name` with `args` as `greed.run` does, giving back what it echoed
/// or the error it failed with.
fn run_with(h: &Host, name: &str, args: &[&str]) -> Result<String, String> {
    let list: Vec<String> = args.iter().map(|a| format!("{a:?}")).collect();
    h.eval(&format!(
        "require('@greed').run({name:?}, {{ args = {{ {} }} }})",
        list.join(", ")
    ))
    .map_err(|err| err.to_string())?;
    Ok(h.with_editor_mut(Editor::take_messages).join("\n"))
}

#[test]
fn typed_commands_get_their_arguments_parsed() {
    let h = host("");
    h.load_str("typed", TYPED).unwrap();
    assert_eq!(
        run_with(&h, "typed", &["3.5", "yes", "b", "x", "y"]).unwrap(),
        "3.5 true b x y 5"
    );
    assert_eq!(
        run_with(&h, "typed", &["-2", "OFF", "a"]).unwrap(),
        "-2 false a nil 3"
    );
    assert_eq!(run_with(&h, "two", &["one"]).unwrap(), "one nil");
    assert_eq!(run_with(&h, "two", &["one", "2"]).unwrap(), "one 2");
}

#[test]
fn typed_commands_refuse_wrong_arguments_with_their_usage() {
    let h = host("");
    h.load_str("typed", TYPED).unwrap();
    let usage = ":typed N FLAG PICK [MORE...]";
    for (args, why) in [
        (&[][..], "needs N and FLAG and PICK"),
        (&["1", "on"][..], "needs PICK"),
        (&["abc", "on", "a"][..], "\"abc\" isn't a number"),
        (&["inf", "on", "a"][..], "\"inf\" isn't a number"),
        (&["1", "maybe", "a"][..], "\"maybe\" isn't true or false"),
        (&["1", "on", "c"][..], "\"c\" isn't one of a, b"),
    ] {
        let err = run_with(&h, "typed", args).unwrap_err();
        assert!(err.contains(&format!("{usage}: {why}")), "{args:?}: {err}");
    }
    let err = run_with(&h, "two", &["a", "b", "c", "d"]).unwrap_err();
    assert!(
        err.contains(":two FIRST [SECOND]: too many arguments: \"c\" \"d\" left over"),
        "{err}"
    );
    assert!(h.with_editor_mut(Editor::take_messages).is_empty());
}

#[test]
fn file_and_folder_arguments_exist_and_resolve_from_the_project() {
    let dir = std::env::temp_dir().join(format!("greed-typed-args-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("src")).unwrap();
    std::fs::write(dir.join("src/main.rs"), "").unwrap();
    let h = host("");
    h.load_str("typed", TYPED).unwrap();
    h.with_editor_mut(|ed| {
        let id = ed.open_project(dir.clone());
        assert!(ed.switch_project(id));
    });
    let root = dir.to_string_lossy();
    assert_eq!(
        run_with(&h, "paths", &["src/../src/main.rs", "src"]).unwrap(),
        format!("{root}/src/main.rs {root}/src")
    );
    assert_eq!(
        run_with(&h, "paths", &[&format!("{root}/src/main.rs")]).unwrap(),
        format!("{root}/src/main.rs nil")
    );
    for (args, why) in [
        (&["nope.rs"][..], "there's no file \"nope.rs\""),
        (&["src"][..], "\"src\" is a folder; it needs a file"),
        (
            &["src/main.rs", "src/main.rs"][..],
            "\"src/main.rs\" is a file; it needs a folder",
        ),
        (&["src/main.rs", "gone"][..], "there's no folder \"gone\""),
    ] {
        let err = run_with(&h, "paths", args).unwrap_err();
        assert!(
            err.contains(&format!(":paths [FILE] [DIR]: {why}")),
            "{args:?}: {err}"
        );
    }
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn untyped_commands_get_their_words_unchecked() {
    let h = host("");
    h.load_str("typed", TYPED).unwrap();
    assert_eq!(run_with(&h, "loose", &[]).unwrap(), "nil nil 0");
    assert_eq!(run_with(&h, "loose", &["x"]).unwrap(), "x nil 1");
    assert_eq!(run_with(&h, "loose", &["x", "y", "z"]).unwrap(), "x y 3");
}

#[test]
fn argument_specs_that_cant_work_fail_when_the_command_is_added() {
    let h = host("");
    for (args, why) in [
        (
            "{ name = 'a', type = 'rest' }, { name = 'b' }",
            "argument a: a \"rest\" argument takes the rest of the words, so it has to be last",
        ),
        (
            "{ name = 'a', type = 'string', optional = true }, { name = 'b', type = 'string' }",
            "argument b: it comes after an optional one, so it has to be optional too",
        ),
        (
            "{ name = 'a', type = 'choice' }",
            "argument a: type \"choice\" needs choices",
        ),
        (
            "{ name = 'a', type = 'object' }",
            "argument a: type \"object\" needs kind",
        ),
        (
            "{ name = 'a', type = 'int' }",
            "argument a: there's no type \"int\"",
        ),
        (
            "{ name = 'a', choices = { 'x' } }",
            "argument a: choices go with type = \"choice\"",
        ),
        (
            "{ name = 'a', type = 'string', kind = 'pod' }",
            "argument a: kind goes with type = \"object\"",
        ),
    ] {
        let err = h
            .load_str(
                "bad",
                &format!(
                    "require('@greed').command {{ name = 'bad', args = {{ {args} }}, run = function() end }}"
                ),
            )
            .unwrap_err()
            .to_string();
        assert!(
            err.contains(&format!("command bad: {why}")),
            "{args}: {err}"
        );
    }
}

#[test]
fn object_arguments_are_found_by_the_object_finder() {
    let h = host("");
    h.load_str(
        "objs",
        r#"
        local greed = require("@greed")
        greed.command {
          name = "poke",
          args = { { name = "pod", type = "object", kind = "pod" } },
          run = function(ctx)
            greed.echo("poked " .. ctx.values.pod.id)
          end,
        }
        "#,
    )
    .unwrap();
    let err = run_with(&h, "poke", &["api"]).unwrap_err();
    assert!(
        err.contains(
            ":poke POD: nothing finds objects: the core plugin does that, and it isn't loaded"
        ),
        "{err}"
    );
    h.load_str(
        "finder",
        r#"
        local greed = require("@greed")
        greed.object_finder(function(kind, text)
          -- It runs in the command, so it can wait.
          greed.sleep(0)
          if text == "api" then
            return { kind = kind, id = kind .. ":" .. text, label = text, value = text }
          elseif text == "two" then
            return nil, "more than one pod is called \"two\""
          end
          return nil
        end)
        "#,
    )
    .unwrap();
    run_with(&h, "poke", &["api"]).unwrap();
    h.fire_timers(std::time::Instant::now()).unwrap();
    assert_eq!(h.with_editor_mut(Editor::take_messages), ["poked pod:api"]);
    // The finder waited, so the command fails as one that waited does.
    run_with(&h, "poke", &["two"]).unwrap();
    let err = h
        .fire_timers(std::time::Instant::now())
        .unwrap_err()
        .to_string();
    assert!(
        err.contains(":poke POD: more than one pod is called \"two\""),
        "{err}"
    );
    h.unload("finder").unwrap();
    assert!(
        run_with(&h, "poke", &["api"])
            .unwrap_err()
            .contains("nothing finds objects")
    );
}

#[test]
fn commands_show_their_argument_types() {
    let h = host("");
    h.load_str("typed", TYPED).unwrap();
    let shown = h
        .eval(
            "for _, c in require('@greed').commands() do
               if c.name == 'typed' then
                 local a = c.args
                 return table.concat({ c.usage, a[1].type, a[3].type, table.concat(a[3].choices, '/'),
                   tostring(a[4].optional), tostring(a[1].optional) }, ' ')
               end
             end",
        )
        .unwrap();
    assert_eq!(
        shown,
        "typed N FLAG PICK [MORE...] number choice a/b true false"
    );
}

#[test]
fn plugins_evaluate_code_in_a_shared_scratch_environment() {
    let h = host("");
    h.load_str(
        "calc",
        r#"
        local greed = require("@greed")
        greed.command { name = "calc", run = function(ctx)
          local ok, result = greed.eval(ctx.args[1])
          greed.echo(tostring(ok) .. ":" .. result)
        end }
        "#,
    )
    .unwrap();
    let calc = |code: &str| {
        h.eval(&format!(
            "require('@greed').run('calc', {{ args = {{ {code:?} }} }})"
        ))
        .unwrap();
        h.with_editor_mut(Editor::take_messages).pop().unwrap()
    };
    assert_eq!(calc("x = 41"), "true:");
    assert_eq!(calc("x + 1"), "true:42");
    assert_eq!(calc("1, 'two'"), "true:1\ttwo");
    let err = calc("error('nope')");
    assert!(err.starts_with("false:") && err.contains("nope"), "{err}");
    assert!(calc("1 +").starts_with("false:"));
}

#[test]
fn floats_change_size_and_title_after_they_open() {
    let h = host("main");
    h.eval("b = require('@greed').create_buffer('prompt', '')")
        .unwrap();
    h.eval("v = require('@greed').float(b, { title = 'Run', width = 30, height = 3, anchor = 'bottom' })")
        .unwrap();
    h.eval("v:configure({ height = 8, title = 'Run (2)' })")
        .unwrap();
    h.with_editor(|ed| {
        let float = &ed.floats()[0];
        assert_eq!(float.options.title.as_deref(), Some("Run (2)"));
        assert_eq!(float.options.height, greed_core::Extent::Cells(8));
        // Fields left out keep their values.
        assert_eq!(float.options.width, greed_core::Extent::Cells(30));
        assert_eq!(float.options.anchor, greed_core::Anchor::Bottom);
    });
    let configure = "require('@greed').view():configure({ height = 2 })";
    assert_eq!(h.eval(configure).unwrap(), "true", "the float is focused");
    h.eval("v:close()").unwrap();
    assert_eq!(h.eval(configure).unwrap(), "false", "a pane isn't floating");
}

#[test]
fn options_are_listed_with_their_docs_and_values() {
    let h = host("");
    h.load_str(
        "opts",
        "local o = require('@greed').option
         o.define { name = 'wrap', doc = 'Wrap long lines', default = true }
         o.define { name = 'tab-width', doc = 'Spaces per tab', default = 4 }
         o.set('tab-width', 2)",
    )
    .unwrap();
    let listed = h
        .eval(
            "local out = {}
             for _, o in require('@greed').option.list() do
               table.insert(out, o.name .. '=' .. tostring(o.value) .. ' (' .. o.doc .. ')')
             end
             return table.concat(out, ', ')",
        )
        .unwrap();
    assert_eq!(
        listed,
        "tab-width=2 (Spaces per tab), wrap=true (Wrap long lines)"
    );
}

#[test]
fn plugins_set_the_cursor_shape_per_mode() {
    let h = host("");
    h.eval("require('@greed').mode.set_cursor('edit', 'bar')")
        .unwrap();
    h.eval("require('@greed').mode.set_cursor('replace', 'underline')")
        .unwrap();
    h.with_editor_mut(|ed| {
        ed.set_mode("edit");
        assert_eq!(ed.cursor_shape(), greed_core::CursorShape::Bar);
        ed.set_mode("replace");
        assert_eq!(ed.cursor_shape(), greed_core::CursorShape::Underline);
    });
    let shapes = h
        .eval("local m = require('@greed').mode return m.cursor_of('edit') .. m.cursor_of() .. m.cursor_of('other')")
        .unwrap();
    assert_eq!(shapes, "barunderlineblock");
    let err = h
        .eval("require('@greed').mode.set_cursor('edit', 'blob')")
        .unwrap_err()
        .to_string();
    assert!(err.contains("block"), "{err}");
}

#[test]
fn plugins_unbind_keys_and_clear_layers() {
    let h = host("");
    h.load_str(
        "base",
        "local greed = require('@greed')
         greed.keymap.bind('helix', { w = 'next-word', x = 'select-line', ['g g'] = 'goto-start' })",
    )
    .unwrap();
    h.load_str(
        "mine",
        "local greed = require('@greed')
         greed.keymap.unbind('helix', { 'w' })
         greed.keymap.clear({ mode = 'insert' })",
    )
    .unwrap();
    let resolve = |keys: &str| {
        h.eval(&format!("require('@greed').keymap.resolve({keys:?})"))
            .unwrap()
    };
    assert_eq!(resolve("w"), "nil\tfalse");
    assert_eq!(resolve("x"), "select-line\tfalse");

    h.load_str(
        "vim",
        "local greed = require('@greed')
         greed.keymap.clear('helix')
         greed.keymap.bind('helix', { ['d d'] = 'delete-line' })",
    )
    .unwrap();
    assert_eq!(resolve("x"), "nil\tfalse");
    assert_eq!(resolve("d"), "nil\ttrue");
    assert_eq!(resolve("g g"), "nil\tfalse");

    h.load_str("vim", "").unwrap();
    assert_eq!(resolve("g g"), "goto-start\tfalse");
}

#[test]
fn commands_get_the_count_typed_before_them() {
    let h = host("");
    h.load_str(
        "counter",
        "local greed = require('@greed')
         greed.keymap.counts('helix')
         greed.command { name = 'show', run = function(ctx) greed.echo(tostring(ctx.count)) end }
         greed.keymap.bind('helix', { s = 'show' })",
    )
    .unwrap();
    h.press_keys("2 5 s s").unwrap();
    assert_eq!(h.with_editor_mut(Editor::take_messages), ["25", "nil"]);
}

#[test]
fn plugins_unload_unless_another_requires_them() {
    let base = plugin_dir(
        "unload-base",
        &[(
            "init.luau",
            "local greed = require('@greed')
             greed.command { name = 'hello', run = function() greed.echo('hi') end }
             greed.keymap.bind('helix', { h = 'hello' })
             return {}",
        )],
    );
    let user = plugin_dir("unload-user", &[("init.luau", "return {}")]);
    std::fs::write(
        user.join("plugin.toml"),
        "name = \"unload-user\"\nrequires = [\"unload-base\"]\n",
    )
    .unwrap();
    let h = host("");
    h.load_dir(&base).unwrap();
    h.load_dir(&user).unwrap();
    assert_eq!(
        h.eval("table.concat(require('@greed').plugin.list(), ',')")
            .unwrap(),
        "unload-base,unload-user"
    );

    let err = h.unload("unload-base").unwrap_err().to_string();
    assert!(err.contains("unload-user"), "{err}");
    h.eval("require('@greed').plugin.unload('unload-user')")
        .unwrap();
    h.unload("unload-base").unwrap();
    assert!(h.with_registry(|reg| reg.command("hello").is_none()));
    assert!(h.press_keys("h").is_ok(), "the key does nothing now");
    assert!(matches!(
        h.unload("unload-base"),
        Err(HostError::UnknownPlugin(_))
    ));
    std::fs::remove_dir_all(&base).unwrap();
    std::fs::remove_dir_all(&user).unwrap();
}

#[test]
fn plugins_set_the_theme() {
    use greed_core::theme::{Color, Medium, Underline};
    let h = host("");
    h.load_str(
        "colors",
        "require('@greed').theme.set({
           keyword = { fg = 'magenta', bold = true },
           ['diagnostic.error'] = { underline = 'curl', underline_color = 'red' },
           ['ui.selection'] = { bg = '#203040', tui = { bg = 'blue' } },
         })",
    )
    .unwrap();
    h.with_editor(|ed| {
        let theme = ed.theme();
        let keyword = theme.style("keyword.control", Medium::Tui);
        assert_eq!(
            (keyword.fg, keyword.bold),
            (Some(Color::Ansi(5)), Some(true))
        );
        let error = theme.style("diagnostic.error", Medium::Tui);
        assert_eq!(error.underline, Some(Underline::Curl));
        assert_eq!(
            theme.style("ui.selection", Medium::Tui).bg,
            Some(Color::Ansi(4))
        );
        assert_eq!(
            theme.style("ui.selection", Medium::Gui).bg,
            Some(Color::Rgb(0x20, 0x30, 0x40))
        );
    });
    assert_eq!(
        h.eval("require('@greed').theme.get('keyword').fg").unwrap(),
        "magenta"
    );
    let err = h
        .eval("require('@greed').theme.set({ x = { fg = 'chartreuse' } })")
        .unwrap_err()
        .to_string();
    assert!(err.contains("chartreuse"), "{err}");
    let err = h
        .eval("require('@greed').theme.set({ x = { colour = 'red' } })")
        .unwrap_err()
        .to_string();
    assert!(err.contains("colour"), "{err}");

    // A plugin's entries go when it does.
    h.load_str("colors", "").unwrap();
    assert!(h.with_editor(|ed| ed.theme().entry("keyword").is_none()));
}

#[test]
fn a_base_theme_switches_whole_and_entries_set_stay_on_top() {
    let h = host("");
    let fg = |name: &str| {
        h.eval(&format!(
            "return (require('@greed').theme.get('{name}') or {{}}).fg"
        ))
    };
    h.load_str(
        "themes",
        "local greed = require('@greed')
         greed.theme.base({ keyword = { fg = 'red' }, comment = { fg = 'blue', italic = true } })
         greed.command({ name = 'switch', run = function()
           greed.theme.base({ keyword = { fg = 'yellow' }, string = { fg = 'cyan' } })
         end })",
    )
    .unwrap();
    h.load_str(
        "mine",
        "require('@greed').theme.set({ keyword = { fg = 'green' }, comment = { italic = false } })",
    )
    .unwrap();
    assert_eq!(fg("keyword").unwrap(), "green", "set wins over the base");
    assert_eq!(
        fg("comment").unwrap(),
        "blue",
        "fields set leave the base's other fields"
    );
    assert_eq!(
        h.eval("return require('@greed').theme.get('comment').italic")
            .unwrap(),
        "false"
    );

    // Another base replaces the whole of the last one.
    h.run(FIRST_CLIENT, "switch").unwrap();
    assert_eq!(fg("keyword").unwrap(), "green", "still on top");
    assert_eq!(fg("comment").unwrap(), "nil", "the old base's entries go");
    assert_eq!(fg("string").unwrap(), "cyan");

    // Unloading the plugin that set an entry shows the base under it again,
    // and unloading the base's plugin takes the base away.
    h.load_str("mine", "").unwrap();
    assert_eq!(fg("keyword").unwrap(), "yellow");
    h.load_str("themes", "").unwrap();
    assert_eq!(fg("keyword").unwrap(), "nil");
}

#[test]
fn plugins_decorate_buffers() {
    let h = host("hello world");
    h.eval(
        "local b = require('@greed').view():buffer()
         b:decorate('search', { { from = 6, to = 11, style = 'match' }, { from = 0, to = 0, style = 'current', line = true } })",
    )
    .unwrap();
    h.with_editor(|ed| {
        let marks = ed.buffer(ed.view(ed.focus()).buffer).marks("search");
        assert_eq!(marks.len(), 2);
        assert_eq!(
            (marks[0].range.clone(), &*marks[0].style, marks[0].line),
            (6..11, "match", false)
        );
        assert!(marks[1].line);
    });
    assert_eq!(
        h.eval(
            "local m = require('@greed').view():buffer():decorations('search')[1]
             return m.from .. ' ' .. m.to .. ' ' .. m.style .. ' ' .. tostring(m.line)"
        )
        .unwrap(),
        "6 11 match false"
    );
    let err = h
        .eval("require('@greed').view():buffer():decorate('x', { { from = 0, to = 1 } })")
        .unwrap_err()
        .to_string();
    assert!(err.contains("style"), "{err}");
    h.eval("require('@greed').view():buffer():decorate('search', {})")
        .unwrap();
    assert_eq!(
        h.eval("#require('@greed').view():buffer():decorations('search')")
            .unwrap(),
        "0"
    );
}

#[test]
fn fuzzy_matches_say_where_they_matched() {
    let h = host("");
    assert_eq!(
        h.eval("table.concat(require('@greed').fuzzy_positions('mrs', 'src/main.rs'), ',')")
            .unwrap(),
        "4,9,10"
    );
    // Byte offsets, so multibyte characters before a match count fully.
    assert_eq!(
        h.eval("table.concat(require('@greed').fuzzy_positions('b', 'éb'), ',')")
            .unwrap(),
        "2"
    );
    assert_eq!(
        h.eval("#require('@greed').fuzzy_positions('zz', 'abc')")
            .unwrap(),
        "0"
    );
}

#[test]
fn marks_carry_inserted_text_signs_and_order() {
    let h = host("let x = 1");
    let shown = h
        .eval(
            "local b = require('@greed').view():buffer()
             b:decorate('lsp', { { from = 5, to = 5, style = 'hint', text = ': i32' },
                                 { from = 0, to = 3, style = 'diagnostic.error', text = 'oops', eol = true, sign = 'E', above = true } })
             local m = b:decorations('lsp')
             return m[1].text .. '|' .. m[2].text .. '|' .. tostring(m[2].eol) .. '|' .. m[2].sign .. '|' .. tostring(m[2].above) .. '|' .. tostring(m[1].sign)",
        )
        .unwrap();
    assert_eq!(shown, ": i32|oops|true|E|true|nil");
}

#[test]
fn plugins_set_file_types_and_find_programs() {
    let h = host("");
    assert_eq!(
        h.eval("table.concat(require('@greed').grammars(), ',')")
            .unwrap(),
        "bash,c,go,javascript,json,luau,markdown,nix,python,rust,toml,tsx,typescript,yaml"
    );
    h.eval(
        "require('@greed').filetype('python', { extensions = { 'py' }, names = { 'SConstruct' } })",
    )
    .unwrap();
    assert_eq!(
        h.eval("require('@greed').language_of('a/b.py'), require('@greed').language_of('SConstruct'), require('@greed').language_of('x.zz')")
            .unwrap(),
        "python\tpython\tnil"
    );
    assert_eq!(
        h.eval(
            "require('@greed').which('sh') ~= nil, require('@greed').which('no-such-program-greed')"
        )
        .unwrap(),
        "true\tnil"
    );
}

#[test]
fn plugins_open_panels_beside_the_main_view() {
    use greed_core::{Extent, Side};
    let h = host("main");
    h.eval("b = require('@greed').create_buffer('tree', 'src/')")
        .unwrap();
    h.eval("p = require('@greed').panel(b, { side = 'right', width = '30%', title = 'Files', focus = false })")
        .unwrap();
    h.with_editor(|ed| {
        let panel = &ed.panels()[0];
        assert_eq!(panel.options.side, Side::Right);
        assert_eq!(panel.options.width, Extent::percent(30));
        assert_eq!(panel.options.title.as_deref(), Some("Files"));
        assert_eq!(ed.focus(), ed.main(), "focus stays");
    });
    // Defaults: the left side, 30 cells, focused.
    h.eval("q = require('@greed').panel(require('@greed').create_buffer('x', ''))")
        .unwrap();
    h.with_editor(|ed| {
        let panel = &ed.panels()[1];
        assert_eq!(
            (panel.options.side, panel.options.width),
            (Side::Left, Extent::Cells(30))
        );
        assert_eq!(ed.focus(), panel.view);
    });
    assert_eq!(h.eval("p:close(), q:close()").unwrap(), "true\ttrue");
    assert!(h.with_editor(|ed| ed.panels().is_empty()));
    let err = h
        .eval("require('@greed').panel(require('@greed').create_buffer('x', ''), { side = 'top' })")
        .unwrap_err()
        .to_string();
    assert!(err.contains("left"), "{err}");
}

#[test]
fn plugins_search_buffers_with_regexes() {
    let h = host("a1 b2 c3");
    let eval = |code: &str| {
        h.eval(&format!(
            "local b = require('@greed').view():buffer()\n{code}"
        ))
        .unwrap()
    };
    assert_eq!(eval("return b:find('%d'), b:find('\\\\d')"), "nil\t1\t2");
    assert_eq!(eval("return b:find('\\\\d', 3)"), "4\t5");
    assert_eq!(
        eval("return b:find('\\\\d', 3, { backward = true })"),
        "1\t2"
    );
    assert_eq!(eval("return b:find('\\\\d', 8)"), "nil");
    assert_eq!(eval("return b:find('\\\\d', 8, { wrap = true })"), "1\t2");
    assert_eq!(
        eval(
            "local out = {}
             for _, m in b:find_all('[a-z]\\\\d') do table.insert(out, m.from .. '-' .. m.to) end
             return table.concat(out, ',')"
        ),
        "0-2,3-5,6-8"
    );
    assert_eq!(eval("return #b:find_all('\\\\d', 2, 5)"), "1");
    // Groups: the second takes no part in a match without an "x".
    assert_eq!(
        eval(
            "local g = b:find_groups('([a-z])(x)?\\\\d')[1] :: any
             return `{g[1].from}-{g[1].to} {g[2].from}-{g[2].to} {tostring(g[3])} {#g}`"
        ),
        "0-2 0-1 false 3"
    );
    let bad = eval(
        "local ok, _, err = b:find('('); local all, err2 = b:find_all('['); return tostring(ok) .. ' ' .. tostring(err ~= nil) .. ' ' .. tostring(all) .. ' ' .. tostring(err2 ~= nil)",
    );
    assert_eq!(bad, "nil true nil true");
}

#[test]
fn a_sikt_program_reads_rows_out_of_text_with_typed_values_and_where_they_are() {
    let h = host("");
    let eval = |code: &str| {
        h.eval(&format!("local greed = require('@greed')\n{code}"))
            .unwrap()
    };
    // Each match is a row of its captures; numbers come as numbers, and a
    // capture that didn't take part is missing. `at` says where each is.
    assert_eq!(
        eval(
            r#"local p = assert(greed.sikt.compile('find name: 1+ letter "=" (n: integer or word: 1+ letter) where name is not "skip"'))
               local rows, at = p:rows("a=1 b=x\nskip=2 c=30", { at = true })
               local out = {}
               for i, row in rows do
                 table.insert(out, `{row.name}:{row.n or row.word}:{type(row.n)}@{at[i].line}:{at[i].from}-{at[i].to}`)
               end
               return table.concat(out, ' ')"#
        ),
        "a:1:number@1:1-4 b:x:nil@1:5-8 c:30:number@2:16-20"
    );
    // A mistake says what and where; a warning comes with the program.
    assert_eq!(
        eval(
            r#"local p, why = greed.sikt.compile('year: 4 digts')
               local problems = greed.sikt.check('year: 4 digts')
               local warned = assert(greed.sikt.compile('0+ any "x"'))
               local warnings = greed.sikt.check('0+ any "x"')
               return tostring(p), why, problems[1].message, problems[1].at.from, problems[1].at.to,
                 problems[1].warning, #warned.warnings > 0, warnings[1].warning, #greed.sikt.check('"a"')"#
        ),
        "nil\tunknown word `digts` (at 9 in the program)\tunknown word `digts`\t9\t14\tfalse\ttrue\ttrue\t0"
    );
    // Rules from Luau, by name; captures and their types; replacing; and a
    // whole text at once rather than line by line.
    assert_eq!(
        eval(
            r#"local p = assert(greed.sikt.compile('use "kv" find kv', { modules = { kv = 'let kv = key: 1+ letter ":" size: size' } }))
               local caps = {}
               for _, c in p.captures do table.insert(caps, `{c.name}={c.type}`) end
               local swap = assert(greed.sikt.compile('find a: 1+ digit "-" b: 1+ digit replace "{b}-{a}"'))
               local across = assert(greed.sikt.compile('"a" newline "b"', { lines = false }))
               return p:rows("disk:1K")[1].size, p:rows("disk:1K", { text = true })[1].size,
                 table.concat(caps, ','), swap:replace("1-2, 30-4"), #across:rows("a\nb")"#
        ),
        "1024\t1K\tkey=text,size=size\t2-1, 4-30\t1"
    );
}

#[test]
fn sikt_reads_many_texts_on_other_threads() {
    let h = host("");
    h.load_str(
        "sikt-test",
        r##"local greed = require('@greed')
           greed.command { name = 'sikt-test', run = function()
             local p = assert(greed.sikt.compile('"#" tag: 1+ letter'))
             local texts = {}
             for i = 1, 100 do texts[i] = `note {i} #a\n#b{if i % 2 == 0 then ' #even' else ''}` end
             local all, at = p:rows_many(texts, { at = true })
             local plain = p:rows_many({})
             greed.echo(`{#all} {#all[1]} {#all[2]} {all[2][3].tag} {at[2][2].line} {#plain}`)
           end }"##,
    )
    .unwrap();
    h.run(FIRST_CLIENT, "sikt-test").unwrap();
    h.settle().unwrap();
    assert_eq!(
        h.with_editor_mut(Editor::take_messages).join(""),
        "100 2 3 even 2 0"
    );
}

#[test]
fn json_round_trips_and_empty_tables_are_objects_unless_marked() {
    let h = host("");
    let eval = |code: &str| {
        h.eval(&format!("local greed = require('@greed')\n{code}"))
            .unwrap()
    };
    assert_eq!(
        eval(
            "return greed.json.encode({ a = 1, list = { 'x', true }, empty = {}, none = greed.json.array() })"
        ),
        r#"{"a":1,"empty":{},"list":["x",true],"none":[]}"#
    );
    assert_eq!(
        eval("local v = greed.json.decode('{\"a\":[1,2],\"b\":null}') return v.a[2], v.b"),
        "2\tnil"
    );
    assert_eq!(
        eval("local v, err = greed.json.decode('{') return v, err ~= nil"),
        "nil\ttrue"
    );
    // JSON can't hold bytes that aren't UTF-8, like half a character cut
    // off or a program's binary output: they become U+FFFD, in values and
    // keys, however deep.
    assert_eq!(
        eval(
            "return greed.json.encode({ text = 'ok \\xE2\\x9C', list = { { ['k\\xFF'] = '\\x80' } } })"
        ),
        "{\"list\":[{\"k\u{fffd}\":\"\u{fffd}\"}],\"text\":\"ok \u{fffd}\"}"
    );
    assert_eq!(
        eval("return greed.json.encode(greed.json.array({ '\\xFF' }))"),
        "[\"\u{fffd}\"]"
    );
}

#[test]
fn signals_wake_whoever_waits_with_the_value_sent() {
    let h = host("");
    h.load_str(
        "signals",
        r#"
        local greed = require("@greed")
        local signal = nil
        greed.command { name = "wait", run = function()
          signal = greed.signal()
          greed.echo("got " .. signal.wait())
        end }
        greed.command { name = "send", run = function()
          signal.send("yes")
          signal.send("ignored")
        end }
        greed.command { name = "early", run = function()
          local s = greed.signal()
          s.send(42)
          greed.echo("early " .. s.wait())
        end }
        "#,
    )
    .unwrap();
    h.run(FIRST_CLIENT, "wait").unwrap();
    assert!(
        h.with_editor_mut(Editor::take_messages).is_empty(),
        "still waiting"
    );
    h.run(FIRST_CLIENT, "send").unwrap();
    assert_eq!(h.with_editor_mut(Editor::take_messages), ["got yes"]);
    h.run(FIRST_CLIENT, "early").unwrap();
    assert_eq!(h.with_editor_mut(Editor::take_messages), ["early 42"]);
}

#[test]
fn files_load_into_buffers_without_being_shown() {
    let dir = plugin_dir("load", &[("a.txt", "from disk")]);
    let h = host("main");
    let loaded = eval_in(
        &h,
        &dir,
        "local b = greed.load(DIR .. '/a.txt')
         return b:text() .. ' ' .. tostring(greed.load(DIR .. '/a.txt'):id() == b:id()) .. ' ' .. greed.view():buffer():text()",
    );
    std::fs::remove_dir_all(&dir).unwrap();
    assert_eq!(loaded, "from disk true main");
}

#[test]
fn diffs_come_back_as_line_changes() {
    let h = host("");
    assert_eq!(
        h.eval(
            "local c = require('@greed').diff('a\\nb\\n', 'a\\nB\\n')[1] return c.from, c.to, c.text"
        )
        .unwrap(),
        "2\t4\tB\n"
    );
}

#[test]
fn plugins_open_switch_and_close_projects() {
    let h = host("first");
    let eval = |code: &str| {
        h.eval(&format!("local greed = require('@greed')\n{code}"))
            .unwrap()
    };
    let first = eval("return greed.project.current().id");
    let second = eval("return greed.project.open('/work/other')");
    assert_eq!(
        eval("local p = greed.project.current() return p.root, p.current, #greed.project.list()"),
        "/work/other\ttrue\t2"
    );
    assert_eq!(
        eval("return greed.view():buffer():project() == greed.project.current().id"),
        "true",
        "the new project's empty buffer is its own"
    );
    assert_eq!(
        eval(&format!("return greed.project.switch({first})")),
        "true"
    );
    assert_eq!(eval("return greed.view():buffer():text()"), "first");
    assert_eq!(
        eval(&format!("return greed.project.close({second})")),
        "true"
    );
    assert_eq!(
        eval(&format!("return greed.project.close({first})")),
        "false",
        "the last one stays"
    );
}

#[test]
fn files_open_before_plugins_load_are_announced_once_they_have() {
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", "text", Some("notes.md".into()));
    editor.create_buffer("scratch", "not a file");
    let host = Host::new(editor).unwrap();
    host.load_str(
        "listen",
        "local greed = require('@greed')\ngreed.on('buffer.opened', function(e) greed.echo('opened ' .. e.buffer:path()) end)",
    )
    .unwrap();
    host.announce_open_files().unwrap();
    let messages = host.with_editor_mut(Editor::take_messages);
    let full = std::env::current_dir().unwrap().join("notes.md");
    assert_eq!(
        messages,
        [format!("opened {}", full.display())],
        "only buffers with files, by full path"
    );
}

#[test]
fn kept_buffers_stay_open_while_nothing_shows_them() {
    let h = host("");
    h.eval(
        r#"
        local greed = require("@greed")
        kept = greed.create_buffer("terminal", "shell")
        kept:set_kept(true)
        greed.view():show(kept)
        greed.view():show(greed.create_buffer("scratch", ""))
        "#,
    )
    .unwrap();
    assert_eq!(h.eval("kept:text()").unwrap(), "shell");
    assert_eq!(h.eval("kept:kept()").unwrap(), "true");
    h.eval("kept:set_kept(false)").unwrap();
    let err = h.eval("kept:text()").unwrap_err().to_string();
    assert!(err.contains("closed"), "{err}");
}

#[test]
fn plugins_hear_when_a_view_is_drawn_at_a_new_size() {
    use greed_core::render::{CellWidth, Plain, Renderer, Size, Status};
    let h = host("text");
    h.load_str(
        "sizes",
        r#"
        local greed = require("@greed")
        local seen = {}
        greed.on("view.resized", function(e)
            table.insert(seen, `{e.rows}x{e.cols}`)
            local rows, cols = e.view:size()
            assert(rows == e.rows and cols == e.cols)
        end)
        return seen
        "#,
    )
    .unwrap();
    let draw = |width, height| {
        h.with_editor_mut(|ed| {
            Renderer::new(CellWidth).frame(
                ed,
                Size { width, height },
                &Status::Default { message: None },
                &Plain,
            );
        });
        h.report_views().unwrap();
    };
    draw(40, 10);
    draw(40, 10);
    draw(50, 10);
    // The main view has a gutter of two cells for its line numbers.
    assert_eq!(
        h.eval("table.concat(require('@sizes'), ' ')").unwrap(),
        "9x38 9x48"
    );
}

#[test]
fn plugins_hear_once_a_frame_when_a_selection_changes() {
    let h = host("hello world");
    h.eval("greed = require('@greed')").unwrap();
    h.load_str(
        "selections",
        r#"
        local greed = require("@greed")
        local seen = {}
        greed.on("selection.changed", function(e)
            local range = e.view:selection().ranges[1]
            table.insert(seen, `{range.anchor}-{range.head}`)
        end)
        return seen
        "#,
    )
    .unwrap();
    let seen = || h.eval("table.concat(require('@selections'), ' ')").unwrap();
    h.report_selections().unwrap();
    assert_eq!(seen(), "", "nothing to compare with yet");

    // A plugin moving it twice, then a key, all before one frame.
    h.eval("greed.view():set_selection({ ranges = { { anchor = 0, head = 2 } } })")
        .unwrap();
    h.eval("greed.view():set_selection({ ranges = { { anchor = 0, head = 3 } } })")
        .unwrap();
    h.with_editor_mut(|ed| {
        let view = ed.focus();
        ed.view_mut(view).selection = Selection::single(1, 4);
    });
    h.report_selections().unwrap();
    assert_eq!(seen(), "1-4");

    h.report_selections().unwrap();
    assert_eq!(seen(), "1-4", "nothing changed");

    // Moved and moved back is no change.
    h.eval("greed.view():set_selection({ ranges = { { anchor = 0, head = 0 } } })")
        .unwrap();
    h.eval("greed.view():set_selection({ ranges = { { anchor = 1, head = 4 } } })")
        .unwrap();
    h.report_selections().unwrap();
    assert_eq!(seen(), "1-4");

    // An edit maps the selection along.
    h.eval("greed.view():buffer():edit(function(e) e:insert(0, 'oh ') end)")
        .unwrap();
    h.report_selections().unwrap();
    assert_eq!(seen(), "1-4 4-7");

    // Another buffer at the same place is a change too.
    h.eval("greed.view():show(greed.create_buffer('scratch', 'x'))")
        .unwrap();
    h.report_selections().unwrap();
    assert_eq!(seen(), "1-4 4-7 0-0");
}

#[test]
fn what_a_selection_handler_changes_is_told_in_the_same_frame() {
    let h = host("hello world");
    h.eval("greed = require('@greed')").unwrap();
    h.load_str(
        "snap",
        r#"
        local greed = require("@greed")
        local heads = {}
        greed.on("selection.changed", function(e)
            local head = e.view:selection().ranges[1].head
            table.insert(heads, head)
            if head == 3 then
                e.view:set_selection({ ranges = { { anchor = 5, head = 5 } } })
            end
        end)
        return heads
        "#,
    )
    .unwrap();
    h.report_selections().unwrap();
    h.eval("greed.view():set_selection({ ranges = { { anchor = 3, head = 3 } } })")
        .unwrap();
    h.report_selections().unwrap();
    assert_eq!(
        h.eval("table.concat(require('@snap'), ' ')").unwrap(),
        "3 5"
    );
}

#[test]
fn plugins_hear_when_another_view_has_focus() {
    let h = host("text");
    h.eval("greed = require('@greed')").unwrap();
    h.load_str(
        "focus",
        r#"
        local greed = require("@greed")
        local seen = {}
        greed.on("view.focused", function(e)
            local from = if e.from then e.from:buffer():text() else "nil"
            table.insert(seen, `{from}>{e.view:buffer():text()}`)
        end)
        return seen
        "#,
    )
    .unwrap();
    let seen = || h.eval("table.concat(require('@focus'), ' ')").unwrap();
    h.report_selections().unwrap();
    assert_eq!(seen(), "");

    h.eval(
        "main = greed.view(); pane = main:split('right', greed.create_buffer('scratch', 'pane'))",
    )
    .unwrap();
    h.eval("pane:focus()").unwrap();
    h.report_selections().unwrap();
    assert_eq!(seen(), "text>pane");

    h.eval("main:focus()").unwrap();
    h.report_selections().unwrap();
    assert_eq!(seen(), "text>pane pane>text");

    // There and back before a frame is no change.
    h.eval("pane:focus(); main:focus()").unwrap();
    h.report_selections().unwrap();
    assert_eq!(seen(), "text>pane pane>text");

    h.eval("float = greed.float(greed.create_buffer('scratch', 'float'))")
        .unwrap();
    h.report_selections().unwrap();
    assert_eq!(seen(), "text>pane pane>text text>float");

    h.eval("float:close()").unwrap();
    h.report_selections().unwrap();
    assert_eq!(seen(), "text>pane pane>text text>float nil>text");
}

#[test]
fn marks_lines_can_be_pieces_with_styles() {
    let h = host("a");
    h.eval(
        "local b = require('@greed').view():buffer()
         b:decorate('d', { { from = 0, to = 0, style = 'diff.plus', lines = {
           'plain',
           { { text = 'x = ' }, { text = '2', style = 'diff.plus.change' }, { text = ';' } },
         } } })",
    )
    .unwrap();
    let lines = h.with_editor(|ed| {
        ed.buffer(ed.view(ed.focus()).buffer).marks("d")[0]
            .lines
            .clone()
    });
    assert_eq!(&*lines[0].text, "plain");
    assert_eq!(&*lines[1].text, "x = 2;");
    assert_eq!(lines[1].styles, [(4..5, "diff.plus.change".into())]);
    let back = h
        .eval("local l = require('@greed').view():buffer():decorations('d')[1].lines; return l[1] .. '|' .. l[2][2].text .. '|' .. l[2][2].style")
        .unwrap();
    assert_eq!(back, "plain|2|diff.plus.change");
}

#[test]
fn waiting_calls_refuse_to_run_where_they_would_hold_up_the_editor() {
    let host = host("");
    for call in [
        "require('@greed').process.run({ 'sleep', '5' })",
        "require('@greed').fs.grep('x')",
        "require('@greed').http.request({ url = 'http://127.0.0.1:1/' })",
    ] {
        let started = std::time::Instant::now();
        let err = host.eval(call).unwrap_err().to_string();
        assert!(
            err.contains("waits, so it only works in a command"),
            "{call}: {err}"
        );
        assert!(
            started.elapsed() < Duration::from_secs(1),
            "{call} didn't block"
        );
    }
}

#[test]
fn table_handles_take_method_calls_and_plain_calls() {
    let host = host("");
    let out = host
        .eval(
            "local greed = require('@greed') \
             local c = assert(greed.process.spawn({ 'cat' })) \
             local a, b = c:write('x'), c.write('y') \
             c:kill() \
             local s = greed.signal() s:send({ 1 }) local t = greed.signal() t.send(2) \
             return tostring(a) .. tostring(b) .. type(c:stderr()) .. type(c.stderr()) \
               .. s:wait()[1] .. t.wait()",
        )
        .unwrap();
    assert_eq!(out, "truetruestringstring12");
    let err = host
        .eval("local c = require('@greed').process.spawn({ 'cat' }) c:kill() c:read()")
        .unwrap_err()
        .to_string();
    assert!(err.contains("child.read waits"), "{err}");
    assert!(
        err.starts_with("runtime error: repl:1:"),
        "it points at the caller: {err}"
    );
}

#[test]
fn marks_can_scale_text_up_from_one_to_four_times() {
    let h = host("# Big");
    h.eval(
        "require('@greed').view():buffer():decorate('rich', { { from = 0, to = 5, style = 'markup.heading', scale = 2 } })",
    )
    .unwrap();
    h.with_editor(|ed| {
        let marks = ed.buffer(ed.view(ed.focus()).buffer).marks("rich");
        assert_eq!(marks[0].scale, 2);
    });
    assert_eq!(
        h.eval("return require('@greed').view():buffer():decorations('rich')[1].scale")
            .unwrap(),
        "2"
    );
    for bad in ["0", "5", "1.5", "'big'"] {
        let err = h
            .eval(&format!(
                "require('@greed').view():buffer():decorate('rich', {{ {{ from = 0, to = 1, style = 'x', scale = {bad} }} }})"
            ))
            .unwrap_err()
            .to_string();
        assert!(
            err.contains("scale is a whole number from 1 to 4"),
            "{bad}: {err}"
        );
    }
}

#[test]
fn marks_say_when_concealed_text_shows() {
    let h = host("- [ ] task");
    h.eval(
        "require('@greed').view():buffer():decorate('md', { { from = 2, to = 5, style = 'x', conceal = true, reveal = 'never' } })",
    )
    .unwrap();
    h.with_editor(|ed| {
        let marks = ed.buffer(ed.view(ed.focus()).buffer).marks("md");
        assert_eq!(marks[0].reveal, greed_core::Reveal::Never);
    });
    assert_eq!(
        h.eval("return require('@greed').view():buffer():decorations('md')[1].reveal")
            .unwrap(),
        "never"
    );
    let err = h
        .eval("require('@greed').view():buffer():decorate('md', { { from = 0, to = 1, style = 'x', reveal = 'sometimes' } })")
        .unwrap_err()
        .to_string();
    assert!(err.contains("reveal is"), "{err}");
}

#[test]
fn reveal_sets_when_auto_marks_show_and_rejects_anything_else() {
    let h = host("- [ ] task");
    h.eval(
        "require('@greed').view():buffer():decorate('md', { { from = 2, to = 5, style = 'x', conceal = true, reveal = 'auto' } })",
    )
    .unwrap();
    assert_eq!(
        h.eval("return require('@greed').view():buffer():decorations('md')[1].reveal")
            .unwrap(),
        "auto"
    );
    h.eval("require('@greed').reveal('never')").unwrap();
    h.with_editor(|ed| assert_eq!(ed.reveal(), greed_core::Reveal::Never));
    let err = h
        .eval("require('@greed').reveal('auto')")
        .unwrap_err()
        .to_string();
    assert!(err.contains("reveal is"), "{err}");
}

#[test]
fn decorate_within_replaces_only_the_marks_starting_there() {
    let h = host("one two three");
    h.eval(
        "local b = require('@greed').view():buffer()
         b:decorate('w', { { from = 0, to = 3, style = 'a' }, { from = 4, to = 7, style = 'a' }, { from = 8, to = 13, style = 'a' } })
         b:decorate('w', { { from = 4, to = 6, style = 'b' } }, { from = 4, to = 8 })",
    )
    .unwrap();
    let styles = h
        .eval(
            "local out = {}
             for _, m in require('@greed').view():buffer():decorations('w') do
                 table.insert(out, `{m.from}-{m.to} {m.style}`)
             end
             table.sort(out)
             return table.concat(out, ', ')",
        )
        .unwrap();
    assert_eq!(styles, "0-3 a, 4-6 b, 8-13 a");
    let to_the_end = h
        .eval(
            "local b = require('@greed').view():buffer()
             b:decorate('w', {}, { from = 4 })
             return #b:decorations('w')",
        )
        .unwrap();
    assert_eq!(to_the_end, "1");
}

#[test]
fn buffer_version_grows_with_every_edit() {
    let h = host("text");
    let grew = h
        .eval(
            "local b = require('@greed').view():buffer()
             local before = b:version()
             b:edit(function(e) e:insert(0, 'x') end)
             local after = b:version()
             require('@greed').view():undo()
             return after > before and b:version() > after",
        )
        .unwrap();
    assert_eq!(grew, "true");
}

#[test]
fn sandboxed_eval_reads_and_edits_buffers_and_needs_approval_for_the_rest() {
    let h = host("hello");
    // What a sandbox may do: read the editor, edit the buffer.
    let ran = h
        .eval(
            r#"require('@greed').eval([[
                local greed = require("@greed")
                local b = greed.view():buffer()
                b:edit(function(e) e:insert(b:len(), " world") end)
                return b:len()
            ]], { sandbox = true })"#,
        )
        .unwrap();
    assert_eq!(ran, "true\t11");
    assert_eq!(text(&h), "hello world");
    // Reading how the editor is set up is fine too.
    let read = h
        .eval(
            r#"require('@greed').eval([[
                local greed = require("@greed")
                return #greed.plugin.list() >= 0 and #greed.option.list() >= 0
            ]], { sandbox = true })"#,
        )
        .unwrap();
    assert_eq!(read, "true\ttrue");
    // What it may not: each says what it would do, and that it needs approval.
    for (code, would) in [
        ("greed.process.run({ 'true' })", "run programs"),
        ("greed.run('save')", "run a command"),
        ("greed.keys.feed('x')", "type keys"),
        ("greed.option.set('indent', '  ')", "change options"),
        ("greed.fs.read('/etc/hostname')", "read or write files"),
        ("greed.fs.remove('/tmp/x')", "read or write files"),
        ("greed.hash.sha256_file('/etc/hostname')", "read files"),
        ("greed.view():buffer():save()", "write a file"),
        ("require('@core')", "require @core"),
        (
            "greed.project.switch(greed.project.open('/'))",
            "open, switch or close projects",
        ),
        (
            "greed.view():buffer():set_keys({ y = 'quit' })",
            "change a buffer's keys",
        ),
        (
            "greed.view():buffer():set_readonly(false)",
            "read-only or writable",
        ),
        (
            "greed.view():buffer():decorate('x', { { from = 0, to = 1, style = 'ui', action = 'quit' } })",
            "add buttons",
        ),
        (
            "local b = greed.create_buffer('page', 'ok', { readonly = true }) b:edit(function(e) e:insert(0, 'x') end)",
            "change a read-only buffer",
        ),
        (
            "greed.load('/etc/hostname')",
            "open a file outside the project",
        ),
        (
            "greed.load('../escape.txt')",
            "open a file outside the project",
        ),
    ] {
        assert_needs_approval(&h, code, would);
    }
    // Without the sandbox, the same code runs with every capability.
    assert_eq!(
        h.eval("require('@greed').eval('1 + 1')").unwrap(),
        "true\t2"
    );
}

/// Asserts that `code`, run in eval's sandbox, stops needing approval to do
/// `would`.
fn assert_needs_approval(h: &Host, code: &str, would: &str) {
    let source = format!("local greed = require('@greed')\n{code}");
    let lua = format!(
        "local ok, err = require('@greed').eval({source:?}, {{ sandbox = true }}) return tostring(ok) .. ' ' .. err"
    );
    let said = h.eval(&lua).unwrap();
    assert!(
        said.starts_with("false ")
            && said.contains("needs approval: it would")
            && said.contains(would),
        "{code}: {said}"
    );
}

#[test]
fn sandboxed_eval_needs_approval_to_change_what_you_see() {
    let h = host("hello");
    for (code, would) in [
        ("greed.view():close()", "close a view"),
        ("greed.view():focus()", "focus a view"),
        (
            "greed.view():show(greed.create_buffer('x', 'x'))",
            "show another buffer",
        ),
        ("greed.view():buffer():close()", "close a buffer"),
        ("greed.mode.set('insert')", "change the mode"),
        ("greed.tab.new()", "change the tabs"),
        ("greed.tab.close(greed.tab.current().id)", "change the tabs"),
        ("greed.tab.switch(1)", "change the tabs"),
        // A gated module says so when iterated, instead of looking empty.
        ("for _ in greed.keys do end", "greed.keys needs approval"),
        (
            "for _ in pairs(greed.keys) do end",
            "greed.keys needs approval",
        ),
        (
            "for _ in pairs(greed.client) do end",
            "greed.client needs approval",
        ),
    ] {
        assert_needs_approval(&h, code, would);
    }
    // Nothing the sandbox refused happened: the view and its buffer are
    // still there, in the mode and tab they were.
    assert_eq!(text(&h), "hello");
    assert_eq!(
        h.eval("local g = require('@greed') return #g.tab.list() .. ' ' .. g.mode.get()")
            .unwrap(),
        format!("1 {}", h.with_editor(|ed| ed.mode().to_owned()))
    );
}

#[test]
fn sandboxed_eval_still_moves_the_cursor_and_reads_tabs_modes_and_clients() {
    let h = host("hello");
    let ran = h
        .eval(
            r#"require('@greed').eval([[
                local greed = require("@greed")
                greed.view():set_cursor(2)
                return greed.view():cursor(), greed.mode.get() ~= nil,
                    greed.tab.current().id ~= nil, #greed.tab.list(), greed.client.id() ~= nil
            ]], { sandbox = true })"#,
        )
        .unwrap();
    assert_eq!(ran, "true\t2\ttrue\ttrue\t1\ttrue");
}

#[test]
fn greed_view_and_buffer_find_one_by_id() {
    let h = host("main");
    h.eval("g = require('@greed'); f = g.float(g.create_buffer('x', 'float'))")
        .unwrap();
    // The focused view with no id; the one asked for with one.
    assert_eq!(
        h.eval("g.view():id() == f:id()").unwrap(),
        h.eval("g.view(g.view():id()):id() == f:id()").unwrap()
    );
    assert_eq!(h.eval("g.view(f:id()):buffer():text()").unwrap(), "float");
    assert_eq!(h.eval("g.view(f:id()) == f").unwrap(), "true");
    assert_eq!(h.eval("g.view(9999) == nil").unwrap(), "true");
    assert_eq!(h.eval("g.buffer(f:buffer():id()):text()").unwrap(), "float");
    assert_eq!(h.eval("g.buffer(9999) == nil").unwrap(), "true");
}

#[test]
fn api_functions_given_arguments_they_dont_take_say_so() {
    let h = host("main");
    for (call, said) in [
        ("g.mode.get(61)", "greed.mode.get takes no arguments"),
        ("g.tab.current(61)", "greed.tab.current takes no arguments"),
        ("g.client.id(61)", "greed.client.id takes no arguments"),
        ("g.messages('x', 'y')", "greed.messages takes no arguments"),
        // Luau doesn't say which method runs, so a method isn't named.
        ("g.view():cursor(61)", "this function takes no arguments"),
    ] {
        let err = h
            .eval(&format!(
                "g = require('@greed') local ok, err = pcall(function() return {call} end) return tostring(ok) .. ' ' .. tostring(err)"
            ))
            .unwrap();
        assert!(
            err.starts_with("false ") && err.contains(said),
            "{call}: {err}"
        );
    }
    // With none, they work as before.
    assert_eq!(h.eval("g.tab.current().id ~= nil").unwrap(), "true");
}

#[test]
fn a_paste_reaches_plugins_and_the_system_clipboard_becomes_the_editors() {
    let host = host("");
    host.load_str(
        "pastes",
        "require('@greed').on('client.paste', function(e) require('@greed').echo('pasted ' .. e.text) end)",
    )
    .unwrap();
    host.paste(FIRST_CLIENT, "from the browser").unwrap();
    let said = host.with_editor_mut(greed_core::Editor::take_messages);
    assert!(
        said.iter().any(|m| m == "pasted from the browser"),
        "{said:?}"
    );

    host.with_editor_mut(|ed| ed.take_system_clipboard("copied elsewhere"));
    assert_eq!(
        host.eval("return require('@greed').clipboard.get()[1]")
            .unwrap(),
        "copied elsewhere"
    );
    let copied = host.with_editor_mut(|ed| {
        ed.take_system_clipboard("copied elsewhere");
        (ed.clipboard_history().count(), ed.take_copied())
    });
    assert_eq!(
        copied,
        (1, None),
        "taken once, and not sent back to the client"
    );
}

#[test]
fn floats_hide_and_carry_border_text_through_their_spec() {
    let h = host("main");
    h.eval(
        "g = require('@greed'); v = g.float(g.create_buffer('x', 'x'), { \
         label = { { text = '‹ 1/2 ›', style = 'ui.float.title' } }, footer = '●○' })",
    )
    .unwrap();
    assert_eq!(
        h.eval("v:float_spec().label[1].text .. v:float_spec().footer")
            .unwrap(),
        "‹ 1/2 ›●○"
    );
    h.eval("v:configure({ hidden = true, footer = '' })")
        .unwrap();
    assert_eq!(h.eval("#g.floats()").unwrap(), "0");
    assert_eq!(h.eval("#g.floats({ hidden = true })").unwrap(), "1");
    assert_eq!(
        h.eval("tostring(v:float_spec().hidden) .. tostring(v:float_spec().footer)")
            .unwrap(),
        "truenil"
    );
    h.eval("v:focus()").unwrap();
    assert_eq!(h.eval("#g.floats()").unwrap(), "1");
}

#[test]
fn edits_kept_out_of_undo_are_skipped_by_it() {
    let h = host("$ ");
    let view = focus(&h);
    h.eval(
        "local b = require('@greed').view():buffer(); b:edit(function(e) e:insert(2, 'ls') end)",
    )
    .unwrap();
    h.eval(
        "local b = require('@greed').view():buffer(); \
         b:edit(function(e) e:insert(0, 'out\\n') end, { undo = false })",
    )
    .unwrap();
    assert_eq!(text(&h), "out\n$ ls");
    assert!(h.with_editor_mut(|ed| ed.undo(view)).unwrap());
    assert_eq!(text(&h), "out\n$ ");
    assert!(!h.with_editor_mut(|ed| ed.undo(view)).unwrap());
}

#[test]
fn a_plugins_menus_and_claude_code_connection_go_with_it() {
    let dir = std::env::temp_dir().join(format!("greed-unload-ide-{}", std::process::id()));
    let h = host("");
    let (sender, _requests) = crossbeam_channel::unbounded();
    h.set_request_sender(sender);
    h.load_str(
        "connects",
        &format!(
            "local greed = require('@greed')
             greed.set_menus({{ {{ title = 'File', items = {{ {{ label = 'Save', command = 'write' }} }} }} }})
             greed.control.serve_ide({{ '/project' }}, {:?})",
            dir.to_str().unwrap()
        ),
    )
    .unwrap();
    let locks = || std::fs::read_dir(&dir).map_or(0, Iterator::count);
    assert_eq!(locks(), 1);
    assert_eq!(h.with_editor(|ed| ed.menus().len()), 1);

    h.unload("connects").unwrap();
    assert_eq!(
        locks(),
        0,
        "its lock file went, so Claude Code stops finding it"
    );
    assert!(h.with_editor(|ed| ed.menus().is_empty()));
    let _ = std::fs::remove_dir_all(&dir);
}
