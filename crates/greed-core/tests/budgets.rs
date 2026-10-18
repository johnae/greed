//! Performance budgets: how long things take and how much memory they use,
//! checked against limits so nothing gets slow or big without a test
//! failing.
//!
//! Each measurement runs in a fresh copy of this test binary, alone in its
//! process, so the CPU time and peak memory it reads are its own. Times are
//! CPU time (the process's, every thread's), which a busy machine changes
//! far less than the clock. Time budgets are about four times what release
//! and debug builds measured with every test running at once, and stayed
//! well inside while the whole workspace's tests ran beside them; memory
//! ones, which vary much less, about one and a half to two times.
//!
//! `GREED_BUDGETS=report cargo test --release --test budgets -- --nocapture`
//! prints every measurement next to its budget; `--include-ignored` adds
//! the ones that take minutes. `GREED_BUDGET_SCALE=2` doubles every budget,
//! for a slower machine than the one they were set on, like CI's runners.

use std::fmt::Write as _;
use std::io::{BufRead, Write as _};
use std::ops::{Deref, Range};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use greed_core::control::{self, Attachment, Client};
use greed_core::keymap::Key;
use greed_core::luau::Host;
use greed_core::render::{CellWidth, Decorations, Frame, Renderer, Row, Size, Status};
use greed_core::search::{GrepOptions, grep};
use greed_core::server::{self, Input, Output};
use greed_core::syntax::{Highlight, Syntax};
use greed_core::{BufferId, Editor, FIRST_CLIENT};
use greed_text::{Author, ChangeSet, ClientId, Rope};
use nix::sys::resource::{UsageWho, getrusage};

mod sessions;

/// Counts what's allocated, to tell memory kept from memory leaked.
#[global_allocator]
static ALLOCATOR: &stats_alloc::StatsAlloc<std::alloc::System> = &stats_alloc::INSTRUMENTED_SYSTEM;

/// The environment variable a child run is told which measurement to make
/// by.
const CHILD: &str = "GREED_BUDGET_CHILD";

/// A large terminal window.
const SIZE: Size = Size {
    width: 160,
    height: 48,
};

// ---------------------------------------------------------------------------
// Measuring

/// The CPU time this process has used, every thread's, and its peak
/// resident memory in bytes.
fn usage() -> (Duration, u64) {
    let usage = getrusage(UsageWho::RUSAGE_SELF).expect("getrusage");
    let time = |t: nix::sys::time::TimeVal| {
        Duration::from_secs(u64::try_from(t.tv_sec()).unwrap_or(0))
            + Duration::from_micros(u64::try_from(t.tv_usec()).unwrap_or(0))
    };
    let cpu = time(usage.user_time()) + time(usage.system_time());
    let rss = u64::try_from(usage.max_rss()).unwrap_or(0);
    // Linux counts in kilobytes, macOS in bytes.
    let rss = if cfg!(target_os = "macos") {
        rss
    } else {
        rss * 1024
    };
    (cpu, rss)
}

fn cpu() -> Duration {
    usage().0
}

#[allow(clippy::cast_precision_loss)]
fn peak_mb() -> f64 {
    usage().1 as f64 / (1024.0 * 1024.0)
}

/// The bytes allocated and not freed yet, by every thread.
fn live_bytes() -> i64 {
    let stats = ALLOCATOR.stats();
    let total = |n: usize| i64::try_from(n).unwrap_or(i64::MAX);
    total(stats.bytes_allocated) - total(stats.bytes_deallocated)
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}

/// What `f` returned, and the CPU time and clock time it took.
fn timed<R>(f: impl FnOnce() -> R) -> (R, Duration, Duration) {
    let (cpu_at, clock_at) = (cpu(), Instant::now());
    let r = f();
    (r, cpu().saturating_sub(cpu_at), clock_at.elapsed())
}

fn median(mut values: Vec<f64>) -> f64 {
    values.sort_by(f64::total_cmp);
    values[values.len() / 2]
}

#[allow(clippy::cast_precision_loss)]
fn per(total: f64, count: usize) -> f64 {
    total / count as f64
}

/// What a measurement found: named numbers, in the order made.
#[derive(Default)]
struct Found(Vec<(String, f64)>);

impl Found {
    fn set(&mut self, name: &str, value: f64) {
        self.0.push((name.to_owned(), value));
    }
}

/// Runs `measure` in a fresh copy of this test binary and checks what it
/// found against `budgets`; in that copy, runs it and prints what it found.
fn budget(test: &str, measure: impl FnOnce(&mut Found), budgets: &[(&str, f64, f64)]) {
    if std::env::var(CHILD).is_ok_and(|child| child == test) {
        let mut found = Found::default();
        measure(&mut found);
        let mut out = std::io::stdout().lock();
        for (name, value) in &found.0 {
            writeln!(out, "budget-found {name} {value}").unwrap();
        }
    } else {
        check(test, &isolated(test), budgets);
    }
}

/// Runs `test` in a fresh copy of this test binary and gives back what it
/// found. The copy's home and config folders are temporary, so nothing it
/// does reaches the user's own.
fn isolated(test: &str) -> Found {
    let home = Temp::new(&format!("home-{test}"));
    let output = Command::new(std::env::current_exe().unwrap())
        .args([
            test,
            "--exact",
            "--include-ignored",
            "--nocapture",
            "--test-threads=1",
        ])
        .env(CHILD, test)
        .env("HOME", &*home)
        .env("XDG_CONFIG_HOME", home.join("config"))
        .env("XDG_STATE_HOME", home.join("state"))
        .env("XDG_DATA_HOME", home.join("data"))
        .env("XDG_CACHE_HOME", home.join("cache"))
        .env("CLAUDE_CONFIG_DIR", home.join("claude"))
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        output.status.success(),
        "{test} failed:\n{stdout}\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let mut found = Found::default();
    // The test harness's own words can start the line.
    for line in stdout.lines() {
        if let Some((_, rest)) = line.split_once("budget-found ") {
            let (name, value) = rest.split_once(' ').unwrap();
            found.set(name, value.parse().unwrap());
        }
    }
    found
}

