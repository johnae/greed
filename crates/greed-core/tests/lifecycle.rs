//! Plugins own what they make: unloading one takes it all away, and
//! reloading one doesn't leave the old copy running.

use std::path::Path;
use std::time::{Duration, Instant};

use greed_core::image::ImageId;
use greed_core::luau::Host;
use greed_core::{Editor, FIRST_CLIENT};
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

/// When the first timer, due every `period` ms, started counting. Counting
/// from it rather than from the time before loading keeps a busy machine,
/// where loading takes a while, from moving timers in or out of a window.
fn started(h: &Host, period: u64) -> Instant {
    h.next_timer()
        .and_then(|at| at.checked_sub(Duration::from_millis(period)))
        .unwrap()
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
    h.load_str("ticker", TICKER).unwrap();
    let start = started(&h, 100);
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
    h.load_str("ticker", TICKER).unwrap();
    h.reload("ticker").unwrap();
    h.load_str("ticker", TICKER).unwrap();
    let start = started(&h, 100);
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
    h.run(FIRST_CLIENT, "call-slow").unwrap();
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
    h.run(FIRST_CLIENT, "go").unwrap();
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
fn a_plugins_scenes_change_by_version_and_go_with_it() {
    let h = host();
    h.load_str(
        "sketches",
        r#"local greed = require("@greed")
        local id = greed.scene.new({ alt = "a dot", items = { { kind = "dots", points = { { 1, 1 } } } } })
        assert(greed.scene.set(id, { alt = "two", items = {} }))
        greed.echo(tostring(id))"#,
    )
    .unwrap();
    let id = greed_core::scene::SceneId(messages(&h)[0].parse().unwrap());
    let scene = h.with_editor(|ed| ed.scenes().get(id).cloned()).unwrap();
    assert_eq!((scene.version, scene.spec.alt.as_str()), (2, "two"));
    let err = h
        .eval("require('@greed').scene.new({ items = 3 })")
        .unwrap_err()
        .to_string();
    assert!(err.contains("a scene is { alt"), "{err}");
    h.unload("sketches").unwrap();
    assert!(h.with_editor(|ed| ed.scenes().get(id).is_none()));
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

#[test]
fn reloading_keeps_the_options_a_plugin_defines() {
    let h = host();
    h.load_str(
        "opts",
        r#"require("@greed").option.define { name = "opts-width", default = 4 }"#,
    )
    .unwrap();
    h.eval("require('@greed').option.set('opts-width', 2)")
        .unwrap();
    h.reload("opts").unwrap();
    assert_eq!(
        h.eval("require('@greed').option.get('opts-width')")
            .unwrap(),
        "2"
    );
}

#[test]
fn init_cleanup_returns_its_owner_and_cancels_shared_work_synchronously() {
    let h = host();
    h.load_str(
        "observer",
        r#"
local greed = require("@greed")
local pending = true
local cleaned_by
return {
    cancel = function()
        cleaned_by = greed.plugin.caller()
        pending = false
    end,
    pending = function() return pending end,
    cleaned_by = function() return cleaned_by end,
}
"#,
    )
    .unwrap();
    h.load_str(
        "cleanup",
        r#"
local greed = require("@greed")
local observer = require("@observer")
local owner = greed.plugin.tie(observer.cancel)
assert(owner == "cleanup")
greed.spawn(function()
    greed.sleep(100)
    assert(not observer.pending())
end)
"#,
    )
    .unwrap();
    h.unload("cleanup").unwrap();
    assert_eq!(h.eval("require('@observer').pending()").unwrap(), "false");
    assert_eq!(
        h.eval("require('@observer').cleaned_by()").unwrap(),
        "cleanup"
    );
    assert!(h.next_timer().is_none());
}

#[test]
fn self_owned_cleanup_keeps_its_capability_limits() {
    let h = host();
    let dir = plugin_folder(
        "limited-cleanup",
        &[
            (
                "plugin.toml",
                "name = \"limited-cleanup\"\ncapabilities = []\n",
            ),
            (
                "init.luau",
                r#"
local greed = require("@greed")
greed.plugin.tie(function()
    local ok = pcall(greed.process.spawn, { "cat" })
    assert(not ok)
    greed.echo("capability limit kept")
end)
"#,
            ),
        ],
    );
    h.load_dir(&dir).unwrap();
    h.unload("limited-cleanup").unwrap();
    assert_eq!(messages(&h), ["capability limit kept"]);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn self_owned_cleanup_cannot_leave_a_yielded_task() {
    let h = host();
    h.load_str(
        "cleanup",
        r#"
local greed = require("@greed")
greed.plugin.tie(function()
    greed.command { name = "failed-cleanup", run = function() greed.echo("escaped command") end }
    greed.sleep(1)
    greed.echo("escaped cleanup")
end)
greed.plugin.tie(function() greed.echo("other cleanup") end)
"#,
    )
    .unwrap();
    assert!(h.unload("cleanup").is_err());
    assert_eq!(messages(&h), ["other cleanup"]);
    assert!(h.next_timer().is_none());
    assert!(h.run(FIRST_CLIENT, "failed-cleanup").is_err());
    h.fire_timers(Instant::now() + Duration::from_secs(1))
        .unwrap();
    assert!(messages(&h).is_empty());
    // The failed unload leaves the plugin loaded, but the rejected cleanup
    // must not be resumable even after a subsequent successful unload.
    h.unload("cleanup").unwrap();
    h.fire_timers(Instant::now() + Duration::from_secs(2))
        .unwrap();
    assert!(messages(&h).is_empty());
}

#[test]
fn self_owned_cleanup_cannot_create_surviving_resources() {
    let h = host();
    h.load_str(
        "observer",
        r#"
local child
return {
    keep = function(value) child = value end,
    writable = function() return child:write("still alive") end,
}
"#,
    )
    .unwrap();
    h.load_str(
        "cleanup",
        r#"
local greed = require("@greed")
greed.plugin.tie(function()
    greed.command { name = "escaped-cleanup", run = function() greed.echo("escaped command") end }
    greed.spawn(function() greed.sleep(1); greed.echo("escaped task") end)
    greed.plugin.tie(function() greed.echo("escaped tie") end)
    local child = greed.process.spawn({ "cat" })
    assert(child:write("alive"))
    require("@observer").keep(child)
end)
"#,
    )
    .unwrap();
    h.unload("cleanup").unwrap();
    assert!(h.run(FIRST_CLIENT, "escaped-cleanup").is_err());
    assert_eq!(h.eval("require('@observer').writable()").unwrap(), "false");
    assert!(h.next_timer().is_none());
    h.fire_timers(Instant::now() + Duration::from_secs(1))
        .unwrap();
    assert!(messages(&h).is_empty());
}

const REGISTRY: &str = r#"
local greed = require("@greed")
local names: { string } = {}
greed.command { name = "names", run = function() greed.echo(table.concat(names, ",")) end }
local function add(name: string)
  table.insert(names, name)
  return greed.plugin.tie(function()
    table.remove(names, table.find(names, name))
  end)
end
add("own")
return {
  add = add,
  caller = function() return greed.plugin.caller() end,
}
"#;

fn names(h: &Host) -> String {
    h.run(FIRST_CLIENT, "names").unwrap();
    messages(h).join(";")
}

#[test]
fn what_a_plugin_adds_to_anothers_registry_goes_when_it_does() {
    let h = host();
    h.load_str("registry", REGISTRY).unwrap();
    h.load_str(
        "adder",
        r#"assert(require("@registry").add("mine") == "adder")"#,
    )
    .unwrap();
    assert_eq!(names(&h), "own,mine");
    h.reload("adder").unwrap();
    assert_eq!(names(&h), "own,mine", "reloading adds it once");
    h.unload("adder").unwrap();
    assert_eq!(
        names(&h),
        "own",
        "the registry's own entry stays until it unloads"
    );
}

#[test]
fn the_caller_is_the_innermost_other_plugin() {
    let h = host();
    h.load_str("registry", REGISTRY).unwrap();
    h.load_str(
        "helper",
        r#"return { add = function(name) return require("@registry").add(name) end }"#,
    )
    .unwrap();
    h.load_str(
        "user",
        r#"
        local greed = require("@greed")
        assert(require("@helper").add("through") == "helper")
        assert(require("@registry").caller() == "user")
        assert(greed.plugin.caller() == nil)
        "#,
    )
    .unwrap();
    h.unload("user").unwrap();
    assert_eq!(names(&h), "own,through");
    h.unload("helper").unwrap();
    assert_eq!(names(&h), "own");
}

#[test]
fn ties_go_with_the_registry_without_running() {
    let h = host();
    h.load_str("registry", REGISTRY).unwrap();
    h.load_str("adder", r#"require("@registry").add("mine")"#)
        .unwrap();
    h.load_str("registry", REGISTRY).unwrap();
    // The new registry starts empty, and the old one's ties don't touch it.
    h.unload("adder").unwrap();
    assert_eq!(names(&h), "own");
}

fn runtime(name: &str) -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../runtime/plugins")
        .join(name)
}

#[test]
fn a_status_line_piece_goes_with_its_plugin_and_stops_refreshing() {
    let h = host();
    h.load_dirs(&[runtime("core"), runtime("helix"), runtime("statusline")])
        .unwrap();
    h.load_str(
        "clock",
        r#"
        require("@statusline").add_async("right", "clock", {
          refresh = function()
            require("@greed").echo("refreshed")
            return "12:00"
          end,
          every = 100,
        })
        "#,
    )
    .unwrap();
    let start = started(&h, 100);
    pass(&h, start, 250);
    assert_eq!(messages(&h), ["refreshed", "refreshed", "refreshed"]);
    let pieces = "local names = {} for _, e in require('@statusline').right do table.insert(names, e.name) end return table.concat(names, ' ')";
    assert!(h.eval(pieces).unwrap().contains("clock"));
    h.unload("clock").unwrap();
    assert!(!h.eval(pieces).unwrap().contains("clock"));
    pass(&h, start, 1000);
    assert!(messages(&h).is_empty());
}

/// A plugin folder with `files`, in a fresh temporary folder.
fn plugin_folder(name: &str, files: &[(&str, &str)]) -> std::path::PathBuf {
    static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let dir =
        std::env::temp_dir().join(format!("greed-lifecycle-{name}-{}-{n}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    for (file, text) in files {
        std::fs::write(dir.join(file), text).unwrap();
    }
    dir
}

const LIB: &str = r#"
local M = { roles = { fast = "small" }, list = { 1, 2, 3 } }
function M.ask() return "asked" end
function M.role(name, model) M.roles[name] = model end
return M
"#;

fn lib(h: &Host) {
    let dir = plugin_folder(
        "lib",
        &[("plugin.toml", "name = \"lib\"\n"), ("init.luau", LIB)],
    );
    h.load_dir(&dir).unwrap();
}

#[test]
fn other_plugins_read_a_module_but_cant_change_it() {
    let h = host();
    lib(&h);
    let user = plugin_folder(
        "user",
        &[
            ("plugin.toml", "name = \"user\"\nrequires = [\"lib\"]\n"),
            (
                "init.luau",
                r#"
local greed = require("@greed")
local lib = require("@lib")
local ok, err = pcall(function() lib.ask = function() return "accepted" end end)
greed.echo(`{ok} {err}`)
ok, err = pcall(function() lib.roles.fast = "huge" end)
greed.echo(`{ok} {err}`)
greed.echo(`{lib.ask()} {lib.roles.fast} {#lib.list}`)
local sum = 0
for _, n in lib.list do sum += n end
greed.echo(`{sum} {lib.roles == lib.roles}`)
lib.role("fast", "medium")
greed.echo(lib.roles.fast)
"#,
            ),
        ],
    );
    h.load_dir(&user).unwrap();
    let said = messages(&h);
    assert!(
        said[0].starts_with("false") && said[0].contains("lib's module is read-only"),
        "{}",
        said[0]
    );
    assert!(
        said[1].starts_with("false") && said[1].contains("can't set fast"),
        "{}",
        said[1]
    );
    assert_eq!(said[2..], ["asked small 3", "6 true", "medium"]);
}

#[test]
fn config_can_change_other_plugins_modules() {
    let h = host();
    lib(&h);
    h.load_str(
        "config",
        r#"require("@lib").roles.fast = "huge" require("@greed").echo(require("@lib").roles.fast)"#,
    )
    .unwrap();
    assert_eq!(messages(&h), ["huge"]);
}

#[test]
fn reading_through_a_view_is_quick() {
    let h = host();
    lib(&h);
    let reader = |name: &str, lib: &str| {
        plugin_folder(
            name,
            &[
                (
                    "plugin.toml",
                    &format!("name = \"{name}\"\nrequires = [\"lib\"]\n"),
                ),
                (
                    "init.luau",
                    &format!(
                        r#"
local lib = {lib}
local greed = require("@greed")
local start = os.clock()
for _ = 1, 200000 do
  local _ = lib.ask
end
greed.echo(tostring(os.clock() - start))
"#
                    ),
                ),
            ],
        )
    };
    h.load_dir(&reader("viewer", r#"require("@lib")"#)).unwrap();
    let viewed: f64 = messages(&h)[0].parse().unwrap();
    // The same loop over a plain table, for comparison.
    h.load_dir(&reader("plain", r#"{ ask = require("@lib").ask }"#))
        .unwrap();
    let plain: f64 = messages(&h)[0].parse().unwrap();
    // Each read through a view is a metamethod call, a few times what a
    // plain read costs; generous, so a busy machine doesn't fail it.
    eprintln!("200000 reads: through a view {viewed}s, plain {plain}s");
    assert!(
        viewed < plain * 20.0 + 0.1,
        "through a view {viewed}s, plain {plain}s"
    );
}

#[test]
fn command_names_must_be_typeable() {
    let h = host();
    for (call, name) in [
        ("command", "Bad Name"),
        ("command", ""),
        ("cli", "two words"),
    ] {
        let err = h
            .eval(&format!(
                "require('@greed').{call}({{ name = {name:?}, run = function() end }})"
            ))
            .unwrap_err()
            .to_string();
        assert!(
            err.contains("can't be a command name"),
            "{call} {name:?}: {err}"
        );
    }
    h.eval("require('@greed').command({ name = 'vim-motion-$', run = function() end })")
        .unwrap();
}

#[test]
fn replacing_another_plugins_command_says_so_unless_its_your_config() {
    let h = host();
    let define = "require('@greed').command({ name = 'shared', run = function() end })";
    h.load_str("one", define).unwrap();
    h.load_str("one", define).unwrap();
    assert!(messages(&h).is_empty(), "reloading replaces its own");
    h.load_str("two", define).unwrap();
    assert_eq!(
        messages(&h),
        ["the two plugin replaces the one plugin's command shared"]
    );
    h.load_str("user/config", define).unwrap();
    assert!(messages(&h).is_empty(), "your config may");
}

#[test]
fn hiding_another_plugins_keys_says_so_unless_its_your_config() {
    let h = host();
    let bind = |command: &str, keys: &str| {
        format!("require('@greed').keymap.bind('normal', {{ [{keys:?}] = {command:?} }})")
    };
    h.load_str("one", &bind("first", "g z")).unwrap();
    h.load_str("one", &bind("first", "g z")).unwrap();
    assert!(messages(&h).is_empty(), "reloading binds its own again");
    h.load_str("two", &bind("first", "g z")).unwrap();
    assert!(messages(&h).is_empty(), "the same command on the same keys");
    h.load_str("three", &bind("second", "g z")).unwrap();
    assert_eq!(
        messages(&h),
        ["g z in normal: the three plugin's second hides the two plugin's first"]
    );
    h.load_str("four", &bind("third", "g")).unwrap();
    assert_eq!(
        messages(&h),
        ["g in normal: the four plugin's third hides the three plugin's second on g z"]
    );
    h.load_str("five", &bind("fourth", "g a b")).unwrap();
    assert_eq!(
        messages(&h),
        ["g a b in normal: the five plugin's fourth hides the four plugin's third on g"]
    );
    h.load_str(
        "six",
        &format!("{}; {}", bind("x", "space q"), bind("y", "space q")),
    )
    .unwrap();
    assert_eq!(
        messages(&h),
        ["space q in normal: the six plugin's y hides its own x"]
    );
    h.load_str("user/config", &bind("mine", "space q")).unwrap();
    assert!(messages(&h).is_empty(), "your config may");
    // What's hidden now, for checking a plugin: a binding hidden since
    // doesn't count.
    let warnings: Vec<String> = h
        .warnings()
        .into_iter()
        .filter(|w| w.contains(" hides "))
        .collect();
    assert_eq!(
        warnings,
        ["g a b in normal: the five plugin's fourth hides the four plugin's third on g"]
    );
}

#[test]
fn keys_bound_to_missing_commands_are_named_at_start() {
    let h = host();
    h.load_str(
        "keys",
        "local greed = require('@greed')
        greed.command({ name = 'there', run = function() end })
        greed.keymap.bind('helix', { ['g z'] = 'nowhere', ['g y'] = 'there' })",
    )
    .unwrap();
    h.started().unwrap();
    assert_eq!(
        messages(&h),
        ["g z in helix runs nowhere, which doesn't exist"]
    );
}
