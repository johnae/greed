//! Keeps the `@greed` type definitions honest: everything they declare must
//! exist in the running API, plain API tables must declare everything they
//! have, and the default runtime must pass `luau-analyze` in strict mode.

use std::path::{Path, PathBuf};
use std::process::Command;

use greed_core::Editor;
use greed_core::luau::Host;
use greed_text::ClientId;

fn runtime() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../runtime")
}

fn types() -> String {
    std::fs::read_to_string(runtime().join("types/greed/init.luau")).unwrap()
}

/// Field names declared in `export type <name> = { ... }`.
fn declared(types: &str, name: &str) -> Vec<String> {
    let start = format!("export type {name} = {{");
    types
        .lines()
        .skip_while(|line| *line != start)
        .skip(1)
        .take_while(|line| *line != "}")
        .filter_map(|line| {
            let field = line.trim().split_once(':')?.0;
            field
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_')
                .then(|| field.to_owned())
        })
        .collect()
}

fn host() -> Host {
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", "", None);
    Host::new(editor).unwrap()
}

/// Names from `names` that the object `setup` passes to `check` doesn't have.
fn missing(host: &Host, setup: &str, names: &[String]) -> Vec<String> {
    let list: Vec<String> = names.iter().map(|n| format!("{n:?}")).collect();
    let script = format!(
        "(function() local missing = {{}} \
         local function check(object) for _, n in {{ {} }} do \
           local ok, value = pcall(function() return object[n] end) \
           if not ok or value == nil then table.insert(missing, n) end \
         end end \
         {setup} \
         return table.concat(missing, ',') end)()",
        list.join(", ")
    );
    let out = host.eval(&script).unwrap();
    out.split(',')
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .collect()
}

#[test]
fn declared_api_exists() {
    let types = types();
    let greed = "local greed = require('@greed')";
    let cases = [
        ("Greed", format!("{greed} check(greed)")),
        ("Keymap", format!("{greed} check(greed.keymap)")),
        ("Mode", format!("{greed} check(greed.mode)")),
        ("Options", format!("{greed} check(greed.option)")),
        ("History", format!("{greed} check(greed.history)")),
        ("Clipboard", format!("{greed} check(greed.clipboard)")),
        ("Client", format!("{greed} check(greed.client)")),
        ("Lsp", format!("{greed} check(greed.lsp)")),
        ("View", format!("{greed} check(greed.view())")),
        ("Buffer", format!("{greed} check(greed.view():buffer())")),
        (
            "Edits",
            format!("{greed} greed.view():buffer():edit(check)"),
        ),
        (
            "Anchor",
            format!("{greed} check(greed.view():buffer():track(0))"),
        ),
        (
            "Tracked",
            format!("{greed} check(greed.view():buffer():track_range(0, 0))"),
        ),
        (
            "Node",
            format!(
                "{greed} local b = greed.view():buffer() \
                 b:edit(function(e) e:insert(0, 'fn a() {{}}') end) b:set_language('rust') \
                 check(b:node_at(3))"
            ),
        ),
        (
            "Terminal",
            format!(
                "{greed} local t = greed.terminal.spawn({{ command = {{ 'true' }}, rows = 2, cols = 10 }}) \
                 check(t) t:close()"
            ),
        ),
        (
            "Child",
            format!(
                "{greed} local c = assert(greed.process.spawn({{ 'true' }})) check(c) c:kill()"
            ),
        ),
    ];
    let h = host();
    for (name, setup) in cases {
        let names = declared(&types, name);
        assert!(!names.is_empty(), "no fields found for {name}");
        assert_eq!(missing(&h, &setup, &names), Vec::<String>::new(), "{name}");
    }
}

