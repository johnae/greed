//! `greed bench`: how long a key takes to show, the way the terminal client
//! sees it. It starts a session with your plugins and config on a file
//! (a large generated Rust file unless you name one), attaches over the
//! session socket as `greed` does, types and moves, and reports how long
//! each key took from being sent to the frame showing it arriving.
//!
//! What it leaves out: drawing the frame in the terminal, and the terminal
//! itself, which `greed`'s client and your terminal emulator add on top.

use std::fmt::Write as _;
use std::io::{BufRead, Write};
use std::path::Path;
use std::time::{Duration, Instant};

use greed_core::control::{self, Attachment, Client};
use greed_core::keymap::Key;
use greed_core::render::Size;
use greed_core::server::{self, Input, Output};

type Error = Box<dyn std::error::Error>;

/// The screen it draws for: a large terminal window.
const SIZE: Size = Size {
    width: 200,
    height: 50,
};

/// How long to wait between keys, about fast typing, so each key gets a
/// frame of its own as it would at a keyboard.
const BETWEEN: Duration = Duration::from_millis(15);

/// A key that takes this long is one you'd feel.
const SLOW: Duration = Duration::from_millis(16);

/// One thing to measure: keys to press first, untimed, then keys to time.
struct Scenario {
    name: &'static str,
    setup: &'static str,
    keys: String,
}

