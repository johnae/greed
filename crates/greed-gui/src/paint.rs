//! What a client draws from: the session's latest frame, the images and
//! scenes it sent, and the fonts and atlas the text is drawn with. The
//! window draws with one, and so does the recorder, into images.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use greed_core::delta::{FrameDelta, Latest};
use greed_core::image::ImageId;
use greed_core::render::grid::{self, Cell};
use greed_core::render::{Frame, Rect, Role, Size, SurfaceId};
use greed_core::scene_image::{Colors, Drawer};
use greed_core::server::{Input, Output};
use greed_core::theme::{Medium, Theme};

use crate::color::Palette;
use crate::draw::{self, Hovered, Instance, Scene};
use crate::gpu::Gpu;
use crate::text::{self, Atlas, Fonts};

/// The first id of the images scenes are drawn into, above any the session
/// gives its own.
const SCENE_IMAGES: u64 = 0x8000_0000;

pub(crate) const ATLAS_SIZE: u32 = 2048;

/// How long a scrolled view's rows take to glide to their new place.
const GLIDE: Duration = Duration::from_millis(150);

/// A scrolled surface's rows gliding to where the scroll put them.
struct Glide {
    surface: SurfaceId,
    started: Instant,
    /// How many rows below their place the rows start, easing to none.
    from: f32,
    /// The quads of the rows that scrolled out of sight, where they were
    /// drawn when it started; they move off as the rest move in.
    leaving: Vec<Instance>,
}

impl Glide {
    /// How many rows below their place the rows are at `now`.
    fn offset(&self, now: Instant) -> f32 {
        let t = (now - self.started).as_secs_f32() / GLIDE.as_secs_f32();
        // Fast at first, slowing down as it arrives.
        self.from * (1.0 - t.clamp(0.0, 1.0)).powi(3)
    }
}

/// `rect`'s cells in pixels: left, top, right, bottom.
fn pixels(rect: Rect, (cw, ch): (f32, f32)) -> [f32; 4] {
    [
        f32::from(rect.x) * cw,
        f32::from(rect.y) * ch,
        f32::from(rect.x + rect.width) * cw,
        f32::from(rect.y + rect.height) * ch,
    ]
}

