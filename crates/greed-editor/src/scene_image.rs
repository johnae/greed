//! Scenes drawn as images, for terminals with kitty graphics: each item in
//! pixels at the terminal's cell size, on a clear background, so the image
//! goes under the text. Text items aren't drawn: the terminal shows them,
//! as the cells under the scene hold them.

use greed_core::scene::{Item, Point, Spec};
use greed_core::theme::{Color, Medium, Theme};
use tiny_skia::{FillRule, Mask, Paint, PathBuilder, Pixmap, Stroke, Transform};

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

/// The color of style `name` in `theme`: its foreground.
pub fn color(theme: &Theme, name: &str) -> [u8; 3] {
    match theme.style(name, Medium::Tui).fg {
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
pub fn draw(spec: &Spec, cols: u16, rows: u16, cell: (u16, u16), theme: &Theme) -> Option<Vec<u8>> {
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
}

impl Canvas<'_> {
    /// A point in cells, in pixels.
    fn at(&self, p: Point) -> (f32, f32) {
        (p[0] * self.cw, p[1] * self.ch)
    }

    fn paint(&self, style: Option<&String>, opacity: Option<f32>) -> Option<Paint<'static>> {
        let [r, g, b] = color(self.theme, style?);
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
            greed_core::theme::Entry::new(greed_core::theme::Style {
                fg: Some(Color::Rgb(0x10, 0x20, 0x30)),
                ..greed_core::theme::Style::default()
            }),
        );
        let drawn = spec(&serde_json::json!([
            { "kind": "rect", "at": [0, 0], "size": [1, 1], "fill": "chart.series.1" },
            { "kind": "text", "at": [1, 0], "text": "x", "style": "chart.label" },
        ]));
        let png = draw(&drawn, 2, 1, (10, 20), &theme).unwrap();
        let image = greed_core::image::Image::from_file_bytes(&png).unwrap();
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
            draw(&drawn, 1000, 1000, (10, 20), &theme).is_none(),
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
        let png = draw(&clipped, 2, 1, (10, 20), &theme).unwrap();
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
