//! Box-drawing, block and braille characters drawn as rectangles rather
//! than taken from the font, so lines meet across cells whatever the font's
//! metrics or the line height, the way terminals like Alacritty do it, and
//! charts drawn in characters show with any font.

/// A rectangle in pixels, from a cell's top left.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

/// The arms of a line character: left, right, up, down, each 0 (none),
/// 1 (light) or 2 (heavy).
fn arms(c: char) -> Option<[u8; 4]> {
    Some(match c {
        '─' => [1, 1, 0, 0],
        '━' => [2, 2, 0, 0],
        '│' => [0, 0, 1, 1],
        '┃' => [0, 0, 2, 2],
        '┌' | '╭' => [0, 1, 0, 1],
        '┏' => [0, 2, 0, 2],
        '┐' | '╮' => [1, 0, 0, 1],
        '┓' => [2, 0, 0, 2],
        '└' | '╰' => [0, 1, 1, 0],
        '┗' => [0, 2, 2, 0],
        '┘' | '╯' => [1, 0, 1, 0],
        '┛' => [2, 0, 2, 0],
        '├' => [0, 1, 1, 1],
        '┣' => [0, 2, 2, 2],
        '┤' => [1, 0, 1, 1],
        '┫' => [2, 0, 2, 2],
        '┬' => [1, 1, 0, 1],
        '┳' => [2, 2, 0, 2],
        '┴' => [1, 1, 1, 0],
        '┻' => [2, 2, 2, 0],
        '┼' => [1, 1, 1, 1],
        '╋' => [2, 2, 2, 2],
        '╴' => [1, 0, 0, 0],
        '╶' => [0, 1, 0, 0],
        '╵' => [0, 0, 1, 0],
        '╷' => [0, 0, 0, 1],
        _ => return None,
    })
}

/// How much of a cell `n` eighths of `size` are, in whole pixels.
fn eighths_of(size: f32, n: u8) -> f32 {
    (size * f32::from(n) / 8.0).round()
}

/// The eighth blocks: filled from the bottom (`▁` to `▇`), from the left
/// (`▉` to `▏`), and the top and right eighths (`▔`, `▕`).
fn eighths(c: char, w: f32, h: f32) -> Option<Rect> {
    let n = u32::from(c);
    let count = |from: u32| u8::try_from(n - from).unwrap_or(8);
    Some(match n {
        0x2581..=0x2587 => {
            let bh = eighths_of(h, count(0x2580));
            Rect {
                x: 0.0,
                y: h - bh,
                w,
                h: bh,
            }
        }
        0x2589..=0x258f => Rect {
            x: 0.0,
            y: 0.0,
            w: eighths_of(w, 8 - count(0x2588)),
            h,
        },
        0x2594 => Rect {
            x: 0.0,
            y: 0.0,
            w,
            h: eighths_of(h, 1),
        },
        0x2595 => {
            let bw = eighths_of(w, 1);
            Rect {
                x: w - bw,
                y: 0.0,
                w: bw,
                h,
            }
        }
        _ => return None,
    })
}

/// Braille: a small square for each of its eight dots that's set, two
/// across and four down.
fn braille(c: char, w: f32, h: f32) -> Option<Vec<Rect>> {
    // Each bit's dot, by column and row.
    const DOTS: [(u8, u8); 8] = [
        (0, 0),
        (0, 1),
        (0, 2),
        (1, 0),
        (1, 1),
        (1, 2),
        (0, 3),
        (1, 3),
    ];
    let bits = u32::from(c).checked_sub(0x2800).filter(|b| *b < 0x100)?;
    let size = (w / 4.0).min(h / 8.0).round().max(1.0);
    let dots = DOTS
        .iter()
        .enumerate()
        .filter(|(bit, _)| bits & (1 << bit) != 0)
        .map(|(_, &(col, row))| Rect {
            x: (w * f32::from(1 + 2 * col) / 4.0 - size / 2.0).round(),
            y: (h * f32::from(1 + 2 * row) / 8.0 - size / 2.0).round(),
            w: size,
            h: size,
        })
        .collect();
    Some(dots)
}

