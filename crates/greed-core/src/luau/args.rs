//! Command arguments: reading a command's `args` specs, and checking and
//! parsing what a typed command is given before it runs. Every way a
//! command runs (keys, the command line, `greed.run`, agents) goes through
//! `invoke` in `api.rs`, which calls [`check`], so they all get the same
//! checks and the same `ctx.values`.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use mlua::{Function, Lua, Table, Value};

use super::state;
use crate::registry::{self, Arg, ArgType};

type LuaResult<T> = mlua::Result<T>;

/// Reads command `command`'s `args = { { name, doc, complete, type,
/// optional, choices, kind } }`, failing on a spec that can't work.
pub(super) fn read(command: &str, spec: Option<Table>) -> LuaResult<Vec<Arg>> {
    let Some(spec) = spec else {
        return Ok(Vec::new());
    };
    let args = spec
        .sequence_values::<Table>()
        .map(|arg| read_one(command, &arg?))
        .collect::<LuaResult<Vec<Arg>>>()?;
    for (i, arg) in args.iter().enumerate() {
        let fail = |why: &str| {
            Err(mlua::Error::runtime(format!(
                "command {command}: argument {}: {why}",
                arg.name
            )))
        };
        if arg.kind == Some(ArgType::Rest) && i + 1 < args.len() {
            return fail("a \"rest\" argument takes the rest of the words, so it has to be last");
        }
        if !arg.optional && i > 0 && args[i - 1].optional {
            return fail("it comes after an optional one, so it has to be optional too");
        }
    }
    Ok(args)
}

fn read_one(command: &str, arg: &Table) -> LuaResult<Arg> {
    let name: String = arg.get("name")?;
    let fail =
        |why: String| mlua::Error::runtime(format!("command {command}: argument {name}: {why}"));
    let choices: Option<Vec<String>> = arg.get("choices")?;
    let kind: Option<String> = arg.get("kind")?;
    let ty: Option<String> = arg.get("type")?;
    let parsed = match ty.as_deref() {
        None => None,
        Some("string") => Some(ArgType::String),
        Some("number") => Some(ArgType::Number),
        Some("boolean") => Some(ArgType::Boolean),
        Some("file") => Some(ArgType::File),
        Some("folder") => Some(ArgType::Folder),
        Some("rest") => Some(ArgType::Rest),
        Some("choice") => match &choices {
            Some(choices) if !choices.is_empty() => Some(ArgType::Choice(
                choices.iter().map(|c| Arc::from(c.as_str())).collect(),
            )),
            _ => return Err(fail("type \"choice\" needs choices = { ... }".into())),
        },
        Some("object") => match &kind {
            Some(kind) => Some(ArgType::Object(kind.as_str().into())),
            None => {
                return Err(fail(
                    "type \"object\" needs kind, the kind of object, e.g. kind = \"pod\"".into(),
                ));
            }
        },
        Some(other) => {
            return Err(fail(format!(
                "there's no type {other:?}; the types are string, number, boolean, file, \
                 folder, choice, object and rest"
            )));
        }
    };
    if choices.is_some() && !matches!(parsed, Some(ArgType::Choice(_))) {
        return Err(fail("choices go with type = \"choice\"".into()));
    }
    if kind.is_some() && !matches!(parsed, Some(ArgType::Object(_))) {
        return Err(fail("kind goes with type = \"object\"".into()));
    }
    Ok(Arg {
        name: name.as_str().into(),
        doc: arg.get::<Option<String>>("doc")?.unwrap_or_default().into(),
        complete: arg.get::<Option<String>>("complete")?.map(Into::into),
        kind: parsed,
        optional: arg.get::<Option<bool>>("optional")?.unwrap_or(false),
    })
}

/// `arg` as `greed.commands()` shows it.
pub(super) fn to_lua(lua: &Lua, arg: &Arg) -> LuaResult<Table> {
    let spec = lua.create_table()?;
    spec.set("name", &*arg.name)?;
    spec.set("doc", &*arg.doc)?;
    spec.set("complete", arg.complete.as_deref())?;
    if let Some(kind) = &arg.kind {
        spec.set("type", kind.name())?;
        match kind {
            ArgType::Choice(choices) => spec.set(
                "choices",
                lua.create_sequence_from(choices.iter().map(|c| &**c))?,
            )?,
            ArgType::Object(kind) => spec.set("kind", &**kind)?,
            ArgType::String
            | ArgType::Number
            | ArgType::Boolean
            | ArgType::File
            | ArgType::Folder
            | ArgType::Rest => {}
        }
    }
    spec.set("optional", arg.optional)?;
    Ok(spec)
}

/// An "object" argument still to find, once the command's coroutine runs,
/// since finding one may wait (asking a program).
pub(super) struct Wanted {
    name: Arc<str>,
    kind: Arc<str>,
    text: String,
}

/// What a command gets for its arguments: `ctx.values`, and the objects to
/// find before it runs.
pub(super) struct Checked {
    pub values: Table,
    pub objects: Vec<Wanted>,
}