/// Checks what `test` found against `budgets`: each a name, and the most
/// it may be in a release build and in a debug one. What has no budget is
/// only reported.
fn check(test: &str, found: &Found, budgets: &[(&str, f64, f64)]) {
    let report = std::env::var("GREED_BUDGETS").is_ok_and(|v| v == "report");
    // A slower machine than the budgets were set on, like CI's shared
    // runners, scales them all: still small enough to catch a real
    // slowdown, which is many times over, never a few percent.
    let scale: f64 = std::env::var("GREED_BUDGET_SCALE")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(1.0);
    let mut over = String::new();
    for (name, value) in &found.0 {
        let budget = budgets
            .iter()
            .find(|b| b.0 == name)
            .map(|&(_, release, debug)| {
                scale
                    * if cfg!(debug_assertions) {
                        debug
                    } else {
                        release
                    }
            });
        if report {
            let budget = budget.map_or_else(String::new, |b| format!("  budget {b}"));
            eprintln!("{test:<20} {name:<24} {value:>10.3}{budget}");
        }
        if let Some(budget) = budget
            && *value > budget
        {
            let _ = writeln!(over, "{name}: {value:.3}, over its budget of {budget}");
        }
    }
    for (name, ..) in budgets {
        assert!(
            found.0.iter().any(|(n, _)| n == name),
            "{test} didn't measure {name}"
        );
    }
    assert!(over.is_empty(), "{test} is over budget:\n{over}");
}

/// A temporary folder, removed when dropped, however the test ends.
struct Temp(PathBuf);

impl Temp {
    fn new(label: &str) -> Self {
        let dir =
            std::env::temp_dir().join(format!("greed-budgets-{label}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }
}

impl Deref for Temp {
    type Target = Path;

    fn deref(&self) -> &Path {
        &self.0
    }
}

impl Drop for Temp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

// ---------------------------------------------------------------------------
// The editor, as `greed` runs it

/// An editor with `text` open and every default plugin loaded, as `greed`
/// starts one, with no language servers.
fn host(text: &str, path: Option<PathBuf>) -> Host {
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", text, path);
    let host = Host::new(editor).unwrap();
    host.set_lsp_launcher(Box::new(|_, _| Ok(None)));
    host.load_dirs(&sessions::default_plugins()).unwrap();
    // A measurement isn't a first start to set up: the page would take the
    // first client's keys. Nor is it about trusting the folders it opens,
    // whose question would wait for an answer where a language server is
    // installed.
    host.eval(
        "local option = require('@greed').option
         option.set('setup-first-start', false)
         option.set('project-trust', 'off')",
    )
    .unwrap();
    host.announce_open_files().unwrap();
    host
}

/// Syntax highlights, drawn as the server draws them.
struct Shown<'a>(&'a Syntax);

impl Decorations for Shown<'_> {
    fn highlights(&self, buffer: BufferId, text: &Rope, range: Range<usize>) -> Vec<Highlight> {
        self.0.highlights(buffer, text, range)
    }
}

/// A host driven on this thread as the server drives it: a key, then a
/// frame with the status line a plugin builds.
struct Driven {
    host: Host,
    renderer: Renderer<CellWidth>,
}

impl Driven {
    fn new(host: Host) -> Self {
        Self {
            host,
            renderer: Renderer::new(CellWidth),
        }
    }

    fn frame(&mut self) -> Frame {
        while let Ok(parsed) = self.host.parses().try_recv() {
            self.host.receive_parse(parsed);
        }
        self.host.fire_timers(Instant::now()).unwrap();
        self.host.report_selections().unwrap();
        let status = match self.host.status_line(None, SIZE.width).unwrap() {
            Some(line) => Status::Line(line),
            None => Status::Default { message: None },
        };
        let renderer = &self.renderer;
        let frame = self
            .host
            .with_editor_and_syntax(|ed, syntax| renderer.frame(ed, SIZE, &status, &Shown(syntax)));
        self.host.report_views().unwrap();
        frame
    }

    fn keys(&mut self, keys: &str) {
        for key in Key::parse_sequence(keys).unwrap() {
            self.host.press(FIRST_CLIENT, key).unwrap();
            self.frame();
        }
    }

    fn eval(&self, code: &str) -> String {
        self.host.eval(code).unwrap()
    }

