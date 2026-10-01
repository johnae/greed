//! `kern ctl`: drives a running editor from the shell, through its session
//! socket. Every tool a plugin offers agents is a subcommand here too.

use std::io;
use std::os::unix::net::UnixStream;

use kern_core::control::{self, Client};
use serde_json::{Map, Value, json};

const USAGE: &str = "\
usage: kern ctl tools                 list the tools the editor offers
       kern ctl TOOL [JSON | KEY=VALUE...]
                                      run a tool, e.g. kern ctl read path=src/main.rs
       kern ctl sessions              list running editors
The session is $KERN_SESSION, or the only editor running.";

pub fn run(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    match args {
        [cmd] if cmd == "sessions" => {
            for name in live_sessions()? {
                println!("{name}");
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
            match result {
                Value::String(text) => println!("{text}"),
                Value::Null => {}
                other => println!("{}", serde_json::to_string_pretty(&other)?),
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
fn live_sessions() -> io::Result<Vec<String>> {
    let mut names = Vec::new();
    let entries = match std::fs::read_dir(control::sessions_dir()) {
        Ok(entries) => entries,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(names),
        Err(err) => return Err(err),
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().is_some_and(|ext| ext == "sock")
            && UnixStream::connect(&path).is_ok()
            && let Some(name) = path.file_stem()
        {
            names.push(name.to_string_lossy().into_owned());
        }
    }
    names.sort();
    Ok(names)
}

/// A connection to `$KERN_SESSION`, or to the only running editor.
fn connect() -> Result<Client, Box<dyn std::error::Error>> {
    let name = match std::env::var("KERN_SESSION") {
        Ok(name) => name,
        Err(_) => match live_sessions()?.as_slice() {
            [only] => only.clone(),
            [] => return Err("no editor is running".into()),
            several => {
                return Err(format!(
                    "several editors are running ({}); set KERN_SESSION to pick one",
                    several.join(", ")
                )
                .into());
            }
        },
    };
    let (socket, token_file) = control::session_files(&name);
    let token = std::fs::read_to_string(&token_file)
        .map_err(|err| format!("can't read the token for session {name}: {err}"))?;
    Ok(Client::connect(&socket, token.trim())?)
}
