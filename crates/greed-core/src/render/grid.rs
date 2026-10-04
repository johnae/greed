//! A frame as a grid of cells, each a grapheme with its resolved style: the
//! main view's rows, the status line, panels with their separators and
//! titles, and floats with their borders. Clients draw the grid their own
//! way: the TUI as terminal cells, the GUI on the GPU.

use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

use super::{Frame, Row, Tag};
use crate::theme::{Style, Surface, Theme};

/// One cell: a grapheme and its style. A wide grapheme's later cells have
/// empty text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cell {
    pub text: String,
    pub style: Style,
}

/// `frame` as rows of cells, with styles as `surface` has them.
pub fn compose(frame: &Frame, surface: Surface) -> Vec<Vec<Cell>> {
    let theme = &frame.theme;
    let look = |tag: &Tag| theme.style(tag.name(), surface);
    let width = usize::from(frame.size.width);
    let text = look(&Tag::TEXT);
    let blank = Cell {
        text: " ".to_owned(),
        style: text,
    };
    let mut grid = vec![vec![blank; width]; usize::from(frame.size.height)];
    if let Some((status, rows)) = frame.rows.split_last() {
        let (x, w) = (usize::from(frame.main.x), usize::from(frame.main.width));
        for (line, row) in grid.iter_mut().zip(rows) {
            put_row(line, x, w, row, text, theme, surface);
        }
        if let Some(line) = grid.get_mut(rows.len()) {
            put_row(line, 0, width, status, text, theme, surface);
        }
    }
    let panel = text.patch(&look(&Tag::PANEL));
    let separator = panel.patch(&look(&Tag::PANEL_BORDER));
    for p in &frame.panels {
        let (x, w) = (usize::from(p.rect.x), usize::from(p.rect.width));
        let top = usize::from(p.rect.y) - usize::from(p.title.is_some());
        for line in grid.iter_mut().skip(top).take(frame.rows.len() - 1 - top) {
            put(line, usize::from(p.separator), 1, "│", separator);
        }
        if let (Some(title), Some(line)) = (&p.title, grid.get_mut(top)) {
            let style = panel.patch(&look(&Tag::PANEL_TITLE));
            put(line, x, w, &format!("{title:<w$}"), style);
        }
        for (line, row) in grid.iter_mut().skip(usize::from(p.rect.y)).zip(&p.rows) {
            put_row(line, x, w, row, panel, theme, surface);
        }
    }
    let body = text.patch(&look(&Tag::FLOAT));
    let border = body.patch(&look(&Tag::FLOAT_BORDER));
    for float in &frame.floats {
        let r = float.rect;
        let (x, y, w, h) = (
            usize::from(r.x),
            usize::from(r.y),
            usize::from(r.width),
            usize::from(r.height),
        );
        for (dy, line) in grid.iter_mut().enumerate().skip(y - 1).take(h + 2) {
            let (left, fill, right) = match dy {
                d if d == y - 1 => ('┌', '─', '┐'),
                d if d == y + h => ('└', '─', '┘'),
                _ => ('│', ' ', '│'),
            };
            let mut cells = std::iter::once(left)
                .chain(std::iter::repeat_n(fill, w))
                .chain(std::iter::once(right));
            for cell in line.iter_mut().skip(x - 1).take(w + 2) {
                let c = cells.next().unwrap_or(' ');
                *cell = Cell {
                    text: c.to_string(),
                    style: if c == ' ' { body } else { border },
                };
            }
        }
        if let (Some(title), Some(top)) = (&float.title, grid.get_mut(y - 1))
            && !title.is_empty()
        {
            let style = border.patch(&look(&Tag::FLOAT_TITLE));
            let title = format!(" {title} ");
            put(top, x + 1, w.saturating_sub(2), &title, style);
        }
        for (line, row) in grid.iter_mut().skip(y).take(h).zip(&float.rows) {
            put_row(line, x, w, row, body, theme, surface);
        }
    }
    grid
}

/// Draws `row` over `base`, each span styled by the row's tags and then its
/// own, in order. A row with tags of its own fills its whole width.
fn put_row(
    line: &mut [Cell],
    x: usize,
    width: usize,
    row: &Row,
    base: Style,
    theme: &Theme,
    surface: Surface,
) {
    let layer = |style: Style, tags: &[Tag]| {
        tags.iter().fold(style, |style, tag| {
            style.patch(&theme.style(tag.name(), surface))
        })
    };
    let base = layer(base, &row.tags);
    let mut used = 0;
    for span in &row.spans {
        let style = layer(base, &span.tags);
        used += put(line, x + used, width - used, &span.text, style);
    }
    if !row.tags.is_empty() {
        let fill = " ".repeat(width - used);
        put(line, x + used, width - used, &fill, base);
    }
}

/// Writes `text` into `line` from cell `x`, within `width` cells. Returns how
/// many cells it used.
fn put(line: &mut [Cell], x: usize, width: usize, text: &str, style: Style) -> usize {
    let mut used = 0;
    for grapheme in text.graphemes(true) {
        let w = grapheme.width().max(1);
        if used + w > width || x + used + w > line.len() {
            break;
        }
        line[x + used] = Cell {
            text: grapheme.to_owned(),
            style,
        };
        for extra in 1..w {
            line[x + used + extra] = Cell {
                text: String::new(),
                style,
            };
        }
        used += w;
    }
    used
}