#[test]
fn api_tables_are_fully_declared() {
    let types = types();
    let cases = [
        ("Greed", "greed"),
        ("Keymap", "greed.keymap"),
        ("Mode", "greed.mode"),
        ("Options", "greed.option"),
        ("History", "greed.history"),
        ("Clipboard", "greed.clipboard"),
        ("Client", "greed.client"),
        ("Lsp", "greed.lsp"),
        ("Terminals", "greed.terminal"),
        ("Tabs", "greed.tab"),
        ("Images", "greed.image"),
        ("Syntax", "greed.syntax"),
    ];
    let h = host();
    for (name, expr) in cases {
        let script = format!(
            "(function() local greed = require('@greed') local names = {{}} \
             for k in {expr} do table.insert(names, k) end \
             table.sort(names) return table.concat(names, ',') end)()"
        );
        let actual: Vec<String> = h
            .eval(&script)
            .unwrap()
            .split(',')
            .map(str::to_owned)
            .collect();
        let mut expected = declared(&types, name);
        expected.sort();
        assert_eq!(actual, expected, "{name}");
    }
}

/// Every event the editor emits has a typed `greed.on` overload and a place
/// in `EventName`, and nothing else does.
#[test]
fn events_are_declared() {
    let types = types();
    let mut expected: Vec<&str> = greed_core::luau::EVENTS.to_vec();
    expected.sort_unstable();
    let mut overloads: Vec<&str> = types
        .lines()
        .filter_map(|line| line.split_once("(event: \"")?.1.split_once('"'))
        .map(|(name, _)| name)
        .collect();
    overloads.sort_unstable();
    assert_eq!(overloads, expected, "greed.on overloads");
    let mut names: Vec<&str> = types
        .lines()
        .skip_while(|line| *line != "export type EventName =")
        .skip(1)
        .map_while(|line| line.trim().strip_prefix("| \""))
        .filter_map(|line| line.strip_suffix('"'))
        .collect();
    names.sort_unstable();
    assert_eq!(names, expected, "EventName");
}

#[test]
fn unknown_events_are_errors() {
    let h = host();
    let err = h
        .eval("require('@greed').on('buffer.chnaged', function() end)")
        .unwrap_err();
    assert!(
        err.to_string()
            .contains("there is no event called \"buffer.chnaged\""),
        "{err}"
    );
    assert!(
        h.eval("require('@greed').off('nope', function() end)")
            .is_err()
    );
    h.eval("require('@greed').on('buffer.changed', function() end)")
        .unwrap();
}

#[test]
fn runtime_passes_strict_type_checking() {
    if Command::new("luau-analyze").arg("--help").output().is_err() {
        eprintln!("luau-analyze not found; skipping (it comes with the devenv shell)");
        return;
    }
    let mut files = Vec::new();
    collect_luau(&runtime(), &mut files);
    // One thread: luau-analyze checks modules in parallel, and its worker
    // threads race on a shared module name string in Luau's Frontend, which
    // corrupts the heap now and then (still the case in 0.740).
    let output = Command::new("luau-analyze")
        .arg("-j1")
        .current_dir(runtime())
        .args(&files)
        .output()
        .unwrap();
    // Lint warnings, like an unused or shadowed local, print without failing.
    let said = String::from_utf8_lossy(&output.stdout);
    assert!(
        output.status.success() && said.trim().is_empty(),
        "{said}{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// What editors check with: luau-lsp, with every Luau flag on as it starts
/// by default, which checks differently from luau-analyze in places.
#[test]
fn runtime_passes_luau_lsp_checking() {
    if Command::new("luau-lsp").arg("--help").output().is_err() {
        eprintln!("luau-lsp not found; skipping (it comes with the devenv shell)");
        return;
    }
    let mut files = Vec::new();
    collect_luau(&runtime(), &mut files);
    let output = Command::new("luau-lsp")
        .args(["analyze", "--platform", "standard"])
        .current_dir(runtime())
        .args(&files)
        .output()
        .unwrap();
    // It notes where its configuration came from on lines like "[INFO] ...".
    let problems: Vec<String> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .chain(String::from_utf8_lossy(&output.stderr).lines())
        .filter(|line| !line.starts_with('[') && !line.trim().is_empty())
        .map(str::to_owned)
        .collect();
    assert!(problems.is_empty(), "{}", problems.join("\n"));
}

fn collect_luau(dir: &Path, files: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            collect_luau(&path, files);
        } else if path.extension().is_some_and(|e| e == "luau") {
            files.push(path);
        }
    }
}
