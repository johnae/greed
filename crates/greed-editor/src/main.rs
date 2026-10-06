//! The `greed` command line: the editor itself, a headless REPL for driving
//! the editor core from a script or an agent, and a test runner for plugins.

use std::io::{self, BufRead, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;

mod bench;
mod client;
mod ctl;
mod graphics;
mod runtime;
mod session;
mod tui;

use crossbeam_channel::Sender;
use greed_core::Editor;
use greed_core::control::Request;
use greed_core::luau::{Host, HostError, run_tests};
use greed_core::server;
use greed_text::ClientId;

const USAGE: &str = "usage: greed [FILE]\n       greed repl [FILE]\n       greed test [PLUGIN_DIR]\n       greed ctl TOOL [ARGS] (greed ctl for more)\n       greed mcp             MCP server for the running editor, on stdio\n       greed serve [FILE]    run the editor with no terminal\n       greed attach [NAME]   show a running editor here\n       greed ssh HOST [--session NAME] [FILE]\n                            show an editor on another machine, starting one if needed\n       greed commands        these, and the commands plugins add (greed ls, greed new, ...)\n       --terminal           with greed [FILE] or greed ssh: open a terminal in the session too\n       --gui                show the editor in a window rather than this terminal";

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
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    // Anywhere on the line: attach with a terminal open in the session.
    let terminal = args.iter().any(|arg| arg == "--terminal");
    args.retain(|arg| arg != "--terminal");
    // Anywhere on the line too: show the editor in a window.
    if args.iter().any(|arg| arg == "--gui") {
        args.retain(|arg| arg != "--gui");
        if let Err(err) = client::use_gui() {
            eprintln!("greed: {err}");
            return ExitCode::FAILURE;
        }
    }
    let result = match args.as_slice() {
        [] => edit(None, None, terminal),
        [flag, name, rest @ ..] if flag == "--session" => {
            edit(Some(name), rest.first().map(PathBuf::from), terminal)
        }
        [cmd, flag, name, rest @ ..] if cmd == "serve" && flag == "--session" => {
            session::serve(name, rest.first().map(Path::new))
        }
        [cmd, rest @ ..] if cmd == "serve" => session::serve_project(rest.first().map(Path::new)),
        [cmd] if cmd == "attach" => session::attach(None),
        [cmd, name] if cmd == "attach" => session::attach(Some(name)),
        [cmd, rest @ ..] if cmd == "bridge" => {
            let (name, file) = session_and_file(rest);
            session::bridge(name, file.map(Path::new))
        }
        [cmd, host, rest @ ..] if cmd == "ssh" => {
            let (name, file) = session_and_file(rest);
            session::ssh(host, name, file, terminal)
        }
        [cmd] if cmd == "repl" => repl(None),
        [cmd, file] if cmd == "repl" => repl(Some(PathBuf::from(file))),
        [cmd] if cmd == "test" => runtime::dir()
            .map_err(Into::into)
            .and_then(|dir| test(&dir.join("plugins/core"))),
        [cmd, rest @ ..] if cmd == "ctl" => ctl::run(rest),
        [cmd] if cmd == "mcp" => ctl::mcp(),
        [cmd, dir] if cmd == "test" => test(Path::new(dir)),
        [cmd] if cmd == "commands" => commands(),
        [cmd] if cmd == "bench" => bench::run(None, false),
        [cmd, flag] if cmd == "bench" && flag == "--draw" => bench::run(None, true),
        [cmd, flag, file] if cmd == "bench" && flag == "--draw" => {
            bench::run(Some(Path::new(file)), true)
        }
        [cmd, file] if cmd == "bench" => bench::run(Some(Path::new(file)), false),
        [name, rest @ ..] if command_name(name) && !Path::new(name).exists() => {
            plugin_command(name, rest, terminal)
        }
        [file] if !file.starts_with('-') => edit(None, Some(PathBuf::from(file)), terminal),
        _ => {
            eprintln!("{USAGE}");
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("greed: {err}");
            ExitCode::FAILURE
        }
    }
}

