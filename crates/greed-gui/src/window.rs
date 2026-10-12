//! The window: a winit event loop that draws the session's frames and sends
//! keys, the mouse and its size back, as the TUI does in a terminal.

use std::cell::RefCell;
use std::path::Path;
use std::sync::Arc;

use crossbeam_channel::{Receiver, Sender};
use greed_core::keymap::{Key, KeyCode, Mods};
use greed_core::mouse::{Button, Mouse, MouseKind};
use greed_core::server::{Input, Output};
use winit::application::ApplicationHandler;
use winit::dpi::{LogicalSize, PhysicalPosition, PhysicalSize};
use winit::event::{ElementState, Ime, KeyEvent, MouseButton, MouseScrollDelta, WindowEvent};
use winit::event_loop::{ActiveEventLoop, EventLoop};
use winit::keyboard::{Key as WinitKey, ModifiersState, NamedKey};
use winit::platform::run_on_demand::EventLoopExtRunOnDemand;
use winit::window::{Window, WindowId};

use crate::columns::Columns;
use crate::gpu::Gpu;
use crate::paint::{ATLAS_SIZE, Painter, Taken};

/// What reaches the event loop from the session's thread.
pub(crate) enum Event {
    Output(Output),
    /// A menu bar item was chosen: the command to run.
    #[cfg(target_os = "macos")]
    Menu(String),
}

thread_local! {
    /// winit allows one event loop per process, so switching sessions runs
    /// the same one again.
    static LOOP: RefCell<Option<EventLoop<Event>>> = const { RefCell::new(None) };
}

/// Runs the window until the session exits or lets it go, or the window is
/// closed (`Output::Detached`), sending keys and sizes to `input` and
/// drawing the frames from `output`. Returns how it ended. The window opens
/// at the size kept in `size_file`, if there is one, and keeps its size
/// there when it closes.
pub fn run(
    input: &Sender<Input>,
    output: &Receiver<Output>,
    size_file: Option<&Path>,
) -> Result<Output, Box<dyn std::error::Error>> {
    LOOP.with(|cell| {
        let mut slot = cell.borrow_mut();
        if slot.is_none() {
            *slot = Some(EventLoop::<Event>::with_user_event().build()?);
        }
        let event_loop = slot.as_mut().expect("just made");
        // The session's output, passed on into the loop until this run ends.
        let proxy = event_loop.create_proxy();
        let (stop, stopped) = crossbeam_channel::bounded::<()>(1);
        let outputs = output.clone();
        let forward = std::thread::spawn(move || {
            loop {
                crossbeam_channel::select! {
                    recv(outputs) -> message => {
                        let message = message.unwrap_or(Output::Exit);
                        let last = !matches!(message, Output::Frame(_) | Output::Delta(_) | Output::Image(_) | Output::Scene(_) | Output::Clipboard(_) | Output::ReadClipboardImage(_) | Output::SshAgentRequest(..) | Output::Notify(_));
                        if proxy.send_event(Event::Output(message)).is_err() || last {
                            return;
                        }
                    }
                    recv(stopped) -> _ => return,
                }
            }
        });
        let mut app = App::new(input.clone());
        #[cfg(target_os = "macos")]
        {
            app.menubar = Some(crate::menubar::MenuBar::new(event_loop.create_proxy()));
        }
        app.size = size_file.and_then(|path| parse_size(&std::fs::read_to_string(path).ok()?));
        event_loop.run_app_on_demand(&mut app)?;
        let _ = stop.send(());
        let _ = forward.join();
        if let (Some(path), Some(size)) = (size_file, app.size) {
            let _ = std::fs::write(path, format!("{} {}\n", size.width, size.height));
        }
        Ok(app.ended.unwrap_or(Output::Detached))
    })
}

/// The window's drawing state, made once it exists.
struct Shown {
    window: Arc<Window>,
    surface: wgpu::Surface<'static>,
    config: wgpu::SurfaceConfiguration,
    gpu: Gpu,
}

