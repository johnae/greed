//! JSON-RPC with a child process: framing, ids, matching, the process.

use std::io::{BufReader, Cursor};
use std::path::Path;
use std::time::{Duration, Instant};

use greed_core::rpc::{Connection, Event, Framing, Transport, read_message, write_message};
use serde_json::{Value, json};

fn sh(script: &str) -> Vec<String> {
    vec!["sh".into(), "-c".into(), script.into()]
}

fn next(events: &crossbeam_channel::Receiver<Event>) -> Event {
    events
        .recv_timeout(Duration::from_secs(5))
        .expect("an event")
}

/// Waits up to five seconds for `done`.
fn eventually(mut done: impl FnMut() -> bool) -> bool {
    let until = Instant::now() + Duration::from_secs(5);
    while Instant::now() < until {
        if done() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    false
}

#[test]
fn messages_are_framed_with_their_length() {
    let mut out = Vec::new();
    write_message(&mut out, &json!({ "a": "é" })).unwrap();
    assert_eq!(
        String::from_utf8(out.clone()).unwrap(),
        "Content-Length: 10\r\n\r\n{\"a\":\"é\"}"
    );

    // Other headers, any case, and a body that isn't JSON between two good
    // ones.
    let mut stream = out.clone();
    stream.extend_from_slice(b"content-type: x\r\ncontent-length: 3\r\n\r\n{x}");
    stream.extend_from_slice(&out);
    let mut reader = BufReader::new(Cursor::new(stream));
    assert_eq!(
        read_message(&mut reader).unwrap(),
        Some(json!({ "a": "é" }))
    );
    let bad = read_message(&mut reader).unwrap_err();
    assert_eq!(bad.kind(), std::io::ErrorKind::InvalidData);
    assert_eq!(
        read_message(&mut reader).unwrap(),
        Some(json!({ "a": "é" }))
    );
    assert_eq!(read_message(&mut reader).unwrap(), None);
}

#[test]
fn a_length_too_big_to_take_ends_the_stream_and_odd_headers_are_skipped() {
    let mut good = Vec::new();
    write_message(&mut good, &json!(1)).unwrap();

    // Bytes that aren't UTF-8 and a header line longer than any real one.
    let mut stream = b"\xff\xfe: 2\r\n\r\n".to_vec();
    stream.extend_from_slice(format!("x-junk: {}\r\n", "y".repeat(10_000)).as_bytes());
    stream.extend_from_slice(&good);
    let mut reader = BufReader::new(Cursor::new(stream));
    let mut read = None;
    for _ in 0..10 {
        match read_message(&mut reader) {
            Ok(message) => {
                read = message;
                break;
            }
            Err(err) => assert_eq!(err.kind(), std::io::ErrorKind::InvalidData, "{err}"),
        }
    }
    assert_eq!(read, Some(json!(1)));

    for length in [u64::MAX.to_string(), (1u64 << 40).to_string()] {
        let stream = format!("Content-Length: {length}\r\n\r\n{{}}");
        let mut reader = BufReader::new(Cursor::new(stream.into_bytes()));
        let err = read_message(&mut reader).unwrap_err();
        assert_ne!(err.kind(), std::io::ErrorKind::InvalidData, "{err}");
    }
}

/// A connection to a peer on a thread: what it's sent comes out of the
/// returned reader, and what's written to the returned writer is what it
/// says.
fn peer(
    id: usize,
) -> (
    Connection,
    crossbeam_channel::Receiver<Event>,
    BufReader<std::io::PipeReader>,
    std::io::PipeWriter,
) {
    let (from_client, client_out) = std::io::pipe().unwrap();
    let (client_in, to_client) = std::io::pipe().unwrap();
    let (sender, events) = crossbeam_channel::unbounded();
    let connection = Connection::open(id, Transport::pipes(client_out, client_in), &sender);
    (connection, events, BufReader::new(from_client), to_client)
}

#[test]
fn requests_are_numbered_and_answers_matched_to_them() {
    let (mut connection, events, mut sent, mut to_client) = peer(7);
    let first = connection.request("a", &json!({ "x": 1 })).unwrap();
    let second = connection.request("b", &Value::Null).unwrap();
    assert_ne!(first, second);
    let message = read_message(&mut sent).unwrap().unwrap();
    assert_eq!(
        message,
        json!({ "jsonrpc": "2.0", "id": first, "method": "a", "params": { "x": 1 } })
    );

    // The second is answered first, with an error; then the first; then the
    // first again and one nobody asked, which are dropped.
    for message in [
        json!({ "jsonrpc": "2.0", "id": second, "error": { "code": 1, "message": "no" } }),
        json!({ "jsonrpc": "2.0", "id": first, "result": "yes" }),
        json!({ "jsonrpc": "2.0", "id": first, "result": "again" }),
        json!({ "jsonrpc": "2.0", "id": 99, "result": "stale" }),
        json!({ "jsonrpc": "2.0", "method": "done" }),
    ] {
        write_message(&mut to_client, &message).unwrap();
    }
    let mut got = Vec::new();
    loop {
        let event = next(&events);
        assert_eq!(event.server(), 7);
        if let Some(event) = connection.receive(event) {
            if matches!(event, Event::Notification { .. }) {
                break;
            }
            got.push(event);
        }
    }
    let answers: Vec<(i64, Result<Value, Value>)> = got
        .into_iter()
        .map(|event| match event {
            Event::Response { id, result, .. } => (id, result),
            other => panic!("{other:?}"),
        })
        .collect();
    assert_eq!(
        answers,
        [
            (second, Err(json!({ "code": 1, "message": "no" }))),
            (first, Ok(json!("yes")))
        ]
    );
    assert_eq!(connection.pending().count(), 0);
}

#[test]
fn the_other_side_asks_and_tells_too() {
    let (mut connection, events, mut sent, mut to_client) = peer(1);
    write_message(
        &mut to_client,
        &json!({ "jsonrpc": "2.0", "id": "q", "method": "ask", "params": [1] }),
    )
    .unwrap();
    write_message(
        &mut to_client,
        &json!({ "jsonrpc": "2.0", "method": "tell" }),
    )
    .unwrap();
    match connection.receive(next(&events)) {
        Some(Event::Request {
            id, method, params, ..
        }) => {
            assert_eq!(
                (id.clone(), method.as_str(), params),
                (json!("q"), "ask", json!([1]))
            );
            connection.respond(&id, Ok(&json!(2))).unwrap();
            connection
                .respond(&id, Err(&json!({ "code": -1, "message": "no" })))
                .unwrap();
        }
        other => panic!("{other:?}"),
    }
    match connection.receive(next(&events)) {
        Some(Event::Notification { method, params, .. }) => {
            assert_eq!((method.as_str(), params), ("tell", Value::Null));
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(
        read_message(&mut sent).unwrap().unwrap(),
        json!({ "jsonrpc": "2.0", "id": "q", "result": 2 })
    );
    assert_eq!(
        read_message(&mut sent).unwrap().unwrap(),
        json!({ "jsonrpc": "2.0", "id": "q", "error": { "code": -1, "message": "no" } })
    );
}

#[test]
fn a_process_that_dies_says_so_last_and_nothing_waits_on_it() {
    let (sender, events) = crossbeam_channel::unbounded();
    let dir = std::env::temp_dir();
    let transport = Transport::spawn(
        &sh("pwd >&2; echo 'something broke' >&2; head -c 1 >/dev/null"),
        &dir,
    )
    .unwrap();
    let mut connection = Connection::open(3, transport, &sender);
    let id = connection.request("anything", &Value::Null).unwrap();
    assert_eq!(connection.pending().collect::<Vec<_>>(), [id]);
    let event = connection.receive(next(&events)).unwrap();
    assert!(matches!(event, Event::Exited { server: 3 }), "{event:?}");
    assert!(!connection.is_alive());
    assert_eq!(connection.pending().count(), 0);
    // Its stderr is kept, and it ran in the folder it was given.
    assert!(eventually(|| connection.stderr().len() == 2));
    let canonical = dir.canonicalize().unwrap();
    assert_eq!(
        connection.stderr(),
        [
            canonical.display().to_string(),
            "something broke".to_owned()
        ]
    );
    // Writing to it now fails rather than hanging, once the writer has seen
    // it go, which a slow machine takes a moment for.
    assert!(eventually(|| connection
        .notify("more", &Value::Null)
        .is_err()));
}

#[test]
fn only_the_last_lines_of_stderr_are_kept() {
    let (sender, events) = crossbeam_channel::unbounded();
    let transport = Transport::spawn(
        &sh("i=0; while [ $i -lt 80 ]; do echo line $i >&2; i=$((i+1)); done"),
        Path::new("/"),
    )
    .unwrap();
    let connection = Connection::open(0, transport, &sender);
    next(&events);
    assert!(eventually(|| connection
        .stderr()
        .last()
        .is_some_and(|l| l == "line 79")));
    let lines = connection.stderr();
    assert_eq!(lines.len(), 50);
    assert_eq!(lines[0], "line 30");
}

#[test]
fn a_program_that_isnt_there_fails_to_start() {
    let err = Transport::spawn(&["greed-no-such-program".to_owned()], Path::new("/")).err();
    assert!(err.is_some());
    assert!(Transport::spawn(&[], Path::new("/")).is_err());
}

#[test]
fn dropping_a_connection_closes_the_process_input_so_it_can_exit() {
    let dir = std::env::temp_dir().join(format!("greed-rpc-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let (sender, _events) = crossbeam_channel::unbounded();
    // It waits for its input to end, then leaves a file behind.
    let transport = Transport::spawn(&sh("cat >/dev/null; echo bye > gone"), &dir).unwrap();
    let mut connection = Connection::open(0, transport, &sender);
    connection.notify("exit", &Value::Null).unwrap();
    drop(connection);
    assert!(eventually(|| dir.join("gone").exists()));
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_process_that_ignores_its_input_ending_is_killed() {
    let (sender, events) = crossbeam_channel::unbounded();
    let transport = Transport::spawn(&sh("trap '' TERM; exec sleep 30"), Path::new("/")).unwrap();
    let connection = Connection::open(0, transport, &sender);
    let started = Instant::now();
    drop(connection);
    // Its output ends once it's killed, after the grace period.
    assert!(matches!(
        events.recv_timeout(Duration::from_secs(10)),
        Ok(Event::Exited { .. })
    ));
    assert!(started.elapsed() < Duration::from_secs(10));
}

#[test]
fn messages_can_go_one_a_line_as_agents_speak() {
    let (sender, events) = crossbeam_channel::unbounded();
    // Answers each request with its own method, a line each, after a blank
    // line and a notification of its own.
    let script = r#"echo; echo '{"jsonrpc":"2.0","method":"hello","params":{"n":1}}'
while read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":\"ok $id\"}"
done"#;
    let transport = Transport::start(&sh(script), None, &[])
        .unwrap()
        .framed(Framing::Lines);
    let mut connection = Connection::open(4, transport, &sender);
    let hello = connection.receive(next(&events)).unwrap();
    assert!(
        matches!(&hello, Event::Notification { method, params, .. } if method == "hello" && params["n"] == 1),
        "{hello:?}"
    );
    let id = connection.request("ping", &json!({ "a": 1 })).unwrap();
    match connection.receive(next(&events)).unwrap() {
        Event::Response {
            id: got, result, ..
        } => {
            assert_eq!(got, id);
            assert_eq!(result.unwrap(), json!(format!("ok {id}")));
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn sending_never_waits_on_a_process_that_isnt_reading() {
    let (sender, _events) = crossbeam_channel::unbounded();
    let dir = std::env::temp_dir();
    let transport = Transport::spawn(&sh("sleep 30"), &dir).unwrap();
    let mut connection = Connection::open(0, transport, &sender);
    // Far more than a pipe holds, which would block a write until it reads.
    let big = json!({ "keys": "k".repeat(64 * 1024) });
    let started = Instant::now();
    for _ in 0..200 {
        connection.request("summaries", &big).unwrap();
    }
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "sending waited {:?} on a process that doesn't read",
        started.elapsed()
    );
}
