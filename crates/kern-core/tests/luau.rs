use std::time::Duration;

use kern_core::luau::{Host, HostError};
use kern_core::registry::Value;
use kern_core::{Editor, ViewId};
use kern_text::{Author, ClientId, Range, Selection};

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
local kern = require("@kern")
kern.command {
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
kern.keymap.bind("normal", { ["m s"] = "wrap-in-some" })
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
        local kern = require("@kern")
        kern.command { name = "insert-char", run = function(ctx)
          local pos = ctx.view:selection().ranges[1].head
          ctx.buffer:edit(function(e) e:insert(pos, ctx.char) end)
        end }
        kern.command { name = "insert-mode", run = function() kern.mode.set("insert") end }
        kern.keymap.bind("normal", { i = "insert-mode" })
        kern.keymap.fallback("insert", "insert-char")
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
        "local kern = require('@kern')\nkern.command { name = 'boom', run = function()\n  error('nope')\nend }",
    )
    .unwrap();
    let err = h.run("boom").unwrap_err().to_string();
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
    assert!(matches!(h.run("nope"), Err(HostError::UnknownCommand(_))));
    h.load_str(
        "k",
        "require('@kern').keymap.bind('normal', { x = 'missing' })",
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
        "require('@kern').command { name = 'other', run = function() end }",
    )
    .unwrap();
    h.with_registry(|reg| {
        assert!(reg.command("wrap-in-some").is_none());
        assert!(reg.command("other").is_some());
    });
    h.with_editor(|ed| {
        assert!(ed.keymap().fallback("normal").is_none());
    });
    h.reload("p").unwrap();
    assert_eq!(h.with_registry(|reg| reg.definitions("other").len()), 1);
    assert!(matches!(h.reload("nope"), Err(HostError::UnknownPlugin(_))));
}