struct App {
    input: Sender<Input>,
    shown: Option<Shown>,
    painter: Painter,
    /// Where the last frame put each row's cells, for the mouse.
    columns: Columns,
    mods: ModifiersState,
    /// The cell the mouse is over, and the button held, for drags.
    mouse: (u16, u16),
    held: Option<Button>,
    /// Scrolling by pixels, gathered until it adds up to a line.
    scrolled: f64,
    clipboard: Option<arboard::Clipboard>,
    ended: Option<Output>,
    /// The window's size, before the screen's scale.
    size: Option<LogicalSize<f64>>,
    /// The system's menu bar, filled with the frame's menus.
    #[cfg(target_os = "macos")]
    menubar: Option<crate::menubar::MenuBar>,
}

impl App {
    /// The text on the system clipboard, if there's any.
    fn clipboard_text(&mut self) -> Option<String> {
        self.clipboard
            .as_mut()?
            .get_text()
            .ok()
            .filter(|text| !text.is_empty())
    }

    /// Whether the system clipboard holds an image. Reading it is the only
    /// way to tell.
    fn clipboard_has_image(&mut self) -> bool {
        self.clipboard
            .as_mut()
            .is_some_and(|clipboard| clipboard.get_image().is_ok())
    }

    fn new(input: Sender<Input>) -> Self {
        Self {
            input,
            shown: None,
            painter: Painter::new(),
            columns: Columns::default(),
            mods: ModifiersState::empty(),
            mouse: (0, 0),
            held: None,
            scrolled: 0.0,
            clipboard: arboard::Clipboard::new().ok(),
            ended: None,
            size: None,
            #[cfg(target_os = "macos")]
            menubar: None,
        }
    }

    /// Takes up the font the frame's options choose, if it's another one,
    /// and tells the session the cells' new size.
    fn follow_options(&mut self) {
        if self.painter.follow_options()
            && let Some(shown) = &self.shown
        {
            self.send_size(shown.window.inner_size());
        }
    }

    /// Sends what `what` says as a debug line, while the session asks for
    /// what happens on this side (its `client` topic is on).
    fn log(&self, what: impl FnOnce() -> String) {
        if self.logging() {
            let _ = self.input.send(Input::Log(what()));
        }
    }

    /// Says what a window event was, while the session asks.
    fn log_event(&self, event: &WindowEvent) {
        if self.logging()
            && let Some(text) = described(event, self.mods)
        {
            let _ = self.input.send(Input::Log(text));
        }
    }

    fn logging(&self) -> bool {
        self.painter
            .frame
            .as_ref()
            .is_some_and(|frame| frame.gui.contains_key(greed_core::debug::CLIENT))
    }

    /// Sends a file dropped on the window, with what's in it when it's small
    /// enough for a session on another machine to keep. Read off this
    /// thread: a big file takes a moment.
    fn dropped(&self, path: std::path::PathBuf) {
        let input = self.input.clone();
        std::thread::spawn(move || {
            let data = greed_core::dropped::contents(&path);
            let _ = input.send(Input::Dropped(path.to_string_lossy().into_owned(), data));
        });
    }

    /// Tells the session how many cells fit in `size`, and how big a cell is.
    fn send_size(&self, size: PhysicalSize<u32>) {
        for input in self.painter.size_inputs(size.width, size.height) {
            let _ = self.input.send(input);
        }
    }

    fn redraw(&mut self) {
        let started = self.logging().then(std::time::Instant::now);
        let drawn = self.draw();
        if let Some(started) = started {
            let took = started.elapsed().as_secs_f64() * 1000.0;
            self.log(|| format!("{drawn} in {took:.2} ms"));
        }
    }

