//! Box-drawing and block characters drawn as rectangles rather than taken
//! from the font, so lines meet across cells whatever the font's metrics or
//! the line height, the way terminals like Alacritty do it.

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

/// The rectangles that draw `c` in a `w` by `h` cell, or `None` when the
/// font should draw it.
pub fn rects(c: char, w: f32, h: f32) -> Option<Vec<Rect>> {
    let block = |x: f32, y: f32, bw: f32, bh: f32| Some(vec![Rect { x, y, w: bw, h: bh }]);
    let (half_w, half_h) = ((w / 2.0).round(), (h / 2.0).round());
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
