//! A frame as a grid of cells, each a grapheme with its resolved style: the
//! main view's rows, the status line, panels with their separators and
//! titles, and floats with their borders. Clients draw the grid their own
//! way: the TUI as terminal cells, the GUI on the GPU.

use std::ops::Range;

use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

use super::{FloatFrame, Frame, Row, Span, Tag};
use crate::theme::{Medium, Style, Theme};

/// One cell: a grapheme and its style. A wide grapheme's later cells have
/// empty text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cell {
    pub text: String,
    pub style: Style,
    /// How many times bigger the text is: it takes that many times its
    /// cells across, the cells after it and the rows under it come empty.
    pub scale: u8,
}

/// How a client draws: the frame's theme for `medium`, and whether it can
/// draw text bigger (the window, kitty) or keeps it one size.
#[derive(Clone, Copy)]
struct Paint<'a> {
    theme: &'a Theme,
    medium: Medium,
    scaled: bool,
}

/// `frame` as rows of cells, with styles as `medium` has them; scaled text
/// is drawn big in the window and one size in a terminal.
pub fn compose(frame: &Frame, medium: Medium) -> Vec<Vec<Cell>> {
    compose_with(frame, medium, medium == Medium::Gui)
}

/// `frame` as rows of cells, with styles as `medium` has them. With
/// `scaled`, scaled text takes cells marked with its scale; without it, its
/// text is one size at the start of the cells it takes.
pub fn compose_with(frame: &Frame, medium: Medium, scaled: bool) -> Vec<Vec<Cell>> {
    let theme = &frame.theme;
    let paint = Paint {
        theme,
        medium,
        scaled,
    };
    let look = |tag: &Tag| theme.style(tag.name(), medium);
    // A frame from a session is drawn no bigger than any the editor makes.
    let size = frame.size.limited();
    let width = usize::from(size.width);
    let text = look(&Tag::TEXT);
    let blank = Cell {
        text: " ".to_owned(),
        style: text,
        scale: 1,
    };
    let mut grid = vec![vec![blank; width]; usize::from(size.height)];
    if let Some((status, rows)) = frame.rows.split_last() {
        let (x, w) = (usize::from(frame.main.x), usize::from(frame.main.width));
        for (line, row) in grid.iter_mut().zip(rows) {
            put_row(line, x, w, row, text, paint);
        }
        spread_scaled(&mut grid, 0..rows.len(), x..x + w);
        if let Some(line) = grid.get_mut(rows.len()) {
            put_row(line, 0, width, status, text, paint);
        }
    }
    let panel = text.patch(&look(&Tag::PANEL));
    let separator = panel.patch(&look(&Tag::PANEL_BORDER));
    for p in &frame.panels {
        let (x, w) = (usize::from(p.rect.x), usize::from(p.rect.width));
        let top = usize::from(p.rect.y).saturating_sub(usize::from(p.title.is_some()));
        let rows = frame.rows.len().saturating_sub(1).saturating_sub(top);
        for line in grid.iter_mut().skip(top).take(rows) {
            put(line, usize::from(p.separator), 1, "│", separator, 1);
        }
        if let (Some(title), Some(line)) = (&p.title, grid.get_mut(top)) {
            let style = panel.patch(&look(&Tag::PANEL_TITLE));
            put(line, x, w, &format!("{title:<w$}"), style, 1);
        }
        for (line, row) in grid.iter_mut().skip(usize::from(p.rect.y)).zip(&p.rows) {
            put_row(line, x, w, row, panel, paint);
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
        if float.border {
            draw_border(
                &mut grid,
                float,
                border,
                body,
                look(&Tag::FLOAT_TITLE),
                paint,
            );
        } else {
            for line in grid.iter_mut().skip(y).take(h) {
                put(line, x, w, &" ".repeat(w), body, 1);
            }
        }
        for (line, row) in grid.iter_mut().skip(y).take(h).zip(&float.rows) {
            put_row(line, x, w, row, body, paint);
        }
    }
    grid
}

/// Draws `float`'s border around its rect, blanking what's inside, with
/// its title at the left of the top border, its label at the right and its
/// footer in the middle of the bottom border.
fn draw_border(
    grid: &mut [Vec<Cell>],
    float: &FloatFrame,
    border: Style,
    body: Style,
    title_look: Style,
    paint: Paint,
) {
    let r = float.rect;
    let (x, y, w, h) = (
        usize::from(r.x),
        usize::from(r.y),
        usize::from(r.width),
        usize::from(r.height),
    );
    // The editor leaves a cell for the border; a frame that doesn't gets none.
    if x == 0 || y == 0 {
        return;
    }
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
                scale: 1,
            };
        }
    }
    // A label or footer has a space either side, and the label keeps a
    // line before the corner.
    let padded = |spans: &[Span]| {
        if spans.is_empty() {
            0
        } else {
            spans.iter().map(|s| s.text.width()).sum::<usize>() + 2
        }
    };
    let label = padded(&float.label);
    let label = if label < w { label } else { 0 };
    if let Some(top) = grid.get_mut(y - 1) {
        let room = w - label - usize::from(label > 0);
        if let Some(title) = float.title.as_deref().filter(|t| !t.is_empty()) {
            let style = border.patch(&title_look);
            put(
                top,
                x + 1,
                room.saturating_sub(2),
                &format!(" {title} "),
                style,
                1,
            );
        }
        if label > 0 {
            put_spans(top, x + w - 1 - label, label, &float.label, border, paint);
        }
    }
    let footer = padded(&float.footer);
    if footer > 0
        && footer <= w
        && let Some(bottom) = grid.get_mut(y + h)
    {
        put_spans(
            bottom,
            x + (w - footer) / 2,
            footer,
            &float.footer,
            border,
            paint,
        );
    }
}

