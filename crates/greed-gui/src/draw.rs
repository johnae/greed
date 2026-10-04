//! A frame's grid of cells as what the GPU draws: rectangles for
//! backgrounds, lines and the cursor, and glyphs from the atlas. Each
//! shaped cluster is put at its own cell, so a glyph from a fallback font
//! or a ligature never pushes the rest of the line off the grid.

use bytemuck::{Pod, Zeroable};
use greed_core::CursorShape;
use greed_core::render::Position;
use greed_core::render::grid::Cell;

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
    /// `RECT`, `MASK` or `COLOR`.
    pub kind: u32,
}

/// A rectangle of one color.
pub const RECT: u32 = 0;
/// A glyph drawn in the text's color.
pub const MASK: u32 = 1;
/// A glyph with colors of its own, like an emoji.
pub const COLOR: u32 = 2;

/// What one frame draws: the background, then the quads in order.
pub struct Scene {
    pub background: Rgba,
    pub instances: Vec<Instance>,
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

/// `grid` drawn with `fonts`, the cursor at `cursor` in `shape` if given.
/// Fails when the atlas fills up; clear it and build again.
pub fn build(
    grid: &[Vec<Cell>],
    cursor: Option<(Position, CursorShape)>,
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
    // A block cursor shows its cell reversed.
    if let Some((at, CursorShape::Block)) = cursor
        && let Some(l) = looks
            .get_mut(usize::from(at.row))
            .and_then(|r| r.get_mut(usize::from(at.col)))
    {
        std::mem::swap(&mut l.fg, &mut l.bg);
    }
    let mut instances = Vec::new();
    // Backgrounds, a rectangle for each run of one color.
    for (y, row) in looks.iter().enumerate() {
        let top = y as f32 * ch;
        let mut x = 0;
        for same in row.chunk_by(|a, b| a.bg == b.bg) {
            let bg = same[0].bg;
            if bg != background {
                instances.push(rect(x as f32 * cw, top, same.len() as f32 * cw, ch, bg));
            }
            x += same.len();
        }
    }
    // Underlines and strikethroughs, under the glyphs.
    let thickness = (ch / 16.0).round().max(1.0);
    for (y, row) in looks.iter().enumerate() {
        let top = y as f32 * ch;
        for (x, l) in row.iter().enumerate() {
            if let Some((_, color)) = l.underline {
                let under = (top + fonts.baseline + thickness).min(top + ch - thickness);
                instances.push(rect(x as f32 * cw, under, cw, thickness, color));
            }
            if l.strikethrough {
                let middle = top + (fonts.baseline * 0.65).round();
                instances.push(rect(x as f32 * cw, middle, cw, thickness, l.fg));
            }
        }
    }
    for (y, (row, row_looks)) in grid.iter().zip(&looks).enumerate() {
        text_row(row, row_looks, y, fonts, atlas, &mut instances)?;
    }
    if let Some((at, shape)) = cursor {
        let (x, y) = (f32::from(at.col) * cw, f32::from(at.row) * ch);
        let color = looks
            .get(usize::from(at.row))
            .and_then(|r| r.get(usize::from(at.col)))
            .map_or(background, |l| l.fg);
        let line = (cw / 8.0).round().max(1.0);
        match shape {
            CursorShape::Block => {}
            CursorShape::Bar => instances.push(rect(x, y, line, ch, color)),
            CursorShape::Underline => instances.push(rect(x, y + ch - line, cw, line, color)),
        }
    }
    Ok(Scene {
        background,
        instances,
    })
}

/// A run of cells shaped together: the text, and the cell each byte starts.
struct Run {
    text: String,
    /// The byte offset of each cell's text, with its column, in order.
    starts: Vec<(usize, usize)>,
    bold: bool,
    italic: bool,
}

/// The glyphs of row `y`, in runs of one weight and slant so ligatures and
/// shaping work across them; box-drawing characters as rectangles.
fn text_row(
    row: &[Cell],
    looks: &[Look],
    y: usize,
    fonts: &mut Fonts,
    atlas: &mut Atlas,
    out: &mut Vec<Instance>,
) -> Result<(), Full> {
    let (cw, ch) = (fonts.cell_w, fonts.cell_h);
    let top = y as f32 * ch;
    let mut run: Option<Run> = None;
    for (x, cell) in row.iter().enumerate() {
        if cell.text.is_empty() {
            continue;
        }
        let l = looks[x];
        let mut chars = cell.text.chars();
        if let (Some(c), None) = (chars.next(), chars.next())
            && let Some(rects) = boxdraw::rects(c, cw, ch)
        {
            if let Some(done) = run.take() {
                shape_run(&done, looks, top, fonts, atlas, out)?;
            }
            for r in rects {
                out.push(rect(x as f32 * cw + r.x, top + r.y, r.w, r.h, l.fg));
            }
            continue;
        }
        if run
            .as_ref()
            .is_some_and(|r| r.bold != l.bold || r.italic != l.italic)
            && let Some(done) = run.take()
        {
            shape_run(&done, looks, top, fonts, atlas, out)?;
        }
        let r = run.get_or_insert_with(|| Run {
            text: String::new(),
            starts: Vec::new(),
            bold: l.bold,
            italic: l.italic,
        });
        r.starts.push((r.text.len(), x));
        r.text.push_str(&cell.text);
    }
    if let Some(done) = run {
        shape_run(&done, looks, top, fonts, atlas, out)?;
    }
    Ok(())
}

fn shape_run(
    run: &Run,
    looks: &[Look],
    top: f32,
    fonts: &mut Fonts,
    atlas: &mut Atlas,
    out: &mut Vec<Instance>,
) -> Result<(), Full> {
    let (glyphs, baseline) = fonts.shape(&run.text, run.bold, run.italic);
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
        let physical = glyph.physical((offset, top + baseline), 1.0);
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
