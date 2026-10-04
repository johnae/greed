//! A frame's grid of cells as what the GPU draws: rectangles for
//! backgrounds, lines and the cursor, and glyphs from the atlas. Each
//! shaped cluster is put at its own cell, so a glyph from a fallback font
//! or a ligature never pushes the rest of the line off the grid.

use bytemuck::{Pod, Zeroable};
use greed_core::CursorShape;
use greed_core::image::ImageId;
use greed_core::render::grid::Cell;
use greed_core::render::{Frame, ImagePlacement, Position, Rect};
use unicode_width::UnicodeWidthStr;

use crate::boxdraw;
use crate::color::{Look, Palette, Rgba, look};
use crate::text::{Atlas, Fonts, Full};

/// One quad on screen, in pixels from the top left.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Pod, Zeroable)]
pub struct Instance {
    pub pos: [f32; 2],
    pub size: [f32; 2],
    /// The atlas region, as 0-1 coordinates: left, top, right, bottom.
    pub uv: [f32; 4],
    pub color: [f32; 4],
    /// `RECT`, `MASK`, `COLOR` or `ROUND`.
    pub kind: u32,
}

/// A rectangle of one color.
pub const RECT: u32 = 0;
/// A glyph drawn in the text's color.
pub const MASK: u32 = 1;
/// A glyph with colors of its own, like an emoji.
pub const COLOR: u32 = 2;
/// A box with rounded corners: `uv[0]` their radius, `uv[1]` the width of
/// its outline, or 0 to fill it.
pub const ROUND: u32 = 3;

/// What one frame draws: the background, then the quads in order, then the
/// images over them.
pub struct Scene {
    pub background: Rgba,
    pub instances: Vec<Instance>,
    pub images: Vec<(ImageId, Instance)>,
}

/// Where each image goes, `COLOR` quads to draw with the image's own
/// texture: the part of it from its cell (`col`, `row`) on, stretched over
/// the cells it's placed on.
fn images(placements: &[ImagePlacement], cell_w: f32, cell_h: f32) -> Vec<(ImageId, Instance)> {
    placements
        .iter()
        .map(|p| {
            let (cols, rows) = (f32::from(p.cols.max(1)), f32::from(p.rows.max(1)));
            let instance = Instance {
                pos: [f32::from(p.rect.x) * cell_w, f32::from(p.rect.y) * cell_h],
                size: [
                    f32::from(p.rect.width) * cell_w,
                    f32::from(p.rect.height) * cell_h,
                ],
                uv: [
                    f32::from(p.col) / cols,
                    f32::from(p.row) / rows,
                    ((f32::from(p.col) + f32::from(p.rect.width)) / cols).min(1.0),
                    ((f32::from(p.row) + f32::from(p.rect.height)) / rows).min(1.0),
                ],
                color: [1.0; 4],
                kind: COLOR,
            };
            (p.id, instance)
        })
        .collect()
}

fn rect(x: f32, y: f32, w: f32, h: f32, color: Rgba) -> Instance {
    Instance {
        pos: [x, y],
        size: [w, h],
        uv: [0.0; 4],
        color,
        kind: RECT,
    }
}

/// What the window draws besides the grid's cells: images, and the floats
/// it gives a look of its own.
#[derive(Debug, Default)]
pub struct Chrome<'a> {
    pub images: &'a [ImagePlacement],
    /// Each float's text, which its border goes around one cell out.
    pub floats: Vec<Rect>,
    /// Floats with rounded corners and an outline instead of box lines.
    pub rounded: bool,
    /// Floats casting a soft shadow on what's under them.
    pub shadows: bool,
}

impl<'a> Chrome<'a> {
    /// What `frame` has besides its cells, looking as its `gui-rounded` and
    /// `gui-shadows` options say (both on unless "false").
    pub fn of(frame: &'a Frame) -> Self {
        let on = |name: &str| frame.gui.get(name).is_none_or(|v| v != "false");
        Chrome {
            images: &frame.images,
            floats: frame.floats.iter().map(|f| f.rect).collect(),
            rounded: on("gui-rounded"),
            shadows: on("gui-shadows"),
        }
    }
}

