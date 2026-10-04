//! The window: a winit event loop that draws the session's frames and sends
//! keys, the mouse and its size back, as the TUI does in a terminal.

use std::cell::RefCell;
use std::sync::Arc;

use crossbeam_channel::{Receiver, Sender};
use greed_core::keymap::{Key, KeyCode, Mods};
use greed_core::mouse::{Button, Mouse, MouseKind};
use greed_core::render::{Frame, Size, grid};
use greed_core::server::{Input, Output};
use greed_core::theme::Surface;
use winit::application::ApplicationHandler;
use winit::dpi::{LogicalSize, PhysicalPosition, PhysicalSize};
use winit::event::{ElementState, KeyEvent, MouseButton, MouseScrollDelta, WindowEvent};
use winit::event_loop::{ActiveEventLoop, EventLoop};
use winit::keyboard::{Key as WinitKey, ModifiersState, NamedKey};
use winit::platform::run_on_demand::EventLoopExtRunOnDemand;
use winit::window::{Window, WindowId};

use crate::color::Palette;
use crate::draw;
use crate::gpu::Gpu;
use crate::text::{Atlas, Fonts};

/// The font size in logical pixels, before the screen's scale.
const FONT_SIZE: f32 = 15.0;
const ATLAS_SIZE: u32 = 2048;

/// What reaches the event loop from the session's thread.
enum Event {
    Output(Output),
}

thread_local! {
    /// winit allows one event loop per process, so switching sessions runs
    /// the same one again.
    static LOOP: RefCell<Option<EventLoop<Event>>> = const { RefCell::new(None) };
}

/// Runs the window until the session exits or lets it go, or the window is
/// closed (`Output::Detached`), sending keys and sizes to `input` and
/// drawing the frames from `output`. Returns how it ended.
pub fn run(
    input: &Sender<Input>,
    output: &Receiver<Output>,
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
        event_loop.run_app_on_demand(&mut app)?;
        let _ = stop.send(());
        let _ = forward.join();
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
    atlas: Atlas,
    palette: Palette,
    frame: Option<Frame>,
    mods: ModifiersState,
    /// The cell the mouse is over, and the button held, for drags.
    mouse: (u16, u16),
    held: Option<Button>,
    /// Scrolling by pixels, gathered until it adds up to a line.
    scrolled: f64,
    clipboard: Option<arboard::Clipboard>,
    ended: Option<Output>,
}

impl App {
    fn new(input: Sender<Input>) -> Self {
        Self {
            input,
            shown: None,
            fonts: Fonts::new(None, FONT_SIZE),
            atlas: Atlas::new(ATLAS_SIZE),
            palette: Palette::default(),
            frame: None,
            mods: ModifiersState::empty(),
            mouse: (0, 0),
            held: None,
            scrolled: 0.0,
            clipboard: arboard::Clipboard::new().ok(),
            ended: None,
        }
    }

    /// Fonts at the window's scale.
    fn set_scale(&mut self, scale: f64) {
        self.fonts = Fonts::new(None, FONT_SIZE * scale as f32);
        self.atlas.clear();
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
        let Ok(scene) = draw::build(
            &grid,
            cursor,
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
                &mut self.fonts,
                &mut self.atlas,
                &self.palette,
            )
        }) else {
            return;
        };
        shown.gpu.upload(&mut self.atlas);
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
            // Images aren't drawn yet.
            Output::Image(_) => return,
            other => {
                self.ended = Some(other);
                event_loop.exit();
                return;
            }
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
            .with_inner_size(LogicalSize::new(1100.0, 720.0));
        let Ok(window) = event_loop.create_window(attributes) else {
            event_loop.exit();
            return;
        };
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
        let Event::Output(output) = event;
        self.handle(event_loop, output);
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

/// A key press as Greed names keys: shifted characters are the character
/// itself ("G"), so shift only counts for other keys.
fn key(event: &KeyEvent, mods: ModifiersState) -> Option<Key> {
    let code = match &event.logical_key {
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
        WinitKey::Character(text) => {
            let mut chars = text.chars();
            match (chars.next(), chars.next()) {
                (Some(c), None) => KeyCode::Char(c),
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
