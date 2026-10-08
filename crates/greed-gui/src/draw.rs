//! A frame's grid of cells as what the GPU draws: rectangles for
//! backgrounds, lines and the cursor, and glyphs from the atlas. Each
//! shaped cluster is put at its own cell, so a glyph from a fallback font
//! or a ligature never pushes the rest of the line off the grid.

use bytemuck::{Pod, Zeroable};
use cosmic_text::PhysicalGlyph;
use greed_core::CursorShape;
use greed_core::image::ImageId;
use greed_core::render::grid::Cell;
use greed_core::render::{Frame, ImagePlacement, Position, Rect};
use greed_core::theme::{Checkbox, Medium, Style};
use unicode_width::UnicodeWidthStr;

use crate::boxdraw;
use crate::color::{Look, Palette, Rgba, look};
use crate::columns::{Columns, lay_out, style_of};
use crate::text::{Atlas, Fonts, Full, Slot, TextStyle};

/// One quad on screen, in pixels from the top left.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Pod, Zeroable)]
pub struct Instance {
    pub pos: [f32; 2],
    pub size: [f32; 2],
    /// The atlas region, as 0-1 coordinates: left, top, right, bottom.
    pub uv: [f32; 4],
    pub color: [f32; 4],
    /// `RECT`, `MASK`, `COLOR`, `ROUND` or `SHADOW`.
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
/// A soft shadow: a box with corners `uv[0]` round, inset `uv[1]` from the
/// quad's edges and fading out over `uv[1]` either side of its edge.
pub const SHADOW: u32 = 4;

/// What one frame draws: the background, then the quads in order, then the
/// images over them.
pub struct Scene {
    pub background: Rgba,
    pub instances: Vec<Instance>,
    pub images: Vec<(ImageId, Instance)>,
    /// Where each row's cells went, for the mouse.
    pub columns: Columns,
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
    /// How text looks where nothing says otherwise (`ui.text`): its
    /// background is the window's, behind every cell.
    pub text: Style,
}

impl<'a> Chrome<'a> {
    /// What `frame` has besides its cells, its floats looking as the theme's
    /// `ui.float` says for the window (`rounded`, `shadow`).
    pub fn of(frame: &'a Frame) -> Self {
        let float = frame.theme.style("ui.float", Medium::Gui);
        Chrome {
            images: &frame.images,
            // A float without a border is plain cells, with no box drawn around it.
            floats: frame.bordered_floats().collect(),
            rounded: float.rounded == Some(true),
            shadows: float.shadow == Some(true),
            text: frame.theme.style("ui.text", Medium::Gui),
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
    let background = look(&chrome.text, palette).bg;
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
    // Floats are boxes over what's under them: its backgrounds (going on
    // under rounded borders), then every float's shadow, so none falls on
    // another float, then their fills and outlines, then the backgrounds
    // inside them (a picker's current line, a title over the outline).
    let regions = regions(grid, chrome);
    let columns = lay_out(grid, &looks, &snaps(grid, &regions), fonts);
    let boxes = float_boxes(chrome, &looks, (cw, ch));
    let mut instances = Vec::new();
    let fill = |pass: Pass, out: &mut Vec<Instance>| {
        backgrounds(&looks, &regions, pass, &columns, ch, background, out);
    };
    fill(Pass::Under, &mut instances);
    let rounded = chrome.rounded;
    if rounded {
        beneath_borders(
            &looks,
            &regions,
            &chrome.floats,
            &columns,
            ch,
            background,
            &mut instances,
        );
    }
    float_shapes(&boxes, chrome, &mut instances);
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
            let (left, w) = columns.span(y, x, x + 1);
            if let Some((_, color)) = l.underline {
                let under = (top + baseline + thickness).min(top + bottom - thickness);
                instances.push(rect(left, under, w, thickness, color));
            }
            if l.strikethrough {
                let middle = top + (baseline * 0.65).round();
                instances.push(rect(left, middle, w, thickness, l.fg));
            }
        }
    }
    for (y, (row, row_looks)) in grid.iter().zip(&looks).enumerate() {
        if let Some(height) = heights[y] {
            let at = RowAt {
                y,
                height,
                columns: &columns,
                outlined: &border[y],
            };
            text_row(row, row_looks, &at, fonts, atlas, &mut instances)?;
        }
    }
    if let Some((shape, col, row, w, h)) = cursor {
        let (x, w) = columns.span(row, col, col + w);
        let (y, h) = (row as f32 * ch, h as f32 * ch);
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
        columns,
    })
}

/// A run of cells shaped together: the text, and the cell each byte starts.
struct Run {
    text: String,
    /// The byte offset of each cell's text, with its column, in order.
    starts: Vec<(usize, usize)>,
    style: TextStyle,
}