    /// Draws the last frame, saying what came of it.
    fn draw(&mut self) -> &'static str {
        let Some(shown) = &mut self.shown else {
            return "no window to draw in yet";
        };
        let Some(scene) = self.painter.paint(&mut shown.gpu) else {
            return "no frame to draw yet";
        };
        let texture = match shown.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(texture)
            | wgpu::CurrentSurfaceTexture::Suboptimal(texture) => texture,
            // Drawn again when the window shows (a window opened from
            // Spotlight starts out covered).
            wgpu::CurrentSurfaceTexture::Occluded => {
                return "left a frame undrawn: the window is covered";
            }
            _ => {
                shown.surface.configure(&shown.gpu.device, &shown.config);
                shown.window.request_redraw();
                return "the window wasn't ready to draw in; drawing again";
            }
        };
        let view = texture
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());
        shown
            .gpu
            .render(&view, (shown.config.width, shown.config.height), &scene);
        shown.window.pre_present_notify();
        shown.gpu.queue.present(texture);
        // An input method shows what it's composing by the cursor.
        if let Some(at) = self.painter.frame.as_ref().and_then(|frame| frame.cursor) {
            let fonts = &self.painter.fonts;
            let (cw, ch) = (f64::from(fonts.cell_w), f64::from(fonts.cell_h));
            let x = scene.columns.x(usize::from(at.row), usize::from(at.col));
            shown.window.set_ime_cursor_area(
                PhysicalPosition::new(f64::from(x), f64::from(at.row) * ch),
                PhysicalSize::new(cw, ch),
            );
        }
        self.columns = scene.columns;
        "drew a frame"
    }

    fn handle(&mut self, event_loop: &ActiveEventLoop, output: Output) {
        match self.painter.take(output) {
            Ok(Taken::Frame) => {}
            // `session::show` answers ssh agent requests before output gets here.
            Ok(Taken::Kept) | Err(Output::Notify(_) | Output::SshAgentRequest(..)) => return,
            Err(Output::Clipboard(text)) => {
                if let Some(clipboard) = &mut self.clipboard {
                    let _ = clipboard.set_text(text);
                }
                return;
            }
            // Made PNG off this thread: a big screenshot takes a moment.
            Err(Output::ReadClipboardImage(ask)) => {
                let image = self
                    .clipboard
                    .as_mut()
                    .and_then(|clipboard| clipboard.get_image().ok());
                let input = self.input.clone();
                std::thread::spawn(move || {
                    use base64::Engine;
                    let png = image
                        .and_then(png_of)
                        .map(|png| base64::engine::general_purpose::STANDARD.encode(png));
                    let _ = input.send(Input::ClipboardImage(ask, png));
                });
                return;
            }
            Err(other) => {
                self.ended = Some(other);
                event_loop.exit();
                return;
            }
        }
        self.follow_options();
        #[cfg(target_os = "macos")]
        if let (Some(bar), Some(frame)) = (&mut self.menubar, &self.painter.frame) {
            bar.show(&frame.menus);
        }
        if let Some(shown) = &self.shown {
            shown.window.request_redraw();
        }
    }

    /// The cell under `position`, as the last frame placed its text: in a
    /// row with prose, the cell of the character there.
    fn cell_at(&self, position: PhysicalPosition<f64>) -> (u16, u16) {
        let row = (position.y / f64::from(self.painter.fonts.cell_h)).max(0.0) as usize;
        let col = self.columns.col_at(row, position.x as f32);
        (
            u16::try_from(col).unwrap_or(u16::MAX),
            u16::try_from(row).unwrap_or(u16::MAX),
        )
    }

    fn mouse(&self, kind: MouseKind) {
        let _ = self.input.send(Input::Mouse(Mouse {
            kind,
            col: self.mouse.0,
            row: self.mouse.1,
            ctrl: self.mods.control_key(),
            alt: self.mods.alt_key(),
            shift: self.mods.shift_key(),
        }));
    }
}