/// `grid` drawn with `fonts`, the cursor at `cursor` in `shape` if given,
/// with `chrome`'s images over it and its looks. Fails when the atlas fills
/// up; clear it and build again.
pub fn build(
    grid: &[Vec<Cell>],
    cursor: Option<(Position, CursorShape)>,
    chrome: &Chrome,
    fonts: &mut Fonts,
    atlas: &mut Atlas,
    palette: &Palette,
) -> Result<Scene, Full> {
    let (cw, ch) = (fonts.cell_w, fonts.cell_h);
    let background = palette.background();
    let mut looks: Vec<Vec<Look>> = grid
        .iter()
        .map(|row| row.iter().map(|cell| look(&cell.style, palette)).collect())
        .collect();
    let heights = row_heights(grid);
    // The cursor takes the cells of what it's on: a scaled character's are
    // wider and taller.
    let cursor = cursor.map(|(at, shape)| {
        let (col, row) = (usize::from(at.col), usize::from(at.row));
        let cell = grid.get(row).and_then(|r| r.get(col));
        let k = cell.map_or(1, |c| usize::from(c.scale.max(1)));
        let wide = cell.map_or(1, |c| c.text.width().max(1));
        (shape, col, row, wide * k, k)
    });
    // A block cursor shows its cells reversed.
    if let Some((CursorShape::Block, col, row, w, h)) = cursor {
        for line in looks.iter_mut().skip(row).take(h) {
            for l in line.iter_mut().skip(col).take(w) {
                std::mem::swap(&mut l.fg, &mut l.bg);
            }
        }
    }
    // Floats are boxes over what's under them: its backgrounds, then their
    // shadows, fills and outlines, then the backgrounds inside them (a
    // picker's current line, a title over the outline).
    let size = (cw, ch);
    let boxes = float_boxes(chrome, &looks, size);
    let regions = regions(grid, chrome);
    let mut instances = Vec::new();
    let fill = |pass: Pass, out: &mut Vec<Instance>| {
        backgrounds(&looks, &regions, pass, size, background, out);
    };
    fill(Pass::Under, &mut instances);
    let rounded = chrome.rounded;
    for b in &boxes {
        b.under(chrome, &mut instances);
        if rounded {
            b.outline(&mut instances);
        }
    }
    fill(Pass::Floats { border: !rounded }, &mut instances);
    let border: Vec<Vec<bool>> = regions
        .iter()
        .map(|row| {
            row.iter()
                .map(|&r| rounded && r == Region::Border)
                .collect()
        })
        .collect();
    // Underlines and strikethroughs, under the glyphs, on each row's shared
    // baseline. Rows under scaled text have none of their own.
    let thickness = (ch / 16.0).round().max(1.0);
    for (y, row) in looks.iter().enumerate() {
        let Some(height) = heights[y] else { continue };
        let top = y as f32 * ch;
        let (baseline, bottom) = (height as f32 * fonts.baseline, height as f32 * ch);
        for (x, l) in row.iter().enumerate() {
            if let Some((_, color)) = l.underline {
                let under = (top + baseline + thickness).min(top + bottom - thickness);
                instances.push(rect(x as f32 * cw, under, cw, thickness, color));
            }
            if l.strikethrough {
                let middle = top + (baseline * 0.65).round();
                instances.push(rect(x as f32 * cw, middle, cw, thickness, l.fg));
            }
        }
    }
    for (y, (row, row_looks)) in grid.iter().zip(&looks).enumerate() {
        if let Some(height) = heights[y] {
            text_row(
                row,
                row_looks,
                (y, height),
                &border[y],
                fonts,
                atlas,
                &mut instances,
            )?;
        }
    }
    if let Some((shape, col, row, w, h)) = cursor {
        let (x, y) = (col as f32 * cw, row as f32 * ch);
        let (w, h) = (w as f32 * cw, h as f32 * ch);
        let color = looks
            .get(row)
            .and_then(|r| r.get(col))
            .map_or(background, |l| l.fg);
        let line = (cw / 8.0).round().max(1.0);
        match shape {
            CursorShape::Block => {}
            CursorShape::Bar => instances.push(rect(x, y, line, h, color)),
            CursorShape::Underline => instances.push(rect(x, y + h - line, w, line, color)),
        }
    }
    Ok(Scene {
        background,
        instances,
        images: images(chrome.images, cw, ch),
    })
}

