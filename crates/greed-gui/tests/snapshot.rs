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

use greed_core::image::ImageId;
use greed_core::render::grid::compose;
use greed_core::render::{
    Frame, ImagePlacement, Position, Rect, Role, Row, Size, Span, Surface, SurfaceId, Tag,
};
use greed_core::theme::{Color, Entry, Medium, Style, Theme};
use greed_core::{CursorShape, ViewId};
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
    ];
    let status = Row {
        tags: [Tag::STATUS].into_iter().collect(),
        ..row(&[(" NORMAL  main.rs", "")])
    };
    let rect = |x, y, width, height| Rect {
        x,
        y,
        width,
        height,
    };
    let float = Role::Float {
        border: true,
        title: Some("pick".to_owned()),
        label: Vec::new(),
        footer: Vec::new(),
    };
    Frame {
        size: Size {
            width: 40,
            height: 7,
        },
        // The pane, the status line, then the float.
        surfaces: vec![
            Surface::new(
                SurfaceId::View(ViewId(1)),
                Role::Pane { active: true },
                rect(0, 0, 40, 6),
                rows,
            ),
            Surface::new(
                SurfaceId::Status,
                Role::Status,
                rect(0, 6, 40, 1),
                vec![status],
            ),
            Surface::new(
                SurfaceId::View(ViewId(2)),
                float,
                rect(26, 4, 12, 1),
                vec![row(&[("a float", "")])],
            ),
        ],
        lines: Vec::new(),
        images: Vec::new(),
        scenes: Vec::new(),
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
    let grid = compose(&frame, Medium::Gui);
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
    // The status line's background fills its row (away from the float, whose
    // shadow falls on its right end).
    let status = pixel(&rgba, size.0, (22.5 * cw) as u32, (6.5 * ch) as u32);
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
    frame.surfaces[0].rows[1] = row(&[("    a -> b != c;", "")]);
    let grid = compose(&frame, Medium::Gui);
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
    frame.surfaces.truncate(2);
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
    let grid = compose(&frame, Medium::Gui);
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
fn an_image_under_the_text_shows_the_text_over_it_as_scenes_are_drawn() {
    let Some(mut gpu) = Gpu::headless(wgpu::TextureFormat::Rgba8Unorm, 1024) else {
        return;
    };
    let mut fonts = Fonts::new(None, 16.0);
    let mut atlas = Atlas::new(1024);
    let palette = Palette::default();
    let mut frame = frame();
    frame.surfaces.truncate(2);
    let id = ImageId(1);
    // Over "    let x" on the second row: spaces, then text.
    let placed = [ImagePlacement {
        id,
        rect: Rect {
            x: 0,
            y: 1,
            width: 8,
            height: 1,
        },
        col: 0,
        row: 0,
        cols: 8,
        rows: 1,
    }];
    let pngs = HashMap::from([(id, halves(80, 20))]);
    let grid = compose(&frame, Medium::Gui);
    let drawn = |chrome: &Chrome, fonts: &mut Fonts, atlas: &mut Atlas| {
        build(&grid, None, chrome, fonts, atlas, &palette).unwrap()
    };
    let mut under = Chrome::of(&frame);
    under.under = &placed;
    let scene = drawn(&under, &mut fonts, &mut atlas);
    gpu.upload(&mut atlas);
    gpu.place_images(&placed, &pngs);
    let (cw, ch) = (fonts.cell_w, fonts.cell_h);
    let size = ((40.0 * cw).ceil() as u32, (7.0 * ch).ceil() as u32);
    let rgba = gpu.snapshot(size, &scene);
    save("under.png", size, &rgba);
    // The cells of `let`, 4 to 7, the text drawn over the image's blue
    // half; a couple of pixels in, clear of where the image's edges blend.
    let not_blue = |rgba: &[u8]| {
        let mut count = 0;
        for y in (ch * 1.0) as u32 + 2..(ch * 2.0) as u32 - 2 {
            for x in (cw * 4.0) as u32 + 2..(cw * 7.0) as u32 - 2 {
                if pixel(rgba, size.0, x, y)[..3] != [0, 0, 255] {
                    count += 1;
                }
            }
        }
        count
    };
    let at = |rgba: &[u8], col: f32| pixel(rgba, size.0, (col * cw) as u32, (1.5 * ch) as u32);
    assert_eq!(
        at(&rgba, 1.5)[..3],
        [255, 0, 0],
        "the image shows where there's no text"
    );
    assert!(not_blue(&rgba) > 0, "the text is over it");
    let mut over = Chrome::of(&frame);
    over.images = &placed;
    let covered = drawn(&over, &mut fonts, &mut atlas);
    let rgba = gpu.snapshot(size, &covered);
    assert_eq!(not_blue(&rgba), 0, "an image over the text hides it");
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
    frame.surfaces.truncate(2);
    // "Hi" twice the size over columns 0-3 and rows 0-1, then "x" at the
    // normal size on the same baseline.
    frame.surfaces[0].rows[0] = Row {
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
    frame.surfaces[0].rows[1] = Row::default();
    frame.cursor = Some(Position { col: 0, row: 0 });
    let grid = compose(&frame, Medium::Gui);
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
    // The block cursor covers all four cells of the big "H": the lower two
    // as well, mostly the cursor's color around the letter's strokes (one
    // pixel could land on a stroke, wherever the font puts it).
    let lower: Vec<(u32, u32)> = (0..(2.0 * cw) as u32)
        .flat_map(|x| (ch as u32 + 1..(2.0 * ch) as u32).map(move |y| (x, y)))
        .collect();
    let covered = lower
        .iter()
        .filter(|&&(x, y)| pixel(&rgba, size.0, x, y)[..3] != palette.bg)
        .count();
    assert!(
        covered * 2 > lower.len(),
        "the cursor's lower half: {covered} of {}",
        lower.len()
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
fn a_pane_beside_scaled_text_draws_its_own_rows() {
    let Some(mut gpu) = Gpu::headless(wgpu::TextureFormat::Rgba8Unorm, 1024) else {
        return;
    };
    let mut fonts = Fonts::new(None, 16.0);
    let mut atlas = Atlas::new(1024);
    let palette = Palette::default();
    let mut frame = frame();
    frame.surfaces.truncate(2);
    // A heading twice the size in the left pane, and a terminal's lines in
    // the right one, "top" and then "next" a row each.
    frame.surfaces[0].rect.width = 20;
    frame.surfaces[0].rows[0] = Row {
        spans: vec![Span {
            scale: 2,
            ..Span::new("Hi", SmallVec::default())
        }],
        covers: 1,
        ..Row::default()
    };
    frame.surfaces[0].rows[1] = Row::default();
    frame.surfaces.push(Surface::new(
        SurfaceId::View(ViewId(3)),
        Role::Pane { active: false },
        Rect {
            x: 20,
            y: 0,
            width: 20,
            height: 6,
        },
        vec![row(&[("top", "")]), row(&[("next", "")])],
    ));
    frame.cursor = None;
    let grid = compose(&frame, Medium::Gui);
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
    let (cw, ch) = (fonts.cell_w, fonts.cell_h);
    let size = ((40.0 * cw).ceil() as u32, (7.0 * ch).ceil() as u32);
    let rgba = gpu.snapshot(size, &scene);
    save("scaled-beside.png", size, &rgba);
    let inked = |cols: std::ops::Range<f32>, rows: std::ops::Range<f32>| {
        ((cols.start * cw) as u32..(cols.end * cw) as u32)
            .flat_map(|x| ((rows.start * ch) as u32..(rows.end * ch) as u32).map(move |y| (x, y)))
            .filter(|&(x, y)| pixel(&rgba, size.0, x, y)[..3] != palette.bg)
            .count()
    };
    // The right pane's "top" sits in its own first row, and "next" shows
    // in the second, beside the heading's lower half.
    assert!(inked(20.0..23.0, 0.0..1.0) > 0, "top, in the first row");
    assert!(inked(20.0..24.0, 1.0..2.0) > 0, "next, in the second row");
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
    let status = usize::from(frame.surfaces[1].rect.y);
    // A pill as the status line plugin makes one: round ends from a
    // Powerline font around the mode.
    frame.surfaces[1].rows[0] = Row {
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
        !Chrome::of(&frame).rounded && Chrome::of(&frame).shadows,
        "rounded only where the theme says, shadows unless it says not"
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
    let grid = compose(&frame, Medium::Gui);
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
fn floats_cast_shadows_unless_the_theme_says_not_lighter_on_a_light_background() {
    // `frame` with its text and float backgrounds `text` and `float`, and
    // its floats rounded, with shadows as `shadow` says.
    fn themed(text: (u8, u8, u8), float: (u8, u8, u8), shadow: Option<bool>) -> Frame {
        let mut frame = frame();
        let mut theme = (*frame.theme).clone();
        for (name, (r, g, b)) in [("ui.text", text), ("ui.float", float)] {
            let is_float = name == "ui.float";
            theme.set(
                name,
                Entry::new(Style {
                    bg: Some(Color::Rgb(r, g, b)),
                    rounded: is_float.then_some(true),
                    shadow: if is_float { shadow } else { None },
                    ..Style::default()
                }),
            );
        }
        frame.theme = Arc::new(theme);
        frame
    }
    let (dark, light) = ((0x30, 0x34, 0x46), (0xef, 0xf1, 0xf5));
    assert!(
        Chrome::of(&themed(dark, dark, None)).shadows,
        "on by default"
    );
    assert!(
        !Chrome::of(&themed(dark, dark, Some(false))).shadows,
        "a theme can turn them off"
    );
    let Some(mut gpu) = Gpu::headless(wgpu::TextureFormat::Rgba8Unorm, 1024) else {
        return;
    };
    let mut fonts = Fonts::new(None, 16.0);
    let mut atlas = Atlas::new(1024);
    let palette = Palette::default();
    // How much darker the shadow makes the blue under the float, with the
    // text's background `under` and the float's `float`.
    let mut drop = |name: &str, under: (u8, u8, u8), float: (u8, u8, u8)| {
        let frame = themed(under, float, None);
        let grid = compose(&frame, Medium::Gui);
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
        save(name, size, &rgba);
        let shade = pixel(&rgba, size.0, (30.0 * cw) as u32, (5.9 * ch) as u32);
        i32::from(under.2) - i32::from(shade[2])
    };
    let on_dark = drop("shadow-dark.png", dark, (0x41, 0x45, 0x59));
    let on_light = drop("shadow-light.png", light, (0xe6, 0xe9, 0xef));
    assert!(on_dark > 0 && on_light > 0, "{on_dark} {on_light}");
    // Black at the same depth would take about three and a half times as
    // much off the light background.
    assert!(
        on_light < on_dark * 5 / 2,
        "lighter on light: {on_light} against {on_dark}"
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
    frame.surfaces.truncate(2);
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
    frame.surfaces[0].rows[0] = row(&[(words, "prose"), ("|", "")]);
    let col = words.len() as u16;
    frame.cursor = Some(Position { col, row: 0 });
    let grid = compose(&frame, Medium::Gui);
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
    frame.surfaces[0].rows[4] = row(&[("Illuminating paragraphs of prose run under", "prose")]);
    let grid = compose(&frame, Medium::Gui);
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

#[test]
fn a_badge_style_draws_a_box_inside_its_cells_over_the_background_beside_it() {
    let Some(mut gpu) = Gpu::headless(wgpu::TextureFormat::Rgba8Unorm, 1024) else {
        return;
    };
    let mut fonts = Fonts::new(None, 16.0);
    let mut atlas = Atlas::new(1024);
    let palette = Palette::default();
    let mut frame = frame();
    let mut theme = (*frame.theme).clone();
    let badge = [0x51, 0x57, 0x6d];
    let line = [0x29, 0x2c, 0x3c];
    theme.set(
        "hint",
        Entry {
            style: Style {
                bg: Some(Color::Rgb(badge[0], badge[1], badge[2])),
                ..Style::default()
            },
            gui: Style {
                badge: Some(true),
                ..Style::default()
            },
            ..Entry::default()
        },
    );
    theme.set(
        "line",
        Entry::new(Style {
            bg: Some(Color::Rgb(line[0], line[1], line[2])),
            ..Style::default()
        }),
    );
    frame.theme = Arc::new(theme);
    // A hint between words, on a plain row and on one with a background.
    frame.surfaces[0].rows[4] = row(&[("one", ""), ("2", "hint"), ("two", "")]);
    frame.surfaces[0].rows[5] = row(&[("one", "line"), ("2", "hint"), ("two", "line")]);
    let grid = compose(&frame, Medium::Gui);
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
    save("badge.png", size, &rgba);
    let at = |col: f32, row: f32| pixel(&rgba, size.0, (col * cw) as u32, (row * ch) as u32);
    // Just inside the badge's left edge, halfway down, beside its digit;
    // and its cell's top corner, outside it, which shows the row's own
    // background.
    let edge = |row: f32| {
        let x = 3.0 * cw + 0.05 * ch + 2.0;
        pixel(&rgba, size.0, x as u32, (row * ch) as u32)
    };
    assert_eq!(edge(4.5)[..3], badge);
    assert_eq!(at(3.0, 4.02)[..3], palette.bg[..3]);
    assert_eq!(edge(5.5)[..3], badge);
    assert_eq!(
        at(3.0, 5.02)[..3],
        line,
        "the background beside it, under the corner"
    );
}

#[test]
fn what_is_under_a_rounded_floats_border_goes_on_behind_it_and_its_title_is_a_pill() {
    let Some(mut gpu) = Gpu::headless(wgpu::TextureFormat::Rgba8Unorm, 1024) else {
        return;
    };
    let mut fonts = Fonts::new(None, 16.0);
    let mut atlas = Atlas::new(1024);
    let palette = Palette::default();
    let mut frame = frame();
    let mut theme = (*frame.theme).clone();
    let block = [0x29, 0x2c, 0x3c];
    let fill = [0x41, 0x45, 0x59];
    theme.set(
        "block",
        Entry::new(Style {
            bg: Some(Color::Rgb(block[0], block[1], block[2])),
            ..Style::default()
        }),
    );
    for name in ["ui.float", "ui.float.border", "ui.float.title"] {
        theme.set(
            name,
            Entry::new(Style {
                bg: Some(Color::Rgb(fill[0], fill[1], fill[2])),
                rounded: Some(true),
                ..Style::default()
            }),
        );
    }
    frame.theme = Arc::new(theme);
    // A code block's rows over and under the float's top border (row 3).
    for y in [2, 3] {
        frame.surfaces[0].rows[y] = row(&[(&" ".repeat(40), "block")]);
    }
    let grid = compose(&frame, Medium::Gui);
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
    save("float-edge.png", size, &rgba);
    let at = |col: f32, row: f32| pixel(&rgba, size.0, (col * cw) as u32, (row * ch) as u32);
    // Above the outline, through the middle of the border row, the block
    // goes on; below it, the float's fill.
    assert_eq!(at(36.5, 3.1)[..3], block, "above the outline");
    assert_eq!(at(36.5, 3.9)[..3], fill, "inside the float");
    // The title's cells: the block at their very top, the pill below.
    let title = grid[3]
        .iter()
        .position(|c| c.text == "p")
        .expect("the title is on the border row");
    assert_eq!(
        at(title as f32 + 0.5, 3.02)[..3],
        block,
        "over the title's pill"
    );
    assert_eq!(at(title as f32 - 0.5, 3.5)[..3], fill, "the title's pill");
}

#[test]
fn a_float_over_a_panel_casts_its_shadow_on_it_with_the_panel_going_on_behind_its_border() {
    let Some(mut gpu) = Gpu::headless(wgpu::TextureFormat::Rgba8Unorm, 1024) else {
        return;
    };
    let mut fonts = Fonts::new(None, 16.0);
    let mut atlas = Atlas::new(1024);
    let palette = Palette::default();
    let mut frame = frame();
    let mut theme = (*frame.theme).clone();
    let window = [0x30, 0x34, 0x46];
    let block = [0xc0, 0xa0, 0x80];
    for (name, bg, rounded) in [
        ("ui.text", window, None),
        ("ui.float", [0x41, 0x45, 0x59], Some(true)),
        ("block", block, None),
    ] {
        theme.set(
            name,
            Entry::new(Style {
                bg: Some(Color::Rgb(bg[0], bg[1], bg[2])),
                rounded,
                ..Style::default()
            }),
        );
    }
    frame.theme = Arc::new(theme);
    // A pane on the left, a panel on the right with a block of color on
    // every row, and a float over both, its right side over the panel.
    let pane = &mut frame.surfaces[0];
    pane.rect.width = 20;
    pane.rows.truncate(6);
    frame.surfaces.insert(
        2,
        Surface::new(
            SurfaceId::View(ViewId(3)),
            Role::Panel {
                separator: 20,
                title: None,
            },
            Rect {
                x: 21,
                y: 0,
                width: 19,
                height: 6,
            },
            (0..6).map(|_| row(&[(&" ".repeat(19), "block")])).collect(),
        ),
    );
    frame.surfaces[3].rect = Rect {
        x: 10,
        y: 2,
        width: 20,
        height: 1,
    };
    let grid = compose(&frame, Medium::Gui);
    let chrome = Chrome::of(&frame);
    assert!(chrome.rounded && chrome.shadows);
    let scene = build(&grid, None, &chrome, &mut fonts, &mut atlas, &palette).unwrap();
    gpu.upload(&mut atlas);
    let (cw, ch) = (fonts.cell_w, fonts.cell_h);
    let size = ((40.0 * cw).ceil() as u32, (7.0 * ch).ceil() as u32);
    let rgba = gpu.snapshot(size, &scene);
    save("float-over-panel.png", size, &rgba);
    let at = |col: f32, row: f32| pixel(&rgba, size.0, (col * cw) as u32, (row * ch) as u32);
    // The float's right border (column 30) and bottom border (row 3) are
    // over the panel. Outside its outline there, the panel's block goes on,
    // darkened by the shadow; the window's own color would be far darker.
    for (what, shade) in [
        ("beside the float", at(30.8, 2.5)),
        ("below the float", at(25.0, 3.9)),
    ] {
        assert!(
            shade[0] > 0x60 && shade[0] < block[0],
            "{what}: the block, in the shadow: {shade:?}"
        );
    }
    assert_eq!(at(35.0, 0.5)[..3], block, "the block away from the float");
}

#[test]
fn checkbox_styles_draw_an_outlined_box_or_a_filled_one_with_a_tick() {
    let Some(mut gpu) = Gpu::headless(wgpu::TextureFormat::Rgba8Unorm, 1024) else {
        return;
    };
    let mut fonts = Fonts::new(None, 16.0);
    let mut atlas = Atlas::new(1024);
    let palette = Palette::default();
    let mut frame = frame();
    let mut theme = (*frame.theme).clone();
    let yellow = [0xe5, 0xc8, 0x90];
    for (name, kind) in [
        ("todo", greed_core::theme::Checkbox::Empty),
        ("done", greed_core::theme::Checkbox::Checked),
        ("choice", greed_core::theme::Checkbox::Choice),
        ("chosen", greed_core::theme::Checkbox::Chosen),
    ] {
        theme.set(
            name,
            Entry {
                style: Style {
                    fg: Some(Color::Rgb(yellow[0], yellow[1], yellow[2])),
                    ..Style::default()
                },
                gui: Style {
                    checkbox: Some(kind),
                    ..Style::default()
                },
                ..Entry::default()
            },
        );
    }
    frame.theme = Arc::new(theme);
    // A todo's box as notes shows it: a symbol and a space, then the text.
    frame.surfaces[0].rows[4] = row(&[("☐ ", "todo"), ("buy milk", "")]);
    frame.surfaces[0].rows[5] = row(&[("☑ ", "done"), ("call mum", "")]);
    // Choices, a ring and a ring with a dot.
    frame.surfaces[0].rows[2] = row(&[("◯ ", "choice"), ("dark", "")]);
    frame.surfaces[0].rows[3] = row(&[("◉ ", "chosen"), ("light", "")]);
    let grid = compose(&frame, Medium::Gui);
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
    save("checkbox.png", size, &rgba);
    // The box is centred on the two cells, 0.62 of a row tall.
    let box_side = ch * 0.62;
    let (left, middle) = (cw - box_side / 2.0, ch / 2.0);
    let at = |x: f32, y: f32| pixel(&rgba, size.0, x as u32, y as u32);
    // Empty: the outline in the todo's color (smoothed at its edges), the
    // middle the background.
    let edge = at(left + 1.0, 4.0 * ch + middle);
    assert!(
        edge[..3]
            .iter()
            .zip(&yellow)
            .all(|(a, b)| a.abs_diff(*b) < 40),
        "the empty box's edge: {edge:?}"
    );
    assert_eq!(
        at(cw, 4.0 * ch + middle)[..3],
        palette.bg,
        "the empty box's inside"
    );
    // Checked: filled, away from the tick in its middle.
    assert_eq!(
        at(left + 2.0, 5.0 * ch + middle)[..3],
        yellow,
        "the checked box's fill"
    );
    // The text after it starts where it always did.
    let inked = ((2.0 * cw) as u32..(3.0 * cw) as u32)
        .flat_map(|x| ((4.0 * ch) as u32..(5.0 * ch) as u32).map(move |y| (x, y)))
        .any(|(x, y)| pixel(&rgba, size.0, x, y)[..3] != palette.bg);
    assert!(inked, "the todo's text after the box");
    // The ring is empty in the middle; the picked one has a dot there.
    assert_eq!(
        at(cw, 2.0 * ch + middle)[..3],
        palette.bg,
        "the choice's middle"
    );
    assert_eq!(
        at(cw, 3.0 * ch + middle)[..3],
        yellow,
        "the chosen one's dot"
    );
}
