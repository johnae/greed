//! `kern.process`: running other programs, like a formatter or `jj`. A
//! command waits for the program on another thread, so the editor keeps
//! going; outside a command it runs right away.

use std::io::Write;
use std::process::{Command, Stdio};

use mlua::{IntoLuaMulti, Lua, Table};

use super::jobs::{self, Output};

type LuaResult<T> = mlua::Result<T>;

/// What a program did: how it exited and what it printed.
pub struct Finished {
    pub code: Option<i32>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

/// How to run a program: its command line, its input and its folder.
struct Run {
    command: Vec<String>,
    stdin: Option<Vec<u8>>,
    cwd: Option<String>,
}

fn run(how: Run) -> std::io::Result<Finished> {
    let (program, args) = how
        .command
        .split_first()
        .ok_or_else(|| std::io::Error::other("an empty command line"))?;
    let mut command = Command::new(program);
    command
        .args(args)
        .stdin(if how.stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(cwd) = &how.cwd {
        command.current_dir(cwd);
    }
    let mut child = command.spawn()?;
    if let (Some(input), Some(mut stdin)) = (how.stdin, child.stdin.take()) {
        // Written on its own thread, so a program that prints while it reads
        // can't fill a pipe and stall both ends.
        std::thread::spawn(move || {
            let _ = stdin.write_all(&input);
        });
    }
    let out = child.wait_with_output()?;
    Ok(Finished {
        code: out.status.code(),
        stdout: out.stdout,
        stderr: out.stderr,
    })
}

fn run_from_lua(command: Vec<String>, opts: Option<&Table>) -> LuaResult<Run> {
    let (stdin, cwd) = match opts {
        Some(opts) => (
            opts.get::<Option<mlua::LuaString>>("stdin")?
                .map(|s| s.as_bytes().to_vec()),
            opts.get("cwd")?,
        ),
        None => (None, None),
    };
    Ok(Run {
        command,
        stdin,
        cwd,
    })
}

/// `{ code, stdout, stderr }` for a program that ran, or `nil, error` for
/// one that couldn't start.
pub(super) fn to_lua(lua: &Lua, result: std::io::Result<Finished>) -> LuaResult<mlua::MultiValue> {
    match result {
        Ok(done) => {
            let table = lua.create_table()?;
            table.set("code", done.code)?;
            table.set("stdout", lua.create_string(&done.stdout)?)?;
            table.set("stderr", lua.create_string(&done.stderr)?)?;
            table.into_lua_multi(lua)
        }
        Err(err) => (mlua::Value::Nil, err.to_string()).into_lua_multi(lua),
    }
}

pub(super) fn module(lua: &Lua) -> LuaResult<Table> {
    let process = lua.create_table()?;
    let start = lua.create_function(|lua, (command, opts): (Vec<String>, Option<Table>)| {
        let how = run_from_lua(command, opts.as_ref())?;
        Ok(jobs::start(lua, move || Output::Process(run(how))))
    })?;
    process.set("run", jobs::waiting(lua, "kern.process.run", start)?)?;
    Ok(process)
}
