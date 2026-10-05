//! `greed ctl`: drives a running editor from the shell, through its session
//! socket. Every tool a plugin offers agents is a subcommand here too.

use std::io;

use greed_core::control::{self, Client};
use serde_json::{Map, Value, json};

const USAGE: &str = "\
usage: greed ctl tools                 list the tools the editor offers
       greed ctl TOOL [JSON | KEY=VALUE...]
                                      run a tool, e.g. greed ctl read path=src/main.rs
       greed ctl sessions              list running editors
The session is $GREED_SESSION, or the only editor running.";

pub fn run(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    match args {
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
    let token = std::fs::read_to_string(&token_file)
        .map_err(|err| format!("can't read the token for session {name}: {err}"))?;
    Ok(Client::connect_as(&socket, token.trim(), shell)?)
}

/// `greed mcp`: an MCP server on stdin and stdout for the running editor, for
/// agents like Claude Code (`claude mcp add greed -- greed mcp`).
pub fn mcp() -> Result<(), Box<dyn std::error::Error>> {
    // Not a shell's: what comes through is an agent's.
    connect_to(None)?.pipe(io::BufReader::new(io::stdin()), io::stdout())?;
    Ok(())
}
