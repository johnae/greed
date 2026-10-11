//! Scenes drawn as images, by clients that can show one under their text
//! (a terminal with kitty graphics, the window): each item in pixels at the
//! client's cell size, on a clear background. Text items aren't drawn: the
//! client shows them as text, as the cells under the scene hold them, so
//! no fonts are needed here.

use std::collections::{HashMap, HashSet};

use tiny_skia::{FillRule, Mask, Paint, PathBuilder, Pixmap, Stroke, Transform};

use crate::image::ImageId;
use crate::render::{ImagePlacement, ScenePlacement};
use crate::scene::{Item, Point, SceneId, Spec};
use crate::server::SceneData;
use crate::theme::{Color, Medium, Theme};

/// xterm's 16 colors, for themes naming terminal colors: the terminal's own
/// may differ, which the image can't know.
const ANSI: [[u8; 3]; 16] = [
    [0x00, 0x00, 0x00],
    [0xcd, 0x00, 0x00],
    [0x00, 0xcd, 0x00],
    [0xcd, 0xcd, 0x00],
    [0x00, 0x00, 0xee],
    [0xcd, 0x00, 0xcd],
    [0x00, 0xcd, 0xcd],
    [0xe5, 0xe5, 0xe5],
    [0x7f, 0x7f, 0x7f],
    [0xff, 0x00, 0x00],
    [0x00, 0xff, 0x00],
    [0xff, 0xff, 0x00],
    [0x5c, 0x5c, 0xff],
    [0xff, 0x00, 0xff],
    [0x00, 0xff, 0xff],
    [0xff, 0xff, 0xff],
];

/// The foreground of a terminal that says nothing of its own.
const FOREGROUND: [u8; 3] = [0xd0, 0xd0, 0xd0];

/// The most pixels along either side of a scene's image.
const MAX_SIDE: u32 = 4096;

/// The color of style `name` in `theme` on `medium`: its foreground.
pub fn color(theme: &Theme, name: &str, medium: Medium) -> [u8; 3] {
    match theme.style(name, medium).fg {
        Some(Color::Rgb(r, g, b)) => [r, g, b],
        Some(Color::Ansi(n)) => ANSI[usize::from(n % 16)],
        None | Some(Color::Default) => FOREGROUND,
    }
}

/// The style names `items` use, each once, in order, for knowing when a
/// theme change means drawing a scene again.
pub fn styles(items: &[Item], out: &mut Vec<String>) {
    fn add(name: Option<&String>, out: &mut Vec<String>) {
        if let Some(name) = name
            && !out.contains(name)
        {
            out.push(name.clone());
        }
    }
    for item in items {
        match item {
            Item::Line { style, .. } | Item::Dots { style, .. } => add(style.as_ref(), out),
            Item::Area { fill, .. } => add(fill.as_ref(), out),
            Item::Rect { fill, style, .. } => {
                add(fill.as_ref(), out);
                add(style.as_ref(), out);
            }
            Item::Group { items, .. } => styles(items, out),
            Item::Text { .. } | Item::Unknown => {}
        }
    }
}

/// Draws `spec` over `cols` by `rows` cells of `cell` pixels each, as a
/// PNG with a clear background; None when it's too big or can't be encoded.
pub fn draw(
    spec: &Spec,
    cols: u16,
    rows: u16,
    cell: (u16, u16),
    theme: &Theme,
    medium: Medium,
) -> Option<Vec<u8>> {
    let cell = (cell.0.max(1), cell.1.max(1));
    let (cw, ch) = (f32::from(cell.0), f32::from(cell.1));
    let width = u32::from(cols) * u32::from(cell.0);
    let height = u32::from(rows) * u32::from(cell.1);
    if width > MAX_SIDE || height > MAX_SIDE {
        return None;
    }
    let mut pixmap = Pixmap::new(width, height)?;
    let canvas = Canvas {
        cw,
        ch,
        width,
        height,
        theme,
        medium,
    };
    let all = [0.0, 0.0, f32::from(cols), f32::from(rows)];
    canvas.items(&mut pixmap, &spec.items, all);
    pixmap.encode_png().ok()
}

/// What items are drawn with: the cell size, the image's size in pixels
/// and the theme.
struct Canvas<'a> {
    cw: f32,
    ch: f32,
    width: u32,
    height: u32,
    theme: &'a Theme,
    medium: Medium,
}