/// A run of cells shaped together: the text, and the cell each byte starts.
struct Run {
    text: String,
    /// The byte offset of each cell's text, with its column, in order.
    starts: Vec<(usize, usize)>,
    bold: bool,
    italic: bool,
    scale: u8,
}

/// The glyphs of row `y`, `height` rows tall, in runs of one weight, slant
/// and size so ligatures and shaping work across them; box-drawing
/// characters as rectangles, except in cells `outlined` says a float's
/// rounded outline takes. Text of every size sits on one baseline.
fn text_row(
    row: &[Cell],
    looks: &[Look],
    (y, height): (usize, usize),
    outlined: &[bool],
    fonts: &mut Fonts,
    atlas: &mut Atlas,
    out: &mut Vec<Instance>,
) -> Result<(), Full> {
    let (cw, ch) = (fonts.cell_w, fonts.cell_h);
    let top = y as f32 * ch;
    let baseline = top + height as f32 * fonts.baseline;
    let mut run: Option<Run> = None;
    for (x, cell) in row.iter().enumerate() {
        if cell.text.is_empty() {
            continue;
        }
        let l = looks[x];
        let k = f32::from(cell.scale.max(1));
        let mut chars = cell.text.chars();
        let one = match (chars.next(), chars.next()) {
            (Some(c), None) => Some(c),
            _ => None,
        };
        if let Some(cap) = one.and_then(|c| round_cap(c, x as f32 * cw, top, cw * k, ch * k, l.fg))
        {
            if let Some(done) = run.take() {
                shape_run(&done, looks, baseline, fonts, atlas, out)?;
            }
            out.push(cap);
            continue;
        }
        if let Some(rects) = one.and_then(|c| boxdraw::rects(c, cw * k, ch * k)) {
            if let Some(done) = run.take() {
                shape_run(&done, looks, baseline, fonts, atlas, out)?;
            }
            if !outlined.get(x).copied().unwrap_or(false) {
                for r in rects {
                    out.push(rect(x as f32 * cw + r.x, top + r.y, r.w, r.h, l.fg));
                }
            }
            continue;
        }
        if run
            .as_ref()
            .is_some_and(|r| r.bold != l.bold || r.italic != l.italic || r.scale != cell.scale)
            && let Some(done) = run.take()
        {
            shape_run(&done, looks, baseline, fonts, atlas, out)?;
        }
        let r = run.get_or_insert_with(|| Run {
            text: String::new(),
            starts: Vec::new(),
            bold: l.bold,
            italic: l.italic,
            scale: cell.scale,
        });
        r.starts.push((r.text.len(), x));
        r.text.push_str(&cell.text);
    }
    if let Some(done) = run {
        shape_run(&done, looks, baseline, fonts, atlas, out)?;
    }
    Ok(())
}

/// `run`'s glyphs, each cluster at its cell, on the baseline at `baseline`
/// pixels down.
fn shape_run(
    run: &Run,
    looks: &[Look],
    baseline: f32,
    fonts: &mut Fonts,
    atlas: &mut Atlas,
    out: &mut Vec<Instance>,
) -> Result<(), Full> {
    let (glyphs, _) = fonts.shape(&run.text, run.bold, run.italic, run.scale);
    let size = atlas.size as f32;
    // Where each cluster starts in the shaped line, so marks drawn after
    // their base keep their place.
    let mut cluster: Option<(usize, f32)> = None;
    for glyph in &glyphs {
        let at = run.starts.partition_point(|&(byte, _)| byte <= glyph.start);
        let Some(&(_, col)) = run.starts.get(at.saturating_sub(1)) else {
            continue;
        };
        let cluster_x = match cluster {
            Some((start, x)) if start == glyph.start => x,
            _ => {
                cluster = Some((glyph.start, glyph.x));
                glyph.x
            }
        };
        let offset = col as f32 * fonts.cell_w - cluster_x;
        let physical = glyph.physical((offset, baseline), 1.0);
        let Some(slot) = atlas.slot(physical.cache_key, fonts)? else {
            continue;
        };
        let (x, y) = (
            (physical.x + slot.left) as f32,
            (physical.y - slot.top) as f32,
        );
        out.push(Instance {
            pos: [x, y],
            size: [slot.w as f32, slot.h as f32],
            uv: [
                slot.x as f32 / size,
                slot.y as f32 / size,
                (slot.x + slot.w) as f32 / size,
                (slot.y + slot.h) as f32 / size,
            ],
            color: looks[col].fg,
            kind: if slot.color { COLOR } else { MASK },
        });
    }
    Ok(())
}

