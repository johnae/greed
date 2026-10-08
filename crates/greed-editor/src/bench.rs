//! `greed bench`: how long a key takes to show, the way the terminal client
//! sees it. It starts a session with your plugins and config on a file
//! (a large generated Rust file unless you name one), attaches over the
//! session socket as `greed` does, types and moves, and reports how long
//! each key took from being sent to the frame showing it arriving.
//!
//! With `--draw` it also draws each frame in the terminal it runs in,
//! as `greed` does, and times that and the terminal taking it in.

use std::fmt::Write as _;
use std::io::{BufRead, IsTerminal, Write};
use std::path::Path;
use std::time::{Duration, Instant};

use greed_core::control::{self, Attachment, Client};
use greed_core::keymap::Key;
use greed_core::render::{Frame, Size, grid};
use greed_core::server::{self, Input, Output};

use crate::tui::{Painter, Terminal};

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
        // In a function's body, where most typing goes.
        Scenario {
            name: "typing",
            setup: "g g 2 1 0 j o",
            keys: [line.as_str(), "enter"].repeat(6).join(" "),
        },
        // Between an attribute and its struct, where the line is a syntax
        // error: tree-sitter's error recovery makes each parse slower.
        Scenario {
            name: "broken code",
            setup: "esc g g 6 0 0 j o",
            keys: [line.as_str(), "enter"].repeat(3).join(" "),
        },
        Scenario {
            name: "new line",
            setup: "esc g g 3 0 0 j A",
            keys: vec!["enter"; 40].join(" "),
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
pub fn run(file: Option<&Path>, terminal: bool) -> Result<(), Error> {
    if terminal && !std::io::stdout().is_terminal() {
        return Err("greed bench --draw draws in the terminal it runs in".into());
    }
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
    let mut shell = Client::connect_as(&socket, token.trim(), true)?;
    // In the terminal, at its size and drawn as `greed` draws.
    let screen = if terminal {
        Some((Terminal::enter()?, Painter::new()))
    } else {
        None
    };
    let size = if terminal {
        let (width, height) = crossterm::terminal::size()?;
        Size { width, height }
    } else {
        SIZE
    };
    let measured = measure(&mut client, &mut shell, size, screen);
    let _ = conn.input.send(Input::Quit);
    let _ = conn.server.join();
    let _ = std::fs::remove_dir_all(&scratch);
    let mut measured = measured?;

    println!(
        "greed bench: {} ({lines} lines), {}x{}, a key every {} ms",
        path.display(),
        size.width,
        size.height,
        BETWEEN.as_millis()
    );
    println!("time from a key leaving the client to the frame showing it arriving\n");
    println!(
        "{:<14} {:>5} {:>8} {:>8} {:>8} {:>8}  {:>6}",
        "", "keys", "median", "p95", "p99", "worst", "> 16ms"
    );
    let mut all = Vec::new();
    for scenario in &measured {
        let mut times = scenario.times.clone();
        report(scenario.name, &mut times);
        if !scenario.slow.is_empty() {
            println!("{:<14} slow: {}", "", scenario.slow.join(", "));
        }
        all.extend(times);
    }
    println!();
    report("all", &mut all);
    if terminal {
        println!(
            "\ndrawing each frame in this terminal, medians: greed's client, the bytes\nit wrote, and the terminal taking them in (then its worst)\n"
        );
        println!(
            "{:<14} {:>10} {:>8} {:>11} {:>10}",
            "", "client", "bytes", "terminal", "worst"
        );
        for scenario in &mut measured {
            if let Some(drawn) = &mut scenario.drawn {
                drawn.report(scenario.name);
            }
        }
    }
    for scenario in &measured {
        println!(
            "\nwhere the time went, {}, per key (plugin: what)\n{}",
            scenario.name,
            per_key(&scenario.profile, scenario.times.len())
        );
    }
    Ok(())
}

/// What one scenario measured.
struct Measured {
    name: &'static str,
    times: Vec<Duration>,
    slow: Vec<String>,
    profile: String,
    drawn: Option<Drawn>,
}

/// Runs every scenario at `size`, drawing each frame in the terminal with
/// `screen`.
fn measure(
    client: &mut Bench,
    shell: &mut Client,
    size: Size,
    mut screen: Option<(Terminal, Painter)>,
) -> Result<Vec<Measured>, Error> {
    client.send(&Input::Resize(size))?;
    client.frame()?;
    // Let highlighting and language servers settle, as when you open a file.
    client.drain(Duration::from_millis(1500));
    let mut measured = Vec::new();
    for scenario in scenarios() {
        for key in Key::parse_sequence(scenario.setup)? {
            client.send(&Input::Key(key))?;
        }
        client.drain(Duration::from_millis(300));
        eval(shell, "require('@greed').profile.start()")?;
        let mut times = Vec::new();
        let mut slow = Vec::new();
        let mut drawn = screen.as_ref().map(|_| Drawn::default());
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
            if let (Some((_, painter)), Some(drawn), Some(frame)) =
                (&mut screen, &mut drawn, &client.current)
            {
                drawn.draw(painter, frame)?;
            }
            std::thread::sleep(BETWEEN);
        }
        client.drain(Duration::from_millis(100));
        measured.push(Measured {
            name: scenario.name,
            times,
            slow,
            profile: eval(shell, PROFILE)?,
            drawn,
        });
    }
    measured.push(terminal_echo(client, shell, &mut screen)?);
    Ok(measured)
}

