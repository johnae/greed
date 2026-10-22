//! A frame as a grid of cells, each a grapheme with its resolved style: the
//! panes with the lines between them, the tab line, the status line, panels
//! with their separators and titles, and floats with their borders. Clients
//! draw the grid their own way: the TUI as terminal cells, the GUI on the
//! GPU.

use std::ops::Range;

use smallvec::{SmallVec, smallvec};
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

use super::{Frame, Position, Rect, Role, Row, Size, Span, Surface, SurfaceId, Tag};
use crate::theme::{Medium, Style, Theme};

/// One cell: a grapheme and its style. A wide grapheme's later cells have
/// empty text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cell {
    pub text: String,
    pub style: Style,
    /// How many times bigger the text is: it takes that many times its
    /// cells across, the cells after it and the rows under it come empty.
    /// 0 for a cell in the rows a scaled line takes, in its pane.
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
    compose_layers(frame, medium, scaled, true)
}

/// What's under `frame`'s floats: its rows of cells as [`compose`] has
/// them for `medium`, without the floats. The window draws from it what
/// shows around a float's rounded border, and lays out the text beside a
/// float as if nothing covered the rest of its row.
pub fn compose_beneath(frame: &Frame, medium: Medium) -> Vec<Vec<Cell>> {
    compose_layers(frame, medium, medium == Medium::Gui, false)
}

/// `frame` as rows of cells, its floats too when `floats` says so.
fn compose_layers(frame: &Frame, medium: Medium, scaled: bool, floats: bool) -> Vec<Vec<Cell>> {
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
    let pane_border = text.patch(&look(&Tag::PANE_BORDER));
    for line in &frame.lines {
        let (x, y) = (usize::from(line.x), usize::from(line.y));
        let len = usize::from(line.len);
        if line.down {
            for row in grid.iter_mut().skip(y).take(len) {
                put(row, x, 1, "│", pane_border, 1);
            }
        } else if let Some(row) = grid.get_mut(y) {
            put(row, x, len, &"─".repeat(len), pane_border, 1);
        }
    }
    let inactive = text.patch(&look(&Tag::PANE_INACTIVE));
    let panel = text.patch(&look(&Tag::PANEL));
    let separator = panel.patch(&look(&Tag::PANEL_BORDER));
    let body = text.patch(&look(&Tag::FLOAT));
    let border = body.patch(&look(&Tag::FLOAT_BORDER));
    let shown = frame
        .surfaces
        .iter()
        .filter(|s| floats || !matches!(s.role, Role::Float { .. }));
    for surface in shown {
        let r = surface.rect;
        let cropped = cropped_rows(frame, surface);
        let (x, y, w, h) = (
            usize::from(r.x),
            usize::from(r.y),
            usize::from(r.width),
            usize::from(r.height),
        );
        match &surface.role {
            Role::Pane { active } => {
                // A pane other than the active one is dimmed to its edges.
                let base = if *active { text } else { inactive };
                put_rows(&mut grid, surface, cropped, base, !active, paint);
            }
            Role::Tabline | Role::Status => {
                put_rows(&mut grid, surface, cropped, text, false, paint);
            }
            Role::Panel {
                separator: column,
                title,
            } => {
                let top = y.saturating_sub(usize::from(title.is_some()));
                for line in grid.iter_mut().take(y + h).skip(top) {
                    put(line, usize::from(*column), 1, "│", separator, 1);
                }
                if let (Some(title), Some(line)) = (title, grid.get_mut(top)) {
                    let style = panel.patch(&look(&Tag::PANEL_TITLE));
                    put(line, x, w, &format!("{title:<w$}"), style, 1);
                }
                put_rows(&mut grid, surface, cropped, panel, false, paint);
            }
            Role::Float {
                border: true,
                title,
                label,
                footer,
            } => {
                let edges = Edges {
                    title: title.as_deref(),
                    label,
                    footer,
                };
                let looks = (border, body, look(&Tag::FLOAT_TITLE));
                draw_border(&mut grid, r, &edges, looks, paint);
                put_rows(&mut grid, surface, cropped, body, false, paint);
            }
            Role::Float { border: false, .. } => {
                for line in grid.iter_mut().skip(y).take(h) {
                    put(line, x, w, &" ".repeat(w), body, 1);
                }
                put_rows(&mut grid, surface, cropped, body, false, paint);
            }
        }
        // A heading in a float or a panel takes its rows as one in a pane does.
        if !matches!(surface.role, Role::Tabline | Role::Status) {
            spread_scaled(&mut grid, y..y + h, x..x + w);
        }
        paint_guides(&mut grid, surface, cropped, paint);
    }
    grid
}

