//! Keeps the `@kern` type definitions honest: everything they declare must
//! exist in the running API, plain API tables must declare everything they
//! have, and the default runtime must pass `luau-analyze` in strict mode.

use std::path::{Path, PathBuf};
use std::process::Command;

use kern_core::Editor;
use kern_core::luau::Host;
use kern_text::ClientId;

fn runtime() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../runtime")
}

fn types() -> String {
    std::fs::read_to_string(runtime().join("types/kern/init.luau")).unwrap()
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
    let kern = "local kern = require('@kern')";
    let cases = [
        ("Kern", format!("{kern} check(kern)")),
        ("Keymap", format!("{kern} check(kern.keymap)")),
        ("Mode", format!("{kern} check(kern.mode)")),
        ("Options", format!("{kern} check(kern.option)")),
        ("History", format!("{kern} check(kern.history)")),
        ("Clipboard", format!("{kern} check(kern.clipboard)")),
        ("Lsp", format!("{kern} check(kern.lsp)")),
        ("View", format!("{kern} check(kern.view())")),
        ("Buffer", format!("{kern} check(kern.view():buffer())")),
        ("Edits", format!("{kern} kern.view():buffer():edit(check)")),
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
        ("Kern", "kern"),
        ("Keymap", "kern.keymap"),
        ("Mode", "kern.mode"),
        ("Options", "kern.option"),
        ("History", "kern.history"),
        ("Clipboard", "kern.clipboard"),
        ("Lsp", "kern.lsp"),
    ];
    let h = host();
    for (name, expr) in cases {
        let script = format!(
            "(function() local kern = require('@kern') local names = {{}} \
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
    assert!(
        output.status.success(),
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
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
