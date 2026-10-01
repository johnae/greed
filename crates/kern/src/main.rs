//! The `kern` command line: the editor itself, a headless REPL for driving
//! the editor core from a script or an agent, and a test runner for plugins.

use std::io::{self, BufRead, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

mod ctl;
mod tui;

use kern_core::Editor;
use kern_core::luau::{Host, HostError, run_tests};
use kern_core::{control, server};
use kern_text::ClientId;

const USAGE: &str = "usage: kern [FILE]\n       kern repl [FILE]\n       kern test [PLUGIN_DIR]\n       kern new PLUGIN_NAME\n       kern ctl TOOL [ARGS] (kern ctl for more)";

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
        [cmd, name] if cmd == "new" => new_plugin(name),
        [cmd, rest @ ..] if cmd == "ctl" => ctl::run(rest),
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

/// Kern's directory in the user's config directory (`$XDG_CONFIG_HOME`, or
/// `~/.config`).
fn config_dir() -> Option<PathBuf> {
    let dir = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))?;
    Some(dir.join("kern"))
}

/// The user's config: `$KERN_CONFIG`, or `init.luau` in the config directory.
fn config_file() -> Option<PathBuf> {
    match std::env::var_os("KERN_CONFIG") {
        Some(path) => Some(PathBuf::from(path)),
        None => Some(config_dir()?.join("init.luau")),
    }
}

/// The plugins to load: the default ones (core first, then by name), then
/// the user's from the `plugins` directory next to their config.
fn plugins() -> io::Result<Vec<PathBuf>> {
    let mut dirs = plugin_dirs(&runtime_dir().join("plugins"))?;
    dirs.sort_by_key(|path| (path.file_name() != Some("core".as_ref()), path.clone()));
    if let Some(user) = config_dir()
        .map(|dir| dir.join("plugins"))
        .filter(|dir| dir.is_dir())
    {
        let mut user = plugin_dirs(&user)?;
        user.sort();
        dirs.extend(user);
    }
    Ok(dirs)
}

/// The directories in `dir` that hold a plugin.
fn plugin_dirs(dir: &Path) -> io::Result<Vec<PathBuf>> {
    Ok(std::fs::read_dir(dir)?
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .filter(|path| path.join("plugin.toml").is_file())
        .collect())
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
    host.load_dirs(&plugins().map_err(|err| HostError::Manifest {
        path: runtime_dir().join("plugins"),
        message: err.to_string(),
    })?)?;
    if let Some(config) = config_file().filter(|path| path.is_file())
        && let Err(err) = host.load_file("user/config", &config)
    {
        host.with_editor_mut(|ed| ed.echo(format!("config: {err}")));
    }
    Ok(host)
}

fn edit(file: Option<PathBuf>) -> Result<(), Box<dyn std::error::Error>> {
    let text = read(file.as_deref())?;
    // Without a socket the editor still works; only `kern ctl` and agents
    // can't reach it.
    let session = control::listen(&std::process::id().to_string()).ok();
    tui::run(server::spawn_with_session(
        move || host(&text, file),
        session,
    ))
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

const NEW_MANIFEST: &str = "name = \"NAME\"\n";

const NEW_INIT: &str = r#"-- NAME: say what this plugin does here.
--
-- Run `kern test .` in this directory to run its tests. To use it, put this
-- directory in the `plugins` directory next to your config
-- (~/.config/kern/plugins/NAME).

local kern = require("@kern")

kern.command({
	name = "NAME-greet",
	doc = "Insert a greeting at each cursor",
	run = function(ctx)
		ctx.buffer:edit(function(e)
			for _, range in ctx.view:selection().ranges do
				e:insert(range.head, "hello")
			end
		end)
	end,
})

-- Bind it to keys like this:
-- kern.keymap.bind("normal", { ["space x"] = "NAME-greet" })
"#;

const NEW_TEST: &str = r#"local test = require("@kern/test")

test("greet inserts a greeting", function(t)
	t:buffer("|!")
	t:run("NAME-greet")
	t:expect("hello|!")
end)
"#;

/// Scaffolds a plugin in a new directory called `name`.
fn new_plugin(name: &str) -> Result<(), Box<dyn std::error::Error>> {
    let valid = !name.is_empty()
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    if !valid {
        return Err(format!("{name:?} isn't a plugin name: use letters, digits, - and _").into());
    }
    let dir = Path::new(name);
    if dir.exists() {
        return Err(format!("{name} already exists").into());
    }
    std::fs::create_dir_all(dir.join("test"))?;
    for (file, text) in [
        ("plugin.toml", NEW_MANIFEST),
        ("init.luau", NEW_INIT),
        ("test/greet.luau", NEW_TEST),
    ] {
        std::fs::write(dir.join(file), text.replace("NAME", name))?;
    }
    println!("created {name}/: plugin.toml, init.luau, test/greet.luau");
    set_up_type_checking()?;
    println!("run `kern test {name}` to try it");
    Ok(())
}

const LUAURC: &str = r#"{
	"languageMode": "strict",
	"aliases": {
		"kern": "./.kern-types/kern"
	}
}
"#;

/// Lets luau-analyze and luau-lsp find Kern's types for plugins in the
/// current directory: a `.luaurc` aliasing `@kern` to a `.kern-types` link.
/// They have to live here, above the plugins, because an `init.luau` looks
/// for its config from its directory's parent, and alias paths can't leave
/// the config's directory. Leaves existing files alone.
fn set_up_type_checking() -> io::Result<()> {
    let link = Path::new(".kern-types");
    if link.symlink_metadata().is_err() {
        std::os::unix::fs::symlink(runtime_dir().canonicalize()?.join("types"), link)?;
        println!("linked .kern-types to Kern's type definitions");
    }
    let config = Path::new(".luaurc");
    if config.exists() {
        if !std::fs::read_to_string(config)?.contains("\"kern\"") {
            println!("note: add \"kern\": \"./.kern-types/kern\" to the aliases in .luaurc");
        }
    } else {
        std::fs::write(config, LUAURC)?;
        println!("created .luaurc for type checking");
    }
    Ok(())
}