impl Canvas<'_> {
    /// A point in cells, in pixels.
    fn at(&self, p: Point) -> (f32, f32) {
        (p[0] * self.cw, p[1] * self.ch)
    }

    fn paint(&self, style: Option<&String>, opacity: Option<f32>) -> Option<Paint<'static>> {
        let [r, g, b] = color(self.theme, style?, self.medium);
        let mut paint = Paint::default();
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
        let alpha = (opacity.unwrap_or(1.0).clamp(0.0, 1.0) * 255.0).round() as u8;
        paint.set_color_rgba8(r, g, b, alpha);
        paint.anti_alias = true;
        Some(paint)
    }

    /// A line's width in pixels for `weight` (1 to 3).
    fn line_width(&self, weight: Option<f32>) -> f32 {
        (self.ch / 10.0).max(1.0) * weight.unwrap_or(1.0).clamp(1.0, 3.0)
    }

    /// The mask keeping drawing inside `clip`, x0 y0 x1 y1 in cells.
    fn mask(&self, clip: [f32; 4]) -> Option<Mask> {
        let mut mask = Mask::new(self.width, self.height)?;
        let (x0, y0) = self.at([clip[0], clip[1]]);
        let (x1, y1) = self.at([clip[2], clip[3]]);
        let rect = tiny_skia::Rect::from_ltrb(x0, y0, x1.max(x0 + 1.0), y1.max(y0 + 1.0))?;
        mask.fill_path(
            &PathBuilder::from_rect(rect),
            FillRule::Winding,
            false,
            Transform::identity(),
        );
        Some(mask)
    }

    fn items(&self, pixmap: &mut Pixmap, items: &[Item], clip: [f32; 4]) {
        let mask = self.mask(clip);
        for item in items {
            self.item(pixmap, item, clip, mask.as_ref());
        }
    }

    fn item(&self, pixmap: &mut Pixmap, item: &Item, clip: [f32; 4], mask: Option<&Mask>) {
        let identity = Transform::identity();
        match item {
            Item::Line {
                points,
                style,
                weight,
            } => {
                let (Some(paint), Some(path)) =
                    (self.paint(style.as_ref(), None), self.path(points))
                else {
                    return;
                };
                let stroke = Stroke {
                    width: self.line_width(*weight),
                    line_cap: tiny_skia::LineCap::Round,
                    line_join: tiny_skia::LineJoin::Round,
                    ..Stroke::default()
                };
                pixmap.stroke_path(&path, &paint, &stroke, identity, mask);
            }
            Item::Area {
                points,
                base,
                fill,
                opacity,
            } => {
                let Some(paint) = self.paint(fill.as_ref(), *opacity) else {
                    return;
                };
                let mut outline = points.clone();
                outline.sort_by(|a, b| a[0].total_cmp(&b[0]));
                let (Some(&first), Some(&last)) = (outline.first(), outline.last()) else {
                    return;
                };
                let base = base.unwrap_or(clip[3]);
                outline.push([last[0], base]);
                outline.push([first[0], base]);
                if let Some(path) = self.closed(&outline) {
                    pixmap.fill_path(&path, &paint, FillRule::Winding, identity, mask);
                }
            }
            Item::Rect {
                at,
                size,
                fill,
                style,
                opacity,
            } => {
                let (x, y) = self.at(*at);
                let (w, h) = (size[0] * self.cw, size[1] * self.ch);
                let Some(rect) = tiny_skia::Rect::from_xywh(x, y, w.max(0.5), h.max(0.5)) else {
                    return;
                };
                let path = PathBuilder::from_rect(rect);
                if let Some(paint) = self.paint(fill.as_ref(), *opacity) {
                    pixmap.fill_path(&path, &paint, FillRule::Winding, identity, mask);
                }
                if let Some(paint) = self.paint(style.as_ref(), *opacity) {
                    let stroke = Stroke {
                        width: self.line_width(None),
                        ..Stroke::default()
                    };
                    pixmap.stroke_path(&path, &paint, &stroke, identity, mask);
                }
            }
            Item::Dots {
                points,
                style,
                weight,
            } => {
                let Some(paint) = self.paint(style.as_ref(), None) else {
                    return;
                };
                let radius = (self.ch / 8.0).max(1.5) * weight.unwrap_or(1.0).clamp(1.0, 3.0);
                for p in points {
                    let (x, y) = self.at(*p);
                    if let Some(dot) = PathBuilder::from_circle(x, y, radius) {
                        pixmap.fill_path(&dot, &paint, FillRule::Winding, identity, mask);
                    }
                }
            }
            Item::Group { clip: inner, items } => {
                let within = inner.map_or(clip, |c| {
                    [
                        clip[0].max(c[0]),
                        clip[1].max(c[1]),
                        clip[2].min(c[2]),
                        clip[3].min(c[3]),
                    ]
                });
                self.items(pixmap, items, within);
            }
            Item::Text { .. } | Item::Unknown => {}
        }
    }

    /// The line through `points`, in pixels.
    fn path(&self, points: &[Point]) -> Option<tiny_skia::Path> {
        let mut builder = PathBuilder::new();
        let (first, rest) = points.split_first()?;
        let (x, y) = self.at(*first);
        builder.move_to(x, y);
        if rest.is_empty() {
            // A single point is a dot of the line's width.
            builder.line_to(x + 0.01, y);
        }
        for p in rest {
            let (x, y) = self.at(*p);
            builder.line_to(x, y);
        }
        builder.finish()
    }

    /// The shape inside `points`, in pixels.
    fn closed(&self, points: &[Point]) -> Option<tiny_skia::Path> {
        let mut builder = PathBuilder::new();
        let (first, rest) = points.split_first()?;
        let (x, y) = self.at(*first);
        builder.move_to(x, y);
        for p in rest {
            let (x, y) = self.at(*p);
            builder.line_to(x, y);
        }
        builder.close();
        builder.finish()
    }
}

