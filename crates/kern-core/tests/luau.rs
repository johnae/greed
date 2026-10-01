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

/// Evaluates `source` with `DIR` set to `dir`.
fn eval_in(h: &Host, dir: &std::path::Path, source: &str) -> String {
    h.eval(&format!(
        "local kern = require('@kern')\nlocal DIR = {:?}\n{source}",
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
                 for _, e in kern.fs.list(DIR{opts}) do
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
        "local list, err = kern.fs.list(DIR .. '/nope') return tostring(list) .. ' ' .. tostring(err ~= nil)",
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
            &format!("local text, err = kern.fs.read(DIR .. '/a.txt'{args}) return text or err"),
        )
    };
    assert_eq!(read(""), "héllo\nworld\n");
    // A limit inside "é" stops before it rather than splitting it.
    assert_eq!(read(", 2"), "h");
    assert_eq!(read(", 3"), "hé");
    let missing = eval_in(
        &h,
        &dir,
        "local text, err = kern.fs.read(DIR .. '/nope') return tostring(text) .. ' ' .. err",
    );
    assert!(missing.starts_with("nil "), "{missing}");

    let stat = eval_in(
        &h,
        &dir,
        "local f, d = kern.fs.stat(DIR .. '/a.txt'), kern.fs.stat(DIR)
         return f.kind .. ' ' .. f.size .. ' ' .. d.kind .. ' ' .. tostring(kern.fs.stat(DIR .. '/nope'))",
    );
    std::fs::remove_dir_all(&dir).unwrap();
    assert_eq!(stat, "file 13 dir nil");
}

