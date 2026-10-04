//! Frames drawn on the GPU into a texture and read back. Skipped where
//! there's no GPU. With `GREED_GUI_SNAPSHOTS` set to a folder, each test also
//! writes its picture there as a PNG to look at.

#![allow(
    clippy::cast_precision_loss,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    clippy::float_cmp
)]

use std::collections::HashMap;
use std::sync::Arc;

use smallvec::SmallVec;

use greed_core::CursorShape;
use greed_core::image::ImageId;
use greed_core::render::grid::compose;
use greed_core::render::{FloatFrame, Frame, ImagePlacement, Position, Rect, Row, Size, Span, Tag};
use greed_core::theme::{Color, Entry, Style, Surface, Theme};
use greed_gui::Palette;
use greed_gui::draw::build;
use greed_gui::gpu::Gpu;
use greed_gui::text::{Atlas, Fonts};

fn row(spans: &[(&str, &str)]) -> Row {
    Row {
        spans: spans
            .iter()
            .map(|(text, tag)| Span {
                text: (*text).to_owned(),
                tags: if tag.is_empty() {
                    SmallVec::default()
                } else {
                    [Tag::from(*tag)].into_iter().collect()
                },
            })
            .collect(),
        tags: SmallVec::default(),
    }
}

fn frame() -> Frame {
    let mut theme = Theme::default();
    theme.set(
        "keyword",
        Entry::new(Style {
            fg: Some(Color::Rgb(0xc3, 0x97, 0xd8)),
            bold: Some(true),
            ..Style::default()
        }),
    );
    theme.set(
        "ui.statusline",
        Entry::new(Style {
            fg: Some(Color::Rgb(0, 0, 0)),
            bg: Some(Color::Rgb(0x81, 0xa2, 0xbe)),
            ..Style::default()
        }),
    );
    let rows = vec![
        row(&[("fn", "keyword"), (" main() {", "")]),
        row(&[("    let x = a => b != c;", "")]),
        row(&[("    // 日本語 and ❄️ stay on the grid|", "")]),
        row(&[("}", "")]),
        row(&[]),
        row(&[]),
        Row {
            tags: [Tag::STATUS].into_iter().collect(),
            ..row(&[(" NORMAL  main.rs", "")])
        },
    ];
    Frame {
        size: Size {
            width: 40,
            height: 7,
        },
        main: Rect {
            x: 0,
            y: 0,
            width: 40,
            height: 6,
        },
        rows,
        panels: Vec::new(),
        floats: vec![FloatFrame {
            rect: Rect {
                x: 26,
                y: 4,
                width: 12,
                height: 1,
            },
            title: Some("pick".to_owned()),
            rows: vec![row(&[("a float", "")])],
        }],
        images: Vec::new(),
        cursor: Some(Position { col: 3, row: 0 }),
        cursor_shape: CursorShape::Block,
        theme: Arc::new(theme),
        gui: std::collections::BTreeMap::new(),
    }
}

fn pixel(rgba: &[u8], width: u32, x: u32, y: u32) -> [u8; 4] {
    let i = ((y * width + x) * 4) as usize;
    [rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]]
}

