//! `greed ctl`: drives a running editor from the shell, through its session
//! socket. Every tool a plugin offers agents is a subcommand here too.

use std::io;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

use greed_core::control::{self, Client};
use serde_json::{Map, Value, json};

const USAGE: &str = "\
usage: greed ctl tools                 list the tools the editor offers
       greed ctl TOOL [JSON | KEY=VALUE...]
                                      run a tool, e.g. greed ctl read path=src/main.rs;
                                      KEY=@- reads that value from standard input
       greed ctl TOOL --help           what a tool does and the arguments it takes
       greed ctl sessions              list running editors
       greed ctl watch [SESSION]       the session's status as JSON, a line at once, whenever
                                      it changes and at least every 15 seconds
       greed ctl watch --hub           the same of this machine's hub, which follows the other
                                      sessions here
       greed ctl agent-socket [SESSION]
                                      the socket a session from greed ssh reaches your
                                      ssh agent on, for SSH_AUTH_SOCK
       greed ctl state SESSION         what's unsaved and running in a session, of any
                                      greed version, as JSON
       greed ctl quit [--force] [SESSION]
                                      end a session, even one of another greed version,
                                      unless files in it have unsaved changes (--force
                                      ends it anyway)
The session is the one --session NAME names first (greed ctl --session NAME TOOL ...),
or $GREED_SESSION, or the only editor running.";

/// Whether `arg` asks for help.
fn is_help(arg: &str) -> bool {
    matches!(arg, "help" | "--help" | "-h")
}

/// The session `--session NAME` named, for what this run of `greed ctl`
/// talks to; it comes before `$GREED_SESSION`, which can't be set over ssh.
static SESSION: std::sync::OnceLock<String> = std::sync::OnceLock::new();

pub fn run(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    if let [flag, name, rest @ ..] = args
        && flag == "--session"
    {
        let _ = SESSION.set(name.clone());
        return run(rest);
    }
    match args {
        [cmd] if is_help(cmd) => {
            println!("{USAGE}");
            Ok(())
        }
        [tool, flag] if flag == "--help" || flag == "-h" => tool_help(tool),
        [cmd, rest @ ..] if cmd == "quit" => {
            let force = rest.iter().any(|arg| arg == "--force");
            match rest
                .iter()
                .filter(|arg| *arg != "--force")
                .collect::<Vec<_>>()[..]
            {
                [] => quit(None, force),
                [name] => quit(Some(name.as_str()), force),
                _ => Err(USAGE.into()),
            }
        }
        [cmd, name] if cmd == "state" => {
            let state = state(name)?;
            println!(
                "{}",
                json!({ "unsaved": state.unsaved, "busy": state.busy })
            );
            Ok(())
        }
        [cmd] if cmd == "agent-socket" => agent_socket(None),
        [cmd, name] if cmd == "agent-socket" => agent_socket(Some(name)),
        [cmd, flag] if cmd == "watch" && flag == "--hub" => watch(Some(&hub()?)),
        [cmd] if cmd == "watch" => watch(None),
        [cmd, name] if cmd == "watch" => watch(Some(name)),
        [cmd] if cmd == "sessions" => {
            for session in control::sessions()? {
                let root = session
                    .root
                    .map(|r| r.display().to_string())
                    .unwrap_or_default();
                println!("{:<20} {root}", session.name);
            }
            Ok(())
        }
        [cmd] if cmd == "tools" => {
            let tools = connect()?
                .call("tools/list", &Value::Null)?
                .map_err(io::Error::other)?;
            for tool in tools
                .get("tools")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                let name = tool.get("name").and_then(Value::as_str).unwrap_or("?");
                let description = tool
                    .get("description")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                println!("{name:<20} {description}");
            }
            Ok(())
        }
        [tool, rest @ ..] => {
            let arguments = arguments(rest)?;
            let result = connect()?
                .call(
                    "tools/call",
                    &json!({ "name": tool, "arguments": arguments }),
                )?
                .map_err(io::Error::other)?;
            let text = result_text(&result);
            if result["isError"].as_bool() == Some(true) {
                return Err(text.into());
            }
            // Pretty-print JSON results; print anything else as it is.
            match serde_json::from_str::<Value>(&text) {
                Ok(json @ (Value::Object(_) | Value::Array(_))) => {
                    println!("{}", serde_json::to_string_pretty(&json)?);
                }
                _ => println!("{text}"),
            }
            Ok(())
        }
        [] => Err(USAGE.into()),
    }
}