/// Greed's config directory on this machine: `$GREED_CONFIG_DIR`, or `greed` in
/// the user's config directory (`$XDG_CONFIG_HOME`, or `~/.config`).
fn config_dir() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("GREED_CONFIG_DIR") {
        return Some(PathBuf::from(dir));
    }
    user_dir("XDG_CONFIG_HOME", ".config")
}

/// Greed's state folder, for what it keeps that isn't config or cache, like
/// which plugins you approved: `$XDG_STATE_HOME/greed` or `~/.local/state/greed`.
fn state_dir() -> Option<PathBuf> {
    user_dir("XDG_STATE_HOME", ".local/state")
}

/// The copy of your config `greed ssh` brought from another machine, when
/// this session runs on the far end of one.
fn brought_dir() -> Option<PathBuf> {
    std::env::var_os("GREED_SSH_CONFIG_DIR").map(PathBuf::from)
}

/// The user's config: `$GREED_CONFIG`, or `init.luau` in the config directory.
fn config_file() -> Option<PathBuf> {
    match std::env::var_os("GREED_CONFIG") {
        Some(path) => Some(PathBuf::from(path)),
        None => Some(config_dir()?.join("init.luau")),
    }
}

/// Greed's data folder, where plugins made in the editor go when the config
/// can't be written: `$XDG_DATA_HOME/greed` or `~/.local/share/greed`.
fn data_dir() -> Option<PathBuf> {
    user_dir("XDG_DATA_HOME", ".local/share")
}

/// `greed` in the folder the environment variable `var` names, or in
/// `fallback` under the home folder.
fn user_dir(var: &str, fallback: &str) -> Option<PathBuf> {
    let base = std::env::var_os(var)
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(fallback)))?;
    Some(base.join("greed"))
}

/// The plugins to load: the default ones (core first, then by name), then
/// the ones in the config `greed ssh` brought, then the ones made in the
/// editor (in the data folder), then this machine's own config's. A plugin
/// in a later place replaces one of the same name in an earlier one.
fn plugins() -> io::Result<Vec<PathBuf>> {
    let mut dirs = plugin_dirs(&runtime::dir()?.join("plugins"))?;
    dirs.sort_by_key(|path| (path.file_name() != Some("core".as_ref()), path.clone()));
    let mut user: Vec<PathBuf> = Vec::new();
    for dir in [brought_dir(), data_dir(), config_dir()] {
        for plugin in user_plugins(dir)? {
            user.retain(|p| p.file_name() != plugin.file_name());
            user.push(plugin);
        }
    }
    dirs.extend(user);
    Ok(dirs)
}