/// The rectangles that draw `c` in a `w` by `h` cell, or `None` when the
/// font should draw it.
pub fn rects(c: char, w: f32, h: f32) -> Option<Vec<Rect>> {
    let block = |x: f32, y: f32, bw: f32, bh: f32| Some(vec![Rect { x, y, w: bw, h: bh }]);
    let (half_w, half_h) = ((w / 2.0).round(), (h / 2.0).round());
    if let Some(dots) = braille(c, w, h) {
        return Some(dots);
    }
    if let Some(eighth) = eighths(c, w, h) {
        return Some(vec![eighth]);
    }
    match c {
        '█' => return block(0.0, 0.0, w, h),
        '▀' => return block(0.0, 0.0, w, half_h),
        '▄' => return block(0.0, half_h, w, h - half_h),
        '▌' => return block(0.0, 0.0, half_w, h),
        '▐' => return block(half_w, 0.0, w - half_w, h),
        _ => {}
    }
    let [left, right, up, down] = arms(c)?;
    let light = (h / 16.0).round().max(1.0);
    let thickness = |weight: u8| if weight == 2 { light * 2.0 } else { light };
    // Lines run through the cell's middle, snapped to whole pixels.
    let cx = ((w - light) / 2.0).round();
    let cy = ((h - light) / 2.0).round();
    let mut out = Vec::new();
    // Horizontal arms reach past the middle by the vertical line's width,
    // so corners close.
    let vertical = thickness(up.max(down));
    let horizontal = thickness(left.max(right));
    if left > 0 {
        out.push(Rect {
            x: 0.0,
            y: cy,
            w: cx + vertical,
            h: thickness(left),
        });
    }
    if right > 0 {
        out.push(Rect {
            x: cx,
            y: cy,
            w: w - cx,
            h: thickness(right),
        });
    }
    if up > 0 {
        out.push(Rect {
            x: cx,
            y: 0.0,
            w: thickness(up),
            h: cy + horizontal,
        });
    }
    if down > 0 {
        out.push(Rect {
            x: cx,
            y: cy,
            w: thickness(down),
            h: h - cy,
        });
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lines_span_the_whole_cell_so_they_meet_the_next() {
        let r = rects('─', 10.0, 20.0).unwrap();
        let left = r[0];
        let right = r[1];
        assert_eq!(left.x, 0.0);
        assert_eq!(right.x + right.w, 10.0, "reaches the right edge");
        let v = rects('│', 10.0, 20.0).unwrap();
        assert_eq!(v[0].y, 0.0);
        assert_eq!(v[1].y + v[1].h, 20.0, "reaches the bottom edge");
    }

    #[test]
    fn braille_is_a_square_for_each_dot_and_eighths_fill_part_of_the_cell() {
        let dots = rects('⡇', 8.0, 16.0).unwrap();
        assert_eq!(dots.len(), 4, "the left column's four dots");
        assert!(dots.iter().all(|d| d.x < 4.0 && d.w == 2.0));
        assert!(rects('\u{2800}', 8.0, 16.0).unwrap().is_empty(), "no dots");
        assert_eq!(
            rects('▂', 8.0, 16.0).unwrap(),
            [Rect {
                x: 0.0,
                y: 12.0,
                w: 8.0,
                h: 4.0
            }]
        );
        assert_eq!(
            rects('▎', 8.0, 16.0).unwrap(),
            [Rect {
                x: 0.0,
                y: 0.0,
                w: 2.0,
                h: 16.0
            }]
        );
    }

    #[test]
    fn corners_have_two_arms_and_letters_are_the_fonts() {
        assert_eq!(rects('┌', 10.0, 20.0).unwrap().len(), 2);
        assert_eq!(rects('┼', 10.0, 20.0).unwrap().len(), 4);
        assert!(rects('a', 10.0, 20.0).is_none());
        assert_eq!(
            rects('█', 10.0, 20.0).unwrap(),
            vec![Rect {
                x: 0.0,
                y: 0.0,
                w: 10.0,
                h: 20.0
            }]
        );
    }
}