/// How many rows each row's text takes, as many as its largest scale; `None`
/// for rows that text above them covers.
fn row_heights(grid: &[Vec<Cell>]) -> Vec<Option<usize>> {
    let mut covered_until = 0;
    grid.iter()
        .enumerate()
        .map(|(y, row)| {
            if y < covered_until {
                return None;
            }
            let height = row
                .iter()
                .map(|c| usize::from(c.scale.max(1)))
                .max()
                .unwrap_or(1);
            covered_until = y + height;
            Some(height)
        })
        .collect()
}

/// A box with rounded corners, `ROUND`, of `color`.
fn rounded(x: f32, y: f32, w: f32, h: f32, radius: f32, outline: f32, color: Rgba) -> Instance {
    Instance {
        pos: [x, y],
        size: [w, h],
        uv: [radius, outline, radius, outline],
        color,
        kind: ROUND,
    }
}

/// A float as the window draws it: where its box goes in pixels (through
/// the middle of its border cells when rounded, around them when not), and
/// its colors.
struct FloatBox {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    radius: f32,
    line: f32,
    fill: Rgba,
    border: Rgba,
}

impl FloatBox {
    /// Its shadow, if `chrome` has them, and its fill over whatever the
    /// shadow fell on.
    fn under(&self, chrome: &Chrome, out: &mut Vec<Instance>) {
        if chrome.shadows {
            // Layers a little bigger and fainter each, lower than the box,
            // make a soft edge.
            for i in 1..=4 {
                let grow = i as f32 * self.line * 1.5;
                let alpha = 0.30 - i as f32 * 0.06;
                out.push(rounded(
                    self.x - grow,
                    self.y - grow + self.line * 3.0,
                    self.w + 2.0 * grow,
                    self.h + 2.0 * grow,
                    self.radius + grow,
                    0.0,
                    [0.0, 0.0, 0.0, alpha],
                ));
            }
        }
        out.push(self.shape(0.0, self.fill));
    }

    /// Its rounded outline, in its border's color.
    fn outline(&self, out: &mut Vec<Instance>) {
        out.push(self.shape(self.line, self.border));
    }

    fn shape(&self, outline: f32, color: Rgba) -> Instance {
        rounded(self.x, self.y, self.w, self.h, self.radius, outline, color)
    }
}

/// The boxes of `chrome`'s floats, colored as their cells are.
fn float_boxes(chrome: &Chrome, looks: &[Vec<Look>], (cw, ch): (f32, f32)) -> Vec<FloatBox> {
    let line = (ch / 16.0).round().max(1.0);
    chrome
        .floats
        .iter()
        .filter_map(|r| {
            let (x, y) = (usize::from(r.x), usize::from(r.y));
            let fill = looks.get(y)?.get(x)?.bg;
            let border = looks.get(y)?.get(x.checked_sub(1)?)?.fg;
            // The border is the cells around the text.
            let (left, top) = ((f32::from(r.x) - 1.0) * cw, (f32::from(r.y) - 1.0) * ch);
            let (w, h) = (
                (f32::from(r.width) + 2.0) * cw,
                (f32::from(r.height) + 2.0) * ch,
            );
            let (dx, dy, radius) = if chrome.rounded {
                (cw / 2.0, ch / 2.0, cw.min(ch) * 0.8)
            } else {
                (0.0, 0.0, 0.0)
            };
            Some(FloatBox {
                x: left + dx,
                y: top + dy,
                w: w - 2.0 * dx,
                h: h - 2.0 * dy,
                radius,
                line,
                fill,
                border,
            })
        })
        .collect()
}

