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
                                      run a tool, e.g. greed ctl read path=src/main.rs
       greed ctl TOOL --help           what a tool does and the arguments it takes
       greed ctl sessions              list running editors
       greed ctl quit [--force] [SESSION]
                                      end a session, even one of another greed version,
                                      unless files in it have unsaved changes (--force
                                      ends it anyway)
The session is $GREED_SESSION, or the only editor running.";

/// Whether `arg` asks for help.
fn is_help(arg: &str) -> bool {
    matches!(arg, "help" | "--help" | "-h")
}

pub fn run(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
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
            // An MCP result: text content, and whether the tool failed.
            let text: String = result["content"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|part| part["text"].as_str())
                .collect::<Vec<_>>()
                .join("\n");
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

/// Prints what the tool `name` does and the arguments it takes, from the
/// editor's list; for ctl's own commands, the usage.
fn tool_help(name: &str) -> Result<(), Box<dyn std::error::Error>> {
    if matches!(name, "tools" | "sessions" | "quit") {
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
fn quit(name: Option<&str>, force: bool) -> Result<(), Box<dyn std::error::Error>> {
    let mut client = session_client(name, true)?;
    let code = format!("require('@greed').run('quit-session', {{ force = {force}, wait = true }})");
    let call = json!({ "name": "eval", "arguments": { "code": code } });
    let result = match client.call("tools/call", &call) {
        // It went before it answered.
        Err(err) if err.kind() == io::ErrorKind::UnexpectedEof => return Ok(()),
        other => other?.map_err(io::Error::other)?,
    };
    if result["isError"].as_bool() == Some(true) {
        let text: String = (result["content"].as_array().into_iter().flatten())
            .filter_map(|part| part["text"].as_str())
            .collect();
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

/// A tool's arguments: one JSON object, or `key=value` pairs where each
/// value is JSON if it parses as JSON and a string otherwise.
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
        let value = serde_json::from_str(value).unwrap_or_else(|_| Value::String(value.to_owned()));
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
    let name = match name
        .map(str::to_owned)
        .or_else(|| std::env::var("GREED_SESSION").ok())
    {
        Some(name) => name,
        None => match live_sessions()?.as_slice() {
            [only] => only.clone(),
            [] => return Err("no editor is running".into()),
            several => {
                return Err(format!(
                    "several editors are running ({}); set GREED_SESSION to pick one",
                    several.join(", ")
                )
                .into());
            }
        },
    };
    let (socket, token_file) = control::session_files(&name);
    let token = read_token(&socket, &token_file)
        .map_err(|err| format!("can't read the token for session {name}: {err}"))?;
    Ok(Client::connect_as(&socket, token.trim(), shell)?)
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