/// What's typed into a terminal: a line at a time, each character timed
/// until it shows.
const TYPED: &str = "the-quick-brown-fox-jumps-over-the-lazy-dog";

/// Types into a terminal running `cat`, whose echo comes from the terminal
/// itself, so what's timed is Greed: the key reaching the program, its
/// output coming back, the buffer and the frame.
fn terminal_echo(
    client: &mut Bench,
    shell: &mut Client,
    screen: &mut Option<(Terminal, Painter)>,
) -> Result<Measured, Error> {
    eval(
        shell,
        "require('@greed').run('terminal', { args = { 'cat' } })",
    )?;
    client.drain(Duration::from_millis(500));
    eval(shell, "require('@greed').profile.start()")?;
    let mut times = Vec::new();
    let mut slow = Vec::new();
    let mut drawn = screen.as_ref().map(|_| Drawn::default());
    for line in 0..3 {
        // Each line different, so a line echoed before doesn't count.
        let text = format!("{line}{TYPED}");
        for (i, c) in text.char_indices() {
            let key = Key::parse(&c.to_string())?;
            let typed = &text[..i + c.len_utf8()];
            let took = client.timed_until(key, |frame| {
                frame
                    .surfaces
                    .iter()
                    .flat_map(|s| &s.rows)
                    .any(|row| row.text().trim_end().ends_with(typed))
            })?;
            if took > SLOW {
                slow.push(format!("{c} {:.1}ms", took.as_secs_f64() * 1000.0));
            }
            times.push(took);
            if let (Some((_, painter)), Some(drawn), Some(frame)) =
                (screen.as_mut(), &mut drawn, &client.current)
            {
                drawn.draw(painter, frame)?;
            }
            std::thread::sleep(BETWEEN);
        }
        client.send(&Input::Key(Key::parse("enter")?))?;
        client.drain(Duration::from_millis(100));
    }
    Ok(Measured {
        name: "terminal echo",
        times,
        slow,
        profile: eval(shell, PROFILE)?,
        drawn,
    })
}

/// Ends the profile and gives back each row as "ms runs longest plugin
/// what", tab separated, the most time first.
const PROFILE: &str = "local out = {}
for _, row in require('@greed').profile.stop() do
    table.insert(out, string.format('%f\\t%d\\t%f\\t%s\\t%s', row.ms, row.runs, row.longest, row.plugin or 'greed', row.what))
end
return table.concat(out, '\\n')";

/// Runs `code` in the session, as `greed ctl eval` does, and returns what it
/// returned.
fn eval(shell: &mut Client, code: &str) -> Result<String, Error> {
    let call = serde_json::json!({ "name": "eval", "arguments": { "code": code } });
    let answer = shell.call("tools/call", &call)??;
    Ok(answer["content"][0]["text"]
        .as_str()
        .unwrap_or_default()
        .to_owned())
}