/// Scenes as a client has them, drawn into images as frames place them:
/// each once for its version, the cells it's placed over, the client's
/// cell size and the colors its styles have.
#[derive(Debug, Default)]
pub struct Drawer {
    scenes: HashMap<SceneId, (u64, Spec)>,
    drawn: HashMap<SceneId, Drawn>,
    /// The id the next image gets, from the first the client keeps for
    /// scenes, above the editor's own images'.
    next: u64,
}

/// A scene drawn into an image: which image, and what for.
#[derive(Debug)]
struct Drawn {
    id: ImageId,
    version: u64,
    cols: u16,
    rows: u16,
    cell: (u16, u16),
    colors: Vec<[u8; 3]>,
}

/// A scene drawn as an image over part of the screen: where, and the
/// image placed there.
#[derive(Debug, Clone, Copy)]
pub struct Shown {
    pub placement: ScenePlacement,
    pub image: ImagePlacement,
}

/// What a frame's scenes need: the images to place, those drawn now (their
/// id, PNG and size in pixels), and those no longer wanted.
#[derive(Debug, Default)]
pub struct Drawing {
    pub shown: Vec<Shown>,
    pub drawn: Vec<(ImageId, Vec<u8>, u32, u32)>,
    pub gone: Vec<ImageId>,
}

impl Drawer {
    /// A drawer whose images' ids start at `first`.
    pub fn new(first: u64) -> Self {
        Self {
            next: first,
            ..Self::default()
        }
    }

    /// Keeps `scene` as it is now, for frames to place.
    pub fn add(&mut self, scene: SceneData) {
        if let Ok(spec) = serde_json::from_value::<Spec>(scene.spec) {
            self.scenes.insert(scene.id, (scene.version, spec));
        }
    }

    /// Draws the scenes `placements` show into images where they changed,
    /// at `cell` pixels a cell, in `theme`'s colors on `medium`.
    pub fn draw(
        &mut self,
        placements: &[ScenePlacement],
        cell: (u16, u16),
        theme: &Theme,
        medium: Medium,
    ) -> Drawing {
        let mut drawing = Drawing::default();
        for placement in placements {
            let Some((version, spec)) = self.scenes.get(&placement.id) else {
                continue;
            };
            let mut names = Vec::new();
            styles(&spec.items, &mut names);
            let colors: Vec<[u8; 3]> = names.iter().map(|n| color(theme, n, medium)).collect();
            let current = self.drawn.get(&placement.id).filter(|d| {
                d.version == *version
                    && d.cols == placement.cols
                    && d.rows == placement.rows
                    && d.cell == cell
                    && d.colors == colors
            });
            let id = if let Some(drawn) = current {
                drawn.id
            } else {
                let Some(png) = draw(spec, placement.cols, placement.rows, cell, theme, medium)
                else {
                    continue;
                };
                let id = ImageId(self.next);
                self.next += 1;
                let drawn = Drawn {
                    id,
                    version: *version,
                    cols: placement.cols,
                    rows: placement.rows,
                    cell,
                    colors,
                };
                if let Some(old) = self.drawn.insert(placement.id, drawn) {
                    drawing.gone.push(old.id);
                }
                let width = u32::from(placement.cols) * u32::from(cell.0);
                let height = u32::from(placement.rows) * u32::from(cell.1);
                drawing.drawn.push((id, png, width, height));
                id
            };
            drawing.shown.push(Shown {
                placement: *placement,
                image: ImagePlacement {
                    id,
                    rect: placement.rect,
                    col: placement.col,
                    row: placement.row,
                    cols: placement.cols,
                    rows: placement.rows,
                },
            });
        }
        drawing
    }