    /// Waits until background parses stop coming.
    fn parsed(&mut self) {
        while let Ok(parsed) = self.host.parses().recv_timeout(Duration::from_millis(300)) {
            self.host.receive_parse(parsed);
        }
        self.frame();
    }
}

/// Presses `keys` `rounds` times, a frame after each key, and gives the
/// CPU time per key of the median round.
fn per_key(driven: &mut Driven, keys: &str, rounds: usize) -> f64 {
    let count = Key::parse_sequence(keys).unwrap().len();
    let times = (0..rounds)
        .map(|_| per(ms(timed(|| driven.keys(keys)).1), count))
        .collect();
    median(times)
}

/// A Rust file of about `lines` lines, of types and functions, so
/// highlighting has work to do.
fn rust_file(lines: usize) -> String {
    let mut text = String::from("//! Generated.\n\nuse std::collections::HashMap;\n\n");
    for i in 0..lines / 15 {
        let _ = write!(
            text,
            "/// Thing number {i}.\n#[derive(Debug, Clone)]\npub struct Thing{i} {{\n    name: String,\n    values: Vec<u64>,\n    seen: HashMap<String, usize>,\n}}\n\nimpl Thing{i} {{\n    pub fn total(&self) -> u64 {{\n        self.values.iter().copied().filter(|v| v % 2 == 0).sum::<u64>() + {i}\n    }}\n}}\n\n"
        );
    }
    text
}

/// Writes plain text of `lines` lines to `path`, each `width` bytes long
/// with its line break, a line at a time, so this process's peak memory
/// stays as it was.
fn write_text_file(path: &Path, lines: usize, width: usize) {
    let words = "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor ";
    let mut out = std::io::BufWriter::new(std::fs::File::create(path).unwrap());
    let mut line = String::with_capacity(width);
    for i in 0..lines {
        line.clear();
        let _ = write!(line, "{i} ");
        while line.len() < width - 1 {
            let take = (width - 1 - line.len()).min(words.len());
            line.push_str(&words[..take]);
        }
        line.push('\n');
        out.write_all(line.as_bytes()).unwrap();
    }
    out.flush().unwrap();
}

// ---------------------------------------------------------------------------
// Starting up

/// Starting with every default plugin on `text`, to the first frame: the
/// median of three starts.
fn startup(found: &mut Found, text: &str, path: Option<&Path>) {
    let (mut cpus, mut clocks) = (Vec::new(), Vec::new());
    for _ in 0..3 {
        let (_, cpu, clock) = timed(|| Driven::new(host(text, path.map(Path::to_owned))).frame());
        cpus.push(ms(cpu));
        clocks.push(ms(clock));
    }
    found.set("first_frame_cpu_ms", median(cpus));
    found.set("first_frame_clock_ms", median(clocks));
    found.set("peak_mb", peak_mb());
}

#[test]
fn startup_empty() {
    budget(
        "startup_empty",
        |found| startup(found, "", None),
        &[
            ("first_frame_cpu_ms", 400.0, 650.0),
            ("peak_mb", 80.0, 100.0),
        ],
    );
}

#[test]
fn startup_rust() {
    budget(
        "startup_rust",
        |found| {
            let dir = Temp::new("startup");
            let path = dir.join("big.rs");
            let text = rust_file(10_000);
            std::fs::write(&path, &text).unwrap();
            startup(found, &text, Some(&path));
        },
        &[
            ("first_frame_cpu_ms", 800.0, 1000.0),
            ("peak_mb", 120.0, 150.0),
        ],
    );
}

// ---------------------------------------------------------------------------
// Large files

/// Opening a file of `lines` lines `width` bytes long, reading it and all,
/// to the first frame; then moving around and typing in it.
fn large_file(found: &mut Found, lines: usize, width: usize) {
    let dir = Temp::new("large");
    let path = dir.join("large.txt");
    write_text_file(&path, lines, width);
    let mut driven = Driven::new(host("", None));
    driven.frame();
    let before = peak_mb();
    let ((), cpu, clock) = timed(|| {
        let text = std::fs::read_to_string(&path).unwrap();
        driven
            .host
            .with_editor_mut(|ed| ed.open("file", &text, Some(path.clone())));
        drop(text);
        driven.host.announce_open_files().unwrap();
        driven.frame();
    });
    found.set("open_cpu_ms", ms(cpu));
    found.set("open_clock_ms", ms(clock));
    found.set("open_added_mb", peak_mb() - before);
    found.set(
        "line_down_cpu_ms",
        per_key(&mut driven, &"j ".repeat(50), 3),
    );
    found.set(
        "page_down_cpu_ms",
        per_key(&mut driven, &"ctrl-d ".repeat(20), 3),
    );
    found.set("end_and_back_cpu_ms", per_key(&mut driven, "G g g", 5));
    driven.keys("g g 5 0 0 0 0 j i");
    found.set(
        "typing_cpu_ms",
        per_key(&mut driven, &"x y z space ".repeat(10), 3),
    );
    found.set("peak_mb", peak_mb());
}

/// Per key in a large file: what moving and typing may take.
const LARGE_KEYS: [(&str, f64, f64); 4] = [
    ("line_down_cpu_ms", 4.0, 8.0),
    ("page_down_cpu_ms", 3.0, 6.0),
    ("end_and_back_cpu_ms", 6.0, 12.0),
    ("typing_cpu_ms", 3.0, 6.0),
];

/// A million short lines, 24 MB.
#[test]
fn million_lines() {
    let mut budgets = vec![
        ("open_cpu_ms", 250.0, 250.0),
        ("open_added_mb", 100.0, 100.0),
    ];
    budgets.extend(LARGE_KEYS);
    budget(
        "million_lines",
        |found| large_file(found, 1_000_000, 24),
        &budgets,
    );
}

/// A million long lines, 100 MB: opening it holds its text twice at most,
/// as read and as the buffer's.
#[test]
fn hundred_mb() {
    let mut budgets = vec![
        ("open_cpu_ms", 1000.0, 1000.0),
        ("open_added_mb", 260.0, 260.0),
    ];
    budgets.extend(LARGE_KEYS);
    budget(
        "hundred_mb",
        |found| large_file(found, 1_000_000, 100),
        &budgets,
    );
}

// ---------------------------------------------------------------------------
// Many buffers

#[test]
fn many_buffers() {
    budget(
        "many_buffers",
        |found| {
            let dir = Temp::new("buffers");
            let text = rust_file(200);
            for i in 0..500 {
                std::fs::write(dir.join(format!("file{i}.rs")), &text).unwrap();
            }
            let mut driven = Driven::new(host("", None));
            driven.frame();
            let before = peak_mb();
            let ((), cpu, _) = timed(|| {
                driven.eval(&format!(
                    "local greed = require('@greed')
                 for i = 0, 499 do greed.open('{}/file' .. i .. '.rs') end",
                    dir.display()
                ));
                driven.frame();
            });
            driven.parsed();
            assert_eq!(driven.eval("return #require('@greed').buffers()"), "500");
            found.set("open_500_cpu_ms", ms(cpu));
            found.set("open_500_added_mb", peak_mb() - before);
            found.set(
                "line_down_cpu_ms",
                per_key(&mut driven, &"j ".repeat(50), 3),
            );
            // The buffer picker: opening it, typing a query, closing it.
            let ((), cpu, _) = timed(|| {
                driven.host.run(FIRST_CLIENT, "pick-buffer").unwrap();
                driven.frame();
                driven.keys("f i l e 4 2 esc");
            });
            found.set("picker_cpu_ms", ms(cpu));
            found.set("peak_mb", peak_mb());
        },
        &[
            ("open_500_cpu_ms", 800.0, 2000.0),
            ("open_500_added_mb", 130.0, 130.0),
            ("line_down_cpu_ms", 6.0, 40.0),
            ("picker_cpu_ms", 150.0, 450.0),
            ("peak_mb", 200.0, 220.0),
        ],
    );
}

// ---------------------------------------------------------------------------
// Notes

/// A note as people write them, some 20 lines: front matter, a couple of
/// headings and paragraphs, a few todos, links and tags.
fn note_text(i: usize) -> String {
    let mut text = format!(
        "---\ntags: [area{}]\n---\n# Note {i}\n\nWhat this is about, with a link to [[note{}]] and #topic{}.\n\n",
        i % 7,
        (i + 1) % 5000,
        i % 13
    );
    for section in 0..2 {
        let _ = write!(
            text,
            "## Part {section}\n\nSome words about it, more than a few, the way notes go.\n\n"
        );
        for item in 0..3 {
            let _ = write!(
                text,
                "- [ ] thing {item} for [[note{}]] due:2026-11-{:02}\n  - a detail\n",
                (i + item) % 5000,
                1 + item
            );
        }
        text.push('\n');
    }
    text
}

/// Indexing 5,000 notes the first time: how long until it's done, and
/// how long the editor was held up at most meanwhile (only holds of 50 ms
/// and more are counted, so 0 means none).
#[test]
fn notes_index() {
    budget(
        "notes_index",
        |found| {
            let dir = Temp::new("notes");
            for i in 0..5000 {
                let sub = dir.join(format!("area{}", i % 20));
                std::fs::create_dir_all(&sub).unwrap();
                std::fs::write(sub.join(format!("note{i}.md")), note_text(i)).unwrap();
            }
            let mut driven = Driven::new(host("", None));
            driven.frame();
            driven.eval(&format!(
                "local greed = require('@greed')
                 greed.option.set('notes-folder', {:?})
                 greed.command({{ name = 'index-now', run = function()
                   require('@notes').index.ensure()
                   indexed = #require('@notes').index.all()
                 end }})",
                dir.display().to_string()
            ));
            let ((), cpu, clock) = timed(|| {
                driven.host.run(FIRST_CLIENT, "index-now").unwrap();
                let deadline = Instant::now() + Duration::from_secs(120);
                while driven.eval("return tostring(indexed)") == "nil" {
                    assert!(Instant::now() < deadline, "the index didn't finish");
                    driven.host.settle().unwrap();
                    driven.frame();
                    std::thread::sleep(Duration::from_millis(1));
                }
            });
            assert_eq!(driven.eval("return tostring(indexed)"), "5000");
            found.set("index_5000_clock_ms", ms(clock));
            found.set("index_5000_cpu_ms", ms(cpu));
            let held: f64 = driven
                .eval(
                    "local most = 0
                     for _, stall in require('@greed').stalls() do
                       if stall.plugin == 'notes' then most = math.max(most, stall.ms) end
                     end
                     return tostring(most)",
                )
                .parse()
                .unwrap();
            found.set("index_longest_hold_ms", held);
        },
        &[
            ("index_5000_clock_ms", 10000.0, 26000.0),
            ("index_longest_hold_ms", 60.0, 120.0),
        ],
    );
}

// ---------------------------------------------------------------------------
// A long session

/// One round of what a session does all day: open a file, edit it and
/// undo, split and float, pick a buffer, close it all again. Through eval
/// as `greed ctl` and agents do, and keys as a person does.
fn session_round(driven: &mut Driven, dir: &Path, i: usize) {
    // Code, and text big enough that a buffer left behind shows.
    let file = if i.is_multiple_of(2) {
        format!("code{}.rs", i % 20)
    } else {
        format!("text{}.txt", i % 20)
    };
    driven.eval(&format!(
        "require('@greed').open('{}/{file}')",
        dir.display()
    ));
    driven.keys("g g 2 0 j o x = 1 ; esc u");
    driven.eval(
        "local greed = require('@greed')
         local main = greed.view()
         local other = main:split('right')
         local float = greed.float(greed.create_buffer('scratch', 'a float'), { width = '40%', height = '30%' })
         float:close()
         other:close()
         main:focus()",
    );
    driven.host.run(FIRST_CLIENT, "pick-buffer").unwrap();
    driven.keys("f esc");
    driven.eval("require('@greed').run('buffer-close', { force = true })");
    driven.frame();
}

/// The bytes the editor holds once it has settled: what waits on a timer
/// due soon (a debounce, an animation) has run, background parses are in
/// and Luau's garbage is collected.
fn held(driven: &mut Driven) -> i64 {
    let until = Instant::now() + Duration::from_secs(1);
    while let Some(due) = driven.host.next_timer().filter(|due| *due < until) {
        std::thread::sleep(due.saturating_duration_since(Instant::now()));
        driven.frame();
    }
    driven.parsed();
    driven.host.luau_memory();
    live_bytes()
}

/// Repeats [`session_round`] `rounds` times after a warm-up, and finds how
/// much memory each round leaves behind. What's held wobbles by a megabyte
/// or so (pages of Luau's heap the garbage left half used, the syntax
/// worker's trees of closed buffers, which it lets go of 64 at a time),
/// never below what's really kept, so the least of the first checkpoints
/// is compared with the least of the last ones.
fn long_session(found: &mut Found, rounds: usize) {
    const CHECKPOINTS: usize = 8;
    let dir = Temp::new("session");
    let code = rust_file(300);
    for i in (0..20).step_by(2) {
        std::fs::write(dir.join(format!("code{i}.rs")), &code).unwrap();
        write_text_file(&dir.join(format!("text{}.txt", i + 1)), 5000, 40);
    }
    let mut driven = Driven::new(host("", None));
    driven.frame();
    // Long enough for caches and pools to have filled.
    for i in 0..40 {
        session_round(&mut driven, &dir, i);
    }
    let step = rounds / CHECKPOINTS;
    let mut checkpoints = vec![held(&mut driven)];
    let mut cpu = Duration::ZERO;
    for checkpoint in 0..CHECKPOINTS {
        cpu += timed(|| {
            for i in 0..step {
                session_round(&mut driven, &dir, checkpoint * step + i);
            }
        })
        .1;
        checkpoints.push(held(&mut driven));
    }
    let first = checkpoints[..3].iter().min().unwrap();
    let last = checkpoints[CHECKPOINTS - 2..].iter().min().unwrap();
    // At least this many rounds apart, whichever checkpoints those are.
    let apart = (CHECKPOINTS - 4) * step;
    #[allow(clippy::cast_precision_loss)]
    found.set("kept_per_round_bytes", per((last - first) as f64, apart));
    found.set("round_cpu_ms", per(ms(cpu), step * CHECKPOINTS));
    found.set("peak_mb", peak_mb());
}

/// A buffer left behind each round would keep at least 100 KB.
const SESSION: [(&str, f64, f64); 3] = [
    ("kept_per_round_bytes", 48_000.0, 48_000.0),
    ("round_cpu_ms", 60.0, 400.0),
    ("peak_mb", 120.0, 150.0),
];

#[test]
fn session() {
    budget("session", |found| long_session(found, 160), &SESSION);
}

/// Minutes of it.
#[test]
#[ignore = "takes minutes; run with --include-ignored"]
fn session_for_minutes() {
    budget(
        "session_for_minutes",
        |found| long_session(found, 8000),
        &SESSION,
    );
}

// ---------------------------------------------------------------------------
// Project grep

/// 2000 files of 300 lines, in 40 folders.
#[test]
fn project_grep() {
    budget(
        "project_grep",
        |found| {
            let dir = Temp::new("grep");
            let text = rust_file(300);
            for d in 0..40 {
                let sub = dir.join(format!("module{d}"));
                std::fs::create_dir_all(&sub).unwrap();
                for f in 0..50 {
                    std::fs::write(sub.join(format!("file{f}.rs")), &text).unwrap();
                }
            }
            let options = GrepOptions {
                hidden: false,
                ignored: false,
                limit: 100_000,
            };
            let (mut cpus, mut clocks) = (Vec::new(), Vec::new());
            for _ in 0..3 {
                let (lines, cpu, clock) =
                    timed(|| grep(&dir, r"Thing1\d\b", options).unwrap().len());
                assert_eq!(lines, 2000 * 10 * 2);
                cpus.push(ms(cpu));
                clocks.push(ms(clock));
            }
            found.set("grep_cpu_ms", median(cpus));
            found.set("grep_clock_ms", median(clocks));
        },
        &[("grep_cpu_ms", 1500.0, 3000.0)],
    );
}

// ---------------------------------------------------------------------------
// Highlighting after an edit

/// A 20,000 line Rust file, parsed again in the background after each of
/// ten edits in its middle, until the highlights are in.
#[test]
fn highlight_after_edit() {
    budget(
        "highlight_after_edit",
        |found| {
            let mut ed = Editor::new(ClientId(1));
            let text = rust_file(20_000);
            let (buffer, view) = ed.open("file", &text, Some("big.rs".into()));
            let mut syntax = Syntax::new();
            let wait = |syntax: &mut Syntax| {
                let parsed = syntax
                    .results()
                    .recv_timeout(Duration::from_secs(60))
                    .expect("a parse");
                syntax.receive(parsed);
            };
            let ((), cpu, _) = timed(|| {
                syntax.update(&ed);
                wait(&mut syntax);
            });
            found.set("first_parse_cpu_ms", ms(cpu));
            let (mut cpus, mut clocks) = (Vec::new(), Vec::new());
            for i in 0..10 {
                let at = ed.buffer(buffer).text().line_to_byte(10_000 + i);
                let len = ed.buffer(buffer).text().len_bytes();
                let change = ChangeSet::from_changes(len, [(at, at, Some("// edited\n"))]).unwrap();
                ed.apply(view, change, Author::User(ClientId(1)), None, None)
                    .unwrap();
                let ((), cpu, clock) = timed(|| {
                    syntax.update(&ed);
                    wait(&mut syntax);
                    let text = ed.buffer(buffer).text();
                    let at = text.line_to_byte(10_000);
                    assert!(!syntax.highlights(buffer, text, at..at + 2000).is_empty());
                });
                cpus.push(ms(cpu));
                clocks.push(ms(clock));
            }
            found.set("reparse_cpu_ms", median(cpus));
            found.set("reparse_clock_ms", median(clocks));
        },
        &[
            ("first_parse_cpu_ms", 400.0, 400.0),
            ("reparse_cpu_ms", 200.0, 200.0),
        ],
    );
}

// ---------------------------------------------------------------------------
// Several clients

/// A client attached over the session socket, reading what the session
/// sends on a thread of its own.
struct Attached {
    writer: std::os::unix::net::UnixStream,
    /// What came, and how many bytes it was on the socket.
    pending: std::sync::mpsc::Receiver<(usize, Output)>,
}

impl Attached {
    fn new(attachment: Attachment) -> Self {
        let mut reader = attachment.reader;
        let (tx, pending) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut line = String::new();
            while reader.read_line(&mut line).is_ok_and(|n| n > 0) {
                if let Ok(output) = serde_json::from_str::<Output>(&line)
                    && tx.send((line.len(), output)).is_err()
                {
                    return;
                }
                line.clear();
            }
        });
        Self {
            writer: attachment.writer,
            pending,
        }
    }

    fn send(&mut self, input: &Input) {
        writeln!(self.writer, "{}", serde_json::to_string(input).unwrap()).unwrap();
    }

    /// Waits for the next frame, whole or what changed, and gives its size.
    fn frame(&self) -> usize {
        loop {
            let (bytes, output) = self
                .pending
                .recv_timeout(Duration::from_secs(30))
                .expect("a frame");
            if matches!(output, Output::Frame(_) | Output::Delta(_)) {
                return bytes;
            }
        }
    }

    /// Waits for the first frame, whole or what changed, with a row showing
    /// `text`.
    fn frame_showing(&self, text: &str) {
        fn shows<'a>(mut rows: impl Iterator<Item = &'a Row>, text: &str) -> bool {
            rows.any(|row| {
                row.spans
                    .iter()
                    .map(|span| span.text.as_str())
                    .collect::<String>()
                    .contains(text)
            })
        }
        loop {
            let (_, output) = self
                .pending
                .recv_timeout(Duration::from_secs(30))
                .unwrap_or_else(|_| panic!("a frame showing {text:?}"));
            let found = match &output {
                Output::Frame(frame) => {
                    shows(frame.surfaces.iter().flat_map(|s| s.rows.iter()), text)
                }
                Output::Delta(delta) => shows(
                    delta
                        .surfaces
                        .iter()
                        .flat_map(|s| s.rows.iter().map(|(_, row)| row)),
                    text,
                ),
                _ => false,
            };
            if found {
                return;
            }
        }
    }

    /// Takes whatever comes until nothing has for `quiet`, and gives the
    /// bytes of the frames among it.
    fn drain(&self, quiet: Duration) -> usize {
        let mut bytes = 0;
        while let Ok((size, output)) = self.pending.recv_timeout(quiet) {
            if matches!(output, Output::Frame(_) | Output::Delta(_)) {
                bytes += size;
            }
        }
        bytes
    }
}