/// The profile's ten biggest rows, as time per key, with the longest run.
fn per_key(profile: &str, keys: usize) -> String {
    let keys = f64::from(u32::try_from(keys.max(1)).unwrap_or(u32::MAX));
    profile
        .lines()
        .take(10)
        .filter_map(|line| {
            let mut fields = line.split('\t');
            let ms: f64 = fields.next()?.parse().ok()?;
            let runs: f64 = fields.next()?.parse().ok()?;
            let longest: f64 = fields.next()?.parse().ok()?;
            let (plugin, what) = (fields.next()?, fields.next()?);
            Some(format!(
                "  {:>7.3}ms  {:>5.1} runs  {longest:>7.2}ms longest  {plugin}: {what}",
                ms / keys,
                runs / keys
            ))
        })
        .collect::<Vec<_>>()
        .join("\n")
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

/// The attached client, reading what the session sends and keeping the
/// frame it's at.
struct Bench {
    attachment: Attachment,
    pending: std::sync::mpsc::Receiver<Output>,
    current: Option<Frame>,
}

/// Drawing frames in the terminal: what it took `greed`'s client, how many
/// bytes went out, and how long the terminal took to take them in.
#[derive(Default)]
struct Drawn {
    client: Vec<Duration>,
    bytes: Vec<usize>,
    terminal: Vec<Duration>,
}

impl Drawn {
    /// Draws `frame` as the terminal client does, then asks the terminal
    /// where the cursor is: it answers once it has read everything before
    /// the question, so the answer's time is how long it took.
    fn draw(&mut self, painter: &mut Painter, frame: &Frame) -> Result<(), Error> {
        let started = Instant::now();
        let mut bytes = Vec::new();
        painter.paint(&mut bytes, frame)?;
        self.client.push(started.elapsed());
        self.bytes.push(bytes.len());
        let started = Instant::now();
        let mut out = std::io::stdout().lock();
        out.write_all(&bytes)?;
        out.flush()?;
        drop(out);
        // Gives up after a while if the terminal never answers.
        crossterm::cursor::position()?;
        self.terminal.push(started.elapsed());
        Ok(())
    }

    fn report(&mut self, name: &str) {
        let bytes = median(&mut self.bytes);
        let (client, terminal) = (median(&mut self.client), median(&mut self.terminal));
        let worst = self.terminal.last().copied().unwrap_or_default();
        println!(
            "{name:<14} {:>8.2}ms {:>8} {:>9.2}ms {:>8.2}ms",
            client.as_secs_f64() * 1000.0,
            bytes,
            terminal.as_secs_f64() * 1000.0,
            worst.as_secs_f64() * 1000.0
        );
    }
}

fn median<T: Ord + Copy + Default>(values: &mut [T]) -> T {
    values.sort_unstable();
    values.get(values.len() / 2).copied().unwrap_or_default()
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
            current: None,
        }
    }

    /// Keeps `output`'s frame as the current one.
    fn take(&mut self, output: Output) {
        match output {
            Output::Frame(frame) => self.current = Some(frame),
            Output::Delta(delta) => {
                if let Some(frame) = &mut self.current {
                    delta.apply(frame);
                }
            }
            _ => {}
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
                frame @ (Output::Frame(_) | Output::Delta(_)) => {
                    self.take(frame);
                    return Ok(());
                }
                Output::Exit | Output::Detached => return Err("the session went away".into()),
                _ => {}
            }
        }
    }

    /// Takes whatever comes for `time`, like frames from highlighting.
    fn drain(&mut self, time: Duration) {
        let until = Instant::now() + time;
        while let Some(left) = until.checked_duration_since(Instant::now()) {
            match self.pending.recv_timeout(left) {
                Ok(output) => self.take(output),
                Err(_) => break,
            }
        }
    }

    /// How long `key` takes to come back as a frame.
    fn timed(&mut self, key: Key) -> Result<Duration, Error> {
        self.timed_until(key, |_| true)
    }

    /// How long `key` takes to come back as a frame that `shows` says
    /// shows it, e.g. a terminal's program echoing it.
    fn timed_until(&mut self, key: Key, shows: impl Fn(&Frame) -> bool) -> Result<Duration, Error> {
        while let Ok(output) = self.pending.try_recv() {
            self.take(output);
        }
        let start = Instant::now();
        self.send(&Input::Key(key))?;
        loop {
            if let Err(err) = self.frame() {
                let screen = self
                    .current
                    .as_ref()
                    .map_or_else(String::new, |frame| grid::text_rows(frame).join("\n"));
                return Err(format!("{key} never showed ({err}); the screen:\n{screen}").into());
            }
            if self.current.as_ref().is_some_and(&shows) {
                return Ok(start.elapsed());
            }
        }
    }
}