/// Draws `surface`'s rows in its rect over `base`; with `fill`, each to
/// the rect's right edge. Rows laid out at another size than the rect are
/// cropped to it (see [`cropped_rows`]), and where they don't reach its
/// edge, the surface's note says why.
fn put_rows(
    grid: &mut [Vec<Cell>],
    surface: &Surface,
    cropped: u16,
    base: Style,
    fill: bool,
    paint: Paint,
) {
    // The window scales rows laid out at another size to fit instead (see
    // `compose_content`).
    if paint.medium == Medium::Gui && surface.content.is_some() {
        return;
    }
    let r = surface.rect;
    let (x, w) = (usize::from(r.x), usize::from(r.width));
    let lines = grid
        .iter_mut()
        .skip(usize::from(r.y))
        .take(usize::from(r.height));
    let rows = surface.rows.iter().skip(usize::from(cropped));
    for (line, row) in lines.zip(rows) {
        put_row(line, x, w, row, base, fill, paint);
    }
    if let (Some(content), Some(note)) = (surface.content, &surface.note) {
        let style = base.patch(&paint.theme.style(Tag::SCREEN_NOTE.name(), paint.medium));
        put_note(grid, r, content, note, style);
    }
}

/// A surface laid out at another size than its rect, as its own grid of
/// that size for the window to scale into the rect, with where the cursor
/// is in that grid if it's there.
pub struct Content {
    pub rect: Rect,
    pub grid: Vec<Vec<Cell>>,
    pub cursor: Option<Position>,
}

/// The surfaces of `frame` laid out at another size than their rects, like
/// a terminal sized for another client's screen, which [`compose`] leaves
/// blank in the window, bottom first.
pub fn compose_content(frame: &Frame) -> Vec<Content> {
    let theme = &frame.theme;
    let paint = Paint {
        theme,
        medium: Medium::Gui,
        scaled: true,
    };
    let look = |tag: &Tag| theme.style(tag.name(), Medium::Gui);
    let text = look(&Tag::TEXT);
    frame
        .surfaces
        .iter()
        .filter_map(|surface| {
            let content = surface.content?;
            let base = match surface.role {
                Role::Pane { active: false } => text.patch(&look(&Tag::PANE_INACTIVE)),
                Role::Panel { .. } => text.patch(&look(&Tag::PANEL)),
                Role::Float { .. } => text.patch(&look(&Tag::FLOAT)),
                _ => text,
            };
            let blank = Cell {
                text: " ".to_owned(),
                style: base,
                scale: 1,
            };
            let width = usize::from(content.width);
            let mut grid = vec![vec![blank; width]; usize::from(content.height)];
            for (line, row) in grid.iter_mut().zip(&surface.rows) {
                put_row(line, 0, width, row, base, false, paint);
            }
            let r = surface.rect;
            let cursor = frame
                .cursor
                .filter(|c| in_content(*c, r, content))
                .map(|c| Position {
                    row: c.row - r.y,
                    col: c.col - r.x,
                });
            Some(Content {
                rect: r,
                grid,
                cursor,
            })
        })
        .collect()
}

/// Puts `note` in the room `rect` has that `content` doesn't fill: right
/// at the end of its last row when the content is shorter, else at the
/// end of its first row when it's narrower and the note fits beside it.
fn put_note(grid: &mut [Vec<Cell>], rect: Rect, content: Size, note: &str, style: Style) {
    let width = note.width();
    let (x, w) = (usize::from(rect.x), usize::from(rect.width));
    let row = if content.height < rect.height {
        rect.y + rect.height - 1
    } else if usize::from(rect.width.saturating_sub(content.width)) > width {
        rect.y
    } else {
        return;
    };
    if let Some(line) = grid.get_mut(usize::from(row)) {
        let at = x + w.saturating_sub(width);
        put(line, at, w.min(width), note, style, 1);
    }
}