/// Checks the words `given` to command `name` against its `args`, when any
/// has a type, and parses them; the error is the usage and what's wrong.
/// An untyped command gets its words by name, unchecked.
pub(super) fn check(
    lua: &Lua,
    name: &str,
    args: &[Arg],
    given: &[String],
) -> LuaResult<Result<Checked, String>> {
    let values = lua.create_table()?;
    if args.iter().all(|arg| arg.kind.is_none()) {
        for (arg, word) in args.iter().zip(given) {
            values.set(&*arg.name, word.as_str())?;
        }
        return Ok(Ok(Checked {
            values,
            objects: Vec::new(),
        }));
    }
    let wrong = |why: String| Ok(Err(format!(":{}: {why}", registry::usage(name, args))));
    let missing: Vec<String> = args
        .iter()
        .skip(given.len())
        .filter(|arg| !arg.optional)
        .map(|arg| arg.name.to_uppercase())
        .collect();
    if !missing.is_empty() {
        return wrong(format!("needs {}", missing.join(" and ")));
    }
    let rest = args
        .last()
        .is_some_and(|arg| arg.kind == Some(ArgType::Rest));
    if !rest && given.len() > args.len() {
        let extra: Vec<String> = given[args.len()..]
            .iter()
            .map(|word| format!("{word:?}"))
            .collect();
        return wrong(format!("too many arguments: {} left over", extra.join(" ")));
    }
    let mut objects = Vec::new();
    for (i, arg) in args.iter().enumerate() {
        let Some(word) = given.get(i) else { break };
        let kind = arg.kind.as_ref().unwrap_or(&ArgType::String);
        let value = match kind {
            ArgType::String => Value::String(lua.create_string(word)?),
            ArgType::Rest => Value::String(lua.create_string(given[i..].join(" "))?),
            ArgType::Number => match word.parse::<f64>() {
                Ok(n) if n.is_finite() => Value::Number(n),
                _ => return wrong(format!("{word:?} isn't a number")),
            },
            ArgType::Boolean => match registry::parse_bool(word) {
                Some(b) => Value::Boolean(b),
                None => {
                    return wrong(format!("{word:?} isn't true or false (or yes/no, on/off)"));
                }
            },
            ArgType::Choice(choices) => {
                if !choices.iter().any(|c| **c == **word) {
                    let list: Vec<&str> = choices.iter().map(|c| &**c).collect();
                    return wrong(format!("{word:?} isn't one of {}", list.join(", ")));
                }
                Value::String(lua.create_string(word)?)
            }
            ArgType::File | ArgType::Folder => {
                let folder = *kind == ArgType::Folder;
                let path = resolve(lua, word);
                let what = if folder { "folder" } else { "file" };
                match std::fs::metadata(&path) {
                    Err(_) => return wrong(format!("there's no {what} {word:?}")),
                    Ok(meta) if meta.is_dir() != folder => {
                        let is = if folder { "a file" } else { "a folder" };
                        return wrong(format!("{word:?} is {is}; it needs a {what}"));
                    }
                    Ok(_) => {}
                }
                Value::String(lua.create_string(path.to_string_lossy().as_ref())?)
            }
            ArgType::Object(kind) => {
                objects.push(Wanted {
                    name: arg.name.clone(),
                    kind: kind.clone(),
                    text: word.clone(),
                });
                continue;
            }
        };
        values.set(&*arg.name, value)?;
    }
    if !objects.is_empty() && state(lua).object_finder.is_none() {
        return wrong(
            "nothing finds objects: the core plugin does that, and it isn't loaded".into(),
        );
    }
    Ok(Ok(Checked { values, objects }))
}

/// `word` as a full path: `~` is the home folder, and a relative path is
/// from the shown project's root.
fn resolve(lua: &Lua, word: &str) -> PathBuf {
    let expanded = super::fs::expand_home(lua, word.to_owned());
    let path = Path::new(&expanded);
    let full = if path.is_absolute() {
        path.to_path_buf()
    } else {
        state(lua).editor.current_project().root().join(path)
    };
    super::modules::normalize(&full)
}

/// The function a command with "object" arguments runs as: it finds each
/// with the object finder, then runs the command, or fails with the usage
/// and what wasn't found. It runs in the command's coroutine, so finding
/// can wait.
pub(super) fn with_objects(
    lua: &Lua,
    name: &str,
    args: &[Arg],
    run: Function,
    ctx: &Table,
    objects: Vec<Wanted>,
) -> LuaResult<(Function, mlua::MultiValue)> {
    const KEY: &str = "greed.args.with_objects";
    let wrapper = if let Some(f) = lua.named_registry_value::<Option<Function>>(KEY)? {
        f
    } else {
        let f: Function = lua
            .load(
                r#"
                return function(find, run, usage, wanted, ctx)
                    for _, w in wanted do
                        local found, why = find(w.kind, w.text)
                        if found == nil then
                            error(":" .. usage .. ": "
                                .. (why or ("no " .. w.kind .. " " .. string.format("%q", w.text))), 0)
                        end
                        ctx.values[w.name] = found
                    end
                    return run(ctx)
                end
                "#,
            )
            .set_name("=command arguments")
            .call(())?;
        lua.set_named_registry_value(KEY, &f)?;
        f
    };
    let find = state(lua)
        .object_finder
        .as_ref()
        .map(|(_, f)| f.clone())
        .ok_or_else(|| mlua::Error::runtime("nothing finds objects"))?;
    let wanted = lua.create_table()?;
    for w in objects {
        let entry = lua.create_table()?;
        entry.set("name", &*w.name)?;
        entry.set("kind", &*w.kind)?;
        entry.set("text", w.text)?;
        wanted.push(entry)?;
    }
    let call = (find, run, registry::usage(name, args), wanted, ctx.clone());
    Ok((wrapper, mlua::IntoLuaMulti::into_lua_multi(call, lua)?))
}