/// This machine's hub, as its sessions say (the hub plugin's `hub/name`):
/// the first by name that answers.
pub(crate) fn hub() -> Result<String, Box<dyn std::error::Error>> {
    let mut names = live_sessions()?;
    names.sort();
    for name in names {
        let said = session_client(Some(&name), false)
            .ok()
            .and_then(|mut client| client.call("hub/name", &Value::Null).ok());
        if let Some(Ok(Value::String(hub))) = said {
            return Ok(hub);
        }
    }
    Err("no session on this machine says which is its hub".into())
}

/// How long `greed ctl watch` waits to hear from the session before taking
/// it for gone: three of the times it says its status anyway (every 15
/// seconds, the agent plugin's `status.RESEND`).
const WATCH_QUIET: Duration = Duration::from_secs(45);

/// `greed ctl watch [SESSION]`: prints the session's status as JSON, a line
/// at a time: at once, whenever it changes, and at least every 15 seconds,
/// until the session ends or goes quiet. Asked as an ordinary client, not
/// a shell's: watching can't do anything there.
fn watch(name: Option<&str>) -> Result<(), Box<dyn std::error::Error>> {
    use std::io::Write;
    let mut client = session_client(name, false)?;
    client.set_wait(Some(WATCH_QUIET))?;
    let first = client
        .call("status/watch", &Value::Null)?
        .map_err(io::Error::other)?;
    let mut out = io::stdout().lock();
    writeln!(out, "{first}")?;
    out.flush()?;
    loop {
        let message = match client.next_notification() {
            Ok(message) => message,
            Err(err)
                if matches!(
                    err.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) =>
            {
                return Err("the session went quiet".into());
            }
            Err(err) => return Err(err.into()),
        };
        if message["method"] == "status/changed" {
            writeln!(out, "{}", message["params"])?;
            out.flush()?;
        }
    }
}

/// Prints what the tool `name` does and the arguments it takes, from the
/// editor's list; for ctl's own commands, the usage.
fn tool_help(name: &str) -> Result<(), Box<dyn std::error::Error>> {
    if matches!(name, "tools" | "sessions" | "quit" | "state" | "watch") {
        println!("{USAGE}");
        return Ok(());
    }
    let tools = connect()?
        .call("tools/list", &Value::Null)?
        .map_err(io::Error::other)?;
    let tool = tools["tools"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|tool| tool["name"].as_str() == Some(name))
        .ok_or_else(|| format!("no tool called {name}; greed ctl tools lists them"))?;
    println!("{}", tool["description"].as_str().unwrap_or(""));
    let schema = &tool["inputSchema"];
    let required: Vec<&str> = schema["required"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    let Some(properties) = schema["properties"].as_object().filter(|p| !p.is_empty()) else {
        println!("\nIt takes no arguments.");
        return Ok(());
    };
    println!("\nArguments, as KEY=VALUE or one JSON object:");
    for (key, spec) in properties {
        let kind = spec["type"].as_str().unwrap_or("any");
        let needed = if required.contains(&key.as_str()) {
            ", required"
        } else {
            ""
        };
        let about = spec["description"].as_str().unwrap_or("");
        println!("  {key:<16} {kind}{needed}  {about}");
    }
    Ok(())
}

/// Ends the session `name`, or `$GREED_SESSION` or the only one running,
/// unless files in it have unsaved changes and not `force`. It asks through
/// the `eval` tool, which a session of an older greed answers too, since a
/// client of this one can't attach to that.
pub(crate) fn quit(name: Option<&str>, force: bool) -> Result<(), Box<dyn std::error::Error>> {
    let mut client = session_client(name, true)?;
    let code = format!("require('@greed').run('quit-session', {{ force = {force}, wait = true }})");
    let call = json!({ "name": "eval", "arguments": { "code": code } });
    let result = match client.call("tools/call", &call) {
        // It went before it answered.
        Err(err) if err.kind() == io::ErrorKind::UnexpectedEof => return Ok(()),
        other => other?.map_err(io::Error::other)?,
    };
    if result["isError"].as_bool() == Some(true) {
        let text = result_text(&result);
        // The reason, without where in the plugins it came from.
        let why = text.split("\nstack traceback:").next().unwrap_or_default();
        let why = why.trim_start_matches("runtime error: ");
        if force {
            return Err(why.into());
        }
        return Err(format!("{why} (greed ctl quit --force ends it anyway)").into());
    }
    Ok(())
}

/// What's open in a session that matters before ending it.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub(crate) struct State {
    /// The files with unsaved changes, as paths from home (`~/...`).
    pub unsaved: Vec<String>,
    /// What's running in it, as `core.file.busy` says.
    pub busy: Vec<String>,
}

