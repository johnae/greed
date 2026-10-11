//! Recording a session as the window shows it, without a window: a script
//! of keys and waits drives the session, and every frame is drawn on the
//! GPU into a PNG, for the videos and screenshots in the docs.
//!
//! A script has a step a line; a line starting `#` is a comment.
//!
//! ```text
//! size 1280 800        the picture's size in pixels, before any step
//! scale 2              pixels per point, for a sharper picture
//! fps 30               frames a second
//! typing 0.04          seconds between the keys `type` presses
//! output media/shell   where the frames and screenshots go
//! hide                 stop recording frames, as while setting up
//! show                 record them again
//! keys esc space f     press keys, as keymaps name them
//! type kubectl get pods  type text, a key at a time
//! run shell            run a command
//! wait 1.5             let seconds pass
//! wait-for Running     until the screen shows the text (10 seconds at most)
//! shot pods            save the screen as pods.png
//! ```

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, RecvTimeoutError, Sender};
use greed_core::keymap::{Key, KeyCode, Mods};
use greed_core::render::grid;
use greed_core::server::{Input, Output};
use greed_core::theme::Medium;

use crate::gpu::Gpu;
use crate::paint::{ATLAS_SIZE, Painter, Taken};

/// How long `wait-for` waits before the recording fails.
const WAIT_FOR: Duration = Duration::from_secs(10);

/// One step of a script.
#[derive(Debug, Clone, PartialEq)]
pub enum Step {
    Hide,
    Show,
    Keys(Vec<Key>),
    Type(String),
    Run(String),
    Wait(Duration),
    WaitFor(String),
    Shot(String),
}

/// A recording's script: how it's drawn, and its steps.
#[derive(Debug, Clone, PartialEq)]
pub struct Script {
    pub size: (u32, u32),
    pub scale: f64,
    pub fps: u32,
    pub typing: Duration,
    /// Where frames and screenshots go; beside the script when it doesn't
    /// say.
    pub output: Option<PathBuf>,
    pub steps: Vec<Step>,
}

impl Script {
    /// Reads a script, or says which line is wrong and why.
    pub fn parse(text: &str) -> Result<Self, String> {
        let mut script = Self {
            size: (1280, 800),
            scale: 1.0,
            fps: 30,
            typing: Duration::from_millis(40),
            output: None,
            steps: Vec::new(),
        };
        for (n, line) in text.lines().enumerate() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let step = script
                .line(line)
                .map_err(|e| format!("line {}: {e}", n + 1))?;
            script.steps.extend(step);
        }
        Ok(script)
    }

    /// Takes in a setting, or gives back a step.
    fn line(&mut self, line: &str) -> Result<Option<Step>, String> {
        let (word, rest) = line.split_once(' ').unwrap_or((line, ""));
        let rest = rest.trim();
        let seconds = || {
            rest.parse::<f64>()
                .ok()
                .filter(|s| s.is_finite() && *s >= 0.0)
                .map(Duration::from_secs_f64)
                .ok_or_else(|| format!("{word} takes seconds, like 1.5"))
        };
        let step = match word {
            "size" => {
                let mut parts = rest.split_whitespace().map(str::parse::<u32>);
                let (Some(Ok(w)), Some(Ok(h)), None) = (parts.next(), parts.next(), parts.next())
                else {
                    return Err("size takes WIDTH HEIGHT".into());
                };
                self.size = (w.max(1), h.max(1));
                None
            }
            "scale" => {
                self.scale = rest
                    .parse::<f64>()
                    .ok()
                    .filter(|s| *s > 0.0 && *s <= 4.0)
                    .ok_or("scale takes 1 to 4")?;
                None
            }
            "fps" => {
                self.fps = rest
                    .parse::<u32>()
                    .ok()
                    .filter(|f| (1..=120).contains(f))
                    .ok_or("fps takes 1 to 120")?;
                None
            }
            "typing" => {
                self.typing = seconds()?;
                None
            }
            "output" if !rest.is_empty() => {
                self.output = Some(PathBuf::from(rest));
                None
            }
            "hide" => Some(Step::Hide),
            "show" => Some(Step::Show),
            "keys" => Some(Step::Keys(
                Key::parse_sequence(rest).map_err(|e| e.to_string())?,
            )),
            "type" if !rest.is_empty() => Some(Step::Type(rest.to_owned())),
            "run" if !rest.is_empty() => Some(Step::Run(rest.to_owned())),
            "wait" => Some(Step::Wait(seconds()?)),
            "wait-for" if !rest.is_empty() => Some(Step::WaitFor(rest.to_owned())),
            "shot" if !rest.is_empty() => Some(Step::Shot(rest.to_owned())),
            _ => return Err(format!("what's {line:?}?")),
        };
        Ok(step)
    }
}

