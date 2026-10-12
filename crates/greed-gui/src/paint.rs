//! What a client draws from: the session's latest frame, the images and
//! scenes it sent, and the fonts and atlas the text is drawn with. The
//! window draws with one, and so does the recorder, into images.

use std::collections::HashMap;

use greed_core::delta::Latest;
use greed_core::image::ImageId;
use greed_core::render::{Frame, Size, grid};
use greed_core::scene_image::{Colors, Drawer};
use greed_core::server::{Input, Output};
use greed_core::theme::Medium;

use crate::color::Palette;
use crate::draw::{self, Scene};
use crate::gpu::Gpu;
use crate::text::{self, Atlas, Fonts};

/// The first id of the images scenes are drawn into, above any the session
/// gives its own.
const SCENE_IMAGES: u64 = 0x8000_0000;

pub(crate) const ATLAS_SIZE: u32 = 2048;

/// What became of an output the painter took.
pub(crate) enum Taken {
    /// A frame came, or changed: there's something new to draw.
    Frame,
    /// Kept for the frames that use it, an image or a scene.
    Kept,
    /// A delta that doesn't fit the frame there is, applied as far as it
    /// makes sense: draw it, and ask the session for a whole frame
    /// (`Input::Refresh`).
    Stale,
}

pub(crate) struct Painter {
    pub(crate) fonts: Fonts,
    /// The fonts the options chose, with their size before the scale.
    font: text::Choice,
    pub(crate) scale: f64,
    atlas: Atlas,
    palette: Palette,
    /// The frame to draw.
    screen: Latest,
    /// Every image the session sent, as PNG: it sends each only once. Scenes
    /// drawn into images are here too, under ids from `SCENE_IMAGES`.
    images: HashMap<ImageId, Vec<u8>>,
    /// The scenes the session sent, and the images they're drawn into.
    drawer: Drawer,
}

impl Painter {
    pub(crate) fn new() -> Self {
        let palette = Palette::default();
        // Scenes in the colors the text has.
        let mut drawer = Drawer::new(SCENE_IMAGES);
        drawer.set_colors(Colors {
            fg: palette.fg,
            ansi: palette.ansi,
        });
        Self {
            fonts: Fonts::new(None, text::DEFAULT_SIZE),
            font: text::Choice::default(),
            scale: 1.0,
            atlas: Atlas::new(ATLAS_SIZE),
            palette,
            screen: Latest::default(),
            images: HashMap::new(),
            drawer,
        }
    }

    /// The frame to draw, once one came.
    pub(crate) fn frame(&self) -> Option<&Frame> {
        self.screen.frame()
    }

    /// Fonts at the screen's scale.
    pub(crate) fn set_scale(&mut self, scale: f64) {
        self.scale = scale;
        self.refont();
    }

    /// The chosen font at the screen's scale, from a fresh atlas.
    fn refont(&mut self) {
        let choice = &self.font;
        self.fonts
            .set(choice.family.clone(), choice.size * self.scale as f32);
        self.fonts.set_prose(choice.prose.clone());
        self.atlas.clear();
    }

    /// Takes up the font the frame's options choose, if it's another one.
    /// True when it did, so the cells changed size.
    pub(crate) fn follow_options(&mut self) -> bool {
        let Some(frame) = self.frame() else {
            return false;
        };
        let font = text::chosen(&frame.gui);
        if font == self.font {
            return false;
        }
        self.font = font;
        self.refont();
        true
    }

    /// What tells the session how many cells fit in `width` by `height`
    /// pixels, and how big a cell is.
    pub(crate) fn size_inputs(&self, width: u32, height: u32) -> [Input; 2] {
        let cols = (width as f32 / self.fonts.cell_w).floor().max(1.0) as u16;
        let rows = (height as f32 / self.fonts.cell_h).floor().max(1.0) as u16;
        let (cell_w, cell_h) = self.cell();
        [
            Input::Resize(Size {
                width: cols,
                height: rows,
            }),
            Input::CellSize(cell_w, cell_h),
        ]
    }

    /// A cell's size in whole pixels.
    fn cell(&self) -> (u16, u16) {
        (
            self.fonts.cell_w.round() as u16,
            self.fonts.cell_h.round() as u16,
        )
    }

    /// Takes in a frame or a change to it, an image or a scene; anything
    /// else, like the session ending or the clipboard, it gives back.
    // Each message passes through once: giving it back costs a move, where
    // boxing it would cost an allocation.
    #[allow(clippy::result_large_err)]
    pub(crate) fn take(&mut self, output: Output) -> Result<Taken, Output> {
        match output {
            Output::Frame(frame) => self.screen.whole(frame),
            Output::Delta(delta) => {
                if self.screen.delta(delta) {
                    return Ok(Taken::Stale);
                }
            }
            Output::Scene(scene) => {
                self.drawer.add(scene);
                return Ok(Taken::Kept);
            }
            // Kept as PNG; frames that place it make its texture.
            Output::Image(image) => {
                use base64::Engine;
                if let Ok(png) = base64::engine::general_purpose::STANDARD.decode(&image.png) {
                    self.images.insert(image.id, png);
                }
                return Ok(Taken::Kept);
            }
            other => return Err(other),
        }
        Ok(Taken::Frame)
    }

