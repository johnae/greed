//! `greed.sikt`: sikt programs, patterns written to read like sentences,
//! for reading structure out of text: the lines of a note, what a program
//! printed. A program compiles once and runs as often as needed, on the
//! editor's thread for a little text or on others for a lot.

use std::collections::HashMap;
use std::sync::Arc;

use mlua::{FromLua, IntoLua, IntoLuaMulti, Lua, LuaString, MultiValue, Table, Value};
use sikt::{Match, MatchError, Program};

use super::jobs::{self, Output};

type LuaResult<T> = mlua::Result<T>;

pub(super) fn module(lua: &Lua) -> LuaResult<Table> {
    let sikt = lua.create_table()?;
    sikt.set(
        "compile",
        lua.create_function(|lua, (source, opts): (LuaString, Option<Table>)| {
            match build(&source.to_str()?, opts.as_ref())? {
                Ok(program) => program_to_lua(lua, Arc::new(program))?.into_lua_multi(lua),
                Err(err) => {
                    let why = format!(
                        "{} (at {} in the program)",
                        err.message(),
                        err.span().start + 1
                    );
                    (Value::Nil, why).into_lua_multi(lua)
                }
            }
        })?,
    )?;
    sikt.set(
        "check",
        lua.create_function(|lua, (source, opts): (LuaString, Option<Table>)| {
            let problems = lua.create_table()?;
            match build(&source.to_str()?, opts.as_ref())? {
                Ok(program) => {
                    for warning in program.warnings() {
                        problems.raw_push(warning_to_lua(lua, warning)?)?;
                    }
                }
                Err(err) => {
                    let mistake = problem(lua, err.message(), err.span(), err.help())?;
                    mistake.set("warning", false)?;
                    problems.raw_push(mistake)?;
                }
            }
            Ok(problems)
        })?,
    )?;
    Ok(sikt)
}

/// `source` compiled as `opts` say: line by line unless `lines` is false,
/// ignoring case with `nocase`, and `use "name"` reading `modules`.
fn build(source: &str, opts: Option<&Table>) -> LuaResult<Result<Program, sikt::Error>> {
    let lines = opt(opts, "lines")?.unwrap_or(true);
    let nocase = opt(opts, "nocase")?.unwrap_or(false);
    let modules: HashMap<String, String> = opt(opts, "modules")?.unwrap_or_default();
    Ok(sikt::Pattern::builder()
        .line_mode(lines)
        .case_insensitive(nocase)
        .import_with(move |name| {
            modules
                .get(name)
                .cloned()
                .ok_or_else(|| format!("there's no module {name:?} in `modules`"))
        })
        .build_program(source))
}

fn opt<T: FromLua>(opts: Option<&Table>, key: &str) -> LuaResult<Option<T>> {
    opts.map_or(Ok(None), |opts| opts.get(key))
}

/// A mistake or a warning in a program: its words and where it is, `from`
/// its first byte to just after its last (1-based, as `string.sub` counts).
fn problem(
    lua: &Lua,
    message: &str,
    span: std::ops::Range<usize>,
    help: Option<&str>,
) -> LuaResult<Table> {
    let out = lua.create_table()?;
    out.set("message", message)?;
    let at = lua.create_table()?;
    at.set("from", span.start + 1)?;
    at.set("to", span.end + 1)?;
    out.set("at", at)?;
    out.set("help", help)?;
    Ok(out)
}

fn warning_to_lua(lua: &Lua, warning: &sikt::Warning) -> LuaResult<Table> {
    let out = problem(lua, warning.message(), warning.span(), warning.help())?;
    out.set("warning", true)?;
    Ok(out)
}