/// What's unsaved and running in the session `name`, asked through the
/// `eval` tool, which a session of an older greed answers too.
pub(crate) fn state(name: &str) -> Result<State, Box<dyn std::error::Error>> {
    let code = r#"
        local greed = require("@greed")
        local ok, core = pcall(require, "@core")
        local out = { unsaved = {}, busy = {} }
        local home = greed.fs.dirs().home
        if ok then
            for _, buffer in greed.buffers() do
                if core.file.unsaved(buffer) then
                    local path = buffer:path() or "a buffer with no file"
                    if home and string.sub(path, 1, #home + 1) == home .. "/" then
                        path = "~" .. string.sub(path, #home + 1)
                    end
                    table.insert(out.unsaved, path)
                end
            end
            local got, busy = pcall(core.file.busy)
            if got then
                out.busy = busy
            end
        end
        return greed.json.encode(out)
    "#;
    let mut client = session_client(Some(name), true)?;
    let call = json!({ "name": "eval", "arguments": { "code": code } });
    let result = client
        .call("tools/call", &call)?
        .map_err(io::Error::other)?;
    let text = result_text(&result);
    if result["isError"].as_bool() == Some(true) {
        return Err(text.into());
    }
    // The tool may quote what the code returned.
    let json = serde_json::from_str::<String>(&text).unwrap_or(text);
    Ok(State::from_json(&serde_json::from_str(&json)?))
}

impl State {
    /// A state as `greed ctl state` prints it.
    pub(crate) fn from_json(value: &Value) -> Self {
        let list = |key: &str| -> Vec<String> {
            value[key]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|item| item.as_str().map(str::to_owned))
                .collect()
        };
        Self {
            unsaved: list("unsaved"),
            busy: list("busy"),
        }
    }
}

/// `greed edit [--wait] FILE...`: shows the files in the running editor,
/// where the shell block in `$GREED_BLOCK` ran, as `$EDITOR` for the
/// programs Greed's shell runs. With `--wait` it returns once each is done
/// with, failing when `:cq` stopped one, so `git commit` gives up.
pub fn edit(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    let wait = args.iter().any(|arg| arg == "--wait");
    let mut paths = Vec::new();
    for arg in args.iter().filter(|arg| *arg != "--wait") {
        // Some programs pass `+LINE` before the file, as for Vim.
        if arg.starts_with('+') {
            continue;
        }
        if arg.starts_with('-') {
            return Err(format!("edit: unknown flag {arg}; it takes --wait").into());
        }
        paths.push(std::path::absolute(arg)?.to_string_lossy().into_owned());
    }
    if paths.is_empty() {
        return Err("usage: greed edit [--wait] FILE...".into());
    }
    let mut arguments = json!({ "paths": paths, "wait": wait });
    if let Some(block) = std::env::var("GREED_BLOCK")
        .ok()
        .and_then(|b| b.parse::<u64>().ok())
    {
        arguments["block"] = json!(block);
    }
    let result = connect()?
        .call(
            "tools/call",
            &json!({ "name": "shell_edit", "arguments": arguments }),
        )?
        .map_err(io::Error::other)?;
    let text = result_text(&result);
    if result["isError"].as_bool() == Some(true) {
        return Err(text.into());
    }
    if text == "aborted" {
        return Err("edit: stopped with :cq".into());
    }
    Ok(())
}

/// An MCP tool result's text content, its parts on lines of their own.
fn result_text(result: &Value) -> String {
    result["content"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|part| part["text"].as_str())
        .collect::<Vec<_>>()
        .join("\n")
}

/// A tool's arguments: one JSON object, or `key=value` pairs where each
/// value is JSON if it parses as JSON and a string otherwise. `key=@-`
/// takes the value from standard input, as a hook's JSON comes, which may
/// be longer than an argument can be.
fn arguments(args: &[String]) -> Result<Value, Box<dyn std::error::Error>> {
    if let [only] = args
        && only.trim_start().starts_with('{')
    {
        return Ok(serde_json::from_str(only)?);
    }
    let mut map = Map::new();
    for arg in args {
        let (key, value) = arg
            .split_once('=')
            .ok_or_else(|| format!("expected KEY=VALUE or a JSON object, got {arg:?}"))?;
        let value = if value == "@-" {
            io::read_to_string(io::stdin())?
        } else {
            value.to_owned()
        };
        let value = serde_json::from_str(&value).unwrap_or(Value::String(value));
        map.insert(key.to_owned(), value);
    }
    Ok(Value::Object(map))
}

/// The names of the sessions whose editors are still running.
pub fn live_sessions() -> io::Result<Vec<String>> {
    Ok(control::sessions()?.into_iter().map(|s| s.name).collect())
}

/// A shell's connection, for `greed ctl`: to `$GREED_SESSION`, or to the only
/// running editor. Whoever runs `greed ctl` can run anything already, so the
/// editor treats its requests as yours.
fn connect() -> Result<Client, Box<dyn std::error::Error>> {
    session_client(None, true)
}

/// A connection to the session called `name`, or without one to
/// `$GREED_SESSION` or the only running editor.
pub fn connect_to(name: Option<&str>) -> Result<Client, Box<dyn std::error::Error>> {
    session_client(name, false)
}

/// A connection to the session called `name`, or `$GREED_SESSION` or the
/// only running editor, as a shell's if `shell`.
fn session_client(name: Option<&str>, shell: bool) -> Result<Client, Box<dyn std::error::Error>> {
    let name = session_name(name)?;
    let (socket, token_file) = control::session_files(&name);
    control::check_sessions_dir(&control::sessions_dir())?;
    let token = read_token(&socket, &token_file)
        .map_err(|err| format!("can't read the token for session {name}: {err}"))?;
    Ok(Client::connect_as(&socket, token.trim(), shell)?)
}

/// `name`, or without one the session `--session` named, `$GREED_SESSION`
/// or the only running editor.
fn session_name(name: Option<&str>) -> Result<String, Box<dyn std::error::Error>> {
    if let Some(name) = name
        .map(str::to_owned)
        .or_else(|| SESSION.get().cloned())
        .or_else(|| std::env::var("GREED_SESSION").ok())
    {
        return Ok(name);
    }
    only_session(
        "set GREED_SESSION to pick one (greed ls lists them, with how their agents are doing)",
    )
}

/// The session to use when none is named: the only one running, leaving
/// out services' sessions, which run beside the ones you use. With several,
/// the error names them and says `pick`, how to choose.
pub fn only_session(pick: &str) -> Result<String, Box<dyn std::error::Error>> {
    let mut names = live_sessions()?;
    names.retain(|name| control::service_of(name).is_none());
    match names.as_slice() {
        [only] => Ok(only.clone()),
        [] => Err("no editor is running".into()),
        several => Err(format!(
            "several editors are running ({}); {pick}",
            several.join(", ")
        )
        .into()),
    }
}

/// `greed ctl agent-socket`: the socket the session `name` (or
/// `$GREED_SESSION`, or the only one) reaches your ssh agent on, for
/// shells outside it to use as `SSH_AUTH_SOCK`. Only a session `greed ssh`
/// started has one.
fn agent_socket(name: Option<&str>) -> Result<(), Box<dyn std::error::Error>> {
    let name = session_name(name)?;
    let socket = greed_core::ssh_agent::socket_of(&name);
    if UnixStream::connect(&socket).is_err() {
        return Err(format!(
            "the session {name} has no ssh agent socket; sessions greed ssh starts have one"
        )
        .into());
    }
    println!("{}", socket.display());
    Ok(())
}

/// The token in `token_file`. A session that has just started listens on
/// `socket` a moment before its token is there, so while the socket
/// answers, a missing token is waited for.
fn read_token(socket: &Path, token_file: &Path) -> io::Result<String> {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match std::fs::read_to_string(token_file) {
            Err(err)
                if err.kind() == io::ErrorKind::NotFound
                    && Instant::now() < deadline
                    && UnixStream::connect(socket).is_ok() =>
            {
                std::thread::sleep(Duration::from_millis(5));
            }
            read => return read,
        }
    }
}

/// `greed mcp`: an MCP server on stdin and stdout for the running editor, for
/// agents like Claude Code (`claude mcp add greed -- greed mcp`).
pub fn mcp() -> Result<(), Box<dyn std::error::Error>> {
    // Not a shell's: what comes through is an agent's.
    connect_to(None)?.pipe(io::BufReader::new(io::stdin()), io::stdout())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir(label: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("greed-token-{label}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_token_not_there_yet_is_waited_for_while_the_socket_answers() {
        let dir = dir("late");
        let (socket, token) = (dir.join("s.sock"), dir.join("s.token"));
        let _listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        let writer = {
            let token = token.clone();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(50));
                // Renamed into place, as a session does.
                let new = token.with_extension("new");
                std::fs::write(&new, "abc").unwrap();
                std::fs::rename(new, token).unwrap();
            })
        };
        assert_eq!(read_token(&socket, &token).unwrap(), "abc");
        writer.join().unwrap();
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn without_a_session_a_missing_token_fails_at_once() {
        let dir = dir("none");
        let started = Instant::now();
        let err = read_token(&dir.join("s.sock"), &dir.join("s.token")).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::NotFound);
        assert!(started.elapsed() < Duration::from_secs(1));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