/// Whether `quad`'s middle is in `area` (left, top, right, bottom).
fn within(quad: &Instance, area: [f32; 4]) -> bool {
    let x = quad.pos[0] + quad.size[0] / 2.0;
    let y = quad.pos[1] + quad.size[1] / 2.0;
    x >= area[0] && x < area[2] && y >= area[1] && y < area[3]
}

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
    /// Whether scrolled views glide (a window, with `gui-smooth-scroll`
    /// on) rather than jump (the recorder, whose pictures can't wait).
    glides: bool,
    gliding: Vec<Glide>,
    /// The quads drawn last, while views glide: what scrolls out of sight
    /// is taken from them.
    drawn: Vec<Instance>,
    /// Where the mouse is (column, row), what it can light up as drawn
    /// last, and what it lit up.
    mouse: Option<(usize, usize)>,
    hoverable: Vec<Hovered>,
    hover: Option<Hovered>,
    /// What an input method is composing, drawn at the cursor until it's
    /// typed, and where its own cursor is in it (bytes).
    preedit: Option<(String, Option<usize>)>,
    /// Lines drawn over the frame, centered near its bottom: a recording's
    /// captions and the keys it pressed.
    pub(crate) overlay: Vec<String>,
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
            glides: false,
            gliding: Vec::new(),
            drawn: Vec::new(),
            mouse: None,
            hoverable: Vec::new(),
            hover: None,
            preedit: None,
            overlay: Vec::new(),
        }
    }

    /// What an input method is composing now, `cursor` bytes into it; none
    /// once it's typed or given up.
    pub(crate) fn set_preedit(&mut self, text: String, cursor: Option<usize>) {
        self.preedit = (!text.is_empty()).then_some((text, cursor));
    }

    /// The mouse moved to `at` (column, row), or off the window: whether
    /// that changes what it lights up, for a redraw.
    pub(crate) fn mouse_at(&mut self, at: Option<(usize, usize)>) -> bool {
        self.mouse = at;
        let hover = at.and_then(|at| draw::hovered(&self.hoverable, at));
        let changed = hover != self.hover;
        self.hover = hover;
        changed
    }

    /// It with scrolled views gliding to their place, as a window has them.
    pub(crate) fn gliding(self) -> Self {
        Self {
            glides: true,
            ..self
        }
    }

    /// Whether views scroll smoothly here: in a window, unless
    /// `gui-smooth-scroll` is off.
    fn smooth(&self) -> bool {
        self.glides
            && self
                .frame()
                .is_some_and(|f| f.gui.get("gui-smooth-scroll").is_none_or(|v| v != "false"))
    }

    /// Whether some view is still gliding, so the window draws again.
    pub(crate) fn animating(&self) -> bool {
        !self.gliding.is_empty()
    }

    /// Starts the glides of the surfaces `delta` scrolls, from where the
    /// frame there is now has them. Only a view that scrolled glides: rows
    /// moving as its text changes, like a line put in above them, jump. A
    /// pane under a float, or with an image or a chart in it, jumps too,
    /// since their quads can't be told from its own.
    fn glide(&mut self, delta: &FrameDelta) {
        let Some(frame) = self.screen.frame() else {
            return;
        };
        let now = Instant::now();
        let cell = (self.fonts.cell_w, self.fonts.cell_h);
        let scrolled = |s: &&greed_core::delta::SurfaceDelta| {
            s.shift != 0 && s.rect.is_none() && matches!(s.top, Some(Some(_)))
        };
        for change in delta.surfaces.iter().filter(scrolled) {
            let Some(surface) = frame.surfaces.iter().find(|s| s.id == change.id) else {
                continue;
            };
            let covered = frame.surfaces.iter().any(|s| match s.role {
                Role::Float { border, .. } => {
                    let rect = if border { s.rect.bordered() } else { s.rect };
                    rect.overlaps(surface.rect)
                }
                Role::Pane { .. } | Role::Panel { .. } | Role::Tabline | Role::Status => false,
            });
            let pictured = frame.images.iter().any(|i| i.rect.overlaps(surface.rect))
                || frame.scenes.iter().any(|s| s.rect.overlaps(surface.rect));
            // Rows that changed in place, besides those scrolling into sight:
            // a part that stays put, like a chat's box under what scrolls,
            // would move with the rest, so a few (the cursor's line) at most.
            let height = surface.rows.len();
            let by = usize::try_from(change.shift.unsigned_abs()).unwrap_or(usize::MAX);
            let entering = |row: usize| {
                if change.shift > 0 {
                    row + by >= height
                } else {
                    row < by
                }
            };
            let in_place = change
                .rows
                .iter()
                .filter(|(row, _)| !entering(usize::from(*row)))
                .count();
            if covered
                || pictured
                || in_place > 2
                || !matches!(surface.role, Role::Pane { .. } | Role::Panel { .. })
            {
                continue;
            }
            // A glide on the way goes on from where it got to.
            let was = self.gliding.iter().position(|g| g.surface == change.id);
            let now_at = was.map_or(0.0, |i| self.gliding.swap_remove(i).offset(now));
            let height = f32::from(surface.rect.height);
            #[expect(clippy::cast_precision_loss, reason = "a shift is a few rows")]
            let from = (now_at + change.shift as f32).clamp(-height, height);
            // The rows uncovered as the rest move in, which those leaving show.
            let [left, top, right, bottom] = pixels(surface.rect, cell);
            let band = if from > 0.0 {
                [left, top, right, top + from * cell.1]
            } else {
                [left, bottom + from * cell.1, right, bottom]
            };
            let leaving = self
                .drawn
                .iter()
                .filter(|q| within(q, band))
                .copied()
                .collect();
            self.gliding.push(Glide {
                surface: change.id,
                started: now,
                from,
                leaving,
            });
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
        self.fonts.set_named(choice.named.clone());
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
                if self.smooth() {
                    self.glide(&delta);
                }
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
        overlay(&mut grid, &self.overlay, &frame.theme);
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
        let mut cursor = frame
            .cursor
            .filter(|_| contents.iter().all(|c| c.cursor.is_none()))
            .map(|c| (c, frame.cursor_shape));
        if let (Some((text, at)), Some((position, _))) = (&self.preedit, cursor.as_mut()) {
            *position = draw::preedit(&mut grid, *position, text, *at);
        }
        self.hoverable = draw::hoverable(&grid);
        self.hover = self.mouse.and_then(|at| draw::hovered(&self.hoverable, at));
        let mut chrome = draw::Chrome::of(frame);
        chrome.under = &under;
        chrome.hover = self.hover;
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
        let mut scene = build(&mut self.fonts, &mut self.atlas)
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
        if !self.gliding.is_empty() {
            let cell = (self.fonts.cell_w, self.fonts.cell_h);
            place_glides(&mut self.gliding, cell, &mut scene, frame, Instant::now());
        }
        if self.smooth() {
            self.drawn.clone_from(&scene.instances);
        }
        Some(scene)
    }
}