#[test]
fn a_frame_draws_text_on_its_grid_with_the_cursor_status_line_and_a_float() {
    let Some(mut gpu) = Gpu::headless(wgpu::TextureFormat::Rgba8Unorm, 1024) else {
        eprintln!("no GPU here; skipped");
        return;
    };
    let mut fonts = Fonts::new(None, 16.0);
    let mut atlas = Atlas::new(1024);
    let palette = Palette::default();
    let frame = frame();
    let grid = compose(&frame, Surface::Gui);
    let scene = build(
        &grid,
        frame.cursor.map(|c| (c, frame.cursor_shape)),
        &frame.images,
        &mut fonts,
        &mut atlas,
        &palette,
    )
    .unwrap();
    gpu.upload(&mut atlas);
    let (cw, ch) = (fonts.cell_w, fonts.cell_h);
    let size = ((40.0 * cw).ceil() as u32, (7.0 * ch).ceil() as u32);
    let rgba = gpu.snapshot(size, &scene);
    if let Some(dir) = std::env::var_os("GREED_GUI_SNAPSHOTS") {
        let file = std::fs::File::create(std::path::Path::new(&dir).join("frame.png")).unwrap();
        let mut png = png::Encoder::new(file, size.0, size.1);
        png.set_color(png::ColorType::Rgba);
        png.set_depth(png::BitDepth::Eight);
        png.write_header().unwrap().write_image_data(&rgba).unwrap();
    }
    let bg = palette.bg;
    // The block cursor's cell is the text color.
    let cursor = pixel(&rgba, size.0, (3.5 * cw) as u32, (0.15 * ch) as u32);
    assert_eq!(&cursor[..3], &palette.fg, "cursor cell");
    // The status line's background fills its row.
    let status = pixel(&rgba, size.0, size.0 - 2, (6.5 * ch) as u32);
    assert_eq!(&status[..3], &[0x81, 0xa2, 0xbe], "status line");
    // Somewhere in "fn" is the keyword's color, not the background.
    let keyword = (0..(2.0 * cw) as u32)
        .flat_map(|x| (0..ch as u32).map(move |y| (x, y)))
        .any(|(x, y)| pixel(&rgba, size.0, x, y)[..3] == [0xc3, 0x97, 0xd8]);
    assert!(keyword, "the keyword is drawn in its color");
    // The float's top border is a line along its top row.
    let border_y = (3.0 * ch) as u32..(4.0 * ch) as u32;
    let border = border_y
        .clone()
        .any(|y| pixel(&rgba, size.0, (30.5 * cw) as u32, y)[..3] != bg);
    assert!(border, "the float has a border");
    // "|" after the wide characters is still at column 37.
    let bar_col = (37.0 * cw) as u32..(38.0 * cw) as u32;
    let bar = bar_col
        .flat_map(|x| ((2.0 * ch) as u32..(3.0 * ch) as u32).map(move |y| (x, y)))
        .any(|(x, y)| pixel(&rgba, size.0, x, y)[..3] != bg);
    assert!(bar, "text after wide characters stays on its column");
}

#[test]
fn a_font_with_ligatures_joins_them_and_keeps_the_columns() {
    let Some(mut gpu) = Gpu::headless(wgpu::TextureFormat::Rgba8Unorm, 1024) else {
        return;
    };
    let mut fonts = Fonts::new(Some("Fira Code".to_owned()), 16.0);
    // Fira Code joins "->" with contextual alternates: the same number of
    // glyphs, but other ones than "-" and ">" on their own.
    let ids = |fonts: &mut Fonts, text: &str| {
        let (glyphs, _) = fonts.shape(text, false, false);
        glyphs.iter().map(|g| g.glyph_id).collect::<Vec<_>>()
    };
    let joined = ids(&mut fonts, "->");
    let apart = [ids(&mut fonts, "-")[0], ids(&mut fonts, ">")[0]];
    if joined == apart {
        eprintln!("no Fira Code ligatures here; skipped");
        return;
    }
    let mut atlas = Atlas::new(1024);
    let palette = Palette::default();
    let mut frame = frame();
    frame.rows[1] = row(&[("    a -> b != c;", "")]);
    let grid = compose(&frame, Surface::Gui);
    let scene = build(&grid, None, &[], &mut fonts, &mut atlas, &palette).unwrap();
    gpu.upload(&mut atlas);
    let size = (
        (40.0 * fonts.cell_w).ceil() as u32,
        (7.0 * fonts.cell_h).ceil() as u32,
    );
    let rgba = gpu.snapshot(size, &scene);
    if let Some(dir) = std::env::var_os("GREED_GUI_SNAPSHOTS") {
        let file = std::fs::File::create(std::path::Path::new(&dir).join("ligatures.png")).unwrap();
        let mut png = png::Encoder::new(file, size.0, size.1);
        png.set_color(png::ColorType::Rgba);
        png.set_depth(png::BitDepth::Eight);
        png.write_header().unwrap().write_image_data(&rgba).unwrap();
    }
    // The ";" after the ligatures is still in column 15.
    let (cw, ch) = (fonts.cell_w, fonts.cell_h);
    let semicolon = ((15.0 * cw) as u32..(16.0 * cw) as u32)
        .flat_map(|x| ((1.0 * ch) as u32..(2.0 * ch) as u32).map(move |y| (x, y)))
        .any(|(x, y)| pixel(&rgba, size.0, x, y)[..3] != palette.bg);
    assert!(semicolon, "text after a ligature stays on its column");
}

