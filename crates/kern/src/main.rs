//! The `kern` command line: the editor itself, a headless REPL for driving
//! the editor core from a script or an agent, and a test runner for plugins.

use std::io::{self, BufRead, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

mod tui;

use kern_core::Editor;
use kern_core::luau::{Host, HostError, run_tests};
use kern_core::server;
use kern_text::ClientId;

const USAGE: &str = "usage: kern [FILE]\n       kern repl [FILE]\n       kern test [PLUGIN_DIR]";

const HELP: &str = "\
Type Luau to evaluate it, or one of:
  :keys KEYS      press keys, e.g. :keys g g  or  :keys i h i esc
  :run COMMAND    run a command by name
  :show           show the buffer with selections (| head, ^ anchor)
  :write          save the buffer to its file
  :reload PLUGIN  reload a plugin
  :help           show this help
  :quit           leave";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.as_slice() {
        [] => edit(None),
        [cmd] if cmd == "repl" => repl(None),
        [cmd, file] if cmd == "repl" => repl(Some(PathBuf::from(file))),
        [cmd] if cmd == "test" => test(&core_plugin()),
        [cmd, dir] if cmd == "test" => test(Path::new(dir)),
        [file] if !file.starts_with('-') => edit(Some(PathBuf::from(file))),
        _ => {
            eprintln!("{USAGE}");
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("kern: {err}");
            ExitCode::FAILURE
        }
    }
}

/// Where the default plugins live: `$KERN_RUNTIME`, or the source tree.
fn runtime_dir() -> PathBuf {
    std::env::var_os("KERN_RUNTIME").map_or_else(
        || Path::new(env!("CARGO_MANIFEST_DIR")).join("../../runtime"),
        PathBuf::from,
    )
}

fn core_plugin() -> PathBuf {
    runtime_dir().join("plugins/core")
}

/// The default plugins: core first, then the rest by name.
fn plugins() -> io::Result<Vec<PathBuf>> {
    let mut dirs: Vec<PathBuf> = std::fs::read_dir(runtime_dir().join("plugins"))?
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .filter(|path| path.join("plugin.toml").is_file())
        .collect();
    dirs.sort_by_key(|path| (path.file_name() != Some("core".as_ref()), path.clone()));
    Ok(dirs)
}

/// The text of `file`, or nothing if there is no file yet.
fn read(file: Option<&Path>) -> io::Result<String> {
    match file {
        Some(path) if path.exists() => std::fs::read_to_string(path),
        _ => Ok(String::new()),
    }
}

/// An editor with `text` open and the default plugins loaded.
fn host(text: &str, file: Option<PathBuf>) -> Result<Host, HostError> {
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", text, file);
    let host = Host::new(editor)?;
    for plugin in plugins().map_err(|err| HostError::Manifest {
        path: runtime_dir().join("plugins"),
        message: err.to_string(),
    })? {
        host.load_dir(&plugin)?;
    }
    Ok(host)
}

fn edit(file: Option<PathBuf>) -> Result<(), Box<dyn std::error::Error>> {
    let text = read(file.as_deref())?;
    tui::run(server::spawn(move || host(&text, file)))
}

fn repl(file: Option<PathBuf>) -> Result<(), Box<dyn std::error::Error>> {
    let host = host(&read(file.as_deref())?, file)?;

    let interactive = io::stdin().is_terminal();
    if interactive {
        println!("kern repl. :help for help.");
    }
    let mut out = io::stdout();
    for line in prompt_lines(interactive) {
        let line = line?;
        let line = line.trim();
        match handle(&host, line) {
            Ok(Action::Quit) => break,
            Ok(Action::Print(text)) if !text.is_empty() => writeln!(out, "{text}")?,
            Ok(Action::Print(_)) => {}
            Err(err) => writeln!(out, "error: {err}")?,
        }
        for message in host.with_editor_mut(Editor::take_messages) {
            writeln!(out, "{message}")?;
        }
        out.flush()?;
    }
    Ok(())
}

/// Lines from stdin, printing a prompt before each when interactive.
fn prompt_lines(interactive: bool) -> impl Iterator<Item = io::Result<String>> {
    let mut lines = io::stdin().lock().lines();
    std::iter::from_fn(move || {
        if interactive {
            print!("kern> ");
            io::stdout().flush().ok();
        }
        lines.next()
    })
}

enum Action {
    Print(String),
    Quit,
}

fn handle(host: &Host, line: &str) -> Result<Action, Box<dyn std::error::Error>> {
    let Some(command) = line.strip_prefix(':') else {
        return Ok(Action::Print(host.eval(line)?));
    };
    let (name, arg) = command.split_once(' ').unwrap_or((command, ""));
    let arg = arg.trim();
    match name {
        "keys" => host.press_keys(arg)?,
        "run" => host.run(arg)?,
        "reload" => host.reload(arg)?,
        "show" => {}
        "write" => return write(host).map(Action::Print),
        "help" => return Ok(Action::Print(HELP.to_owned())),
        "quit" | "q" => return Ok(Action::Quit),
        other => return Err(format!("unknown REPL command :{other} (try :help)").into()),
    }
    Ok(Action::Print(show(host)))
}

fn show(host: &Host) -> String {
    host.with_editor(|ed| format!("[{}]\n{}", ed.mode(), ed.marked_text(ed.focus())))
}

fn write(host: &Host) -> Result<String, Box<dyn std::error::Error>> {
    host.with_editor(|ed| {
        let buffer = ed.buffer(ed.view(ed.focus()).buffer);
        let path = buffer.path().ok_or("this buffer has no file")?;
        std::fs::write(path, buffer.text().to_string())?;
        Ok(format!("wrote {}", path.display()))
    })
}

/// Runs a plugin's tests, with the default plugins loaded so keymaps work.
/// Fails if any test fails.
fn test(dir: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let dir = dir.canonicalize()?;
    let mut plugins = plugins()?
        .iter()
        .map(|p| p.canonicalize())
        .collect::<io::Result<Vec<_>>>()?;
    if !plugins.contains(&dir) {
        plugins.push(dir.clone());
    }
    let results = run_tests(&plugins, &dir)?;
    let mut file = None;
    for result in &results {
        if file != Some(&result.file) {
            println!("{}", result.file.display());
            file = Some(&result.file);
        }
        match &result.failure {
            None => println!("  ok    {}", result.name),
            Some(why) => println!("  FAIL  {}\n        {why}", result.name),
        }
    }
    let failed = results.iter().filter(|r| r.failure.is_some()).count();
    println!("{} passed, {failed} failed", results.len() - failed);
    if failed > 0 {
        return Err(format!("{failed} test(s) failed").into());
    }
    Ok(())
}