/// Draws `spans` with a space either side from cell `x`, within `width`
/// cells, each styled by its tags over `base`.
fn put_spans(line: &mut [Cell], x: usize, width: usize, spans: &[Span], base: Style, paint: Paint) {
    let mut used = put(line, x, width, " ", base, 1);
    for span in spans {
        let style = span.tags.iter().fold(base, |style, tag| {
            style.patch(&paint.theme.style(tag.name(), paint.medium))
        });
        used += put(line, x + used, width - used, &span.text, style, 1);
    }
    put(line, x + used, width - used, " ", base, 1);
}

/// Draws `row` over `base`, each span styled by the row's tags and then its
/// own, in order. A row with tags of its own fills its whole width.
fn put_row(line: &mut [Cell], x: usize, width: usize, row: &Row, base: Style, paint: Paint) {
    let layer = |style: Style, tags: &[Tag]| {
        tags.iter().fold(style, |style, tag| {
            style.patch(&paint.theme.style(tag.name(), paint.medium))
        })
    };
    let base = layer(base, &row.tags);
    let mut used = 0;
    for span in &row.spans {
        let style = layer(base, &span.tags);
        let scale = span.scale.max(1);
        if paint.scaled {
            used += put(line, x + used, width - used, &span.text, style, scale);
        } else {
            // One size: scaled text keeps its cells, with the text at the
            // start of them.
            let cells = put(line, x + used, width - used, &span.text, style, 1);
            let wide = cells * usize::from(scale);
            let rest = wide.min(width - used) - cells;
            put(line, x + used + cells, rest, &" ".repeat(rest), style, 1);
            used += cells + rest;
        }
    }
    if !row.tags.is_empty() {
        let fill = " ".repeat(width - used);
        put(line, x + used, width - used, &fill, base, 1);
    }
}

/// Writes `text` into `line` from cell `x`, within `width` cells, `scale`
/// times its size. Returns how many cells it used.
fn put(line: &mut [Cell], x: usize, width: usize, text: &str, style: Style, scale: u8) -> usize {
    let mut used = 0;
    for grapheme in text.graphemes(true) {
        let w = grapheme.width().max(1) * usize::from(scale);
        if used + w > width || x + used + w > line.len() {
            break;
        }
        line[x + used] = Cell {
            text: grapheme.to_owned(),
            style,
            scale,
        };
        for extra in 1..w {
            line[x + used + extra] = Cell {
                text: String::new(),
                style,
                scale: 1,
            };
        }
        used += w;
    }
    used
}