/// Moves the quads of each surface `gliding` in `scene` to where its glide
/// has them at `now`, and adds the rows leaving it; drops the glides done.
fn place_glides(
    gliding: &mut Vec<Glide>,
    cell: (f32, f32),
    scene: &mut Scene,
    frame: &Frame,
    now: Instant,
) {
    gliding.retain(|g| now - g.started < GLIDE);
    for glide in gliding.iter() {
        let Some(surface) = frame.surfaces.iter().find(|s| s.id == glide.surface) else {
            continue;
        };
        let area = pixels(surface.rect, cell);
        let offset = glide.offset(now);
        for quad in scene.instances.iter_mut().filter(|q| within(q, area)) {
            quad.pos[1] += offset * cell.1;
            quad.clip = area;
        }
        let back = (offset - glide.from) * cell.1;
        scene
            .instances
            .extend(glide.leaving.iter().map(|q| Instance {
                pos: [q.pos[0], q.pos[1] + back],
                clip: area,
                ..*q
            }));
    }
}

/// Draws `lines` over `grid`, each centered, the last a row above the
/// status line, as badges in the theme's button style. One cell a
/// character, so the lines should keep to characters a cell wide.
fn overlay(grid: &mut [Vec<Cell>], lines: &[String], theme: &Theme) {
    let mut style = theme.style("ui.button", Medium::Gui);
    style.bold = Some(true);
    let rows = grid.len();
    for (n, line) in lines.iter().rev().enumerate() {
        let Some(row) = rows.checked_sub(3 + n).and_then(|y| grid.get_mut(y)) else {
            break;
        };
        let text: Vec<char> = format!(" {line} ").chars().collect();
        let start = row.len().saturating_sub(text.len()) / 2;
        for (cell, c) in row.iter_mut().skip(start).zip(text) {
            *cell = Cell {
                text: c.to_string(),
                style,
                scale: 1,
            };
        }
    }
}

#[cfg(test)]
mod tests {
    use greed_core::delta::FrameDelta;
    use greed_core::render::{Rect, Role, Row, Span, Surface, SurfaceId};
    use greed_core::{CursorShape, ViewId};

    use super::*;

    const PANE: SurfaceId = SurfaceId::View(ViewId(1));

    /// A frame showing `text` in a pane, as the session's `seq`th.
    fn frame(text: &str, seq: u64) -> Frame {
        frame_of(&[text], seq)
    }