/// Where a cell is, for floats drawn as boxes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Region {
    Outside,
    /// In a float's border, the cells around its text.
    Border,
    Inside,
}

/// Each cell's region, for `chrome`'s floats.
fn regions(grid: &[Vec<Cell>], chrome: &Chrome) -> Vec<Vec<Region>> {
    let mut regions: Vec<Vec<Region>> = grid
        .iter()
        .map(|row| vec![Region::Outside; row.len()])
        .collect();
    for r in &chrome.floats {
        let (x, y) = (usize::from(r.x), usize::from(r.y));
        let (w, h) = (usize::from(r.width), usize::from(r.height));
        let (Some(left), Some(top)) = (x.checked_sub(1), y.checked_sub(1)) else {
            continue;
        };
        for (row, cells) in regions.iter_mut().enumerate().skip(top).take(h + 2) {
            let edge = row == top || row == y + h;
            for (col, cell) in cells.iter_mut().enumerate().skip(left).take(w + 2) {
                // Text in the border, like a title, sits on the float's
                // color over its outline.
                let line = grid[row][col]
                    .text
                    .chars()
                    .next()
                    .is_none_or(|c| boxdraw::rects(c, 1.0, 1.0).is_some());
                *cell = if (edge || col == left || col == x + w) && line {
                    Region::Border
                } else {
                    Region::Inside
                };
            }
        }
    }
    regions
}

/// Which backgrounds a pass draws.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Pass {
    /// Outside floats, where the window's own color needs no drawing.
    Under,
    /// Inside floats, every cell, so it covers their fill, outline and
    /// shadow; with `border`, their border cells too.
    Floats { border: bool },
}

impl Pass {
    /// Whether a cell in `region` is drawn, and if so, even in the window's
    /// own color.
    fn draws(self, region: Region) -> Option<bool> {
        match (self, region) {
            (Pass::Under, Region::Outside) => Some(false),
            (Pass::Floats { .. }, Region::Inside)
            | (Pass::Floats { border: true }, Region::Border) => Some(true),
            _ => None,
        }
    }
}

/// The backgrounds `pass` draws, a rectangle for each run of one color.
fn backgrounds(
    looks: &[Vec<Look>],
    regions: &[Vec<Region>],
    pass: Pass,
    (cw, ch): (f32, f32),
    background: Rgba,
    out: &mut Vec<Instance>,
) {
    for (y, row) in looks.iter().enumerate() {
        let top = y as f32 * ch;
        let bgs: Vec<Option<Rgba>> = row
            .iter()
            .zip(&regions[y])
            .map(|(l, &r)| match pass.draws(r) {
                Some(always) if always || l.bg != background => Some(l.bg),
                _ => None,
            })
            .collect();
        let mut x = 0;
        for same in bgs.chunk_by(|a, b| a == b) {
            let (left, w) = (x as f32 * cw, same.len() as f32 * cw);
            x += same.len();
            if let Some(bg) = same[0] {
                out.push(rect(left, top, w, ch, bg));
            }
        }
    }
}

/// The round ends Powerline fonts have for pills (U+E0B6 on the left, U+E0B4
/// on the right) as half circles in `color`, drawn crisp at any size rather
/// than from whatever font has them. The box reaches into the cell beside,
/// the pill's own, which is the same color.
fn round_cap(c: char, x: f32, top: f32, cw: f32, ch: f32, color: Rgba) -> Option<Instance> {
    let radius = cw.min(ch / 2.0);
    match c {
        '\u{e0b6}' => Some(rounded(x, top, 2.0 * cw, ch, radius, 0.0, color)),
        '\u{e0b4}' => Some(rounded(x - cw, top, 2.0 * cw, ch, radius, 0.0, color)),
        _ => None,
    }
}