/// Where a row's text goes: row `y`, `height` rows tall, its cells placed
/// as `columns` says, and which cells a float's rounded outline takes.
struct RowAt<'a> {
    y: usize,
    height: usize,
    columns: &'a Columns,
    outlined: &'a [bool],
}

/// The glyphs of a row, in runs of one weight, slant, size and font so
/// ligatures and shaping work across them; box-drawing characters as
/// rectangles, except where a float's outline is. Text of every size sits
/// on one baseline.
fn text_row(
    row: &[Cell],
    looks: &[Look],
    at: &RowAt,
    fonts: &mut Fonts,
    atlas: &mut Atlas,
    out: &mut Vec<Instance>,
) -> Result<(), Full> {
    let (cw, ch) = (fonts.cell_w, fonts.cell_h);
    let top = at.y as f32 * ch;
    let baseline = top + at.height as f32 * fonts.baseline;
    let mut run: Option<Run> = None;
    for (x, cell) in row.iter().enumerate() {
        let l = looks[x];
        // A checkbox goes over its cells, in place of their text.
        if let Some(kind) = l.checkbox {
            if let Some(done) = run.take() {
                shape_run(&done, at, looks, baseline, fonts, atlas, out)?;
            }
            if x == 0 || looks[x - 1].checkbox != Some(kind) {
                let end = (x..looks.len())
                    .find(|&e| looks[e].checkbox != Some(kind))
                    .unwrap_or(looks.len());
                checkbox(
                    kind,
                    at.columns.span(at.y, x, end),
                    at,
                    &l,
                    fonts,
                    atlas,
                    out,
                )?;
            }
            continue;
        }
        if cell.text.is_empty() {
            continue;
        }
        let left = at.columns.x(at.y, x);
        let k = f32::from(cell.scale.max(1));
        let mut chars = cell.text.chars();
        let one = match (chars.next(), chars.next()) {
            (Some(c), None) => Some(c),
            _ => None,
        };
        if let Some(cap) = one.and_then(|c| round_cap(c, left, top, cw * k, ch * k, l.fg)) {
            if let Some(done) = run.take() {
                shape_run(&done, at, looks, baseline, fonts, atlas, out)?;
            }
            out.push(cap);
            continue;
        }
        if let Some(rects) = one.and_then(|c| boxdraw::rects(c, cw * k, ch * k)) {
            if let Some(done) = run.take() {
                shape_run(&done, at, looks, baseline, fonts, atlas, out)?;
            }
            if !at.outlined.get(x).copied().unwrap_or(false) {
                for r in rects {
                    out.push(rect(left + r.x, top + r.y, r.w, r.h, l.fg));
                }
            }
            continue;
        }
        let style = style_of(cell, &l);
        if run.as_ref().is_some_and(|r| r.style != style)
            && let Some(done) = run.take()
        {
            shape_run(&done, at, looks, baseline, fonts, atlas, out)?;
        }
        let r = run.get_or_insert_with(|| Run {
            text: String::new(),
            starts: Vec::new(),
            style,
        });
        r.starts.push((r.text.len(), x));
        r.text.push_str(&cell.text);
    }
    if let Some(done) = run {
        shape_run(&done, at, looks, baseline, fonts, atlas, out)?;
    }
    Ok(())
}

/// `run`'s glyphs, each cluster where its cell's text goes, on the baseline
/// at `baseline` pixels down.
fn shape_run(
    run: &Run,
    at: &RowAt,
    looks: &[Look],
    baseline: f32,
    fonts: &mut Fonts,
    atlas: &mut Atlas,
    out: &mut Vec<Instance>,
) -> Result<(), Full> {
    let (glyphs, _) = fonts.shape(&run.text, run.style);
    let size = atlas.size as f32;
    // Where each cluster starts in the shaped line, so marks drawn after
    // their base keep their place.
    let mut cluster: Option<(usize, f32)> = None;
    for glyph in &glyphs {
        let i = run.starts.partition_point(|&(byte, _)| byte <= glyph.start);
        let Some(&(_, col)) = run.starts.get(i.saturating_sub(1)) else {
            continue;
        };
        let cluster_x = match cluster {
            Some((start, x)) if start == glyph.start => x,
            _ => {
                cluster = Some((glyph.start, glyph.x));
                glyph.x
            }
        };
        let offset = at.columns.x(at.y, col) - cluster_x;
        let physical = glyph.physical((offset, baseline), 1.0);
        if let Some(slot) = atlas.slot(physical.cache_key, fonts)? {
            out.push(glyph_quad(&physical, &slot, size, looks[col].fg));
        }
    }
    Ok(())
}