impl ApplicationHandler<Event> for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.shown.is_some() {
            return;
        }
        let attributes = Window::default_attributes()
            .with_title("Greed")
            .with_inner_size(self.size.unwrap_or(LogicalSize::new(1100.0, 720.0)));
        // The app id desktops match against greed.desktop, for its icon and
        // name in docks and task switchers.
        #[cfg(any(target_os = "linux", target_os = "freebsd"))]
        let attributes = {
            use winit::platform::{
                wayland::WindowAttributesExtWayland, x11::WindowAttributesExtX11,
            };
            let attributes = WindowAttributesExtWayland::with_name(attributes, "greed", "greed");
            WindowAttributesExtX11::with_name(attributes, "greed", "greed")
        };
        let Ok(window) = event_loop.create_window(attributes) else {
            event_loop.exit();
            return;
        };
        window.set_ime_allowed(true);
        let window = Arc::new(window);
        let Some(shown) = Shown::new(window.clone(), event_loop) else {
            eprintln!("greed: no GPU to draw the window with");
            event_loop.exit();
            return;
        };
        self.painter.set_scale(window.scale_factor());
        self.send_size(window.inner_size());
        // Frames may have come before the window did.
        window.request_redraw();
        self.shown = Some(shown);
    }

    fn user_event(&mut self, event_loop: &ActiveEventLoop, event: Event) {
        match event {
            Event::Output(output) => self.handle(event_loop, output),
            #[cfg(target_os = "macos")]
            Event::Menu(command) => {
                let _ = self.input.send(Input::Run(command));
            }
        }
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, _id: WindowId, event: WindowEvent) {
        self.log_event(&event);
        match event {
            WindowEvent::CloseRequested => {
                self.ended = Some(Output::Detached);
                event_loop.exit();
            }
            WindowEvent::Resized(size) => {
                if let Some(shown) = &mut self.shown {
                    shown.config.width = size.width.max(1);
                    shown.config.height = size.height.max(1);
                    shown.surface.configure(&shown.gpu.device, &shown.config);
                }
                self.size = Some(size.to_logical(self.painter.scale));
                self.send_size(size);
            }
            WindowEvent::ScaleFactorChanged { scale_factor, .. } => {
                self.painter.set_scale(scale_factor);
                if let Some(shown) = &self.shown {
                    self.send_size(shown.window.inner_size());
                }
            }
            WindowEvent::ModifiersChanged(mods) => self.mods = mods.state(),
            WindowEvent::KeyboardInput { event, .. } if event.state == ElementState::Pressed => {
                if is_paste(&event.logical_key, self.mods) {
                    if let Some(text) = self.clipboard_text() {
                        let _ = self.input.send(Input::Paste(text));
                    } else if self.clipboard_has_image() {
                        // An image, which what you're in may take, like an
                        // agent's box.
                        let _ = self.input.send(Input::Run("paste-image".into()));
                    }
                } else if let Some(input) = option_key(&event, self.mods) {
                    let _ = self.input.send(input);
                } else if let Some(key) = key(&event, self.mods) {
                    let _ = self.input.send(Input::Key(key));
                }
            }
            // What you copied in another program becomes Greed's clipboard
            // too, for its own paste keys.
            WindowEvent::Focused(true) => {
                if let Some(text) = self.clipboard_text() {
                    let _ = self.input.send(Input::Clipboard(text));
                }
            }
            // Text an input method made, as keys typed one by one.
            WindowEvent::Ime(Ime::Commit(text)) => {
                for c in text.chars().filter(|c| !c.is_control()) {
                    let _ = self.input.send(Input::Key(Key {
                        code: KeyCode::Char(c),
                        mods: Mods::NONE,
                    }));
                }
            }
            WindowEvent::CursorMoved { position, .. } => {
                let cell = self.cell_at(position);
                if cell != self.mouse {
                    self.mouse = cell;
                    self.mouse(self.held.map_or(MouseKind::Move, MouseKind::Drag));
                }
            }
            WindowEvent::MouseInput { state, button, .. } => {
                let Some(button) = (match button {
                    MouseButton::Left => Some(Button::Left),
                    MouseButton::Right => Some(Button::Right),
                    MouseButton::Middle => Some(Button::Middle),
                    _ => None,
                }) else {
                    return;
                };
                if state == ElementState::Pressed {
                    self.held = Some(button);
                    self.mouse(MouseKind::Press(button));
                } else {
                    self.held = None;
                    self.mouse(MouseKind::Release(button));
                }
            }
            WindowEvent::MouseWheel { delta, .. } => {
                let lines = match delta {
                    MouseScrollDelta::LineDelta(_, y) => f64::from(y),
                    MouseScrollDelta::PixelDelta(p) => {
                        self.scrolled += p.y / f64::from(self.painter.fonts.cell_h);
                        let whole = self.scrolled.trunc();
                        self.scrolled -= whole;
                        whole
                    }
                };
                let kind = if lines > 0.0 {
                    MouseKind::ScrollUp
                } else {
                    MouseKind::ScrollDown
                };
                for _ in 0..lines.abs() as u32 {
                    self.mouse(kind);
                }
            }
            WindowEvent::RedrawRequested => self.redraw(),
            WindowEvent::DroppedFile(path) => self.dropped(path),
            WindowEvent::Occluded(false) => {
                if let Some(shown) = &self.shown {
                    shown.window.request_redraw();
                }
            }
            _ => {}
        }
    }
}

