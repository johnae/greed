//! `greed.http`: requests over the network, each on a thread of its own so
//! the editor never waits on one. `request` waits for the whole response;
//! `stream` waits for its status and headers, then `read` waits for each
//! piece of the body as it arrives, e.g. tokens from a model.
//!
//! Both only work in a command or event handler, which wait for them the
//! way they wait for `greed.sleep`. A plugin needs the `net` capability, or
//! `net:HOST` for one host, and `fs.write` to save a response to a file.

use std::collections::{HashMap, VecDeque};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use mlua::{Function, IntoLuaMulti, Lua, MultiValue, Table, Value};

use super::jobs::{self, Output};
use super::{capabilities, state_mut, tasks};
use crate::registry::PluginId;

type LuaResult<T> = mlua::Result<T>;

/// The most `request` reads of a body; `stream` has no limit.
const MAX_BODY: u64 = 64 * 1024 * 1024;

/// How long connecting may take.
const CONNECT: Duration = Duration::from_secs(30);

/// A request, as a plugin describes it.
struct Request {
    method: String,
    url: String,
    headers: Vec<(String, String)>,
    body: Option<Vec<u8>>,
    timeout: Option<Duration>,
}

/// A response's status and headers.
pub(super) struct Head {
    status: u16,
    headers: Vec<(String, String)>,
}

/// A whole response, for `request`; an empty body when it was saved to a
/// file.
pub(super) struct Fetched {
    head: Head,
    body: Vec<u8>,
}

/// What a stream's thread sends after the head.
pub(super) enum Chunk {
    Data(Vec<u8>),
    End,
    Failed(String),
}

/// A stream being read: what arrived and wasn't read yet, and the command
/// waiting for more.
struct Stream {
    queue: VecDeque<Chunk>,
    waiter: Option<u64>,
    cancel: Arc<AtomicBool>,
}

/// The open streams, by id.
#[derive(Default)]
pub(crate) struct Streams {
    next: u64,
    open: HashMap<u64, Stream>,
}

/// The host a URL names, for the capability check; only http and https.
fn host_of(url: &str) -> Option<&str> {
    let rest = url
        .strip_prefix("https://")
        .or_else(|| url.strip_prefix("http://"))?;
    let authority = rest.split(['/', '?', '#']).next()?;
    let host = authority.rsplit('@').next()?;
    let host = if let Some(bracketed) = host.strip_prefix('[') {
        bracketed.split(']').next()?
    } else {
        host.split(':').next()?
    };
    (!host.is_empty()).then_some(host)
}

fn request_from_lua(lua: &Lua, owner: &PluginId, opts: &Table) -> LuaResult<Request> {
    let url: String = opts.get("url")?;
    let host = host_of(&url)
        .ok_or_else(|| mlua::Error::runtime(format!("{url:?} isn't an http or https URL")))?;
    capabilities::check_host(lua, owner, host)?;
    let body: Option<mlua::LuaString> = opts.get("body")?;
    let method: Option<String> = opts.get("method")?;
    let mut headers = Vec::new();
    if let Some(table) = opts.get::<Option<Table>>("headers")? {
        for pair in table.pairs::<String, String>() {
            headers.push(pair?);
        }
    }
    let timeout: Option<f64> = opts.get("timeout")?;
    Ok(Request {
        method: method.unwrap_or_else(|| if body.is_some() { "POST" } else { "GET" }.to_owned()),
        url,
        headers,
        body: body.map(|b| b.as_bytes().to_vec()),
        timeout: timeout.map(|ms| Duration::from_secs_f64(ms.max(0.0) / 1000.0)),
    })
}

/// Sends `request` and returns the response, its body not read yet.
fn send(request: Request) -> Result<(Head, ureq::Body), String> {
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .timeout_connect(Some(CONNECT))
        .timeout_global(request.timeout)
        .build()
        .into();
    let mut builder = ureq::http::Request::builder()
        .method(request.method.as_str())
        .uri(&request.url);
    for (name, value) in &request.headers {
        builder = builder.header(name, value);
    }
    let response = match request.body {
        Some(body) => builder.body(body).map(|r| agent.run(r)),
        None => builder.body(()).map(|r| agent.run(r)),
    }
    .map_err(|err| err.to_string())?
    .map_err(|err| err.to_string())?;
    let head = Head {
        status: response.status().as_u16(),
        headers: response
            .headers()
            .iter()
            .map(|(name, value)| {
                (
                    name.as_str().to_owned(),
                    String::from_utf8_lossy(value.as_bytes()).into_owned(),
                )
            })
            .collect(),
    };
    Ok((head, response.into_body()))
}