/// The table a plugin runs a compiled program through.
fn program_to_lua(lua: &Lua, program: Arc<Program>) -> LuaResult<Table> {
    let out = lua.create_table()?;
    let warnings = lua.create_table()?;
    for warning in program.warnings() {
        warnings.raw_push(warning_to_lua(lua, warning)?)?;
    }
    out.set("warnings", warnings)?;
    let captures = lua.create_table()?;
    for name in program.pattern().capture_names() {
        let capture = lua.create_table()?;
        capture.set("name", name)?;
        let kind = program.pattern().capture_type(name);
        capture.set("type", kind.map(type_name))?;
        captures.raw_push(capture)?;
    }
    out.set("captures", captures)?;

    let run = Arc::clone(&program);
    out.set(
        "rows",
        lua.create_function(
            move |lua, (_, text, opts): (Value, LuaString, Option<Table>)| {
                let at = opt(opts.as_ref(), "at")?.unwrap_or(false);
                let as_text = opt(opts.as_ref(), "text")?.unwrap_or(false);
                let text = text.as_bytes();
                let rows = lua.create_table()?;
                let places = if at { Some(lua.create_table()?) } else { None };
                let ran = each_match::<mlua::Error>(&run, &text, |m, line| {
                    rows.raw_push(row_to_lua(lua, taken(&m, as_text))?)?;
                    if let Some(places) = &places {
                        places.raw_push(place(lua, m.range(), line)?)?;
                    }
                    Ok(())
                })?;
                match ran {
                    Ok(()) => (rows, places).into_lua_multi(lua),
                    Err(err) => Err(mlua::Error::runtime(format!("sikt gave up: {err}"))),
                }
            },
        )?,
    )?;

    let run = Arc::clone(&program);
    let start = lua.create_function(
        move |lua, (_, texts, opts): (Value, Vec<LuaString>, Option<Table>)| {
            let at = opt(opts.as_ref(), "at")?.unwrap_or(false);
            let as_text = opt(opts.as_ref(), "text")?.unwrap_or(false);
            let texts: Vec<Vec<u8>> = texts.iter().map(|t| t.as_bytes().to_vec()).collect();
            let program = Arc::clone(&run);
            Ok(jobs::start(lua, "greed.sikt rows_many", move || {
                Output::Sikt(rows_many(&program, &texts, at, as_text))
            }))
        },
    )?;
    // Waits like greed.sleep, and raises what made matching give up, as
    // `rows` does.
    let rows_many: mlua::Function = lua
        .load(
            r"
            local start = ...
            return function(...)
                if not coroutine.isyieldable() then
                    error('rows_many waits, so it only works in a command, an event handler or greed.spawn', 2)
                end
                local rows, places, why = coroutine.yield(start(...))
                if why then
                    error(why, 2)
                end
                return rows, places
            end
            ",
        )
        .set_name("=rows_many")
        .call(start)?;
    out.set("rows_many", rows_many)?;

    out.set(
        "replace",
        lua.create_function(move |lua, (_, text): (Value, LuaString)| {
            let text = text.to_str()?;
            match program.replace_all(&text) {
                Ok(replaced) => lua.create_string(replaced.as_bytes())?.into_lua_multi(lua),
                Err(err) => Err(mlua::Error::runtime(format!("sikt gave up: {err}"))),
            }
        })?,
    )?;
    Ok(out)
}

fn type_name(kind: sikt::CaptureType) -> &'static str {
    match kind {
        sikt::CaptureType::Text => "text",
        sikt::CaptureType::Integer => "integer",
        sikt::CaptureType::Number => "number",
        sikt::CaptureType::Size => "size",
        sikt::CaptureType::Percent => "percent",
        sikt::CaptureType::Duration => "duration",
    }
}

/// Runs `program` over `text`, giving `found` each match and its line
/// (1-based); `Err` inside when matching gave up, as on a pattern that
/// takes too many steps.
fn each_match<E>(
    program: &Program,
    text: &[u8],
    mut found: impl FnMut(Match<'_, [u8]>, usize) -> Result<(), E>,
) -> Result<Result<(), MatchError>, E> {
    let mut line = 1;
    let mut counted = 0;
    for m in program.find_iter_bytes(text) {
        let m = match m {
            Ok(m) => m,
            Err(err) => return Ok(Err(err)),
        };
        line += text[counted..m.start()].split(|&b| b == b'\n').count() - 1;
        counted = m.start();
        found(m, line)?;
    }
    Ok(Ok(()))
}

/// The captures of `m` that took part: their values as the program types
/// them, or with `as_text` each the text it matched.
fn taken<'a>(
    m: &Match<'a, [u8]>,
    as_text: bool,
) -> impl Iterator<Item = (&'a str, sikt::Value<'a, [u8]>)> {
    m.values().filter_map(move |(name, value)| {
        let value = value?;
        Some(if as_text {
            (name, sikt::Value::Text(m.get(name)?))
        } else {
            (name, value)
        })
    })
}

/// A match's row: each capture that matched, by its name.
fn row_to_lua<'a, N: IntoLua>(
    lua: &Lua,
    captures: impl Iterator<Item = (N, sikt::Value<'a, [u8]>)>,
) -> LuaResult<Table> {
    let row = lua.create_table_with_capacity(0, captures.size_hint().0)?;
    for (name, value) in captures {
        match value {
            sikt::Value::Text(text) => row.raw_set(name, lua.create_string(text)?)?,
            sikt::Value::Integer(n) => row.raw_set(name, n)?,
            sikt::Value::Number(n) => row.raw_set(name, n)?,
        }
    }
    Ok(row)
}