    /// The frame as a scene for `gpu`, its glyphs and images uploaded. None
    /// before the first frame, or when it can't be drawn.
    pub(crate) fn paint(&mut self, gpu: &mut Gpu) -> Option<Scene> {
        let frame = self.screen.frame()?;
        let mut grid = grid::compose(frame, Medium::Gui);
        // Scenes are drawn into images under the text: the cells there keep
        // only the scene's own text, its labels.
        let drawing = self
            .drawer
            .draw(&frame.scenes, self.cell(), &frame.theme, Medium::Gui);
        for id in &drawing.gone {
            self.images.remove(id);
        }
        for (id, png, _, _) in drawing.drawn {
            self.images.insert(id, png);
        }
        let mut under = Vec::new();
        for scene in &drawing.shown {
            for (x, y) in self.drawer.uncovered(scene) {
                if let Some(cell) = grid
                    .get_mut(usize::from(y))
                    .and_then(|r| r.get_mut(usize::from(x)))
                {
                    cell.text = " ".into();
                }
            }
            under.push(scene.image);
        }
        // Views laid out at another size, like a terminal sized for another
        // client's screen, are drawn scaled to fit, the cursor with them.
        let contents = grid::compose_content(frame);
        let cursor = frame
            .cursor
            .filter(|_| contents.iter().all(|c| c.cursor.is_none()))
            .map(|c| (c, frame.cursor_shape));
        let mut chrome = draw::Chrome::of(frame);
        chrome.under = &under;
        let palette = &self.palette;
        let build = |fonts: &mut _, atlas: &mut _| {
            let mut scene = draw::build(&grid, cursor, &chrome, fonts, atlas, palette)?;
            draw::add_scaled(
                &mut scene,
                &contents,
                frame.cursor_shape,
                &chrome,
                fonts,
                atlas,
                palette,
            )?;
            Ok::<_, crate::text::Full>(scene)
        };
        let scene = build(&mut self.fonts, &mut self.atlas)
            .or_else(|_| {
                // The atlas is full: start it again with this frame's glyphs.
                self.atlas.clear();
                build(&mut self.fonts, &mut self.atlas)
            })
            .ok()?;
        gpu.upload(&mut self.atlas);
        let mut placed = frame.images.clone();
        placed.extend_from_slice(&under);
        gpu.place_images(&placed, &self.images);
        Some(scene)
    }
}

#[cfg(test)]
mod tests {
    use greed_core::delta::FrameDelta;
    use greed_core::render::{Rect, Role, Row, Span, Surface, SurfaceId};
    use greed_core::{CursorShape, ViewId};

    use super::*;

    /// A frame showing `text` in a pane, as the session's `seq`th.
    fn frame(text: &str, seq: u64) -> Frame {
        let row = Row {
            spans: vec![Span::new(text, smallvec::SmallVec::new())],
            ..Row::default()
        };
        let rect = Rect {
            x: 0,
            y: 0,
            width: 20,
            height: 1,
        };
        let pane = Role::Pane { active: true };
        Frame {
            size: Size {
                width: 20,
                height: 1,
            },
            surfaces: vec![Surface::new(
                SurfaceId::View(ViewId(1)),
                pane,
                rect,
                vec![row],
            )],
            lines: Vec::new(),
            images: Vec::new(),
            scenes: Vec::new(),
            cursor: None,
            cursor_shape: CursorShape::Block,
            theme: std::sync::Arc::default(),
            gui: std::collections::BTreeMap::new(),
            menus: Vec::new(),
            seq,
        }
    }

    #[test]
    fn a_delta_that_doesnt_fit_is_drawn_and_asks_for_a_whole_frame_once() {
        let frames = [frame("one", 1), frame("two", 2), frame("three", 3)];
        let delta = |a: usize, b: usize| {
            Output::Delta(FrameDelta::between(&frames[a], &frames[b]).unwrap())
        };
        let mut painter = Painter::new();
        let mut take = |output| {
            painter
                .take(output)
                .ok()
                .map(|taken| matches!(taken, Taken::Stale))
        };
        assert_eq!(take(Output::Frame(frames[0].clone())), Some(false));
        assert_eq!(take(delta(1, 2)), Some(true), "it missed frame 2");
        assert_eq!(take(delta(1, 2)), Some(false), "it asked already");
        assert_eq!(take(Output::Frame(frames[1].clone())), Some(false));
        assert_eq!(take(delta(1, 2)), Some(false));
        assert_eq!(painter.frame(), Some(&frames[2]));
    }
}