/// The plugins in the `plugins` folder of the config in `dir`, by name.
fn user_plugins(dir: Option<PathBuf>) -> io::Result<Vec<PathBuf>> {
    let Some(dir) = dir
        .map(|dir| dir.join("plugins"))
        .filter(|dir| dir.is_dir())
    else {
        return Ok(Vec::new());
    };
    let mut found = plugin_dirs(&dir)?;
    found.sort();
    Ok(found)
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
fn host(
    text: &str,
    file: Option<PathBuf>,
    requests: Option<Sender<Request>>,
) -> Result<Host, HostError> {
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", text, file);
    let host = Host::new(editor)?;
    // Before plugins load, so they can start transports like the IDE
    // connection.
    if let Some(requests) = requests {
        host.set_request_sender(requests);
    }
    // Plugins other than Greed's own load once you've approved what they use.
    if let (Some(state), Ok(runtime)) = (state_dir(), runtime::dir()) {
        host.require_approval(state.join("approved.json"), vec![runtime.join("plugins")]);
    }
    host.load_dirs(&plugins().map_err(|err| HostError::Manifest {
        path: PathBuf::from("plugins"),
        message: err.to_string(),
    })?)?;
    // The brought config first, so this machine's own has the last word.
    let configs = [
        (
            "user/brought-config",
            brought_dir().map(|dir| dir.join("init.luau")),
        ),
        ("user/config", config_file()),
    ];
    for (name, config) in configs {
        if let Some(config) = config.filter(|path| path.is_file())
            && let Err(err) = host.load_file(name, &config)
        {
            host.with_editor_mut(|ed| ed.echo(format!("config: {err}")));
        }
    }
    // Last, the project's own config, which core runs if you trusted it.
    if let Err(err) = host.run("project-config") {
        host.with_editor_mut(|ed| ed.echo(format!("project config: {err}")));
    }
    // The file opened at the start was opened before plugins were there to
    // hear it.
    if let Err(err) = host.announce_open_files() {
        host.with_editor_mut(|ed| ed.echo(err.to_string()));
    }
    Ok(host)
}

/// The editor: in a background session this terminal attaches to, or with
/// `GREED_NO_SESSION` set, in this process.
fn edit(
    name: Option<&str>,
    path: Option<PathBuf>,
    terminal: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    if std::env::var_os("GREED_NO_SESSION").is_some() {
        return edit_here(path.filter(|p| !p.is_dir()));
    }
    if let Some(inside) = session::inside()
        && name.is_none_or(|name| name == inside)
    {
        return session::open_inside(&inside, path.as_deref());
    }
    session::start(name, path.as_deref(), terminal)
}

/// The editor in this process, for when a background session can't start.
fn edit_here(file: Option<PathBuf>) -> Result<(), Box<dyn std::error::Error>> {
    let text = read(file.as_deref())?;
    let conn = server::spawn(move || host(&text, file, None));
    // Closing a window leaves the editor; here that means quitting it.
    if matches!(
        client::run(&conn.input, &conn.output)?,
        server::Output::Detached
    ) {
        let _ = conn.input.send(server::Input::Quit);
    }
    conn.server.join().map_err(|_| "the editor crashed")??;
    Ok(())
}

fn repl(file: Option<PathBuf>) -> Result<(), Box<dyn std::error::Error>> {
    let host = host(&read(file.as_deref())?, file, None)?;

    let interactive = io::stdin().is_terminal();
    if interactive {
        println!("greed repl. :help for help.");
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
            print!("greed> ");
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

/// `[--session NAME] [FILE]` from the end of a command line.
fn session_and_file(args: &[String]) -> (Option<&str>, Option<&str>) {
    match args {
        [flag, name, rest @ ..] if flag == "--session" => {
            (Some(name.as_str()), rest.first().map(String::as_str))
        }
        rest => (None, rest.first().map(String::as_str)),
    }
}

/// Whether `name` could be a command plugins add with `greed.cli`: plain
/// lowercase words with dashes. Anything else is a file.
fn command_name(name: &str) -> bool {
    name.starts_with(|c: char| c.is_ascii_lowercase())
        && name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

/// `greed NAME ARGS`: the command a plugin added with `greed.cli`, run in an
/// editor with no screen. With no such command, `greed NAME` edits the file.
fn plugin_command(
    name: &str,
    args: &[String],
    terminal: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let host = host("", None, None)?;
    if !host.cli_commands().iter().any(|(n, _, _)| n == name) {
        if args.is_empty() {
            return edit(None, Some(PathBuf::from(name)), terminal);
        }
        return Err(format!("there's no command {name} (greed commands lists them)").into());
    }
    // What starting up said, like a config error, before the command's own.
    for message in host.with_editor_mut(Editor::take_messages) {
        eprintln!("{message}");
    }
    let returned = host
        .run_cli(name, args.to_vec(), &mut |message| println!("{message}"))
        .map_err(|err| err.brief())?;
    if let Some(text) = returned.filter(|text| !text.is_empty()) {
        println!("{text}");
    }
    Ok(())
}

/// `greed commands`: Greed's own commands, then the ones plugins add.
fn commands() -> Result<(), Box<dyn std::error::Error>> {
    println!("{USAGE}");
    let commands = host("", None, None)?.cli_commands();
    if !commands.is_empty() {
        println!("\nfrom plugins:");
    }
    for (name, usage, doc) in commands {
        let line = format!("{name} {usage}");
        println!("       greed {:<15} {doc}", line.trim_end());
    }
    Ok(())
}
