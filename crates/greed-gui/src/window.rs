//! The window: a winit event loop that draws the session's frames and sends
//! keys, the mouse and its size back, as the TUI does in a terminal.

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

use crossbeam_channel::{Receiver, Sender};
use greed_core::image::ImageId;
use greed_core::keymap::{Key, KeyCode, Mods};
use greed_core::mouse::{Button, Mouse, MouseKind};
use greed_core::render::{Frame, Size, grid};
use greed_core::server::{Input, Output};
use greed_core::theme::Surface;
use winit::application::ApplicationHandler;
use winit::dpi::{LogicalSize, PhysicalPosition, PhysicalSize};
use winit::event::{ElementState, Ime, KeyEvent, MouseButton, MouseScrollDelta, WindowEvent};
use winit::event_loop::{ActiveEventLoop, EventLoop};
use winit::keyboard::{Key as WinitKey, ModifiersState, NamedKey};
use winit::platform::run_on_demand::EventLoopExtRunOnDemand;
use winit::window::{Window, WindowId};

use crate::color::Palette;
use crate::draw;
use crate::gpu::Gpu;
use crate::text::{self, Atlas, Fonts};

const ATLAS_SIZE: u32 = 2048;

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
                        let last = !matches!(message, Output::Frame(_) | Output::Delta(_) | Output::Image(_) | Output::Clipboard(_));
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
    fonts: Fonts,
    /// The font the options chose, a family and a size before the scale.
    font: (Option<String>, f32),
    scale: f64,
    atlas: Atlas,
    palette: Palette,
    frame: Option<Frame>,
    /// Every image the session sent, as PNG: it sends each only once.
    images: HashMap<ImageId, Vec<u8>>,
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
    fn new(input: Sender<Input>) -> Self {
        Self {
            input,
            shown: None,
            fonts: Fonts::new(None, text::DEFAULT_SIZE),
            font: (None, text::DEFAULT_SIZE),
            scale: 1.0,
            atlas: Atlas::new(ATLAS_SIZE),
            palette: Palette::default(),
            frame: None,
            images: HashMap::new(),
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

    /// Fonts at the window's scale.
    fn set_scale(&mut self, scale: f64) {
        self.scale = scale;
        self.refont();
    }

    /// The chosen font at the window's scale, from a fresh atlas.
    fn refont(&mut self) {
        let (family, size) = &self.font;
        self.fonts.set(family.clone(), size * self.scale as f32);
        self.atlas.clear();
    }

    /// Takes up the font the frame's options choose, if it's another one,
    /// and tells the session the cells' new size.
    fn follow_options(&mut self) {
        let Some(frame) = &self.frame else { return };
        let font = text::chosen(&frame.gui);
        if font == self.font {
            return;
        }
        self.font = font;
        self.refont();
        if let Some(shown) = &self.shown {
            self.send_size(shown.window.inner_size());
        }
    }

    /// Tells the session how many cells fit in `size`, and how big a cell is.
    fn send_size(&self, size: PhysicalSize<u32>) {
        let width = (size.width as f32 / self.fonts.cell_w).floor().max(1.0) as u16;
        let height = (size.height as f32 / self.fonts.cell_h).floor().max(1.0) as u16;
        let _ = self.input.send(Input::Resize(Size { width, height }));
        let _ = self.input.send(Input::CellSize(
            self.fonts.cell_w.round() as u16,
            self.fonts.cell_h.round() as u16,
        ));
    }

    fn redraw(&mut self) {
        let (Some(shown), Some(frame)) = (&mut self.shown, &self.frame) else {
            return;
        };
        let grid = grid::compose(frame, Surface::Gui);
        let cursor = frame.cursor.map(|c| (c, frame.cursor_shape));
        let chrome = draw::Chrome::of(frame);
        let Ok(scene) = draw::build(
            &grid,
            cursor,
            &chrome,
            &mut self.fonts,
            &mut self.atlas,
            &self.palette,
        )
        .or_else(|_| {
            // The atlas is full: start it again with this frame's glyphs.
            self.atlas.clear();
            draw::build(
                &grid,
                cursor,
                &chrome,
                &mut self.fonts,
                &mut self.atlas,
                &self.palette,
            )
        }) else {
            return;
        };
        shown.gpu.upload(&mut self.atlas);
        shown.gpu.place_images(&frame.images, &self.images);
        let (wgpu::CurrentSurfaceTexture::Success(texture)
        | wgpu::CurrentSurfaceTexture::Suboptimal(texture)) = shown.surface.get_current_texture()
        else {
            shown.surface.configure(&shown.gpu.device, &shown.config);
            return;
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
        if let Some(at) = frame.cursor {
            let (cw, ch) = (f64::from(self.fonts.cell_w), f64::from(self.fonts.cell_h));
            shown.window.set_ime_cursor_area(
                PhysicalPosition::new(f64::from(at.col) * cw, f64::from(at.row) * ch),
                PhysicalSize::new(cw, ch),
            );
        }
    }

    fn handle(&mut self, event_loop: &ActiveEventLoop, output: Output) {
        match output {
            Output::Frame(frame) => self.frame = Some(frame),
            Output::Delta(delta) => {
                if let Some(frame) = &mut self.frame {
                    delta.apply(frame);
                }
            }
            Output::Clipboard(text) => {
                if let Some(clipboard) = &mut self.clipboard {
                    let _ = clipboard.set_text(text);
                }
                return;
            }
            // Kept as PNG; frames that place it make its texture.
            Output::Image(image) => {
                use base64::Engine;
                if let Ok(png) = base64::engine::general_purpose::STANDARD.decode(&image.png) {
                    self.images.insert(image.id, png);
                }
                return;
            }
            other => {
                self.ended = Some(other);
                event_loop.exit();
                return;
            }
        }
        self.follow_options();
        #[cfg(target_os = "macos")]
        if let (Some(bar), Some(frame)) = (&mut self.menubar, &self.frame) {
            bar.show(&frame.menus);
        }
        if let Some(shown) = &self.shown {
            shown.window.request_redraw();
        }
    }

    fn cell_at(&self, position: PhysicalPosition<f64>) -> (u16, u16) {
        let col = (position.x / f64::from(self.fonts.cell_w)).max(0.0) as u16;
        let row = (position.y / f64::from(self.fonts.cell_h)).max(0.0) as u16;
        (col, row)
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
        self.set_scale(window.scale_factor());
        self.send_size(window.inner_size());
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
                self.size = Some(size.to_logical(self.scale));
                self.send_size(size);
            }
            WindowEvent::ScaleFactorChanged { scale_factor, .. } => {
                self.set_scale(scale_factor);
                if let Some(shown) = &self.shown {
                    self.send_size(shown.window.inner_size());
                }
            }
            WindowEvent::ModifiersChanged(mods) => self.mods = mods.state(),
            WindowEvent::KeyboardInput { event, .. } if event.state == ElementState::Pressed => {
                if let Some(key) = key(&event, self.mods) {
                    let _ = self.input.send(Input::Key(key));
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
                        self.scrolled += p.y / f64::from(self.fonts.cell_h);
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
            present_mode: wgpu::PresentMode::Fifo,
            desired_maximum_frame_latency: 2,
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
