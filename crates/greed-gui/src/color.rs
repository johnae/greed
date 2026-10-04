//! Theme styles as colors on screen. The theme names colors the way a
//! terminal does (its own default foreground and background, 16 numbered
//! colors, or RGB); the window has a palette for the first two kinds.

use greed_core::theme::{Color, Style, Underline};

/// RGBA, 0 to 1.
pub type Rgba = [f32; 4];

/// The window's own colors: what a theme's "default" and its 16 numbered
/// colors are.
#[derive(Debug, Clone)]
pub struct Palette {
    pub fg: [u8; 3],
    pub bg: [u8; 3],
    pub ansi: [[u8; 3]; 16],
}

impl Default for Palette {
    /// Tomorrow Night, a calm dark palette.
    fn default() -> Self {
        Self {
            fg: [0xc5, 0xc8, 0xc6],
            bg: [0x1d, 0x1f, 0x21],
            ansi: [
                [0x1d, 0x1f, 0x21],
                [0xcc, 0x66, 0x66],
                [0xb5, 0xbd, 0x68],
                [0xf0, 0xc6, 0x74],
                [0x81, 0xa2, 0xbe],
                [0xb2, 0x94, 0xbb],
                [0x8a, 0xbe, 0xb7],
                [0xc5, 0xc8, 0xc6],
                [0x96, 0x98, 0x96],
                [0xd5, 0x4e, 0x53],
                [0xb9, 0xca, 0x4a],
                [0xe7, 0xc5, 0x47],
                [0x7a, 0xa6, 0xda],
                [0xc3, 0x97, 0xd8],
                [0x70, 0xc0, 0xb1],
                [0xea, 0xea, 0xea],
            ],
        }
    }
}

fn rgba([r, g, b]: [u8; 3]) -> Rgba {
    [
        f32::from(r) / 255.0,
        f32::from(g) / 255.0,
        f32::from(b) / 255.0,
        1.0,
    ]
}

impl Palette {
    /// `color` on screen, with `default` for the theme's "default".
    fn resolve(&self, color: Option<Color>, default: [u8; 3]) -> Rgba {
        rgba(match color {
            None | Some(Color::Default) => default,
            Some(Color::Ansi(n)) => self.ansi[usize::from(n % 16)],
            Some(Color::Rgb(r, g, b)) => [r, g, b],
        })
    }

    pub fn background(&self) -> Rgba {
        rgba(self.bg)
    }
}

/// How a cell looks on screen.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Look {
    pub fg: Rgba,
    pub bg: Rgba,
    pub bold: bool,
    pub italic: bool,
    pub underline: Option<(Underline, Rgba)>,
    pub strikethrough: bool,
}

/// `style` as `palette` shows it: reversed and dimmed as asked.
pub fn look(style: &Style, palette: &Palette) -> Look {
    let mut fg = palette.resolve(style.fg, palette.fg);
    let mut bg = palette.resolve(style.bg, palette.bg);
    if style.reverse == Some(true) {
        std::mem::swap(&mut fg, &mut bg);
    }
    if style.dim == Some(true) {
        for i in 0..3 {
            fg[i] = f32::midpoint(fg[i], bg[i]);
        }
    }
    Look {
        fg,
        bg,
        bold: style.bold == Some(true),
        italic: style.italic == Some(true),
        underline: style.underline.map(|kind| {
            (
                kind,
                style
                    .underline_color
                    .map_or(fg, |c| palette.resolve(Some(c), palette.fg)),
            )
        }),
        strikethrough: style.strikethrough == Some(true),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_colors_are_the_palettes_and_reverse_swaps_them() {
        let palette = Palette::default();
        let plain = look(&Style::default(), &palette);
        assert_eq!(plain.fg, rgba(palette.fg));
        assert_eq!(plain.bg, rgba(palette.bg));
        let reversed = look(
            &Style {
                reverse: Some(true),
                ..Style::default()
            },
            &palette,
        );
        assert_eq!((reversed.fg, reversed.bg), (plain.bg, plain.fg));
    }

    #[test]
    fn numbered_colors_come_from_the_palette_and_rgb_is_itself() {
        let palette = Palette::default();
        let style = Style {
            fg: Some(Color::Ansi(9)),
            bg: Some(Color::Rgb(255, 0, 0)),
            ..Style::default()
        };
        let l = look(&style, &palette);
        assert_eq!(l.fg, rgba(palette.ansi[9]));
        assert_eq!(l.bg, [1.0, 0.0, 0.0, 1.0]);
    }
}