/// How many rows of `surface` are cropped off its top: none unless it was
/// laid out taller than its rect, like a terminal sized for a bigger
/// screen, and then as few as keep the row it says to keep showing (where
/// a terminal's program has its cursor), else the cursor's row when the
/// cursor is in it, or else as many as show its bottom.
pub fn cropped_rows(frame: &Frame, surface: &Surface) -> u16 {
    let Some(content) = surface.content else {
        return 0;
    };
    let r = surface.rect;
    let extra = content.height.saturating_sub(r.height);
    let cursor = frame.cursor.filter(|c| in_content(*c, r, content));
    match surface.keep.or(cursor.map(|c| c.row - r.y)) {
        _ if extra == 0 => 0,
        Some(row) => (row + 1).saturating_sub(r.height).min(extra),
        None => extra,
    }
}

/// Whether `at` is in what a surface in `rect` laid out at `content` shows,
/// before cropping.
fn in_content(at: Position, rect: Rect, content: Size) -> bool {
    let inside = |p: u16, start: u16, len: u16| {
        p >= start && u32::from(p) < u32::from(start) + u32::from(len)
    };
    inside(at.col, rect.x, content.width) && inside(at.row, rect.y, content.height)
}

/// Where the cursor shows once surfaces are cropped: moved up with the
/// rows cropped off the surface it's in, and `None` when it's cropped off
/// that surface's side.
pub fn cursor(frame: &Frame) -> Option<Position> {
    let at = frame.cursor?;
    let Some(surface) = frame
        .surfaces
        .iter()
        .rev()
        .find(|s| s.content.is_some_and(|c| in_content(at, s.rect, c)))
    else {
        return Some(at);
    };
    let r = surface.rect;
    let moved = Position {
        row: at.row - cropped_rows(frame, surface),
        ..at
    };
    let room = Size {
        width: r.width,
        height: r.height,
    };
    in_content(moved, r, room).then_some(moved)
}

/// What a float shows on its border.
struct Edges<'a> {
    title: Option<&'a str>,
    label: &'a [Span],
    footer: &'a [Span],
}

