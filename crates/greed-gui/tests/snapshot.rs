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
use greed_gui::draw::{Chrome, build};
use greed_gui::gpu::Gpu;
use greed_gui::text::{Atlas, Fonts};

fn row(spans: &[(&str, &str)]) -> Row {
    Row {
        spans: spans
            .iter()
            .map(|(text, tag)| {
                Span::new(
                    *text,
                    if tag.is_empty() {
                        SmallVec::default()
                    } else {
                        [Tag::from(*tag)].into_iter().collect()
                    },
                )
            })
            .collect(),
        ..Row::default()
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
        menus: Vec::new(),
    }
}

/// Writes `rgba`, `size` pixels, as `name` in the folder `GREED_GUI_SNAPSHOTS`
/// names, if it names one, to look at.
fn save(name: &str, size: (u32, u32), rgba: &[u8]) {
    if let Some(dir) = std::env::var_os("GREED_GUI_SNAPSHOTS") {
        let file = std::fs::File::create(std::path::Path::new(&dir).join(name)).unwrap();
        let mut png = png::Encoder::new(file, size.0, size.1);
        png.set_color(png::ColorType::Rgba);
        png.set_depth(png::BitDepth::Eight);
        png.write_header().unwrap().write_image_data(rgba).unwrap();
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
        &Chrome::of(&frame),
        &mut fonts,
        &mut atlas,
        &palette,
    )
    .unwrap();
    gpu.upload(&mut atlas);
    let (cw, ch) = (fonts.cell_w, fonts.cell_h);
    let size = ((40.0 * cw).ceil() as u32, (7.0 * ch).ceil() as u32);
    let rgba = gpu.snapshot(size, &scene);
    save("frame.png", size, &rgba);
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
        let (glyphs, _) = fonts.shape(text, greed_gui::text::TextStyle::default());
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
    let scene = build(
        &grid,
        None,
        &Chrome::default(),
        &mut fonts,
        &mut atlas,
        &palette,
    )
    .unwrap();
    gpu.upload(&mut atlas);
    let size = (
        (40.0 * fonts.cell_w).ceil() as u32,
        (7.0 * fonts.cell_h).ceil() as u32,
    );
    let rgba = gpu.snapshot(size, &scene);
    save("ligatures.png", size, &rgba);
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
    let scene = build(
        &grid,
        None,
        &Chrome::of(&frame),
        &mut fonts,
        &mut atlas,
        &palette,
    )
    .unwrap();
    gpu.upload(&mut atlas);
    gpu.place_images(&frame.images, &pngs);
    let (cw, ch) = (fonts.cell_w, fonts.cell_h);
    let size = ((40.0 * cw).ceil() as u32, (7.0 * ch).ceil() as u32);
    let rgba = gpu.snapshot(size, &scene);
    save("images.png", size, &rgba);
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

#[test]
fn scaled_text_is_drawn_big_across_its_cells_and_rows() {
    let Some(mut gpu) = Gpu::headless(wgpu::TextureFormat::Rgba8Unorm, 1024) else {
        return;
    };
    let mut fonts = Fonts::new(None, 16.0);
    let mut atlas = Atlas::new(1024);
    let palette = Palette::default();
    let mut frame = frame();
    frame.floats.clear();
    // "Hi" twice the size over columns 0-3 and rows 0-1, then "x" at the
    // normal size on the same baseline.
    frame.rows[0] = Row {
        spans: vec![
            Span {
                scale: 2,
                ..Span::new("Hi", SmallVec::default())
            },
            Span::new("x", SmallVec::default()),
        ],
        covers: 1,
        ..Row::default()
    };
    frame.rows[1] = Row::default();
    frame.cursor = Some(Position { col: 0, row: 0 });
    let grid = compose(&frame, Surface::Gui);
    let cursor = frame.cursor.map(|c| (c, frame.cursor_shape));
    let scene = build(
        &grid,
        cursor,
        &Chrome::default(),
        &mut fonts,
        &mut atlas,
        &palette,
    )
    .unwrap();
    gpu.upload(&mut atlas);
    let (cw, ch) = (fonts.cell_w, fonts.cell_h);
    let size = ((40.0 * cw).ceil() as u32, (7.0 * ch).ceil() as u32);
    let rgba = gpu.snapshot(size, &scene);
    save("scaled.png", size, &rgba);
    let inked = |cols: std::ops::Range<f32>, rows: std::ops::Range<f32>| {
        ((cols.start * cw) as u32..(cols.end * cw) as u32)
            .flat_map(|x| ((rows.start * ch) as u32..(rows.end * ch) as u32).map(move |y| (x, y)))
            .filter(|&(x, y)| pixel(&rgba, size.0, x, y)[..3] == palette.fg)
            .count()
    };
    // The block cursor covers all four cells of the big "H".
    assert_ne!(
        pixel(&rgba, size.0, (1.5 * cw) as u32, (1.5 * ch) as u32)[..3],
        palette.bg
    );
    // The big "i" reaches down into the second row.
    assert!(inked(2.0..4.0, 1.0..2.0) > 0, "the big text spans two rows");
    // The small "x" sits on the shared baseline, in the lower row.
    assert_eq!(inked(4.0..5.0, 0.0..0.9), 0, "nothing small up top");
    assert!(
        inked(4.0..5.0, 1.0..2.0) > 0,
        "the small x is down on the baseline"
    );
}

#[test]
fn floats_are_rounded_boxes_with_shadows_and_pill_ends_are_half_circles() {
    let Some(mut gpu) = Gpu::headless(wgpu::TextureFormat::Rgba8Unorm, 1024) else {
        return;
    };
    let mut fonts = Fonts::new(None, 16.0);
    let mut atlas = Atlas::new(1024);
    let palette = Palette::default();
    let mut frame = frame();
    let mut theme = (*frame.theme).clone();
    theme.set(
        "ui.statusline.mode",
        Entry::new(Style {
            bg: Some(Color::Rgb(0xb5, 0xbd, 0x68)),
            ..Style::default()
        }),
    );
    theme.set(
        "cap",
        Entry::new(Style {
            fg: Some(Color::Rgb(0xb5, 0xbd, 0x68)),
            ..Style::default()
        }),
    );
    frame.theme = Arc::new(theme);
    let status = frame.rows.len() - 1;
    // A pill as the status line plugin makes one: round ends from a
    // Powerline font around the mode.
    frame.rows[status] = Row {
        spans: vec![
            Span::new("\u{e0b6}", [Tag::from("cap")].into_iter().collect()),
            Span::new(" NORMAL ", [Tag::MODE].into_iter().collect()),
            Span::new("\u{e0b4}", [Tag::from("cap")].into_iter().collect()),
            Span::new(" main.rs", SmallVec::default()),
        ],
        tags: [Tag::STATUS].into_iter().collect(),
        ..Row::default()
    };
    assert!(
        !Chrome::of(&frame).rounded && !Chrome::of(&frame).shadows,
        "only where the theme says"
    );
    let mut theme = (*frame.theme).clone();
    theme.set(
        "ui.text",
        Entry::new(Style {
            bg: Some(Color::Rgb(0x30, 0x34, 0x46)),
            ..Style::default()
        }),
    );
    theme.set(
        "ui.float",
        Entry {
            gui: Style {
                bg: Some(Color::Rgb(0x41, 0x45, 0x59)),
                rounded: Some(true),
                shadow: Some(true),
                ..Style::default()
            },
            ..Entry::default()
        },
    );
    frame.theme = Arc::new(theme);
    let grid = compose(&frame, Surface::Gui);
    let chrome = Chrome::of(&frame);
    assert!(chrome.rounded && chrome.shadows);
    let scene = build(&grid, None, &chrome, &mut fonts, &mut atlas, &palette).unwrap();
    gpu.upload(&mut atlas);
    let (cw, ch) = (fonts.cell_w, fonts.cell_h);
    let size = ((40.0 * cw).ceil() as u32, (7.0 * ch).ceil() as u32);
    let rgba = gpu.snapshot(size, &scene);
    save("chrome.png", size, &rgba);
    let at = |col: f32, row: f32| pixel(&rgba, size.0, (col * cw) as u32, (row * ch) as u32);
    let green = [0xb5, 0xbd, 0x68];
    // The ends are half circles: green in the middle of their cells, not
    // in their outer corners.
    assert_eq!(at(0.9, status as f32 + 0.5)[..3], green);
    assert_ne!(
        at(0.05, status as f32 + 0.05)[..3],
        green,
        "a round left end"
    );
    assert_eq!(at(9.1, status as f32 + 0.5)[..3], green);
    assert_ne!(
        at(9.95, status as f32 + 0.95)[..3],
        green,
        "a round right end"
    );
    // The float's box goes through the middle of its border cells, rounded:
    // the border's outer corner shows what's under it.
    let corner = at(25.05, 3.05);
    assert_eq!(
        corner[..3],
        [0x30, 0x34, 0x46],
        "outside the rounded corner, the text's background, not the window's default"
    );
    // Its shadow darkens the text area below it.
    let shade = at(30.0, 5.9);
    assert!(
        shade[..3]
            .iter()
            .zip(&[0x30, 0x34, 0x46])
            .all(|(s, b)| s < b),
        "shadow under the float: {shade:?}"
    );
}

#[test]
fn prose_is_drawn_narrower_and_the_cursor_follows_the_text() {
    let Some(mut gpu) = Gpu::headless(wgpu::TextureFormat::Rgba8Unorm, 1024) else {
        return;
    };
    let mut fonts = Fonts::new(None, 16.0);
    let mut atlas = Atlas::new(1024);
    let palette = Palette::default();
    let mut frame = frame();
    frame.floats.clear();
    let mut theme = (*frame.theme).clone();
    theme.set(
        "prose",
        Entry {
            gui: Style {
                font: Some(greed_core::theme::Font::Prose),
                ..Style::default()
            },
            ..Entry::default()
        },
    );
    frame.theme = Arc::new(theme);
    let words = "Illuminating paragraphs of prose";
    frame.rows[0] = row(&[(words, "prose"), ("|", "")]);
    let col = words.len() as u16;
    frame.cursor = Some(Position { col, row: 0 });
    let grid = compose(&frame, Surface::Gui);
    let cursor = frame.cursor.map(|c| (c, frame.cursor_shape));
    let scene = build(
        &grid,
        cursor,
        &Chrome::default(),
        &mut fonts,
        &mut atlas,
        &palette,
    )
    .unwrap();
    gpu.upload(&mut atlas);
    let (cw, ch) = (fonts.cell_w, fonts.cell_h);
    let size = ((40.0 * cw).ceil() as u32, (7.0 * ch).ceil() as u32);
    let rgba = gpu.snapshot(size, &scene);
    save("prose.png", size, &rgba);
    let x = scene.columns.x(0, usize::from(col));
    assert!(
        x < f32::from(col) * cw,
        "prose is narrower: {x} < {}",
        f32::from(col) * cw
    );
    // The block cursor is where the "|" is drawn, after the prose.
    let at = pixel(&rgba, size.0, (x + cw * 0.15) as u32, (ch * 0.1) as u32);
    assert_eq!(at[..3], palette.fg, "the cursor at {x}");
    // And nothing is drawn where the grid would have put it.
    let grid_x = f32::from(col) * cw + cw / 2.0;
    assert_eq!(
        pixel(&rgba, size.0, grid_x as u32, (ch / 2.0) as u32)[..3],
        palette.bg
    );
}

#[test]
fn a_float_over_prose_keeps_its_place() {
    let Some(mut gpu) = Gpu::headless(wgpu::TextureFormat::Rgba8Unorm, 1024) else {
        return;
    };
    let mut fonts = Fonts::new(None, 16.0);
    let mut atlas = Atlas::new(1024);
    let palette = Palette::default();
    let mut frame = frame();
    let mut theme = (*frame.theme).clone();
    theme.set(
        "prose",
        Entry {
            gui: Style {
                font: Some(greed_core::theme::Font::Prose),
                ..Style::default()
            },
            ..Entry::default()
        },
    );
    frame.theme = Arc::new(theme);
    // Prose all along the row the float ("a float", from cell 26) is on.
    frame.rows[4] = row(&[("Illuminating paragraphs of prose run under", "prose")]);
    let grid = compose(&frame, Surface::Gui);
    let scene = build(
        &grid,
        None,
        &Chrome::of(&frame),
        &mut fonts,
        &mut atlas,
        &palette,
    )
    .unwrap();
    gpu.upload(&mut atlas);
    let (cw, ch) = (fonts.cell_w, fonts.cell_h);
    let size = ((40.0 * cw).ceil() as u32, (7.0 * ch).ceil() as u32);
    let rgba = gpu.snapshot(size, &scene);
    save("float-over-prose.png", size, &rgba);
    assert!(
        scene.columns.x(4, 20) < 20.0 * cw,
        "the prose before it flows"
    );
    for col in 25..39 {
        assert_eq!(
            scene.columns.x(4, col),
            col as f32 * cw,
            "the float's cell {col}"
        );
    }
    // "a float"'s "a" is drawn in its own cell.
    let inked = ((26.0 * cw) as u32..(27.0 * cw) as u32)
        .flat_map(|x| ((4.0 * ch) as u32..(5.0 * ch) as u32).map(move |y| (x, y)))
        .any(|(x, y)| pixel(&rgba, size.0, x, y)[..3] != palette.bg);
    assert!(inked, "the float's text where its box is");
}