/// The quad that draws a glyph from its place in the atlas, in `color`
/// unless it has colors of its own.
fn glyph_quad(physical: &PhysicalGlyph, slot: &Slot, size: f32, color: Rgba) -> Instance {
    Instance {
        pos: [
            (physical.x + slot.left) as f32,
            (physical.y - slot.top) as f32,
        ],
        size: [slot.w as f32, slot.h as f32],
        uv: [
            slot.x as f32 / size,
            slot.y as f32 / size,
            (slot.x + slot.w) as f32 / size,
            (slot.y + slot.h) as f32 / size,
        ],
        color,
        kind: if slot.color { COLOR } else { MASK },
    }
}

/// A checkbox over the cells from `left` across `width`: an outlined box,
/// or for a checked one a filled box with a tick in the background's color,
/// or for a choice a ring, with a dot in it when chosen.
fn checkbox(
    kind: Checkbox,
    (left, width): (f32, f32),
    at: &RowAt,
    look: &Look,
    fonts: &mut Fonts,
    atlas: &mut Atlas,
    out: &mut Vec<Instance>,
) -> Result<(), Full> {
    let ch = fonts.cell_h;
    let side = (ch * 0.62).min(width);
    let (x, y) = (
        left + (width - side) / 2.0,
        at.y as f32 * ch + (ch - side) / 2.0,
    );
    let radius = side * 0.22;
    let line = (ch / 14.0).round().max(1.0);
    match kind {
        Checkbox::Empty => {
            out.push(rounded(x, y, side, side, radius, line, look.fg));
            return Ok(());
        }
        Checkbox::Choice | Checkbox::Chosen => {
            out.push(rounded(x, y, side, side, side / 2.0, line, look.fg));
            if kind == Checkbox::Chosen {
                let dot = side * 0.45;
                let inset = (side - dot) / 2.0;
                out.push(rounded(
                    x + inset,
                    y + inset,
                    dot,
                    dot,
                    dot / 2.0,
                    0.0,
                    look.fg,
                ));
            }
            return Ok(());
        }
        Checkbox::Checked => {}
    }
    out.push(rounded(x, y, side, side, radius, 0.0, look.fg));
    let bold = TextStyle {
        bold: true,
        ..TextStyle::default()
    };
    let (glyphs, _) = fonts.shape("✓", bold);
    let atlas_size = atlas.size as f32;
    for glyph in &glyphs {
        // In the middle of the box: a tick is about 0.7 of the font's size.
        let baseline = y + side / 2.0 + 0.35 * glyph.font_size;
        let physical = glyph.physical((x + (side - glyph.w) / 2.0 - glyph.x, baseline), 1.0);
        if let Some(slot) = atlas.slot(physical.cache_key, fonts)? {
            out.push(glyph_quad(&physical, &slot, atlas_size, look.bg));
        }
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

/// The floats' boxes: every shadow first, so none falls on another float,
/// then each fill, and its outline when rounded.
fn float_shapes(boxes: &[FloatBox], chrome: &Chrome, out: &mut Vec<Instance>) {
    if chrome.shadows {
        out.extend(boxes.iter().map(FloatBox::shadow));
    }
    for b in boxes {
        out.push(b.fill());
        if chrome.rounded {
            b.outline(out);
        }
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
    /// How far its shadow fades out.
    blur: f32,
    fill: Rgba,
    border: Rgba,
}

impl FloatBox {
    /// Its shadow: one soft edge, a little lower than the box, so it falls
    /// mostly below it, as from a light above.
    fn shadow(&self) -> Instance {
        let blur = self.blur;
        Instance {
            pos: [self.x - blur, self.y - blur + blur / 2.0],
            size: [self.w + 2.0 * blur, self.h + 2.0 * blur],
            uv: [self.radius, blur, self.radius, blur],
            color: [0.0, 0.0, 0.0, 0.45],
            kind: SHADOW,
        }
    }

    /// Its fill, over whatever shadows fell on it.
    fn fill(&self) -> Instance {
        self.shape(0.0, self.fill)
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
                blur: ch * 0.6,
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
    /// Text in a float's border, like its title.
    Title,
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
                *cell = match (edge || col == left || col == x + w, line) {
                    (true, true) => Region::Border,
                    (true, false) => Region::Title,
                    (false, _) => Region::Inside,
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
            (Pass::Floats { .. }, Region::Inside | Region::Title)
            | (Pass::Floats { border: true }, Region::Border) => Some(true),
            _ => None,
        }
    }
}

/// How a run of cells' background is drawn.
#[derive(Debug, Clone, Copy, PartialEq)]
enum Shape {
    Block,
    /// A box with rounded corners inside the cells, for a style that asks
    /// for one, like a key cap.
    Badge,
    /// A pill as tall as the text, for a title on a rounded float's outline.
    Title,
}

/// The backgrounds `pass` draws, a rectangle for each run of one color, or
/// a badge or pill over the background beside it.
fn backgrounds(
    looks: &[Vec<Look>],
    regions: &[Vec<Region>],
    pass: Pass,
    columns: &Columns,
    ch: f32,
    background: Rgba,
    out: &mut Vec<Instance>,
) {
    let titled = pass == Pass::Floats { border: false };
    for (y, row) in looks.iter().enumerate() {
        let top = y as f32 * ch;
        let bgs: Vec<Option<(Rgba, Shape)>> = row
            .iter()
            .zip(&regions[y])
            .map(|(l, &r)| match pass.draws(r) {
                Some(always) if always || l.bg != background => {
                    let shape = if l.badge {
                        Shape::Badge
                    } else if titled && r == Region::Title {
                        Shape::Title
                    } else {
                        Shape::Block
                    };
                    Some((l.bg, shape))
                }
                _ => None,
            })
            .collect();
        let mut x = 0;
        for same in bgs.chunk_by(|a, b| a == b) {
            let (left, w) = columns.span(y, x, x + same.len());
            let beside = x
                .checked_sub(1)
                .and_then(|b| bgs[b])
                .filter(|b| b.1 == Shape::Block);
            x += same.len();
            match same[0] {
                Some((bg, Shape::Block)) => out.push(rect(left, top, w, ch, bg)),
                Some((bg, shape)) => {
                    if let Some((under, _)) = beside {
                        out.push(rect(left, top, w, ch, under));
                    }
                    out.push(badge(left, top, w, ch, shape == Shape::Title, bg));
                }
                None => {}
            }
        }
    }
}

/// Under the border cells of rounded floats, whose box goes through their
/// middle, what's beside the float on the same row: the floats took the
/// place of those cells, and a code block's color, say, should go on
/// behind the border.
fn beneath_borders(
    looks: &[Vec<Look>],
    regions: &[Vec<Region>],
    floats: &[Rect],
    columns: &Columns,
    ch: f32,
    background: Rgba,
    out: &mut Vec<Instance>,
) {
    for r in floats {
        let (x0, y0) = (usize::from(r.x), usize::from(r.y));
        let (Some(left), Some(top)) = (x0.checked_sub(1), y0.checked_sub(1)) else {
            continue;
        };
        let (right, bottom) = (x0 + usize::from(r.width), y0 + usize::from(r.height));
        for (y, row) in looks.iter().enumerate().take(bottom + 1).skip(top) {
            let outside =
                |x: usize| (regions[y].get(x) == Some(&Region::Outside)).then(|| row[x].bg);
            let color = left
                .checked_sub(1)
                .and_then(outside)
                .or_else(|| outside(right + 1))
                .unwrap_or(background);
            if color == background {
                continue;
            }
            let edge = y == top || y == bottom;
            for x in (left..=right.min(row.len().saturating_sub(1)))
                .filter(|&x| edge || x == left || x == right)
            {
                let (cx, w) = columns.span(y, x, x + 1);
                out.push(rect(cx, y as f32 * ch, w, ch, color));
            }
        }
    }
}

/// A badge behind text from `x` to `x + w` in a row at `top`: a box with
/// rounded corners a little inside its cells, so badges side by side stay
/// apart; or for a `title`, a pill with round ends.
fn badge(x: f32, top: f32, w: f32, ch: f32, title: bool, color: Rgba) -> Instance {
    let (h, gap, round) = if title {
        (ch * 0.84, 0.0, 0.5)
    } else {
        (ch * 0.8, ch * 0.02, 0.3)
    };
    let w = w - 2.0 * gap;
    rounded(
        x + gap,
        top + (ch - h) / 2.0,
        w,
        h,
        w.min(h) * round,
        0.0,
        color,
    )
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

/// Where a row's flowing prose must leave off and its cells go back to
/// their columns: where it goes into or out of a float, and at box-drawing
/// characters, the borders between panes and panels.
fn snaps(grid: &[Vec<Cell>], regions: &[Vec<Region>]) -> Vec<Vec<bool>> {
    grid.iter()
        .zip(regions)
        .map(|(row, regions)| {
            row.iter()
                .enumerate()
                .map(|(x, cell)| {
                    let border = cell
                        .text
                        .chars()
                        .next()
                        .is_some_and(|c| boxdraw::rects(c, 1.0, 1.0).is_some());
                    border || (x > 0 && regions[x] != regions[x - 1])
                })
                .collect()
        })
        .collect()
}