impl Shown {
    fn new(window: Arc<Window>, event_loop: &ActiveEventLoop) -> Option<Self> {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_with_display_handle(
            Box::new(event_loop.owned_display_handle()),
        ));
        let surface = instance.create_surface(window.clone()).ok()?;
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            compatible_surface: Some(&surface),
            ..Default::default()
        }))
        .ok()?;
        let (device, queue) =
            pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor::default())).ok()?;
        let caps = surface.get_capabilities(&adapter);
        // Colors are given as the theme has them, so not an sRGB target.
        let format = caps
            .formats
            .iter()
            .copied()
            .find(|f| !f.is_srgb())
            .or_else(|| caps.formats.first().copied())?;
        let size = window.inner_size();
        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format,
            width: size.width.max(1),
            height: size.height.max(1),
            present_mode: present_mode(&caps.present_modes),
            // One frame queued at most, so a key shows on the next refresh
            // rather than behind frames drawn before it.
            desired_maximum_frame_latency: 1,
            alpha_mode: caps
                .alpha_modes
                .first()
                .copied()
                .unwrap_or(wgpu::CompositeAlphaMode::Auto),
            view_formats: vec![],
            color_space: wgpu::SurfaceColorSpace::Auto,
        };
        surface.configure(&device, &config);
        Some(Self {
            window,
            surface,
            config,
            gpu: Gpu::new(device, queue, format, ATLAS_SIZE),
        })
    }
}

/// What a window event was, for a debug line: keys as the system gave them
/// and what they became, the input method, modifiers and focus. None for
/// the rest, like the mouse moving.
fn described(event: &WindowEvent, mods: ModifiersState) -> Option<String> {
    Some(match event {
        WindowEvent::KeyboardInput { event: key, .. } if key.state == ElementState::Pressed => {
            let sent = option_key(key, mods)
                .map(|input| format!("{input:?}"))
                .or_else(|| self::key(key, mods).map(|key| format!("{key}")))
                .unwrap_or_else(|| "nothing".to_owned());
            format!(
                "key {:?} ({:?}) typing {:?} with {mods:?}: sent {sent}",
                key.logical_key, key.physical_key, key.text
            )
        }
        WindowEvent::Ime(ime) => format!("input method: {ime:?}"),
        WindowEvent::ModifiersChanged(now) => format!("modifiers: {:?}", now.state()),
        WindowEvent::Focused(focused) => format!("focused: {focused}"),
        WindowEvent::Occluded(covered) => format!("covered: {covered}"),
        WindowEvent::Resized(size) => format!("resized to {}x{}", size.width, size.height),
        _ => return None,
    })
}

/// A window size kept as "WIDTH HEIGHT", if it's one a screen could have.
fn parse_size(text: &str) -> Option<LogicalSize<f64>> {
    let mut parts = text.split_whitespace().map(str::parse::<f64>);
    let (Some(Ok(width)), Some(Ok(height)), None) = (parts.next(), parts.next(), parts.next())
    else {
        return None;
    };
    let fits = |v: f64| (200.0..=20_000.0).contains(&v);
    (fits(width) && fits(height)).then(|| LogicalSize::new(width, height))
}

/// How frames go to the screen: Mailbox where the system has it, which
/// shows the newest frame at the next refresh without tearing and never
/// waits behind older ones; otherwise Fifo, which every system has.
fn present_mode(available: &[wgpu::PresentMode]) -> wgpu::PresentMode {
    if available.contains(&wgpu::PresentMode::Mailbox) {
        wgpu::PresentMode::Mailbox
    } else {
        wgpu::PresentMode::Fifo
    }
}

/// A clipboard image as PNG.
fn png_of(image: arboard::ImageData<'_>) -> Option<Vec<u8>> {
    let width = u32::try_from(image.width).ok()?;
    let height = u32::try_from(image.height).ok()?;
    let rgba = image::RgbaImage::from_raw(width, height, image.bytes.into_owned())?;
    let mut png = std::io::Cursor::new(Vec::new());
    rgba.write_to(&mut png, image::ImageFormat::Png).ok()?;
    Some(png.into_inner())
}