    /// The cells of scene `id` that hold its text, by column and row in the
    /// scene: the client shows them over its image.
    fn text_cells(&self, id: SceneId) -> HashSet<(i32, i32)> {
        fn add(items: &[Item], cells: &mut HashSet<(i32, i32)>) {
            for item in items {
                match item {
                    Item::Text {
                        at, text, align, ..
                    } => {
                        let (column, row, width) = Item::text_cells(*at, text, align.as_deref());
                        for x in column..column + width {
                            cells.insert((x, row));
                        }
                    }
                    Item::Group { items, .. } => add(items, cells),
                    _ => {}
                }
            }
        }
        let mut cells = HashSet::new();
        if let Some((_, spec)) = self.scenes.get(&id) {
            add(&spec.items, &mut cells);
        }
        cells
    }

    /// The screen cells `shown` covers that don't hold its scene's text:
    /// the ones to empty so its image shows, by column and row.
    pub fn uncovered(&self, shown: &Shown) -> Vec<(u16, u16)> {
        let text = self.text_cells(shown.placement.id);
        let p = shown.placement;
        let mut out = Vec::new();
        for y in p.rect.y..p.rect.y.saturating_add(p.rect.height) {
            let row = i32::from(p.row) + i32::from(y - p.rect.y);
            for x in p.rect.x..p.rect.x.saturating_add(p.rect.width) {
                let col = i32::from(p.col) + i32::from(x - p.rect.x);
                if !text.contains(&(col, row)) {
                    out.push((x, y));
                }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(items: &serde_json::Value) -> Spec {
        serde_json::from_value(serde_json::json!({ "alt": "test", "items": items })).unwrap()
    }

    #[test]
    fn a_scene_is_a_png_its_cells_big_drawn_in_its_theme() {
        let mut theme = Theme::default();
        theme.set(
            "chart.series.1",
            crate::theme::Entry::new(crate::theme::Style {
                fg: Some(Color::Rgb(0x10, 0x20, 0x30)),
                ..crate::theme::Style::default()
            }),
        );
        let drawn = spec(&serde_json::json!([
            { "kind": "rect", "at": [0, 0], "size": [1, 1], "fill": "chart.series.1" },
            { "kind": "text", "at": [1, 0], "text": "x", "style": "chart.label" },
        ]));
        let png = draw(&drawn, 2, 1, (10, 20), &theme, Medium::Tui).unwrap();
        let image = crate::image::Image::from_file_bytes(&png).unwrap();
        assert_eq!((image.width, image.height), (20, 20));
        let pixmap = Pixmap::decode_png(&png).unwrap();
        let filled = pixmap.pixel(5, 10).unwrap();
        assert_eq!(
            (filled.red(), filled.green(), filled.blue(), filled.alpha()),
            (0x10, 0x20, 0x30, 255)
        );
        assert_eq!(
            pixmap.pixel(15, 10).unwrap().alpha(),
            0,
            "text isn't drawn: the terminal shows it"
        );
        assert!(
            draw(&drawn, 1000, 1000, (10, 20), &theme, Medium::Tui).is_none(),
            "too big"
        );
    }

    #[test]
    fn a_group_clips_what_it_holds() {
        let theme = Theme::default();
        let clipped = spec(&serde_json::json!([
            { "kind": "group", "clip": [0, 0, 1, 1], "items": [
                { "kind": "rect", "at": [0, 0], "size": [2, 1], "fill": "chart.series.1" },
            ] },
        ]));
        let png = draw(&clipped, 2, 1, (10, 20), &theme, Medium::Tui).unwrap();
        let pixmap = Pixmap::decode_png(&png).unwrap();
        assert!(pixmap.pixel(5, 10).unwrap().alpha() > 0);
        assert_eq!(pixmap.pixel(15, 10).unwrap().alpha(), 0);
    }

    #[test]
    fn styles_are_listed_once() {
        let mut names = Vec::new();
        styles(
            &spec(&serde_json::json!([
                { "kind": "line", "points": [], "style": "a" },
                { "kind": "group", "items": [{ "kind": "dots", "points": [], "style": "a" }, { "kind": "area", "fill": "b" }] },
            ]))
            .items,
            &mut names,
        );
        assert_eq!(names, ["a", "b"]);
    }
}