/// Where the script at `path` puts what it records: its own `output`
/// (from the script's folder), or a folder named as the script beside it.
#[must_use]
pub fn output_of(script: &Script, path: &Path) -> PathBuf {
    let folder = path.parent().unwrap_or(Path::new("."));
    match &script.output {
        Some(output) => folder.join(output),
        None => folder.join(path.file_stem().unwrap_or_default()),
    }
}

/// The screen's text, a row a line, for `wait-for`.
fn screen_text(painter: &Painter) -> String {
    let Some(frame) = &painter.frame else {
        return String::new();
    };
    grid::compose(frame, Medium::Gui)
        .iter()
        .map(|row| {
            row.iter()
                .map(|cell| cell.text.as_str())
                .collect::<String>()
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// What the recorder is doing now: a step that takes time, until when.
enum Doing {
    Nothing,
    Waiting(Instant),
    /// Text left to type, and when the next key goes.
    Typing(Vec<char>, Instant),
    WaitingFor(String, Instant),
}

type Error = Box<dyn std::error::Error>;

struct Recorder<'a> {
    input: &'a Sender<Input>,
    script: &'a Script,
    out: &'a Path,
    frames: PathBuf,
    gpu: Gpu,
    painter: Painter,
    /// The next step, by its index.
    next_step: usize,
    doing: Doing,
    /// When the steps ran out: a moment on the last screen, then the end.
    finished: Option<Instant>,
    recording: bool,
    /// When the next frame is due: frames are the same time apart however
    /// long drawing takes, a late one catching up with copies.
    next_frame: Instant,
    written: u32,
    /// The last frame drawn, and whether the session changed it since.
    last: Option<PathBuf>,
    changed: bool,
}

impl Recorder<'_> {
    fn send(&self, message: Input) {
        let _ = self.input.send(message);
    }

    fn send_size(&self) {
        let (width, height) = self.script.size;
        for message in self.painter.size_inputs(width, height) {
            self.send(message);
        }
    }

    /// Draws the screen as it is now into a PNG at `path`.
    fn draw_to(&mut self, path: &Path) -> Result<bool, Error> {
        let Some(scene) = self.painter.paint(&mut self.gpu) else {
            return Ok(false);
        };
        let size = self.script.size;
        let rgba = self.gpu.snapshot(size, &scene);
        let image = image::RgbaImage::from_raw(size.0, size.1, rgba)
            .ok_or("the picture isn't the size it should be")?;
        image
            .save(path)
            .map_err(|e| format!("can't write {}: {e}", path.display()))?;
        Ok(true)
    }

    /// Takes the steps due at `now`, up to one that takes time. True once
    /// the script is done.
    fn advance(&mut self, now: Instant) -> Result<bool, Error> {
        loop {
            match &mut self.doing {
                Doing::Waiting(until) if now < *until => return Ok(false),
                Doing::Typing(left, next) if !left.is_empty() => {
                    if now >= *next {
                        let c = left.remove(0);
                        *next = now + self.script.typing;
                        self.send(Input::Key(Key {
                            code: KeyCode::Char(c),
                            mods: Mods::NONE,
                        }));
                    }
                    return Ok(false);
                }
                Doing::WaitingFor(text, until) => {
                    if !screen_text(&self.painter).contains(text.as_str()) {
                        if now >= *until {
                            return Err(format!("the screen never showed {text:?}").into());
                        }
                        return Ok(false);
                    }
                }
                Doing::Nothing | Doing::Waiting(_) | Doing::Typing(..) => {}
            }
            self.doing = Doing::Nothing;
            let Some(step) = self.script.steps.get(self.next_step) else {
                let end = *self.finished.get_or_insert(now + Duration::from_secs(1));
                return Ok(now >= end);
            };
            self.next_step += 1;
            match step {
                Step::Hide => self.recording = false,
                Step::Show => self.recording = true,
                Step::Keys(keys) => {
                    for key in keys {
                        self.send(Input::Key(*key));
                    }
                }
                Step::Type(text) => self.doing = Doing::Typing(text.chars().collect(), now),
                Step::Run(command) => self.send(Input::Run(command.clone())),
                Step::Wait(time) => self.doing = Doing::Waiting(now + *time),
                Step::WaitFor(text) => {
                    self.doing = Doing::WaitingFor(text.clone(), now + WAIT_FOR);
                }
                Step::Shot(name) => {
                    let path = self.out.join(format!("{name}.png"));
                    self.draw_to(&path)?;
                }
            }
        }
    }

    /// Writes the frame due at `now`, if one is. True when it did.
    fn frame(&mut self, now: Instant) -> Result<bool, Error> {
        if !self.recording {
            self.next_frame = now;
            return Ok(false);
        }
        if now < self.next_frame {
            return Ok(false);
        }
        self.next_frame += Duration::from_secs_f64(1.0 / f64::from(self.script.fps));
        let path = self.frames.join(format!("{:05}.png", self.written));
        match &self.last {
            // Unchanged, it's the last one again.
            Some(previous) if !self.changed => {
                if std::fs::hard_link(previous, &path).is_err() {
                    std::fs::copy(previous, &path)?;
                }
            }
            _ => {
                if !self.draw_to(&path)? {
                    return Ok(false);
                }
                self.changed = false;
                self.last = Some(path);
            }
        }
        self.written += 1;
        Ok(true)
    }

    /// Takes in what the session sent. True once it ended.
    fn receive(&mut self, message: Output) -> bool {
        match self.painter.take(message) {
            Ok(Taken::Frame) => {
                self.changed = true;
                if self.painter.follow_options() {
                    self.send_size();
                }
            }
            Ok(Taken::Kept) => self.changed = true,
            Err(Output::Exit | Output::Detached | Output::Switch(_)) => return true,
            Err(_) => {}
        }
        false
    }
}

/// Records the session on `input` and `output` as `script` says, into
/// `out`: the frames in `out/frames`, numbered from 00000, and
/// screenshots by name. Ends the session at the end, or when a step
/// fails.
pub fn record(
    input: &Sender<Input>,
    output: &Receiver<Output>,
    script: &Script,
    out: &Path,
) -> Result<Output, Error> {
    let frames = out.join("frames");
    std::fs::create_dir_all(&frames)?;
    let gpu = Gpu::headless(wgpu::TextureFormat::Rgba8Unorm, ATLAS_SIZE)
        .ok_or("no GPU to draw the frames with (software Vulkan, like lavapipe, will do)")?;
    let mut recorder = Recorder {
        input,
        script,
        out,
        frames,
        gpu,
        painter: Painter::new(),
        next_step: 0,
        doing: Doing::Nothing,
        finished: None,
        recording: true,
        next_frame: Instant::now(),
        written: 0,
        last: None,
        changed: true,
    };
    recorder.painter.set_scale(script.scale);
    recorder.send_size();
    let ended = loop {
        let now = Instant::now();
        match recorder.advance(now) {
            Ok(false) => {}
            Ok(true) => break Ok(Output::Exit),
            Err(err) => break Err(err),
        }
        match recorder.frame(now) {
            Ok(true) => continue,
            Ok(false) => {}
            Err(err) => break Err(err),
        }
        let wait = recorder
            .next_frame
            .saturating_duration_since(Instant::now());
        match output.recv_timeout(wait.min(Duration::from_millis(10))) {
            Ok(message) => {
                if recorder.receive(message) {
                    return Ok(Output::Exit);
                }
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return Ok(Output::Exit),
        }
    };
    // The session was the recording's own.
    recorder.send(Input::Run("quit-session!".into()));
    eprintln!(
        "greed: {} frames in {}",
        recorder.written,
        recorder.frames.display()
    );
    ended
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_script_reads_its_settings_and_steps_and_skips_comments() {
        let script = Script::parse(
            "# the shell\nsize 800 600\nscale 2\nfps 24\ntyping 0.1\noutput media/shell\n\n\
             hide\nrun shell\nshow\ntype ls | chart # all of it\nkeys enter\n\
             wait 1.5\nwait-for Running\nshot pods\n",
        )
        .unwrap();
        assert_eq!(script.size, (800, 600));
        assert_eq!(script.scale, 2.0);
        assert_eq!(script.fps, 24);
        assert_eq!(script.typing, Duration::from_millis(100));
        assert_eq!(script.output, Some(PathBuf::from("media/shell")));
        assert_eq!(
            script.steps,
            vec![
                Step::Hide,
                Step::Run("shell".into()),
                Step::Show,
                Step::Type("ls | chart # all of it".into()),
                Step::Keys(vec![Key::parse("enter").unwrap()]),
                Step::Wait(Duration::from_millis(1500)),
                Step::WaitFor("Running".into()),
                Step::Shot("pods".into()),
            ]
        );
    }

    #[test]
    fn a_wrong_line_says_which_and_why() {
        for (text, said) in [
            ("size 800", "line 1: size takes WIDTH HEIGHT"),
            ("\nfps 0", "line 2: fps takes 1 to 120"),
            ("wait soon", "line 1: wait takes seconds, like 1.5"),
            ("keys ctrl-nope-x", "line 1:"),
            ("dance", "line 1: what's \"dance\"?"),
            ("type", "line 1: what's \"type\"?"),
        ] {
            let err = Script::parse(text).unwrap_err();
            assert!(err.starts_with(said), "{text:?} gave {err:?}");
        }
    }

    #[test]
    fn output_goes_beside_the_script() {
        let script = Script::parse("").unwrap();
        assert_eq!(
            output_of(&script, Path::new("site/media/shell.demo")),
            PathBuf::from("site/media/shell")
        );
        let script = Script::parse("output out/x").unwrap();
        assert_eq!(
            output_of(&script, Path::new("site/media/shell.demo")),
            PathBuf::from("site/media/out/x")
        );
    }
}