/// Gives the cells under scaled text in `rows` and `cols`, in the rows it
/// covers, its style, so its background (a selection, a highlight) fills
/// all of it.
fn spread_scaled(grid: &mut [Vec<Cell>], rows: Range<usize>, cols: Range<usize>) {
    let bottom = rows.end.min(grid.len());
    for y in rows.start..bottom {
        let mut x = cols.start;
        while x < cols.end.min(grid[y].len()) {
            let cell = &grid[y][x];
            let scale = usize::from(cell.scale);
            if scale < 2 {
                x += 1;
                continue;
            }
            let wide = (cell.text.width().max(1) * scale).min(cols.end - x);
            let style = cell.style;
            for row in grid[..bottom].iter_mut().skip(y + 1).take(scale - 1) {
                for under in row.iter_mut().skip(x).take(wide) {
                    *under = Cell {
                        text: String::new(),
                        style,
                        scale: 1,
                    };
                }
            }
            x += wide;
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use smallvec::smallvec;

    use super::*;
    use crate::CursorShape;
    use crate::render::{Rect, Size, Span};
    use crate::theme::{Color, Entry};

    /// A frame 8 wide and 4 high: `rows` in the main view, then the status
    /// line.
    fn frame(rows: Vec<Row>) -> Frame {
        let mut theme = Theme::default();
        theme.set(
            "big",
            Entry::new(Style {
                bg: Some(Color::Ansi(4)),
                ..Style::default()
            }),
        );
        let mut rows = rows;
        rows.resize_with(3, Row::default);
        rows.push(Row::default());
        Frame {
            size: Size {
                width: 8,
                height: 4,
            },
            main: Rect {
                x: 0,
                y: 0,
                width: 8,
                height: 3,
            },
            rows,
            panels: Vec::new(),
            floats: Vec::new(),
            images: Vec::new(),
            cursor: None,
            cursor_shape: CursorShape::Block,
            theme: Arc::new(theme),
            gui: std::collections::BTreeMap::new(),
            menus: Vec::new(),
        }
    }

    fn scaled_row() -> Row {
        Row {
            spans: vec![
                Span {
                    scale: 2,
                    ..Span::new("ab", smallvec![Tag::from("big")])
                },
                Span::new("c", smallvec![]),
            ],
            covers: 1,
            ..Row::default()
        }
    }

    fn texts(grid: &[Vec<Cell>], y: usize) -> Vec<&str> {
        grid[y].iter().map(|c| c.text.as_str()).collect()
    }

    #[test]
    fn a_window_gets_scaled_cells_and_their_style_in_the_rows_they_cover() {
        let grid = compose(&frame(vec![scaled_row()]), Medium::Gui);
        assert_eq!(texts(&grid, 0), ["a", "", "b", "", "c", " ", " ", " "]);
        assert_eq!(
            (grid[0][0].scale, grid[0][2].scale, grid[0][4].scale),
            (2, 2, 1)
        );
        let blue = Some(Color::Ansi(4));
        assert!(
            grid[1][..4]
                .iter()
                .all(|c| c.text.is_empty() && c.style.bg == blue)
        );
        assert_eq!(grid[1][4].text, " ", "the 1x text covers nothing below");
    }

    #[test]
    fn a_terminal_packs_scaled_text_at_the_start_of_its_cells() {
        let grid = compose(&frame(vec![scaled_row()]), Medium::Tui);
        assert_eq!(texts(&grid, 0), ["a", "b", " ", " ", "c", " ", " ", " "]);
        assert!(grid[0].iter().all(|c| c.scale == 1));
        assert_eq!(
            grid[0][3].style.bg,
            Some(Color::Ansi(4)),
            "its cells keep its style"
        );
    }
}