/// Whether a key press is the system's paste: ctrl-shift-v or shift-insert,
/// and cmd-v on macOS.
fn is_paste(logical: &WinitKey, mods: ModifiersState) -> bool {
    match logical {
        WinitKey::Named(NamedKey::Insert) => mods == ModifiersState::SHIFT,
        WinitKey::Character(c) if c.eq_ignore_ascii_case("v") => {
            mods == ModifiersState::CONTROL | ModifiersState::SHIFT
                || (cfg!(target_os = "macos") && mods == ModifiersState::SUPER)
        }
        _ => false,
    }
}

/// A character key with macOS's Option held, which types a character of
/// its own (`π`, or `[` on a Swedish keyboard): it goes as Alt with the
/// plain key, `alt-p`, and what it typed, for the editor to type that when
/// the alt key isn't bound or it's plain ASCII. Shifted, a letter is its
/// capital; another key's shifted character depends on the layout, so it's
/// the one typed. None elsewhere, and with Control or Command held, which
/// stop Option typing.
#[cfg(target_os = "macos")]
fn option_key(event: &KeyEvent, mods: ModifiersState) -> Option<Input> {
    use winit::platform::modifier_supplement::KeyEventExtModifierSupplement;
    if !mods.alt_key() || mods.control_key() || mods.super_key() {
        return None;
    }
    let WinitKey::Character(plain) = event.key_without_modifiers() else {
        return None;
    };
    let one = |text: &str| {
        let mut chars = text.chars();
        match (chars.next(), chars.next()) {
            (Some(c), None) => Some(c),
            _ => None,
        }
    };
    let plain = one(&plain)?;
    let typed = event.text.as_deref().unwrap_or_default();
    let c = match (mods.shift_key(), plain.is_alphabetic()) {
        (false, _) => plain,
        (true, true) => plain.to_uppercase().next()?,
        (true, false) => one(typed)?,
    };
    let key = Key {
        code: KeyCode::Char(c),
        mods: Mods::ALT,
    };
    Some(Input::KeyOrText(key, typed.to_owned()))
}

#[cfg(not(target_os = "macos"))]
fn option_key(_event: &KeyEvent, _mods: ModifiersState) -> Option<Input> {
    None
}

/// A key press as Greed names keys: shifted characters are the character
/// itself ("G"), so shift only counts for other keys. Without ctrl or alt,
/// a character key is the text it types, which is what a dead key before it
/// made of it ("é" from "´" then "e").
fn key(event: &KeyEvent, mods: ModifiersState) -> Option<Key> {
    key_from(&event.logical_key, event.text.as_deref(), mods)
}