/// Draws a border around `r`, blanking what's inside, with the title at
/// the left of the top border, the label at the right and the footer in
/// the middle of the bottom border. `looks` are the border's, the inside's
/// and the title's styles.
fn draw_border(
    grid: &mut [Vec<Cell>],
    r: Rect,
    edges: &Edges,
    (border, body, title_look): (Style, Style, Style),
    paint: Paint,
) {
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
    let label = padded(edges.label);
    let label = if label < w { label } else { 0 };
    if let Some(top) = grid.get_mut(y - 1) {
        let room = w - label - usize::from(label > 0);
        if let Some(title) = edges.title.filter(|t| !t.is_empty()) {
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
            put_spans(top, x + w - 1 - label, label, edges.label, border, paint);
        }
    }
    let footer = padded(edges.footer);
    if footer > 0
        && footer <= w
        && let Some(bottom) = grid.get_mut(y + h)
    {
        put_spans(
            bottom,
            x + (w - footer) / 2,
            footer,
            edges.footer,
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
/// own, in order. A row with tags of its own, or with `fill`, fills its
/// whole width.
fn put_row(
    line: &mut [Cell],
    x: usize,
    width: usize,
    row: &Row,
    base: Style,
    fill: bool,
    paint: Paint,
) {
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
    if fill || !row.tags.is_empty() {
        let fill = " ".repeat(width - used);
        put(line, x + used, width - used, &fill, base, 1);
    }
}

/// Paint guides only after glyph backgrounds have spread to covered rows.
fn paint_guides(grid: &mut [Vec<Cell>], surface: &Surface, cropped: u16, paint: Paint) {
    if paint.medium == Medium::Gui && surface.content.is_some() {
        return;
    }
    if paint.theme.entry("ui.ruler").is_none() {
        return;
    }
    let Some(bg) = paint.theme.style("ui.ruler", paint.medium).bg else {
        return;
    };
    let x = usize::from(surface.rect.x);
    let y = usize::from(surface.rect.y);
    let width = usize::from(surface.rect.width);
    let rows = &surface.rows[usize::from(cropped).min(surface.rows.len())..];
    for (offset, row) in rows
        .iter()
        .take(usize::from(surface.rect.height))
        .enumerate()
    {
        for &column in &row.guides {
            if column >= width || y + offset >= grid.len() || x + column >= grid[y + offset].len() {
                continue;
            }
            let mut source = offset;
            if paint.scaled && grid[y + offset][x + column].scale == 0 {
                // A covered glyph owns its explicit background, but never
                // carries a synthetic guide into adjacent cells.
                'source: for above in (0..offset).rev().take(usize::from(u8::MAX) - 1) {
                    for (left, cell) in grid[y + above].iter().enumerate().skip(x).take(column + 1)
                    {
                        let scale = usize::from(cell.scale);
                        if scale > offset - above
                            && left + cell.text.width().max(1) * scale > x + column
                        {
                            source = above;
                            break 'source;
                        }
                    }
                }
            }
            let source_row = &rows[source];
            let mut explicit = Style::default();
            for tag in &source_row.tags {
                explicit = explicit.patch(&paint.theme.style(tag.name(), paint.medium));
            }
            let mut used = 0;
            for span in &source_row.spans {
                for grapheme in span.text.graphemes(true) {
                    let cells = visible(grapheme).width().max(1) * usize::from(span.scale.max(1));
                    if used + cells > width {
                        break;
                    }
                    used += cells;
                }
                if column < used {
                    for tag in &span.tags {
                        explicit = explicit.patch(&paint.theme.style(tag.name(), paint.medium));
                    }
                    break;
                }
            }
            grid[y + offset][x + column].style.bg = explicit.bg.or(Some(bg));
        }
    }
}

/// `grapheme` as it can safely be shown: control characters, which a
/// terminal would act on (an escape sequence in a file could set the
/// clipboard or hide lines), become their Unicode pictures, like `␛`.
fn visible(grapheme: &str) -> std::borrow::Cow<'_, str> {
    if !grapheme.chars().any(char::is_control) {
        return std::borrow::Cow::Borrowed(grapheme);
    }
    grapheme
        .chars()
        .map(|c| match u32::from(c) {
            code @ 0..=0x1f => char::from_u32(0x2400 + code).unwrap_or('�'),
            0x7f => '␡',
            _ if c.is_control() => '�',
            _ => c,
        })
        .collect::<String>()
        .into()
}

/// Writes `text` into `line` from cell `x`, within `width` cells, `scale`
/// times its size. Returns how many cells it used.
fn put(line: &mut [Cell], x: usize, width: usize, text: &str, style: Style, scale: u8) -> usize {
    let mut used = 0;
    for grapheme in text.graphemes(true) {
        let shown = visible(grapheme);
        let w = shown.width().max(1) * usize::from(scale);
        if used + w > width || x + used + w > line.len() {
            break;
        }
        line[x + used] = Cell {
            text: shown.into_owned(),
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

/// The panes, the tab line and the lines between panes merged into one
/// row per screen row of the area they share, then the status line; a
/// single pane with no tab line is its rows as they are. Each pane's
/// row-wide tags (`ui.pane.inactive` first, for all but the active pane)
/// go on its spans and padding, so a merged row draws as the surfaces do.
/// Panels and floats are left out. For tests that read a frame as text.
pub fn screen_rows(frame: &Frame) -> Vec<Row> {
    let panes: Vec<&Surface> = frame
        .surfaces
        .iter()
        .filter(|s| matches!(s.role, Role::Pane { .. }))
        .collect();
    let tabline = frame.surface(SurfaceId::Tabline);
    let mut rows = match (tabline, panes.as_slice()) {
        (None, [pane]) => pane.rows.clone(),
        _ => merged_rows(frame, &panes, tabline),
    };
    let status = frame.surface(SurfaceId::Status);
    rows.extend(status.and_then(|s| s.rows.first()).cloned());
    rows
}

/// The text of each of [`screen_rows`].
pub fn text_rows(frame: &Frame) -> Vec<String> {
    screen_rows(frame).iter().map(Row::text).collect()
}

/// `panes`, `tabline` and the frame's lines as one row per screen row,
/// across the area they take together.
fn merged_rows(frame: &Frame, panes: &[&Surface], tabline: Option<&Surface>) -> Vec<Row> {
    let rects = || panes.iter().chain(&tabline).map(|s| s.rect);
    let left = rects().map(|r| r.x).min().unwrap_or(0);
    let top = rects().map(|r| r.y).min().unwrap_or(0);
    let bottom = rects().map(|r| r.y.saturating_add(r.height)).max();
    let bottom = bottom.unwrap_or(0).max(top);
    // Each screen row, as the pieces on it: where each starts, its width
    // and its row.
    let mut pieces: Vec<Vec<(u16, u16, Row)>> = vec![Vec::new(); usize::from(bottom - top)];
    let mut put = |y: u16, piece: (u16, u16, Row)| {
        if let Some(row) = y
            .checked_sub(top)
            .and_then(|i| pieces.get_mut(usize::from(i)))
        {
            row.push(piece);
        }
    };
    for surface in tabline.into_iter().chain(panes.iter().copied()) {
        let r = surface.rect;
        let inactive = matches!(surface.role, Role::Pane { active: false });
        for (y, row) in (r.y..r.y.saturating_add(r.height)).zip(&surface.rows) {
            let mut row = row.clone();
            if inactive {
                row.tags.insert(0, Tag::PANE_INACTIVE);
            }
            put(y, (r.x, r.width, row));
        }
    }
    let border = |text: String| Row {
        spans: vec![Span::new(text, smallvec![Tag::PANE_BORDER])],
        ..Row::default()
    };
    for line in &frame.lines {
        if line.down {
            for y in line.y..line.y.saturating_add(line.len) {
                put(y, (line.x, 1, border("│".to_owned())));
            }
        } else {
            let text = "─".repeat(usize::from(line.len));
            put(line.y, (line.x, line.len, border(text)));
        }
    }
    pieces
        .into_iter()
        .map(|mut row_pieces| {
            row_pieces.sort_by_key(|(x, _, _)| *x);
            let mut row = Row::default();
            let mut at = left;
            for (x, width, piece) in row_pieces {
                if x > at {
                    row.push(&" ".repeat(usize::from(x - at)), SmallVec::new());
                }
                append(&mut row, piece, usize::from(width));
                at = x.saturating_add(width);
            }
            row
        })
        .collect()
}

/// Adds `piece` to the end of `row`, padded to `width` cells, with its
/// row-wide tags on each of its spans so they stay within its width.
fn append(row: &mut Row, piece: Row, width: usize) {
    if !piece.guides.is_empty() {
        let offset: usize = row
            .spans
            .iter()
            .map(|span| span.text.width() * usize::from(span.scale.max(1)))
            .sum();
        row.guides.extend(
            piece
                .guides
                .iter()
                .copied()
                .filter(|column| *column < width)
                .map(|column| offset + column),
        );
    }
    let mut used = 0;
    for span in piece.spans {
        used += span.text.graphemes(true).map(str::width).sum::<usize>();
        let tags = piece.tags.iter().chain(&span.tags).cloned().collect();
        row.push(&span.text, tags);
    }
    if used < width {
        row.push(&" ".repeat(width - used), piece.tags.into_iter().collect());
    }
}

/// Marks the cells under scaled text in `rows` and `cols`, a pane, panel or
/// float: in the rows a scaled line takes, every cell of it is under it (its
/// `scale` is 0), and those under the text itself take its style, so its
/// background (a selection, a highlight) fills all of it. Other panes'
/// rows beside it are their own.
fn spread_scaled(grid: &mut [Vec<Cell>], rows: Range<usize>, cols: Range<usize>) {
    let bottom = rows.end.min(grid.len());
    for y in rows.start..bottom {
        let end = cols.end.min(grid[y].len());
        let tallest = grid[y][cols.start.min(end)..end]
            .iter()
            .map(|cell| usize::from(cell.scale))
            .max()
            .unwrap_or(1);
        if tallest < 2 {
            continue;
        }
        for row in grid[..bottom].iter_mut().skip(y + 1).take(tallest - 1) {
            for under in row.iter_mut().take(end).skip(cols.start) {
                under.scale = 0;
            }
        }
        let mut x = cols.start;
        while x < end {
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
                        scale: 0,
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
    use crate::render::{Separator, Size, Span};
    use crate::theme::{Color, Entry};
    use crate::{CursorShape, ViewId};

    #[test]
    fn rulers_stay_one_cell_wide_across_scaled_glyphs() {
        for medium in [Medium::Tui, Medium::Gui] {
            for column in [0, 1] {
                for background in [false, true] {
                    let mut span = Span::new(
                        "a",
                        if background {
                            smallvec![Tag::from("big")]
                        } else {
                            smallvec![]
                        },
                    );
                    span.scale = 2;
                    let mut f = frame(vec![
                        Row {
                            spans: vec![span],
                            guides: smallvec![column],
                            ..Row::default()
                        },
                        Row {
                            guides: smallvec![column],
                            ..Row::default()
                        },
                    ]);
                    Arc::make_mut(&mut f.theme).set(
                        "ui.ruler",
                        Entry::new(Style {
                            bg: Some(Color::Ansi(5)),
                            ..Style::default()
                        }),
                    );
                    let grid = compose_with(&f, medium, true);
                    for row in grid.iter().take(2) {
                        for (cell_column, cell) in row.iter().take(2).enumerate() {
                            let expected = if background {
                                Some(Color::Ansi(4))
                            } else if cell_column == column {
                                Some(Color::Ansi(5))
                            } else {
                                None
                            };
                            assert_eq!(cell.style.bg, expected);
                        }
                    }
                }
            }
        }
    }

    #[test]
    fn rulers_fill_sparse_cells_below_explicit_backgrounds_on_both_clients() {
        let row = Row {
            spans: vec![
                Span::new("ab", smallvec![]),
                Span::new("cd", smallvec![Tag::from("big")]),
            ],
            guides: smallvec![1, 2, 6, 99],
            ..Row::default()
        };
        let mut f = frame(vec![row]);
        Arc::make_mut(&mut f.theme).set(
            "ui.ruler",
            Entry::new(Style {
                bg: Some(Color::Ansi(5)),
                ..Style::default()
            }),
        );
        for medium in [Medium::Tui, Medium::Gui] {
            let grid = compose(&f, medium);
            assert_eq!(grid[0][1].style.bg, Some(Color::Ansi(5)));
            assert_eq!(grid[0][2].style.bg, Some(Color::Ansi(4)));
            assert_eq!(grid[0][6].style.bg, Some(Color::Ansi(5)));
            assert_eq!(grid[0][0].style.bg, None);
        }
        f.surfaces.push(Surface::new(
            SurfaceId::View(ViewId(2)),
            Role::Float {
                border: false,
                title: None,
                label: Vec::new(),
                footer: Vec::new(),
            },
            rect(6, 0, 1, 1),
            vec![text_row("x")],
        ));
        for medium in [Medium::Tui, Medium::Gui] {
            let grid = compose(&f, medium);
            assert_eq!(grid[0][6].text, "x");
            assert_ne!(grid[0][6].style.bg, Some(Color::Ansi(5)));
        }
    }

    fn rect(x: u16, y: u16, width: u16, height: u16) -> Rect {
        Rect {
            x,
            y,
            width,
            height,
        }
    }

    /// A frame 8 wide and 4 high: `rows` in a pane, then the status line.
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
        let pane = Surface::new(
            SurfaceId::View(ViewId(1)),
            Role::Pane { active: true },
            rect(0, 0, 8, 3),
            rows,
        );
        let status = Surface::new(
            SurfaceId::Status,
            Role::Status,
            rect(0, 3, 8, 1),
            vec![Row::default()],
        );
        Frame {
            size: Size {
                width: 8,
                height: 4,
            },
            surfaces: vec![pane, status],
            lines: Vec::new(),
            images: Vec::new(),
            scenes: Vec::new(),
            cursor: None,
            cursor_shape: CursorShape::Block,
            theme: Arc::new(theme),
            gui: std::collections::BTreeMap::new(),
            menus: Vec::new(),
            seq: 0,
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

    fn text_row(text: &str) -> Row {
        Row {
            spans: vec![Span::new(text, smallvec![])],
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
        assert!(
            grid[1].iter().all(|c| c.scale == 0),
            "the whole row under it is the scaled line's, in its pane"
        );
        assert!(grid[2].iter().all(|c| c.scale == 1));
    }

    #[test]
    fn a_scaled_line_in_a_float_takes_its_rows_there() {
        // A heading on a float's first line sits on that line and the one
        // under it, so it isn't drawn up over the float's title.
        let mut f = frame(Vec::new());
        let role = Role::Float {
            border: true,
            title: Some("t".into()),
            label: Vec::new(),
            footer: Vec::new(),
        };
        let rows = vec![scaled_row(), Row::default()];
        let float = Surface::new(SurfaceId::View(ViewId(2)), role, rect(1, 1, 6, 2), rows);
        f.surfaces.push(float);
        let grid = compose(&f, Medium::Gui);
        assert_eq!((grid[1][1].scale, grid[1][3].scale), (2, 2));
        assert!(grid[2][1..7].iter().all(|c| c.scale == 0));
        assert_eq!((grid[2][0].scale, grid[2][7].scale), (1, 1), "its border");
    }

    #[test]
    fn a_scaled_line_takes_rows_only_in_its_own_pane() {
        // Two panes side by side, the left one with a heading at twice the
        // size: the right one's rows are its own.
        let mut f = frame(vec![scaled_row()]);
        f.surfaces[0].rect = rect(0, 0, 4, 3);
        f.surfaces.push(Surface::new(
            SurfaceId::View(ViewId(2)),
            Role::Pane { active: false },
            rect(4, 0, 4, 3),
            vec![text_row("top"), text_row("next"), Row::default()],
        ));
        let grid = compose(&f, Medium::Gui);
        assert!(grid[1][..4].iter().all(|c| c.scale == 0));
        assert_eq!(texts(&grid, 1)[4..], ["n", "e", "x", "t"]);
        assert!(grid[1][4..].iter().all(|c| c.scale == 1));
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

    #[test]
    fn panes_draw_as_their_merged_rows_do() {
        let mut f = frame(Vec::new());
        f.size = Size {
            width: 9,
            height: 5,
        };
        for (name, look) in [("ui.pane.inactive", 8), ("ui.pane.border", 3), ("hl", 5)] {
            let style = Style {
                fg: Some(Color::Ansi(look)),
                ..Style::default()
            };
            Arc::make_mut(&mut f.theme).set(name, Entry::new(style));
        }
        let text = |t: &str| Row {
            spans: vec![Span::new(t, smallvec![])],
            ..Row::default()
        };
        let marked = Row {
            tags: smallvec![Tag::from("hl")],
            ..text("ab")
        };
        let pane = |id, active, x, rows| {
            let role = Role::Pane { active };
            Surface::new(SurfaceId::View(ViewId(id)), role, rect(x, 1, 4, 3), rows)
        };
        let tabs = Surface::new(
            SurfaceId::Tabline,
            Role::Tabline,
            rect(0, 0, 9, 1),
            vec![text(" 1 a  2 b")],
        );
        let status = Surface::new(
            SurfaceId::Status,
            Role::Status,
            rect(0, 4, 9, 1),
            vec![text("NORMAL")],
        );
        f.surfaces = vec![
            pane(1, true, 0, vec![text("one"), marked.clone(), text("")]),
            pane(2, false, 5, vec![text("two"), marked, text("x")]),
            tabs,
            status,
        ];
        f.lines = vec![Separator {
            x: 4,
            y: 1,
            len: 3,
            down: true,
        }];
        assert_eq!(
            text_rows(&f),
            [" 1 a  2 b", "one │two ", "ab  │ab  ", "    │x   ", "NORMAL"]
        );
        // The same rows as one pane, the way frames used to hold them.
        let rows = screen_rows(&f);
        let mut merged = f.clone();
        let (status, panes) = rows.split_last().unwrap();
        merged.lines.clear();
        merged.surfaces = vec![
            Surface::new(
                SurfaceId::View(ViewId(1)),
                Role::Pane { active: true },
                rect(0, 0, 9, 4),
                panes.to_vec(),
            ),
            Surface::new(
                SurfaceId::Status,
                Role::Status,
                rect(0, 4, 9, 1),
                vec![status.clone()],
            ),
        ];
        for medium in [Medium::Tui, Medium::Gui] {
            assert_eq!(compose(&f, medium), compose(&merged, medium));
        }
        let grid = compose(&f, Medium::Tui);
        assert_eq!(
            grid[3][7].style.fg,
            Some(Color::Ansi(8)),
            "dimmed to its edge"
        );
        assert_eq!(grid[2][2].style.fg, Some(Color::Ansi(5)), "a marked row");
        assert_eq!(
            grid[1][4].style.fg,
            Some(Color::Ansi(3)),
            "the line between"
        );
    }

    #[test]
    fn a_float_covers_a_panel_as_it_covers_a_pane() {
        // A pane on the left, a panel on the right with its own background,
        // and a float over both.
        let mut f = frame(Vec::new());
        f.size = Size {
            width: 12,
            height: 6,
        };
        let panel_bg = Style {
            bg: Some(Color::Ansi(2)),
            ..Style::default()
        };
        Arc::make_mut(&mut f.theme).set("ui.panel", Entry::new(panel_bg));
        f.surfaces = vec![
            Surface::new(
                SurfaceId::View(ViewId(1)),
                Role::Pane { active: true },
                rect(0, 0, 6, 5),
                (0..5).map(|_| text_row("pppppp")).collect(),
            ),
            Surface::new(
                SurfaceId::Status,
                Role::Status,
                rect(0, 5, 12, 1),
                vec![Row::default()],
            ),
            Surface::new(
                SurfaceId::View(ViewId(2)),
                Role::Panel {
                    separator: 6,
                    title: None,
                },
                rect(7, 0, 5, 5),
                (0..5).map(|_| text_row("qqqqq")).collect(),
            ),
            Surface::new(
                SurfaceId::View(ViewId(3)),
                Role::Float {
                    border: true,
                    title: None,
                    label: Vec::new(),
                    footer: Vec::new(),
                },
                rect(3, 2, 6, 1),
                vec![text_row("ffffff")],
            ),
        ];
        for medium in [Medium::Tui, Medium::Gui] {
            let grid = compose(&f, medium);
            let float_bg = grid[2][3].style.bg;
            assert_eq!(
                texts(&grid, 2)[..],
                ["p", "p", "│", "f", "f", "f", "f", "f", "f", "│", "q", "q"],
                "{medium:?}"
            );
            assert_eq!(texts(&grid, 4)[..], texts(&grid, 0)[..], "{medium:?}");
            assert!(
                (2..=9).all(|x| grid[2][x].style.bg == float_bg),
                "over the pane, the panel's line and the panel alike ({medium:?})"
            );
            assert_eq!(grid[2][10].style.bg, panel_bg.bg, "the panel beside it");
            // Under it, the pane and the panel as they are without it.
            let beneath = compose_beneath(&f, medium);
            assert_eq!(texts(&beneath, 2)[..], texts(&beneath, 0)[..]);
            assert_eq!(beneath[2][8].style.bg, panel_bg.bg);
        }
    }

    #[test]
    fn control_characters_show_as_their_pictures_and_never_reach_the_terminal() {
        let blank = Cell {
            text: String::new(),
            style: Style::default(),
            scale: 1,
        };
        let mut line = vec![blank; 12];
        let used = put(
            &mut line,
            0,
            12,
            "a\u{1b}]52;\u{7}\u{9b}\u{7f}é",
            Style::default(),
            1,
        );
        let shown: String = line[..used].iter().map(|c| c.text.as_str()).collect();
        assert_eq!(shown, "a␛]52;␇�␡é");
    }
}