/// Sends `request` and reads the response; a successful one's body goes
/// to `save` instead, if given.
fn fetch(request: Request, save: Option<&Path>) -> Result<Fetched, String> {
    let (head, body) = send(request)?;
    if let Some(path) = save.filter(|_| (200..300).contains(&head.status)) {
        save_body(body, path)
            .map_err(|err| format!("can't save the response to {}: {err}", path.display()))?;
        return Ok(Fetched {
            head,
            body: Vec::new(),
        });
    }
    let mut bytes = Vec::new();
    body.into_with_config()
        .limit(MAX_BODY)
        .reader()
        .read_to_end(&mut bytes)
        .map_err(|err| err.to_string())?;
    Ok(Fetched { head, body: bytes })
}

/// Writes `body` to `path` as it arrives, with no size limit. The file
/// appears only once it's whole.
fn save_body(body: ureq::Body, path: &Path) -> std::io::Result<()> {
    super::fs::create_parent(path)?;
    let mut reader = body.into_with_config().limit(u64::MAX).reader();
    crate::files::write(path, |out| std::io::copy(&mut reader, out).map(drop))
}

/// Where `request`'s `save` option says to put the body, checked: the
/// plugin needs `fs.write`, and Greed's own files are off limits.
fn save_path(lua: &Lua, owner: &PluginId, opts: &Table) -> LuaResult<Option<PathBuf>> {
    let Some(path) = opts.get::<Option<String>>("save")? else {
        return Ok(None);
    };
    capabilities::check_for(lua, owner, "fs.write")?;
    super::fs::guard_write(lua, Path::new(&path))?;
    Ok(Some(PathBuf::from(path)))
}

/// Reads the body of the stream `id` on this thread, sending each piece.
fn pump(id: u64, mut body: ureq::Body, cancel: &AtomicBool, send: &dyn Fn(Output)) {
    let mut reader = body.as_reader();
    let mut buffer = vec![0; 16 * 1024];
    while !cancel.load(Ordering::Relaxed) {
        match reader.read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => send(Output::StreamChunk(id, Chunk::Data(buffer[..n].to_vec()))),
            Err(err) => {
                send(Output::StreamChunk(id, Chunk::Failed(err.to_string())));
                return;
            }
        }
    }
    send(Output::StreamChunk(id, Chunk::End));
}

fn head_to_lua(lua: &Lua, head: &Head, into: &Table) -> LuaResult<()> {
    into.set("status", head.status)?;
    let headers = lua.create_table()?;
    for (name, value) in &head.headers {
        // Repeated headers come joined, as HTTP allows.
        let joined = match headers.get::<Option<String>>(name.as_str())? {
            Some(earlier) => format!("{earlier}, {value}"),
            None => value.clone(),
        };
        headers.set(name.as_str(), joined)?;
    }
    into.set("headers", headers)
}

/// The value `request`'s caller wakes with.
pub(super) fn fetched_to_lua(lua: &Lua, result: Result<Fetched, String>) -> LuaResult<MultiValue> {
    match result {
        Ok(fetched) => {
            let t = lua.create_table()?;
            head_to_lua(lua, &fetched.head, &t)?;
            t.set("body", lua.create_string(&fetched.body)?)?;
            t.into_lua_multi(lua)
        }
        Err(err) => (Value::Nil, err).into_lua_multi(lua),
    }
}

/// Wakes `stream`'s caller with the stream, once its head arrived.
pub(super) fn stream_started(
    lua: &Lua,
    token: u64,
    id: u64,
    head: Result<Head, String>,
) -> LuaResult<()> {
    let head = match head {
        Ok(head) => head,
        Err(err) => {
            state_mut(lua).http.open.remove(&id);
            return tasks::deliver(lua, token, (Value::Nil, err));
        }
    };
    let stream = lua.create_table()?;
    head_to_lua(lua, &head, &stream)?;
    let read_now = lua.create_function(move |lua, ()| read_now(lua, id))?;
    let read: Function = lua
        .load(
            r"
            local read_now = ...
            return function()
                local ready, a, b = read_now()
                if ready then
                    return a, b
                end
                return coroutine.yield(a)
            end
            ",
        )
        .set_name("=greed.http.stream.read")
        .call(read_now)?;
    stream.set("read", read)?;
    stream.set(
        "close",
        lua.create_function(move |lua, ()| {
            if let Some(stream) = state_mut(lua).http.open.remove(&id) {
                stream.cancel.store(true, Ordering::Relaxed);
            }
            Ok(())
        })?,
    )?;
    tasks::deliver(lua, token, super::handles::methods(lua, stream)?)
}