fn key_from(logical: &WinitKey, text: Option<&str>, mods: ModifiersState) -> Option<Key> {
    let code = match logical {
        WinitKey::Named(named) => match named {
            NamedKey::Enter => KeyCode::Enter,
            NamedKey::Escape => KeyCode::Esc,
            NamedKey::Tab => KeyCode::Tab,
            NamedKey::Backspace => KeyCode::Backspace,
            NamedKey::Delete => KeyCode::Delete,
            NamedKey::Insert => KeyCode::Insert,
            NamedKey::ArrowUp => KeyCode::Up,
            NamedKey::ArrowDown => KeyCode::Down,
            NamedKey::ArrowLeft => KeyCode::Left,
            NamedKey::ArrowRight => KeyCode::Right,
            NamedKey::Home => KeyCode::Home,
            NamedKey::End => KeyCode::End,
            NamedKey::PageUp => KeyCode::PageUp,
            NamedKey::PageDown => KeyCode::PageDown,
            NamedKey::Space => KeyCode::Char(' '),
            NamedKey::F1 => KeyCode::F(1),
            NamedKey::F2 => KeyCode::F(2),
            NamedKey::F3 => KeyCode::F(3),
            NamedKey::F4 => KeyCode::F(4),
            NamedKey::F5 => KeyCode::F(5),
            NamedKey::F6 => KeyCode::F(6),
            NamedKey::F7 => KeyCode::F(7),
            NamedKey::F8 => KeyCode::F(8),
            NamedKey::F9 => KeyCode::F(9),
            NamedKey::F10 => KeyCode::F(10),
            NamedKey::F11 => KeyCode::F(11),
            NamedKey::F12 => KeyCode::F(12),
            _ => return None,
        },
        // Command on a Mac (Super elsewhere) is for the system and the
        // menus: with a character it's no key, rather than the plain one,
        // which would be an editing key.
        WinitKey::Character(_) if mods.super_key() => return None,
        WinitKey::Character(logical) => {
            let typed = text.filter(|_| !mods.control_key() && !mods.alt_key());
            let mut chars = typed.unwrap_or(logical).chars();
            match (chars.next(), chars.next()) {
                (Some(c), None) if !c.is_control() => KeyCode::Char(c),
                _ => return None,
            }
        }
        _ => return None,
    };
    let mut out = Mods::NONE;
    if mods.control_key() {
        out = out | Mods::CTRL;
    }
    if mods.alt_key() {
        out = out | Mods::ALT;
    }
    if mods.shift_key() && !matches!(code, KeyCode::Char(_)) {
        out = out | Mods::SHIFT;
    }
    Some(Key { code, mods: out })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ctrl_shift_v_and_shift_insert_paste_and_plain_v_types() {
        let v = WinitKey::Character("V".into());
        assert!(is_paste(
            &v,
            ModifiersState::CONTROL | ModifiersState::SHIFT
        ));
        assert!(is_paste(
            &WinitKey::Named(NamedKey::Insert),
            ModifiersState::SHIFT
        ));
        assert!(
            !is_paste(&v, ModifiersState::CONTROL),
            "ctrl-v is the editor's"
        );
        assert!(!is_paste(&v, ModifiersState::SHIFT));
        assert!(!is_paste(
            &WinitKey::Named(NamedKey::Insert),
            ModifiersState::empty()
        ));
    }

    fn char_key(logical: &str, text: Option<&str>, mods: ModifiersState) -> Option<Key> {
        key_from(&WinitKey::Character(logical.into()), text, mods)
    }

    #[test]
    fn character_keys_are_the_text_they_type_unless_ctrl_or_alt_is_held() {
        let typed = |c| {
            Some(Key {
                code: KeyCode::Char(c),
                mods: Mods::NONE,
            })
        };
        // A dead key's accent and then "e" type "é".
        assert_eq!(
            char_key("e", Some("é"), ModifiersState::empty()),
            typed('é')
        );
        assert_eq!(char_key("G", Some("G"), ModifiersState::SHIFT), typed('G'));
        assert_eq!(
            char_key("c", Some("\u{3}"), ModifiersState::CONTROL),
            Some(Key {
                code: KeyCode::Char('c'),
                mods: Mods::CTRL,
            }),
            "ctrl-c is the key, not the control character it types"
        );
        assert_eq!(char_key("´", None, ModifiersState::empty()), typed('´'));
        assert_eq!(char_key("e", Some("\u{7f}"), ModifiersState::empty()), None);
    }

    #[test]
    fn a_character_with_command_or_super_held_is_no_key() {
        assert_eq!(char_key("c", Some("c"), ModifiersState::SUPER), None);
        assert_eq!(
            char_key(
                "P",
                Some("P"),
                ModifiersState::SUPER | ModifiersState::SHIFT
            ),
            None
        );
        assert_eq!(
            key_from(
                &WinitKey::Named(NamedKey::ArrowLeft),
                None,
                ModifiersState::SUPER
            ),
            Some(Key {
                code: KeyCode::Left,
                mods: Mods::NONE,
            }),
            "other keys still go"
        );
    }

    #[test]
    fn dead_keys_wait_for_the_next_key() {
        let dead = WinitKey::Dead(Some('´'));
        assert_eq!(key_from(&dead, None, ModifiersState::empty()), None);
    }

    #[test]
    fn a_kept_size_is_two_numbers_a_screen_could_have() {
        assert_eq!(
            parse_size("1280 800\n"),
            Some(LogicalSize::new(1280.0, 800.0))
        );
        assert_eq!(
            parse_size("1280.5 800"),
            Some(LogicalSize::new(1280.5, 800.0))
        );
        for bad in ["", "1280", "1280 800 3", "wide tall", "10 10", "1e9 800"] {
            assert_eq!(parse_size(bad), None, "{bad:?}");
        }
    }
}
