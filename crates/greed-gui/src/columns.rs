//! Where each cell's text goes across its row. Rows of the grid font keep
//! every cell at its column. A row with prose in it flows instead: prose is
//! set at its own, narrower width, and whatever follows in the row moves up
//! behind it, so a word in `code` mid-sentence doesn't leave a gap. Nothing
//! ever moves right of its cell, so the row never grows; the server's cells
//! stay where they are, and the cursor, selections and clicks go through
//! this map to the text where it's drawn.

use greed_core::render::grid::Cell;

use crate::color::Look;
use crate::text::{Fonts, TextStyle};

/// The x of each cell in each row: `None` for a row on the grid, else one
/// for each cell and one for the row's end.
#[derive(Debug, Clone, Default)]
pub struct Columns {
    cell_w: f32,
    rows: Vec<Option<Vec<f32>>>,
}

impl Columns {
    /// Where cell `col` of `row` starts, in pixels.
    pub fn x(&self, row: usize, col: usize) -> f32 {
        match self.rows.get(row).and_then(Option::as_ref) {
            Some(xs) => xs[col.min(xs.len() - 1)],
            None => col as f32 * self.cell_w,
        }
    }

    /// Where cells `from` to `to` (not included) of `row` start, and how
    /// wide they are together.
    pub fn span(&self, row: usize, from: usize, to: usize) -> (f32, f32) {
        let x = self.x(row, from);
        (x, self.x(row, to) - x)
    }

    /// The cell of `row` that pixel `x` is in.
    pub fn col_at(&self, row: usize, x: f32) -> usize {
        match self.rows.get(row).and_then(Option::as_ref) {
            Some(xs) => xs.partition_point(|&start| start <= x).saturating_sub(1),
            None => (x / self.cell_w).max(0.0) as usize,
        }
    }
}

/// Where every cell of `grid` goes, its prose shaped with `fonts`. Cells
/// `snaps` marks (where something else starts: a float, a pane's border)
/// go back to their column, and the flow starts again from there.
pub fn lay_out(
    grid: &[Vec<Cell>],
    looks: &[Vec<Look>],
    snaps: &[Vec<bool>],
    fonts: &mut Fonts,
) -> Columns {
    let cell_w = fonts.cell_w;
    let rows = grid
        .iter()
        .zip(looks)
        .zip(snaps)
        .map(|((row, looks), snaps)| {
            let prose = row
                .iter()
                .zip(looks)
                .any(|(c, l)| l.prose && !c.text.is_empty());
            prose.then(|| flow(row, looks, snaps, fonts))
        })
        .collect();
    Columns { cell_w, rows }
}

/// The x of each cell of a row with prose in it, and of its end.
fn flow(row: &[Cell], looks: &[Look], snaps: &[bool], fonts: &mut Fonts) -> Vec<f32> {
    let cw = fonts.cell_w;
    let mut xs = vec![0.0; row.len() + 1];
    // How far left of its column the flow has put the next cell: never
    // right of it, and none at all on the grid.
    let mut shift: f32 = 0.0;
    let mut col = 0;
    while col < row.len() {
        if snaps[col] {
            shift = 0.0;
        }
        let x = col as f32 * cw - shift;
        if !looks[col].prose || row[col].text.is_empty() {
            xs[col] = x;
            col += 1;
            continue;
        }
        // A run of prose of one style, with the empty cells wide or scaled
        // characters take after their first.
        let style = style_of(&row[col], &looks[col]);
        let end = (col + 1..row.len())
            .find(|&c| {
                snaps[c]
                    || !row[c].text.is_empty()
                        && (!looks[c].prose || style_of(&row[c], &looks[c]) != style)
            })
            .unwrap_or(row.len());
        let mut text = String::new();
        let mut starts = Vec::new();
        for (c, cell) in row.iter().enumerate().take(end).skip(col) {
            if !cell.text.is_empty() {
                starts.push((text.len(), c));
                text.push_str(&cell.text);
            }
        }
        let (glyphs, _) = fonts.shape(&text, style);
        let width = glyphs.iter().map(|g| g.x + g.w).fold(0.0, f32::max);
        // Squeezed only if it wouldn't fit its cells, which is rare.
        let room = (end - col) as f32 * cw;
        let squeeze = if width > room { room / width } else { 1.0 };
        for &(byte, c) in &starts {
            let natural = glyphs
                .iter()
                .find(|g| g.start >= byte)
                .map_or(width, |g| g.x);
            xs[c] = x + natural * squeeze;
        }
        // The empty cells after a character start where the next one does.
        let run_end = x + width * squeeze;
        for (i, &(_, c)) in starts.iter().enumerate() {
            let next = starts.get(i + 1).map_or(end, |&(_, n)| n);
            let at = if next < end { xs[next] } else { run_end };
            xs[c + 1..next].fill(at);
        }
        shift = end as f32 * cw - run_end;
        col = end;
    }
    // The row's end stays at the screen's edge, under the last cell.
    xs[row.len()] = row.len() as f32 * cw;
    xs
}