    /// A frame showing `lines` in a pane, one a row.
    fn frame_of(lines: &[&str], seq: u64) -> Frame {
        let rows = lines
            .iter()
            .map(|text| Row {
                spans: vec![Span::new(*text, smallvec::SmallVec::new())],
                ..Row::default()
            })
            .collect();
        let height = u16::try_from(lines.len()).unwrap();
        let rect = Rect {
            x: 0,
            y: 0,
            width: 20,
            height,
        };
        let pane = Role::Pane { active: true };
        Frame {
            size: Size { width: 20, height },
            surfaces: vec![Surface::new(PANE, pane, rect, rows)],
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

    /// Ten numbered rows from `first`, as a scrolled view shows them.
    fn scrolled(first: usize, seq: u64) -> Frame {
        let mut frame = moved(first, seq);
        frame.surfaces[0].top = Some([first as u64, 0]);
        frame
    }

    /// The same rows as `scrolled`, there because the text changed: the
    /// view itself didn't scroll.
    fn moved(first: usize, seq: u64) -> Frame {
        let lines: Vec<String> = (first..first + 10).map(|n| format!("row {n}")).collect();
        let lines: Vec<&str> = lines.iter().map(String::as_str).collect();
        let mut frame = frame_of(&lines, seq);
        frame.surfaces[0].top = Some([0, 0]);
        frame
    }

    /// A quad on each of `rows` rows, as if each row drew one.
    fn quads(painter: &Painter, rows: usize) -> Vec<Instance> {
        let ch = painter.fonts.cell_h;
        (0..rows)
            .map(|row| {
                #[expect(clippy::cast_precision_loss, reason = "a few rows")]
                let y = row as f32 * ch;
                Instance {
                    pos: [0.0, y],
                    size: [10.0, ch],
                    uv: [0.0; 4],
                    color: [1.0; 4],
                    kind: draw::RECT,
                    clip: draw::NO_CLIP,
                }
            })
            .collect()
    }

    fn scene(instances: Vec<Instance>) -> Scene {
        Scene {
            background: [0.0; 4],
            instances,
            backgrounds: 0,
            under: Vec::new(),
            images: Vec::new(),
            columns: crate::columns::Columns::default(),
        }
    }

    /// A painter showing `before`, its quads drawn, that took the delta to
    /// `after`.
    fn scrolled_painter(mut painter: Painter, before: &Frame, after: &Frame) -> Painter {
        let _ = painter.take(Output::Frame(before.clone()));
        painter.drawn = quads(&painter, 10);
        let delta = FrameDelta::between(before, after).unwrap();
        assert_eq!(delta.surfaces[0].shift, 3);
        let _ = painter.take(Output::Delta(delta));
        painter
    }

    #[test]
    fn a_scrolled_pane_glides_from_where_it_was_to_its_place() {
        let (before, after) = (scrolled(0, 1), scrolled(3, 2));
        let mut painter = scrolled_painter(Painter::new().gliding(), &before, &after);
        assert!(painter.animating());
        assert_eq!(
            painter.gliding[0].leaving.len(),
            3,
            "the three rows leaving"
        );
        let ch = painter.fonts.cell_h;
        let started = painter.gliding[0].started;
        // At first it's drawn as it was: each row three rows lower, the
        // rows leaving where they were, all cut at the pane's edges.
        let mut first = scene(quads(&painter, 10));
        place_glides(
            &mut painter.gliding,
            (10.0, ch),
            &mut first,
            &after,
            started,
        );
        assert_eq!(first.instances.len(), 13);
        assert!((first.instances[0].pos[1] - 3.0 * ch).abs() < 0.01);
        assert!(first.instances[10].pos[1].abs() < 0.01);
        assert!((first.instances[0].clip[3] - 10.0 * ch).abs() < 0.01);
        // Halfway it's on its way up.
        let mut half = scene(quads(&painter, 10));
        place_glides(
            &mut painter.gliding,
            (10.0, ch),
            &mut half,
            &after,
            started + GLIDE / 2,
        );
        let y = half.instances[0].pos[1];
        assert!(y > 0.0 && y < 3.0 * ch, "{y}");
        // Then it's where it is, and done.
        let mut last = scene(quads(&painter, 10));
        place_glides(
            &mut painter.gliding,
            (10.0, ch),
            &mut last,
            &after,
            started + GLIDE,
        );
        assert_eq!(last.instances.len(), 10);
        assert!(last.instances[0].pos[1].abs() < 0.01);
        assert!(!painter.animating());
    }

    #[test]
    fn rows_moved_by_the_text_changing_jump_and_a_pane_with_an_image_too() {
        let (before, after) = (moved(0, 1), moved(3, 2));
        let painter = scrolled_painter(Painter::new().gliding(), &before, &after);
        assert!(!painter.animating(), "the view didn't scroll");
        let (mut before, mut after) = (scrolled(0, 1), scrolled(3, 2));
        let image = greed_core::render::ImagePlacement {
            id: greed_core::image::ImageId(1),
            rect: Rect {
                x: 0,
                y: 0,
                width: 4,
                height: 2,
            },
            col: 0,
            row: 0,
            cols: 4,
            rows: 2,
        };
        before.images.push(image);
        after.images.push(image);
        let painter = scrolled_painter(Painter::new().gliding(), &before, &after);
        assert!(!painter.animating(), "its image wouldn't move with it");
    }

    #[test]
    fn a_scroll_under_lines_that_stay_put_jumps() {
        // A chat's box at the bottom stays as the reply scrolls above it.
        let box_lines = ["╭─ box ─╮", "│ typed │", "╰───────╯"];
        let frame = |first: usize, seq: u64| {
            let mut lines: Vec<String> = (first..first + 20).map(|n| format!("row {n}")).collect();
            lines.extend(box_lines.iter().map(|l| (*l).to_owned()));
            let lines: Vec<&str> = lines.iter().map(String::as_str).collect();
            let mut frame = frame_of(&lines, seq);
            frame.surfaces[0].top = Some([first as u64, 0]);
            frame
        };
        let (before, after) = (frame(0, 1), frame(3, 2));
        let mut painter = Painter::new().gliding();
        let _ = painter.take(Output::Frame(before.clone()));
        let delta = FrameDelta::between(&before, &after).unwrap();
        assert_eq!(delta.surfaces[0].shift, 3, "it moved");
        let _ = painter.take(Output::Delta(delta));
        assert!(!painter.animating(), "the box would move with the rest");
    }

    #[test]
    fn with_smooth_scrolling_off_or_in_the_recorder_it_jumps() {
        let (mut before, mut after) = (scrolled(0, 1), scrolled(3, 2));
        let recorder = scrolled_painter(Painter::new(), &before, &after);
        assert!(!recorder.animating());
        for frame in [&mut before, &mut after] {
            frame
                .gui
                .insert("gui-smooth-scroll".to_owned(), "false".to_owned());
        }
        let off = scrolled_painter(Painter::new().gliding(), &before, &after);
        assert!(!off.animating());
    }
}