/// The values a read of stream `id` gives for `chunk`: the text, nil at the
/// end, or nil and why it failed. The end and a failure close the stream.
fn chunk_values(lua: &Lua, id: u64, chunk: Chunk) -> LuaResult<MultiValue> {
    if !matches!(chunk, Chunk::Data(_)) {
        state_mut(lua).http.open.remove(&id);
    }
    match chunk {
        Chunk::Data(bytes) => lua.create_string(&bytes)?.into_lua_multi(lua),
        Chunk::End => Value::Nil.into_lua_multi(lua),
        Chunk::Failed(err) => (Value::Nil, err).into_lua_multi(lua),
    }
}

/// The next piece of stream `id` if one arrived: `true` and its values.
/// Otherwise `false` and the token the next piece wakes.
fn read_now(lua: &Lua, id: u64) -> LuaResult<MultiValue> {
    let chunk = {
        let mut state = state_mut(lua);
        let state = &mut *state;
        // Closed, or read to its end.
        let Some(stream) = state.http.open.get_mut(&id) else {
            return (true, Value::Nil).into_lua_multi(lua);
        };
        let Some(chunk) = stream.queue.pop_front() else {
            let token = state.tasks.token();
            stream.waiter = Some(token);
            return (false, token).into_lua_multi(lua);
        };
        chunk
    };
    let mut values = chunk_values(lua, id, chunk)?;
    values.push_front(Value::Boolean(true));
    Ok(values)
}

/// A piece of stream `id` arrived: the waiting command gets it, or it
/// waits for the next read.
pub(super) fn chunk_arrived(lua: &Lua, id: u64, chunk: Chunk) -> LuaResult<()> {
    let waiter = {
        let mut state = state_mut(lua);
        let Some(stream) = state.http.open.get_mut(&id) else {
            return Ok(());
        };
        let Some(token) = stream.waiter.take() else {
            stream.queue.push_back(chunk);
            return Ok(());
        };
        token
    };
    let values = chunk_values(lua, id, chunk)?;
    tasks::wake(lua, waiter, values)
}

/// `greed.http` for `owner`.
pub(super) fn module(lua: &Lua, owner: &PluginId) -> LuaResult<Table> {
    let http = lua.create_table()?;
    let o = owner.clone();
    let start_request = lua.create_function(move |lua, opts: Table| {
        let request = request_from_lua(lua, &o, &opts)?;
        let save = save_path(lua, &o, &opts)?;
        Ok(jobs::start(
            lua,
            format!("greed.http.request {}", request.url),
            move || Output::Http(fetch(request, save.as_deref())),
        ))
    })?;
    let o = owner.clone();
    let start_stream = lua.create_function(move |lua, opts: Table| {
        let request = request_from_lua(lua, &o, &opts)?;
        let cancel = Arc::new(AtomicBool::new(false));
        let id = {
            let mut state = state_mut(lua);
            state.http.next += 1;
            let id = state.http.next;
            state.http.open.insert(
                id,
                Stream {
                    queue: VecDeque::new(),
                    waiter: None,
                    cancel: cancel.clone(),
                },
            );
            id
        };
        Ok(jobs::start_streaming(
            lua,
            format!("greed.http.stream {}", request.url),
            move |token, emit| match send(request) {
                Ok((head, body)) => {
                    emit(Output::StreamHead(token, id, Ok(head)));
                    pump(id, body, &cancel, emit);
                }
                Err(err) => emit(Output::StreamHead(token, id, Err(err))),
            },
        ))
    })?;
    http.set(
        "request",
        jobs::waiting(lua, "greed.http.request", start_request)?,
    )?;
    http.set(
        "stream",
        jobs::waiting(lua, "greed.http.stream", start_stream)?,
    )?;
    Ok(http)
}

#[cfg(test)]
mod tests {
    use super::host_of;

    #[test]
    fn hosts_come_from_http_urls_only() {
        assert_eq!(
            host_of("https://api.anthropic.com/v1/messages"),
            Some("api.anthropic.com")
        );
        assert_eq!(host_of("http://localhost:11434/api"), Some("localhost"));
        assert_eq!(
            host_of("https://user:pw@example.com?q"),
            Some("example.com")
        );
        assert_eq!(host_of("http://[::1]:8080/"), Some("::1"));
        assert_eq!(host_of("file:///etc/passwd"), None);
        assert_eq!(host_of("https://"), None);
    }
}