#[test]
fn plugin_directories_load_with_local_requires() {
    let dir = std::env::temp_dir().join(format!("kern-plugin-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("plugin.toml"), "name = \"greeter\"\n").unwrap();
    std::fs::write(dir.join("words.luau"), "return { hello = 'hi there' }\n").unwrap();
    std::fs::write(
        dir.join("init.luau"),
        "local kern = require('@kern')\nlocal words = require('@self/words')\nkern.command { name = 'greet', run = function() kern.echo(words.hello) end }\n",
    )
    .unwrap();

    let h = host("");
    let name = h.load_dir(&dir).unwrap();
    assert_eq!(&*name, "greeter");
    h.run("greet").unwrap();
    assert_eq!(h.with_editor_mut(Editor::take_messages), ["hi there"]);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn eval_returns_values_and_keeps_globals() {
    let h = host("hello");
    assert_eq!(h.eval("x = 40").unwrap(), "");
    assert_eq!(h.eval("x + 2").unwrap(), "42");
    assert_eq!(
        h.eval("require('@kern').view():buffer():text()").unwrap(),
        "hello"
    );
}

#[test]
fn mode_changes_emit_an_event() {
    let h = host("");
    h.load_str(
        "watch",
        r#"
        local kern = require("@kern")
        kern.on("mode.changed", function(ev) kern.echo(ev.from .. "->" .. ev.to) end)
        "#,
    )
    .unwrap();
    h.eval("require('@kern').mode.set('insert')").unwrap();
    h.eval("require('@kern').mode.set('insert')").unwrap();
    assert_eq!(h.with_editor_mut(Editor::take_messages), ["normal->insert"]);
}

#[test]
fn options_round_trip_through_luau() {
    let h = host("");
    h.load_str(
        "opts",
        "local o = require('@kern').option\no.define { name = 'tab-width', doc = 'Spaces per tab', default = 4 }",
    )
    .unwrap();
    assert_eq!(
        h.eval("require('@kern').option.get('tab-width')").unwrap(),
        "4"
    );
    h.eval("require('@kern').option.set('tab-width', 2)")
        .unwrap();
    assert_eq!(
        h.with_registry(|reg| reg.option("tab-width").cloned()),
        Some(Value::Int(2))
    );
    assert!(
        h.eval("require('@kern').option.set('tab-width', 'x')")
            .is_err()
    );
}

#[test]
fn buffer_helpers_use_byte_offsets_and_zero_based_lines() {
    let h = host("aé\nb\r\nlast");
    let eval = |s: &str| {
        h.eval(&format!(
            "(function() local b = require('@kern').view():buffer(); return {s} end)()"
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
    assert!(
        h.eval("require('@kern').view():buffer():char_at(2)")
            .is_err()
    );
    assert!(
        h.eval("require('@kern').view():buffer():slice(0, 99)")
            .is_err()
    );
}

#[test]
fn selections_round_trip_and_are_validated() {
    let h = host("hello world");
    h.eval("require('@kern').view():set_selection({ ranges = { { anchor = 0, head = 5 }, { anchor = 6, head = 11 } }, primary = 2 })")
        .unwrap();
    let sel = selection(&h);
    assert_eq!(sel.ranges(), &[Range::new(0, 5), Range::new(6, 11)]);
    assert_eq!(sel.primary(), Range::new(6, 11));
    assert_eq!(
        h.eval("require('@kern').view():selection().primary")
            .unwrap(),
        "2"
    );
    assert!(
        h.eval("require('@kern').view():set_selection({ ranges = { { anchor = 0, head = 50 } } })")
            .is_err()
    );
}

#[test]
fn overlapping_edits_are_rejected_without_changing_anything() {
    let h = host("hello");
    let err = h
        .eval(
            "require('@kern').view():buffer():edit(function(e) e:delete(0, 3) e:delete(2, 4) end)",
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
        "require('@kern').view():buffer():edit(function(e) e:insert(0, 'hi') end)",
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
    h.eval("require('@kern').view():buffer():edit(function(e) e:insert(0, 'x') end)")
        .unwrap();
    assert_eq!(h.eval("require('@kern').view():undo()").unwrap(), "true");
    assert_eq!(text(&h), "");
    assert_eq!(h.eval("require('@kern').view():undo()").unwrap(), "false");
    assert_eq!(h.eval("require('@kern').view():redo()").unwrap(), "true");
    assert_eq!(text(&h), "x");
}

/// Writes a plugin called `name` with `files` into a fresh temp directory.
fn plugin_dir(name: &str, files: &[(&str, &str)]) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("kern-{name}-{}", std::process::id()));
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
                "local a = require('@self/lib/a')\nrequire('@kern').echo(a.name, a.b)",
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
        ("bare", "require('kern')", "use \"@kern\""),
        (
            "self-outside-init",
            "require('./lib/x')",
            "outside the plugin",
        ),
        (
            "test-api",
            "require('@kern/test')",
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
fn scratch_buffers_float_and_go_away_when_closed() {
    let h = host("main");
    h.eval("b = require('@kern').create_buffer('picker', 'one\\ntwo')")
        .unwrap();
    h.eval("v = require('@kern').float(b, { title = 'Pick', width = 30, height = '50%' })")
        .unwrap();
    assert_eq!(
        h.eval("require('@kern').view():buffer():kind()").unwrap(),
        "picker"
    );
    h.with_editor(|ed| {
        let float = &ed.floats()[0];
        assert_eq!(float.options.title.as_deref(), Some("Pick"));
        assert_eq!(float.options.width, kern_core::Extent::Cells(30));
        assert_eq!(float.options.height, kern_core::Extent::Percent(50));
    });
    assert_eq!(h.eval("v:close()").unwrap(), "true");
    assert_eq!(
        h.eval("require('@kern').view():buffer():text()").unwrap(),
        "main"
    );
    let err = h.eval("b:text()").unwrap_err().to_string();
    assert!(err.contains("this buffer was closed"), "{err}");
    let err = h.eval("v:selection()").unwrap_err().to_string();
    assert!(err.contains("this view was closed"), "{err}");
    assert!(
        h.eval("require('@kern').float(require('@kern').create_buffer('x'), { anchor = 'left' })")
            .is_err()
    );
}

#[test]
fn edits_and_undo_announce_buffer_changes() {
    let h = host("");
    h.load_str(
        "watch",
        "local kern = require('@kern')\nkern.on('buffer.changed', function(ev) kern.echo('changed ' .. ev.buffer:text()) end)",
    )
    .unwrap();
    h.eval("require('@kern').view():buffer():edit(function(e) e:insert(0, 'x') end)")
        .unwrap();
    h.eval("require('@kern').view():undo()").unwrap();
    assert_eq!(
        h.with_editor_mut(Editor::take_messages),
        ["changed x", "changed "]
    );
}

#[test]
fn buffers_off_screen_can_be_edited() {
    let h = host("");
    h.eval("s = require('@kern').create_buffer('scratch', 'abc')")
        .unwrap();
    h.eval("s:edit(function(e) e:insert(3, 'd') end)").unwrap();
    assert_eq!(h.eval("s:text()").unwrap(), "abcd");
    assert_eq!(h.eval("#require('@kern').buffers()").unwrap(), "2");
}

#[test]
fn open_shows_a_file_in_the_main_view() {
    let dir = plugin_dir("open-files", &[("notes.md", "# Notes")]);
    let h = host("start");
    h.eval("b = require('@kern').create_buffer('picker')")
        .unwrap();
    h.eval("require('@kern').float(b)").unwrap();
    let path = dir.join("notes.md");
    h.eval(&format!(
        "require('@kern').open({:?})",
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
        .eval("(function() local c = require('@kern').commands()[1] return c.name .. '|' .. c.doc .. '|' .. c.owner end)()")
        .unwrap();
    assert_eq!(listed, "wrap-in-some|Wrap each selection in Some(...)|mine");
}

#[test]
fn fuzzy_matching_ranks_best_first() {
    let h = host("");
    let ranked = |q: &str| {
        h.eval(&format!(
            "table.concat(require('@kern').fuzzy({q:?}, {{ 'README.md', 'src/main.rs', 'Cargo.toml', 'src/lib.rs' }}), ',')"
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
            "table.concat(require('@kern').files({:?}), ',')",
            dir.to_str().unwrap()
        ))
        .unwrap();
    std::fs::remove_dir_all(&dir).unwrap();
    assert_eq!(listed, "README.md,plugin.toml,src/main.rs");
}

#[test]
fn status_lines_come_from_the_plugin_that_set_them() {
    let h = host("abc");
    assert_eq!(h.status_line(None, 80).unwrap(), None);
    h.load_str(
        "bar",
        "require('@kern').statusline(function(s) return { left = { { text = s.mode, style = 'mode' } }, right = { s.message or '-' } } end)",
    )
    .unwrap();
    let line = h.status_line(Some("hi"), 80).unwrap().unwrap();
    let text = |spans: &[kern_core::render::Span]| {
        spans.iter().map(|s| s.text.clone()).collect::<String>()
    };
    assert_eq!(text(&line.left), "normal");
    assert_eq!(text(&line.right), "hi");

    h.load_str("bar", "").unwrap();
    assert_eq!(h.status_line(None, 80).unwrap(), None);

    h.load_str("bad", "require('@kern').statusline(function() return { left = { { text = 'x', style = 'loud' } } } end)")
        .unwrap();
    let err = h.status_line(None, 80).unwrap_err().to_string();
    assert!(err.contains("style must be"), "{err}");
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
            "require('@kern').echo(require('@lib').greet())",
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