#[test]
fn status_lines_come_from_the_plugin_that_set_them() {
    let h = host("abc");
    assert_eq!(h.status_line(None, 80).unwrap(), None);
    h.load_str(
        "bar",
        "require('@kern').statusline(function(s) return { left = { { text = s.mode, style = 'ui.statusline.mode' } }, right = { s.message or '-' } } end)",
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

    // Any style name works; it's drawn over the status line's own style.
    h.load_str("loud", "require('@kern').statusline(function() return { left = { { text = 'x', style = 'loud' } } } end)")
        .unwrap();
    let line = h.status_line(None, 80).unwrap().unwrap();
    let names: Vec<&str> = line.left[0]
        .tags
        .iter()
        .map(kern_core::render::Tag::name)
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

#[test]
fn running_a_command_is_announced() {
    let h = host("");
    h.load_str(
        "log",
        "local kern = require('@kern')\nkern.command { name = 'noop', run = function() end }\nkern.on('command.run', function(ev) kern.echo('ran ' .. ev.name) end)",
    )
    .unwrap();
    h.run("noop").unwrap();
    assert_eq!(h.with_editor_mut(Editor::take_messages), ["ran noop"]);
}

#[test]
fn a_single_file_loads_as_a_plugin_with_local_requires() {
    let dir = plugin_dir(
        "config",
        &[
            (
                "init.luau",
                "require('@kern').echo(require('@self/helpers').name)",
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
local kern = require("@kern")
kern.command { name = "later", run = function(ctx)
  kern.echo("before")
  kern.sleep(500)
  kern.echo("after")
  ctx.buffer:edit(function(e) e:insert(0, "!") end)
end }
"#;

#[test]
fn commands_can_wait_without_blocking() {
    let h = host("");
    h.load_str("sleepy", SLEEPY).unwrap();
    h.run("later").unwrap();
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
    let err = h.eval("require('@kern').sleep(1)").unwrap_err().to_string();
    assert!(err.contains("can only be used in a command"), "{err}");

    h.load_str(
        "raw",
        "require('@kern').command { name = 'raw', run = function() coroutine.yield() end }",
    )
    .unwrap();
    let err = h.run("raw").unwrap_err().to_string();
    assert!(
        err.contains("can only wait through kern functions"),
        "{err}"
    );
}

#[test]
fn plugins_make_read_only_buffers_in_a_language() {
    let h = host("");
    h.load_str(
        "viewer",
        r#"
        local kern = require("@kern")
        local buffer = kern.create_buffer("preview", "fn main() {}", { readonly = true, language = "rust" })
        kern.float(buffer)
        kern.command { name = "type-x", run = function(ctx)
          ctx.buffer:edit(function(e) e:insert(0, "x") end)
        end }
        kern.command { name = "comment-out", run = function()
          buffer:edit(function(e) e:insert(0, "// ") end)
        end }
        kern.command { name = "describe", run = function()
          kern.echo(tostring(buffer:readonly()) .. " " .. tostring(buffer:language()))
        end }
        kern.command { name = "unlock", run = function()
          buffer:set_readonly(false)
          buffer:set_language(nil)
        end }
        "#,
    )
    .unwrap();
    let err = h.run("type-x").unwrap_err().to_string();
    assert!(err.contains("read-only"), "{err}");
    h.run("comment-out").unwrap();
    assert_eq!(text(&h), "// fn main() {}");
    h.run("describe").unwrap();
    h.run("unlock").unwrap();
    h.run("describe").unwrap();
    h.run("type-x").unwrap();
    assert_eq!(text(&h), "x// fn main() {}");
    assert_eq!(
        h.with_editor_mut(Editor::take_messages),
        ["true rust", "false nil"]
    );
    assert_eq!(
        h.eval(
            "require('@kern').language_of('src/a.rs'), require('@kern').language_of('Makefile')"
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
        local kern = require("@kern")
        kern.command {
          name = "greet",
          doc = "Say hello",
          args = { { name = "who", doc = "Who to greet", complete = "buffer" } },
          run = function(ctx)
            kern.echo(table.concat(ctx.args, "+") .. " " .. tostring(ctx.force))
          end,
        }
        kern.keymap.bind("normal", { g = "greet" })
        "#,
    )
    .unwrap();
    h.eval("require('@kern').run('greet', { args = { 'a', 'b' }, force = true })")
        .unwrap();
    h.press_keys("g").unwrap();
    assert_eq!(
        h.with_editor_mut(Editor::take_messages),
        ["a+b true", " false"]
    );
    let args = h
        .eval(
            "local a = require('@kern').commands()[1].args[1]
             return a.name .. ' ' .. a.doc .. ' ' .. a.complete",
        )
        .unwrap();
    assert_eq!(args, "who Who to greet buffer");
}

#[test]
fn plugins_evaluate_code_in_a_shared_scratch_environment() {
    let h = host("");
    h.load_str(
        "calc",
        r#"
        local kern = require("@kern")
        kern.command { name = "calc", run = function(ctx)
          local ok, result = kern.eval(ctx.args[1])
          kern.echo(tostring(ok) .. ":" .. result)
        end }
        "#,
    )
    .unwrap();
    let calc = |code: &str| {
        h.eval(&format!(
            "require('@kern').run('calc', {{ args = {{ {code:?} }} }})"
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
    h.eval("b = require('@kern').create_buffer('prompt', '')")
        .unwrap();
    h.eval("v = require('@kern').float(b, { title = 'Run', width = 30, height = 3, anchor = 'bottom' })")
        .unwrap();
    h.eval("v:configure({ height = 8, title = 'Run (2)' })")
        .unwrap();
    h.with_editor(|ed| {
        let float = &ed.floats()[0];
        assert_eq!(float.options.title.as_deref(), Some("Run (2)"));
        assert_eq!(float.options.height, kern_core::Extent::Cells(8));
        // Fields left out keep their values.
        assert_eq!(float.options.width, kern_core::Extent::Cells(30));
        assert_eq!(float.options.anchor, kern_core::Anchor::Bottom);
    });
    let err = h
        .eval("require('@kern').view():configure({ height = 2 })")
        .err();
    assert!(err.is_none(), "the float is focused");
    h.eval("v:close()").unwrap();
    let err = h
        .eval("require('@kern').view():configure({ height = 2 })")
        .unwrap_err()
        .to_string();
    assert!(err.contains("floating"), "{err}");
}

#[test]
fn options_are_listed_with_their_docs_and_values() {
    let h = host("");
    h.load_str(
        "opts",
        "local o = require('@kern').option
         o.define { name = 'wrap', doc = 'Wrap long lines', default = true }
         o.define { name = 'tab-width', doc = 'Spaces per tab', default = 4 }
         o.set('tab-width', 2)",
    )
    .unwrap();
    let listed = h
        .eval(
            "local out = {}
             for _, o in require('@kern').option.list() do
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
    h.eval("require('@kern').mode.cursor('edit', 'bar')")
        .unwrap();
    h.eval("require('@kern').mode.cursor('replace', 'underline')")
        .unwrap();
    h.with_editor_mut(|ed| {
        ed.set_mode("edit");
        assert_eq!(ed.cursor_shape(), kern_core::CursorShape::Bar);
        ed.set_mode("replace");
        assert_eq!(ed.cursor_shape(), kern_core::CursorShape::Underline);
    });
    let err = h
        .eval("require('@kern').mode.cursor('edit', 'blob')")
        .unwrap_err()
        .to_string();
    assert!(err.contains("block"), "{err}");
}

#[test]
fn plugins_unbind_keys_and_clear_layers() {
    let h = host("");
    h.load_str(
        "base",
        "local kern = require('@kern')
         kern.keymap.bind('normal', { w = 'next-word', x = 'select-line', ['g g'] = 'goto-start' })",
    )
    .unwrap();
    h.load_str(
        "mine",
        "local kern = require('@kern')
         kern.keymap.unbind('normal', { 'w' })
         kern.keymap.clear({ mode = 'insert' })",
    )
    .unwrap();
    let resolve = |keys: &str| {
        h.eval(&format!("require('@kern').keymap.resolve({keys:?})"))
            .unwrap()
    };
    assert_eq!(resolve("w"), "nil\tfalse");
    assert_eq!(resolve("x"), "select-line\tfalse");

    h.load_str(
        "vim",
        "local kern = require('@kern')
         kern.keymap.clear('normal')
         kern.keymap.bind('normal', { ['d d'] = 'delete-line' })",
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
        "local kern = require('@kern')
         kern.keymap.counts('normal')
         kern.command { name = 'show', run = function(ctx) kern.echo(tostring(ctx.count)) end }
         kern.keymap.bind('normal', { s = 'show' })",
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
            "local kern = require('@kern')
             kern.command { name = 'hello', run = function() kern.echo('hi') end }
             kern.keymap.bind('normal', { h = 'hello' })
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
        h.eval("table.concat(require('@kern').plugin.list(), ',')")
            .unwrap(),
        "unload-base,unload-user"
    );

    let err = h.unload("unload-base").unwrap_err().to_string();
    assert!(err.contains("unload-user"), "{err}");
    h.eval("require('@kern').plugin.unload('unload-user')")
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
    use kern_core::theme::{Color, Surface, Underline};
    let h = host("");
    h.load_str(
        "colors",
        "require('@kern').theme.set({
           keyword = { fg = 'magenta', bold = true },
           ['diagnostic.error'] = { underline = 'curl', underline_color = 'red' },
           ['ui.selection'] = { bg = '#203040', tui = { bg = 'blue' } },
         })",
    )
    .unwrap();
    h.with_editor(|ed| {
        let theme = ed.theme();
        let keyword = theme.style("keyword.control", Surface::Tui);
        assert_eq!(
            (keyword.fg, keyword.bold),
            (Some(Color::Ansi(5)), Some(true))
        );
        let error = theme.style("diagnostic.error", Surface::Tui);
        assert_eq!(error.underline, Some(Underline::Curl));
        assert_eq!(
            theme.style("ui.selection", Surface::Tui).bg,
            Some(Color::Ansi(4))
        );
        assert_eq!(
            theme.style("ui.selection", Surface::Gui).bg,
            Some(Color::Rgb(0x20, 0x30, 0x40))
        );
    });
    assert_eq!(
        h.eval("require('@kern').theme.get('keyword').fg").unwrap(),
        "magenta"
    );
    let err = h
        .eval("require('@kern').theme.set({ x = { fg = 'chartreuse' } })")
        .unwrap_err()
        .to_string();
    assert!(err.contains("chartreuse"), "{err}");
    let err = h
        .eval("require('@kern').theme.set({ x = { colour = 'red' } })")
        .unwrap_err()
        .to_string();
    assert!(err.contains("colour"), "{err}");

    // A plugin's entries go when it does.
    h.load_str("colors", "").unwrap();
    assert!(h.with_editor(|ed| ed.theme().entry("keyword").is_none()));
}