fn place(lua: &Lua, range: std::ops::Range<usize>, line: usize) -> LuaResult<Table> {
    let place = lua.create_table()?;
    place.raw_set("from", range.start + 1)?;
    place.raw_set("to", range.end + 1)?;
    place.raw_set("line", line)?;
    Ok(place)
}

/// A capture's value, kept until it's handed to Luau.
pub(super) enum Kept {
    Text(Vec<u8>),
    Integer(i64),
    Number(f64),
}

impl Kept {
    fn value(&self) -> sikt::Value<'_, [u8]> {
        match self {
            Kept::Text(text) => sikt::Value::Text(text),
            Kept::Integer(n) => sikt::Value::Integer(*n),
            Kept::Number(n) => sikt::Value::Number(*n),
        }
    }
}

/// What a program found in one text, away from the editor's thread: each
/// match's captures by the index of their name, and with `at`, where it is.
pub(super) struct Found {
    rows: Vec<Vec<(usize, Kept)>>,
    places: Option<Vec<(std::ops::Range<usize>, usize)>>,
}

/// What `rows_many` found in each text, with the capture names the
/// indexes in it stand for; or why matching gave up.
pub(super) type Many = Result<(Vec<String>, Vec<Found>, bool), String>;

fn rows_many(program: &Program, texts: &[Vec<u8>], at: bool, as_text: bool) -> Many {
    let names: Vec<String> = program
        .pattern()
        .capture_names()
        .map(str::to_owned)
        .collect();
    let index: HashMap<&str, usize> = names
        .iter()
        .enumerate()
        .map(|(i, n)| (n.as_str(), i))
        .collect();
    let one = |text: &Vec<u8>| -> Result<Found, String> {
        let mut found = Found {
            rows: Vec::new(),
            places: at.then(Vec::new),
        };
        let ran = each_match::<std::convert::Infallible>(program, text, |m, line| {
            let mut row = Vec::new();
            for (name, value) in taken(&m, as_text) {
                let kept = match value {
                    sikt::Value::Text(text) => Kept::Text(text.to_vec()),
                    sikt::Value::Integer(n) => Kept::Integer(n),
                    sikt::Value::Number(n) => Kept::Number(n),
                };
                row.push((index[name], kept));
            }
            found.rows.push(row);
            if let Some(places) = &mut found.places {
                places.push((m.range(), line));
            }
            Ok(())
        });
        match ran {
            Ok(Ok(())) => Ok(found),
            Ok(Err(err)) => Err(err.to_string()),
            Err(never) => match never {},
        }
    };
    // Spread over the machine's cores, in order.
    let threads = std::thread::available_parallelism()
        .map_or(1, usize::from)
        .min(8);
    let size = texts.len().div_ceil(threads).max(1);
    let parts: Vec<Result<Vec<Found>, String>> = std::thread::scope(|scope| {
        let handles: Vec<_> = texts
            .chunks(size)
            .map(|chunk| scope.spawn(move || chunk.iter().map(one).collect()))
            .collect();
        handles
            .into_iter()
            .map(|h| {
                h.join()
                    .unwrap_or_else(|_| Err("matching failed".to_owned()))
            })
            .collect()
    });
    let mut all = Vec::with_capacity(texts.len());
    for part in parts {
        all.extend(part?);
    }
    Ok((names, all, at))
}

/// `rows_many`'s result in Luau: a list of rows for each text, and with
/// `at`, a list of places for each; or nil and why.
pub(super) fn many_to_lua(lua: &Lua, many: Many) -> LuaResult<MultiValue> {
    let (names, found, at) = match many {
        Ok(found) => found,
        Err(why) => {
            return (Value::Nil, Value::Nil, format!("sikt gave up: {why}")).into_lua_multi(lua);
        }
    };
    let names: Vec<LuaString> = names
        .iter()
        .map(|n| lua.create_string(n))
        .collect::<LuaResult<_>>()?;
    let all_rows = lua.create_table_with_capacity(found.len(), 0)?;
    let all_places = at
        .then(|| lua.create_table_with_capacity(found.len(), 0))
        .transpose()?;
    for text in found {
        let rows = lua.create_table_with_capacity(text.rows.len(), 0)?;
        for kept in &text.rows {
            let captures = kept
                .iter()
                .map(|(name, value)| (&names[*name], value.value()));
            rows.raw_push(row_to_lua(lua, captures)?)?;
        }
        all_rows.raw_push(rows)?;
        if let (Some(all_places), Some(found_places)) = (&all_places, text.places) {
            let places = lua.create_table_with_capacity(found_places.len(), 0)?;
            for (range, line) in found_places {
                places.raw_push(place(lua, range, line)?)?;
            }
            all_places.raw_push(places)?;
        }
    }
    (all_rows, all_places).into_lua_multi(lua)
}