/// A PNG `width` by `height`, its left half red and its right half blue.
fn halves(width: u32, height: u32) -> Vec<u8> {
    let mut png = Vec::new();
    let mut encoder = png::Encoder::new(&mut png, width, height);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let pixels: Vec<u8> = (0..height)
        .flat_map(|_| {
            (0..width).flat_map(|x| {
                if x < width / 2 {
                    [255, 0, 0, 255]
                } else {
                    [0, 0, 255, 255]
                }
            })
        })
        .collect();
    encoder
        .write_header()
        .unwrap()
        .write_image_data(&pixels)
        .unwrap();
    png
}

#[test]
fn images_are_drawn_over_their_cells_cut_where_the_placement_says() {
    let Some(mut gpu) = Gpu::headless(wgpu::TextureFormat::Rgba8Unorm, 1024) else {
        return;
    };
    let mut fonts = Fonts::new(None, 16.0);
    let mut atlas = Atlas::new(1024);
    let palette = Palette::default();
    let mut frame = frame();
    frame.floats.clear();
    let (whole, cut) = (ImageId(1), ImageId(2));
    let placement = |id, x, col| ImagePlacement {
        id,
        rect: Rect {
            x,
            y: 4,
            width: 4 - col,
            height: 2,
        },
        col,
        row: 0,
        cols: 4,
        rows: 2,
    };
    // The whole image at column 2; only the right half of the other at 30.
    frame.images = vec![placement(whole, 2, 0), placement(cut, 30, 2)];
    let pngs = HashMap::from([(whole, halves(40, 20)), (cut, halves(40, 20))]);
    let grid = compose(&frame, Surface::Gui);
    let scene = build(&grid, None, &frame.images, &mut fonts, &mut atlas, &palette).unwrap();
    gpu.upload(&mut atlas);
    gpu.place_images(&frame.images, &pngs);
    let (cw, ch) = (fonts.cell_w, fonts.cell_h);
    let size = ((40.0 * cw).ceil() as u32, (7.0 * ch).ceil() as u32);
    let rgba = gpu.snapshot(size, &scene);
    if let Some(dir) = std::env::var_os("GREED_GUI_SNAPSHOTS") {
        let file = std::fs::File::create(std::path::Path::new(&dir).join("images.png")).unwrap();
        let mut png = png::Encoder::new(file, size.0, size.1);
        png.set_color(png::ColorType::Rgba);
        png.set_depth(png::BitDepth::Eight);
        png.write_header().unwrap().write_image_data(&rgba).unwrap();
    }
    let at = |col: f32, row: f32| pixel(&rgba, size.0, (col * cw) as u32, (row * ch) as u32);
    assert_eq!(
        at(2.5, 4.5)[..3],
        [255, 0, 0],
        "the whole image's left half"
    );
    assert_eq!(at(5.5, 5.5)[..3], [0, 0, 255], "and its right half");
    assert_eq!(at(6.5, 4.5)[..3], palette.bg, "nothing past it");
    assert_eq!(
        at(30.5, 4.5)[..3],
        [0, 0, 255],
        "the cut one starts halfway"
    );
    assert_eq!(at(31.5, 5.5)[..3], [0, 0, 255]);

    // A frame without the image drops its texture; placing it again makes
    // it again from the PNG.
    gpu.place_images(&[], &pngs);
    gpu.place_images(&frame.images, &pngs);
    let again = gpu.snapshot(size, &scene);
    assert_eq!(again, rgba);
}