fn scenarios() -> Vec<Scenario> {
    // A line of code, as keys: each character, with space by its name.
    let line = "let value = compute(input, 42);"
        .chars()
        .map(|c| {
            if c == ' ' {
                "space".to_owned()
            } else {
                c.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join(" ");
    vec![
        Scenario {
            name: "typing",
            setup: "g g 2 0 0 j o",
            keys: [line.as_str(), "enter"].repeat(6).join(" "),
        },
        Scenario {
            name: "line down",
            setup: "esc g g",
            keys: vec!["j"; 150].join(" "),
        },
        Scenario {
            name: "word forward",
            setup: "esc g g",
            keys: vec!["w"; 150].join(" "),
        },
        Scenario {
            name: "half page",
            setup: "esc g g",
            keys: vec!["ctrl-d"; 40].join(" "),
        },
    ]
}

/// A large Rust file to edit: many functions and types, so highlighting
/// and syntax have work to do.
fn generated() -> String {
    let mut text =
        String::from("//! Generated for greed bench.\n\nuse std::collections::HashMap;\n\n");
    for i in 0..400 {
        let _ = write!(
            text,
            "/// Thing number {i}.\n#[derive(Debug, Clone)]\npub struct Thing{i} {{\n    name: String,\n    values: Vec<u64>,\n    seen: HashMap<String, usize>,\n}}\n\nimpl Thing{i} {{\n    pub fn total(&self) -> u64 {{\n        self.values.iter().copied().filter(|v| v % 2 == 0).sum::<u64>() + {i}\n    }}\n}}\n\n"
        );
    }
    text
}

/// Runs the benchmark on `file`, or a generated one, and prints a report.
pub fn run(file: Option<&Path>) -> Result<(), Error> {
    let name = format!("bench-{}", std::process::id());
    let scratch = std::env::temp_dir().join(format!("greed-{name}"));
    std::fs::create_dir_all(&scratch)?;
    let path = if let Some(file) = file {
        std::path::absolute(file)?
    } else {
        let path = scratch.join("bench.rs");
        std::fs::write(&path, generated())?;
        path
    };
    let text = std::fs::read_to_string(&path)?;
    let lines = text.lines().count();
    let session = control::listen(&name, Some(path.parent().unwrap_or(&scratch)))?;
    let requests = session.sender().clone();
    let opened = path.clone();
    let conn = server::spawn_with_session(
        move || {
            let host = crate::host(&text, Some(opened), Some(requests))?;
            // A benchmark isn't a session to come back to.
            host.eval("require('@greed').option.set('restore-session', false)")?;
            Ok(host)
        },
        Some(session),
    );
    let (socket, token) = control::session_files(&name);
    let token = std::fs::read_to_string(token)?;
    let mut client = Bench::new(Client::connect(&socket, token.trim())?.attach()?);
    client.send(&Input::Resize(SIZE))?;
    client.frame()?;
    // Let highlighting and language servers settle, as when you open a file.
    client.drain(Duration::from_millis(1500));

    println!(
        "greed bench: {} ({lines} lines), {}x{}, a key every {} ms",
        path.display(),
        SIZE.width,
        SIZE.height,
        BETWEEN.as_millis()
    );
    println!("time from a key leaving the client to the frame showing it arriving\n");
    println!(
        "{:<14} {:>5} {:>8} {:>8} {:>8} {:>8}  {:>6}",
        "", "keys", "median", "p95", "p99", "worst", "> 16ms"
    );
    let mut all = Vec::new();
    for scenario in scenarios() {
        for key in Key::parse_sequence(scenario.setup)? {
            client.send(&Input::Key(key))?;
        }
        client.drain(Duration::from_millis(300));
        let mut times = Vec::new();
        let mut slow = Vec::new();
        for (i, key) in Key::parse_sequence(&scenario.keys)?.into_iter().enumerate() {
            let took = client.timed(key)?;
            if took > SLOW {
                slow.push(format!(
                    "{key} (#{}) {:.1}ms",
                    i + 1,
                    took.as_secs_f64() * 1000.0
                ));
            }
            times.push(took);
            std::thread::sleep(BETWEEN);
        }
        client.drain(Duration::from_millis(100));
        report(scenario.name, &mut times);
        if !slow.is_empty() {
            println!("{:<14} slow: {}", "", slow.join(", "));
        }
        all.extend(times);
    }
    println!();
    report("all", &mut all);
    let _ = conn.input.send(Input::Quit);
    let _ = conn.server.join();
    let _ = std::fs::remove_dir_all(&scratch);
    Ok(())
}

fn report(name: &str, times: &mut [Duration]) {
    times.sort();
    // The time `percent` of the way along, slowest last.
    let at = |percent: usize| {
        let i = (times.len() - 1) * percent / 100;
        times[i].as_secs_f64() * 1000.0
    };
    let slow = times.iter().filter(|t| **t > SLOW).count();
    println!(
        "{name:<14} {:>5} {:>7.2}ms {:>6.2}ms {:>6.2}ms {:>6.2}ms  {slow:>6}",
        times.len(),
        at(50),
        at(95),
        at(99),
        at(100),
    );
}

/// The attached client, reading what the session sends.
struct Bench {
    attachment: Attachment,
    pending: std::sync::mpsc::Receiver<Output>,
}

impl Bench {
    fn new(attachment: Attachment) -> Self {
        // Read on a thread of its own, so waiting can time out.
        let reader = attachment
            .reader
            .get_ref()
            .try_clone()
            .expect("the socket clones");
        let (tx, pending) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut reader = std::io::BufReader::new(reader);
            let mut line = String::new();
            while reader.read_line(&mut line).is_ok_and(|n| n > 0) {
                if let Ok(output) = serde_json::from_str::<Output>(&line)
                    && tx.send(output).is_err()
                {
                    return;
                }
                line.clear();
            }
        });
        Bench {
            attachment,
            pending,
        }
    }

    fn send(&mut self, input: &Input) -> Result<(), Error> {
        writeln!(self.attachment.writer, "{}", serde_json::to_string(input)?)?;
        Ok(())
    }

    /// Waits for the next frame, whole or a delta.
    fn frame(&mut self) -> Result<(), Error> {
        loop {
            match self.pending.recv_timeout(Duration::from_secs(10))? {
                Output::Frame(_) | Output::Delta(_) => return Ok(()),
                Output::Exit | Output::Detached => return Err("the session went away".into()),
                _ => {}
            }
        }
    }

    /// Takes whatever comes for `time`, like frames from highlighting.
    fn drain(&mut self, time: Duration) {
        let until = Instant::now() + time;
        while let Some(left) = until.checked_duration_since(Instant::now()) {
            if self.pending.recv_timeout(left).is_err() {
                break;
            }
        }
    }

    /// How long `key` takes to come back as a frame.
    fn timed(&mut self, key: Key) -> Result<Duration, Error> {
        while self.pending.try_recv().is_ok() {}
        let start = Instant::now();
        self.send(&Input::Key(key))?;
        self.frame()?;
        Ok(start.elapsed())
    }
}