/// Lays the screen out as a busy one is: the file, a split beside it, a
/// terminal running `cat` and a float, with the file focused.
const LAYOUT: &str = "local greed = require('@greed')
greed.command({ name = 'budget-layout', run = function()
    local main = greed.tab.current().panes[1]
    main:split('right', greed.create_buffer('scratch', string.rep('some other text\\n', 200)))
    greed.run('terminal', { args = { 'cat' } })
    greed.float(greed.create_buffer('scratch', 'a float\\nof two lines'), { width = '40%', height = '30%', focus = false })
    main:focus()
end })";

/// Three clients attached over the socket, one typing into a file the
/// others see, with a split, a terminal and a float on screen: what a key
/// costs the session, and the bytes each client gets for it.
#[test]
fn clients() {
    budget(
        "clients",
        |found| {
            sessions::private();
            let dir = Temp::new("clients");
            let path = dir.join("main.rs");
            let text = rust_file(2000);
            std::fs::write(&path, &text).unwrap();
            let name = format!("budgets-{}", std::process::id());
            let session = control::listen(&name, None).unwrap();
            let socket = session.socket.clone();
            let token = std::fs::read_to_string(control::session_files(&name).1).unwrap();
            let conn = server::spawn_with_session(
                move || {
                    let host = host(&text, Some(path));
                    host.load_str("budget-layout", LAYOUT)?;
                    Ok(host)
                },
                Some(session),
            );
            let attach =
                || Attached::new(Client::connect(&socket, &token).unwrap().attach().unwrap());
            let mut clients = [attach(), attach(), attach()];
            for client in &mut clients {
                client.send(&Input::Resize(SIZE));
            }
            for client in &clients {
                client.frame();
            }
            clients[0].send(&Input::Run("budget-layout".into()));
            for key in Key::parse_sequence("g g 1 0 0 j o").unwrap() {
                clients[0].send(&Input::Key(key));
            }
            for client in &clients {
                client.drain(Duration::from_millis(500));
            }
            let keys = Key::parse_sequence(&"x y z space ".repeat(10)).unwrap();
            let mut bytes = [Vec::new(), Vec::new(), Vec::new()];
            let mut clocks = Vec::new();
            let ((), cpu, _) = timed(|| {
                for key in &keys {
                    let start = Instant::now();
                    clients[0].send(&Input::Key(*key));
                    let typed = clients[0].frame();
                    clocks.push(ms(start.elapsed()));
                    // A client only gets a frame when its screen changed.
                    for (i, client) in clients.iter().enumerate() {
                        let more = client.drain(Duration::from_millis(15));
                        #[allow(clippy::cast_precision_loss)]
                        bytes[i].push((more + if i == 0 { typed } else { 0 }) as f64);
                    }
                }
            });
            found.set("key_cpu_ms", per(ms(cpu), keys.len()));
            found.set("key_clock_ms", median(clocks));
            let [typist, watcher, _] = bytes;
            found.set("typist_bytes", median(typist));
            found.set("watcher_bytes", median(watcher));
            let ((), idle, _) = timed(|| std::thread::sleep(Duration::from_secs(1)));
            found.set("idle_cpu_ms_per_s", ms(idle));
            // What was measured is what was meant: the typing went into the
            // file, beside a split, with a terminal open.
            let mut shell = Client::connect_as(&socket, &token, true).unwrap();
            let call = serde_json::json!({ "name": "eval", "arguments": { "code":
            "local greed = require('@greed')
             local kinds = {}
             for _, buffer in greed.buffers() do kinds[buffer:kind()] = true end
             return tostring(string.find(greed.buffers()[1]:text(), 'xyz xyz', 1, true) ~= nil)
                 .. ' ' .. #greed.tab.current().panes .. ' ' .. tostring(kinds.terminal)" } });
            let answer = shell.call("tools/call", &call).unwrap().unwrap();
            assert_eq!(answer["content"][0]["text"], "true 2 true", "{answer}");
            let _ = conn.input.send(Input::Quit);
            let _ = conn.server.join();
        },
        &[
            ("key_cpu_ms", 50.0, 250.0),
            ("typist_bytes", 2000.0, 2000.0),
            ("watcher_bytes", 1000.0, 1000.0),
            ("idle_cpu_ms_per_s", 150.0, 300.0),
        ],
    );
}

/// Work a plugin keeps the session busy with: Luau computing without end
/// (cut into slices), a program it waits on again and again, a status line
/// piece that takes 200 ms to draw, and a status line of your own that
/// takes a second to build.
const BUSY: &str = "local greed = require('@greed')
local statusline = require('@statusline')
greed.command({ name = 'budget-busy-cpu', run = function()
    greed.spawn(function()
        local x = 0
        while true do
            for i = 1, 100000 do x = (x + i) % 7919 end
        end
    end)
end })
greed.command({ name = 'budget-busy-io', run = function()
    greed.spawn(function()
        while true do greed.process.run({ 'sleep', '0.2' }) end
    end)
end })
greed.command({ name = 'budget-busy-piece', run = function()
    statusline.add('right', 'budget-slow', function()
        local from = os.clock()
        while os.clock() - from < 0.2 do end
        return 'slow'
    end)
end })
greed.command({ name = 'budget-busy-line', run = function()
    greed.statusline(function()
        local from = os.clock()
        while os.clock() - from < 1 do end
        return { left = { 'slow' }, right = {} }
    end)
end })";

/// From typing a key to the first frame showing it, in a session the work
/// in `BUSY` named `parts` keeps busy: the median, the 90th percentile and
/// the slowest of 26 keys.
fn key_to_frame(found: &mut Found, parts: &[&str]) {
    sessions::private();
    let dir = Temp::new("busy");
    let path = dir.join("notes.txt");
    std::fs::write(&path, "some text\n".repeat(50)).unwrap();
    let name = format!("budgets-busy-{}", std::process::id());
    let session = control::listen(&name, None).unwrap();
    let socket = session.socket.clone();
    let token = std::fs::read_to_string(control::session_files(&name).1).unwrap();
    let conn = server::spawn_with_session(
        move || {
            let host = host("", Some(path));
            host.load_str("budget-busy", BUSY)?;
            Ok(host)
        },
        Some(session),
    );
    let mut client = Attached::new(Client::connect(&socket, &token).unwrap().attach().unwrap());
    client.send(&Input::Resize(SIZE));
    client.frame();
    for part in parts {
        client.send(&Input::Run(format!("budget-busy-{part}")));
    }
    for key in Key::parse_sequence("g g o").unwrap() {
        client.send(&Input::Key(key));
    }
    client.drain(Duration::from_millis(500));
    let mut typed = String::new();
    let mut clocks = Vec::new();
    for c in "abcdefghijklmnopqrstuvwxyz".chars() {
        typed.push(c);
        let start = Instant::now();
        client.send(&Input::Key(Key::parse_sequence(&c.to_string()).unwrap()[0]));
        client.frame_showing(&typed);
        clocks.push(ms(start.elapsed()));
    }
    clocks.sort_by(f64::total_cmp);
    found.set("key_to_frame_median_ms", clocks[clocks.len() / 2]);
    found.set("key_to_frame_p90_ms", clocks[clocks.len() * 9 / 10]);
    found.set("key_to_frame_max_ms", clocks[clocks.len() - 1]);
    let _ = conn.input.send(Input::Quit);
    let _ = conn.server.join();
}

/// A key shows on screen as soon as it's typed, however busy plugins keep
/// the session: computing, waiting on programs, a status line piece slow
/// to draw. Nothing a plugin does may hold the editor up (Emacs's freezes
/// are what this guards against). A key waits at most for the time slice
/// that's running when it comes.
#[test]
fn busy() {
    budget(
        "busy",
        |found| key_to_frame(found, &["cpu", "io", "piece"]),
        &[
            ("key_to_frame_p90_ms", 60.0, 70.0),
            ("key_to_frame_max_ms", 100.0, 150.0),
        ],
    );
}

/// A status line of your own that takes a second to build: the editor
/// stops it, draws the last one, and tries again a second later, so keys
/// wait for it at most once a second.
#[test]
fn slow_status_line() {
    budget(
        "slow_status_line",
        |found| key_to_frame(found, &["line"]),
        &[
            ("key_to_frame_median_ms", 20.0, 40.0),
            ("key_to_frame_max_ms", 200.0, 800.0),
        ],
    );
}

// ---------------------------------------------------------------------------
// An index of many items

mod index_budget {
    use std::collections::HashMap;

    use greed_index::index::{Index, Item, View};
    use greed_index::query::{Flag, Kind, Node, Schema};

    /// How many items the index holds: about a big mailbox.
    pub const ITEMS: usize = 200_000;

    const WORDS: [&str; 24] = [
        "invoice", "meeting", "report", "garden", "travel", "budget", "review", "project",
        "deploy", "release", "lunch", "coffee", "kitchen", "server", "update", "question",
        "family", "weekend", "music", "ticket", "contract", "design", "photo", "receipt",
    ];
    const PEOPLE: [&str; 8] = ["anna", "bo", "carl", "dana", "erik", "fia", "gus", "hedda"];
    const TAGS: [&str; 6] = ["work", "home", "money", "news", "travel", "family"];

    /// Item `i` of a mailbox-like index: in one of 20 mailboxes, with text,
    /// a sender, tags, a size, a date over five years and flags.
    fn item(i: usize) -> Item {
        let word = |n: usize| WORDS[(i * 7 + n * 13) % WORDS.len()];
        let text = (0..30).map(word).collect::<Vec<_>>().join(" ") + &format!(" ref{i}");
        let day = i % (5 * 365);
        let date = format!(
            "{:04}-{:02}-{:02}",
            2022 + day / 365,
            (day % 365) / 31 % 12 + 1,
            day % 28 + 1
        );
        let mut fields = HashMap::new();
        fields.insert(
            "from".into(),
            vec![format!("{} <{}@example.org>", PEOPLE[i % 8], PEOPLE[i % 8])],
        );
        fields.insert(
            "tag".into(),
            vec![TAGS[i % 6].into(), TAGS[(i / 6) % 6].into()],
        );
        fields.insert("size".into(), vec![format!("{}k", (i * 37) % 500)]);
        fields.insert("date".into(), vec![date]);
        let mut flags = vec!["mail".to_string()];
        if i.is_multiple_of(3) {
            flags.push("unread".into());
        }
        Item {
            key: format!("m{i}"),
            parent: Some(format!("box{}", i % 20)),
            text,
            fields,
            flags,
            ..Item::default()
        }
    }

    pub fn schema() -> Schema {
        Schema {
            fields: HashMap::from([
                ("from".into(), Kind::Text),
                ("tag".into(), Kind::Exact),
                ("size".into(), Kind::Value),
                ("date".into(), Kind::Date),
            ]),
            flags: HashMap::from([("mail".into(), Flag::Row), ("unread".into(), Flag::Row)]),
            ..Schema::default()
        }
    }

    pub fn write(index: &mut Index) {
        let boxes: Vec<Item> = (0..20)
            .map(|b| Item {
                key: format!("box{b}"),
                name: Some(if b == 0 {
                    "inbox".into()
                } else {
                    format!("box{b}")
                }),
                ..Item::default()
            })
            .collect();
        index.write(&boxes).unwrap();
        let mut batch = Vec::with_capacity(1000);
        for i in 0..ITEMS {
            batch.push(item(i));
            if batch.len() == 1000 {
                index.write(&batch).unwrap();
                batch.clear();
            }
        }
        index.write(&batch).unwrap();
    }

    pub fn word(text: &str) -> Node {
        Node {
            kind: "word".into(),
            text: Some(text.into()),
            ..Node::default()
        }
    }

    pub fn field(name: &str, op: &str, value: &str) -> Node {
        Node {
            kind: "field".into(),
            field: Some(name.into()),
            op: Some(op.into()),
            value: Some(value.into()),
            ..Node::default()
        }
    }

    pub fn days(name: &str, from: &str, to: &str) -> Node {
        Node {
            from: Some(from.into()),
            to: Some(to.into()),
            ..field(name, ":", "")
        }
    }

    pub fn and(items: Vec<Node>) -> Node {
        Node {
            kind: "and".into(),
            items,
            ..Node::default()
        }
    }

    pub fn view(sort: &str, limit: Option<usize>) -> View {
        View {
            sort: if sort.is_empty() {
                Vec::new()
            } else {
                vec![(sort.trim_start_matches('-').into(), sort.starts_with('-'))]
            },
            limit,
        }
    }
}

/// An index of 200,000 mail-like items: writing them, and the searches a
/// mail client and an agent make, from a word in one item to two in nearly
/// every one (where a limit stops early) and a size SQL narrows by number.
#[test]
fn index_of_many() {
    use index_budget::{and, days, field, view, word};
    budget(
        "index_of_many",
        |found| {
            let dir = Temp::new("index");
            let path = dir.join("mail.db");
            let mut index = greed_index::index::Index::open(&path).unwrap();
            let ((), cpu, _) = timed(|| index_budget::write(&mut index));
            found.set(
                "write_ms_per_1000",
                per(ms(cpu), index_budget::ITEMS / 1000),
            );
            let schema = index_budget::schema();
            let in_inbox = || field("in", ":", "inbox");
            let searches: Vec<(&str, greed_index::query::Node, greed_index::index::View)> = vec![
                ("one_word_one_item", word("ref123456"), view("", None)),
                (
                    "from_unread_latest",
                    and(vec![field("from", ":", "anna"), field("is", ":", "unread")]),
                    view("-date", Some(50)),
                ),
                (
                    "tag_in_a_month",
                    and(vec![
                        field("tag", ":", "money"),
                        days("date", "2026-10-01", "2026-10-31"),
                    ]),
                    view("", None),
                ),
                (
                    "inbox_unread",
                    and(vec![in_inbox(), field("is", ":", "unread")]),
                    view("-date", Some(50)),
                ),
                (
                    "two_words",
                    and(vec![word("invoice"), word("garden")]),
                    view("", Some(50)),
                ),
                ("size_over", field("size", ">", "490k"), view("", None)),
            ];
            for (name, node, shown) in &searches {
                let (mut cpus, mut count) = (Vec::new(), 0);
                for _ in 0..3 {
                    let (keys, cpu, _) =
                        timed(|| index.search(Some(node), &schema, shown).unwrap().keys.len());
                    count = keys;
                    cpus.push(ms(cpu));
                }
                assert!(count > 0, "{name} found nothing");
                found.set(&format!("{name}_ms"), median(cpus));
            }
            #[allow(clippy::cast_precision_loss)]
            let mb = std::fs::metadata(&path).unwrap().len() as f64 / (1024.0 * 1024.0);
            found.set("file_mb", mb);
        },
        &[
            ("write_ms_per_1000", 250.0, 300.0),
            ("one_word_one_item_ms", 1.0, 1.0),
            ("from_unread_latest_ms", 350.0, 600.0),
            ("tag_in_a_month_ms", 300.0, 350.0),
            ("inbox_unread_ms", 200.0, 300.0),
            ("two_words_ms", 300.0, 400.0),
            ("size_over_ms", 130.0, 220.0),
            ("file_mb", 400.0, 400.0),
        ],
    );
}