/// How `cell`, looking like `look`, is shaped.
pub fn style_of(cell: &Cell, look: &Look) -> TextStyle {
    TextStyle {
        bold: look.bold,
        italic: look.italic,
        scale: cell.scale.max(1),
        prose: look.prose,
    }
}

#[cfg(test)]
mod tests {
    use greed_core::theme::{Font, Style};

    use super::*;
    use crate::color::{Palette, look};

    fn cells(text: &str, font: Option<Font>) -> (Vec<Cell>, Vec<Look>) {
        let style = Style {
            font,
            ..Style::default()
        };
        let palette = Palette::default();
        text.chars()
            .map(|c| {
                let cell = Cell {
                    text: c.to_string(),
                    style,
                    scale: 1,
                };
                (cell, look(&style, &palette))
            })
            .unzip()
    }

    #[test]
    fn prose_flows_narrower_and_the_grid_text_after_it_follows() {
        let mut fonts = Fonts::new(None, 16.0);
        let cw = fonts.cell_w;
        let (mut row, mut looks) = cells("Illuminate", Some(Font::Prose));
        let (code, code_looks) = cells("ab", None);
        row.extend(code);
        looks.extend(code_looks);
        let snaps = vec![false; row.len()];
        let columns = lay_out(&[row], &[looks], &[snaps], &mut fonts);
        let xs: Vec<f32> = (0..=12).map(|c| columns.x(0, c)).collect();
        assert!(xs.windows(2).all(|w| w[0] <= w[1]), "left to right: {xs:?}");
        // Prose is narrower than the grid, and never wider.
        assert!(xs[10] < 10.0 * cw, "{xs:?}");
        // "ab" comes right after it, a cell each.
        assert!((xs[11] - xs[10] - cw).abs() < 0.01, "{xs:?}");
        assert_eq!(xs[12], 12.0 * cw, "the row's end stays at the edge");
        // A click on a character finds its cell.
        for col in 0..11 {
            let middle = f32::midpoint(xs[col], xs[col + 1]);
            assert_eq!(columns.col_at(0, middle), col, "{xs:?}");
        }
    }

    #[test]
    fn something_else_on_the_row_starts_back_on_the_grid() {
        let mut fonts = Fonts::new(None, 16.0);
        let cw = fonts.cell_w;
        // Prose, then a float over the row from cell 12: its border and text.
        let (mut row, mut looks) = cells("Illuminating", Some(Font::Prose));
        let (float, float_looks) = cells("│new terminal", None);
        row.extend(float);
        looks.extend(float_looks);
        let mut snaps = vec![false; row.len()];
        snaps[12] = true;
        let columns = lay_out(&[row], &[looks], &[snaps], &mut fonts);
        assert!(columns.x(0, 11) < 11.0 * cw, "the prose still flows");
        for col in 12..25 {
            assert_eq!(columns.x(0, col), col as f32 * cw, "the float's cell {col}");
        }
    }

    #[test]
    fn rows_without_prose_stay_on_the_grid() {
        let mut fonts = Fonts::new(None, 16.0);
        let cw = fonts.cell_w;
        let (row, looks) = cells("plain", None);
        let snaps = vec![false; row.len()];
        let columns = lay_out(&[row], &[looks], &[snaps], &mut fonts);
        assert_eq!(columns.x(0, 3), 3.0 * cw);
        assert_eq!(columns.col_at(0, 3.5 * cw), 3);
    }
}
