//! Images in the terminal Greed runs in, drawn with the kitty graphics
//! protocol (kitty, Ghostty, `WezTerm`, Konsole). Each image is sent once and
//! then placed, cropped and scaled, wherever a frame puts it. Scenes are
//! drawn into images of their own, which go under the text, so a scene's
//! labels stay the terminal's text.

use std::collections::{HashMap, HashSet};
use std::io::{self, Write};

use base64::Engine;
use crossterm::{cursor, queue};
use greed_core::image::ImageId;
use greed_core::render::{ImagePlacement, ScenePlacement};
use greed_core::scene_image::{Drawer, Shown};
use greed_core::server::{ImageData, SceneData};
use greed_core::theme::{Medium, Theme};

/// The first id of the images scenes are drawn into, above any the editor
/// gives its own; kitty's ids are 32 bits.
const SCENE_IMAGES: u64 = 0x8000_0000;

/// How much base64 goes in one escape sequence; the protocol's limit.
const CHUNK: usize = 4096;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Protocol {
    Kitty,
}

/// The image protocol this terminal speaks, from `$GREED_IMAGES` ("kitty"
/// or "none") or the variables terminals set.
pub fn detect() -> Option<Protocol> {
    let var = |name: &str| std::env::var(name).unwrap_or_default();
    match var("GREED_IMAGES").as_str() {
        "kitty" => return Some(Protocol::Kitty),
        "none" => return None,
        _ => {}
    }
    let term = var("TERM");
    let program = var("TERM_PROGRAM");
    let kitty = term.contains("kitty")
        || term.contains("ghostty")
        || matches!(program.as_str(), "ghostty" | "WezTerm")
        || std::env::var_os("KITTY_WINDOW_ID").is_some()
        || std::env::var_os("KONSOLE_VERSION").is_some();
    kitty.then_some(Protocol::Kitty)
}

pub struct Graphics {
    protocol: Option<Protocol>,
    images: HashMap<ImageId, ImageData>,
    /// Images the terminal has the data of.
    sent: HashSet<ImageId>,
    /// What's on screen now.
    placed: Vec<ImagePlacement>,
    /// Scenes, and the images they're drawn into.
    drawer: Drawer,
    /// A cell's size in pixels, once the terminal said.
    cell: Option<(u16, u16)>,
}

impl Default for Graphics {
    fn default() -> Self {
        Self {
            protocol: None,
            images: HashMap::new(),
            sent: HashSet::new(),
            placed: Vec::new(),
            drawer: Drawer::new(SCENE_IMAGES),
            cell: None,
        }
    }
}

impl Graphics {
    pub fn new(protocol: Option<Protocol>) -> Self {
        Self {
            protocol,
            ..Self::default()
        }
    }

    pub fn add(&mut self, image: ImageData) {
        self.images.insert(image.id, image);
    }

    /// The screen was cleared, and the images on it with it. Its cells may
    /// be another size now.
    pub fn cleared(&mut self) {
        self.placed.clear();
        self.cell = None;
    }

    /// Keeps `scene` as it is now, for frames to place.
    pub fn add_scene(&mut self, scene: SceneData) {
        self.drawer.add(scene);
    }

    /// Says how big a cell is in pixels, as the terminal would.
    #[cfg(test)]
    pub fn set_cell(&mut self, cell: (u16, u16)) {
        self.cell = Some(cell);
    }

    /// A cell's size in pixels, asking the terminal the first time.
    fn cell(&mut self) -> Option<(u16, u16)> {
        if self.cell.is_none()
            && let Ok(size) = crossterm::terminal::window_size()
            && size.columns > 0
            && size.rows > 0
            && size.width > 0
        {
            self.cell = Some((size.width / size.columns, size.height / size.rows));
        }
        self.cell
    }

    /// Draws the scenes `placements` show into images, as needed, with
    /// `theme`'s colors: the ones it could, each with the image to place.
    /// Empty without a protocol, or before the terminal said its cell size.
    pub fn scenes(
        &mut self,
        out: &mut impl Write,
        placements: &[ScenePlacement],
        theme: &Theme,
    ) -> io::Result<Vec<Shown>> {
        if self.protocol.is_none() {
            return Ok(Vec::new());
        }
        let Some(cell) = self.cell() else {
            return Ok(Vec::new());
        };
        let drawing = self.drawer.draw(placements, cell, theme, Medium::Tui);
        for id in drawing.gone {
            self.forget(out, id)?;
        }
        for (id, png, width, height) in drawing.drawn {
            let png = base64::engine::general_purpose::STANDARD.encode(png);
            self.images.insert(
                id,
                ImageData {
                    id,
                    width,
                    height,
                    png,
                },
            );
        }
        Ok(drawing.shown)
    }

    /// The screen cells `shown` covers that don't hold its scene's text.
    pub fn uncovered(&self, shown: &Shown) -> Vec<(u16, u16)> {
        self.drawer.uncovered(shown)
    }

    /// Takes image `id`, one a scene was drawn into before, off the
    /// terminal, its data too.
    fn forget(&mut self, out: &mut impl Write, id: ImageId) -> io::Result<()> {
        self.images.remove(&id);
        if self.sent.remove(&id) {
            write!(out, "\x1b_Ga=d,d=I,i={},q=2\x1b\\", id.0)?;
        }
        Ok(())
    }

    /// Shows `placements`, replacing what was there.
    pub fn draw(&mut self, out: &mut impl Write, placements: &[ImagePlacement]) -> io::Result<()> {
        if self.protocol.is_none() || self.placed == placements {
            return Ok(());
        }
        // Lower case keeps the images' data, so placing them again is cheap.
        write!(out, "\x1b_Ga=d,d=a,q=2\x1b\\")?;
        for (n, placement) in placements.iter().enumerate() {
            let Some(image) = self.images.get(&placement.id) else {
                continue;
            };
            if self.sent.insert(image.id) {
                transmit(out, image)?;
            }
            // A scene's image goes under the text, which holds its labels.
            let under = image.id.0 >= SCENE_IMAGES;
            place(out, image, placement, n + 1, under)?;
        }
        self.placed = placements.to_vec();
        Ok(())
    }
}

/// Sends the image's PNG, in chunks.
fn transmit(out: &mut impl Write, image: &ImageData) -> io::Result<()> {
    let chunks: Vec<&[u8]> = image.png.as_bytes().chunks(CHUNK).collect();
    for (i, chunk) in chunks.iter().enumerate() {
        let more = u8::from(i + 1 < chunks.len());
        let chunk = std::str::from_utf8(chunk).unwrap_or_default();
        if i == 0 {
            write!(
                out,
                "\x1b_Ga=t,f=100,t=d,i={},q=2,m={more};{chunk}\x1b\\",
                image.id.0
            )?;
        } else {
            write!(out, "\x1b_Gm={more};{chunk}\x1b\\")?;
        }
    }
    Ok(())
}

/// Puts the part of `image` the placement shows over its cells, as
/// placement `n` of the image; `under` the text there.
fn place(
    out: &mut impl Write,
    image: &ImageData,
    p: &ImagePlacement,
    n: usize,
    under: bool,
) -> io::Result<()> {
    // The part shown, in the image's pixels.
    let crop = |cell: u16, cells: u16, pixels: u32| {
        u32::try_from(u64::from(cell) * u64::from(pixels) / u64::from(cells.max(1)))
            .unwrap_or(pixels)
    };
    let x = crop(p.col, p.cols, image.width);
    let y = crop(p.row, p.rows, image.height);
    let w = crop(p.col.saturating_add(p.rect.width), p.cols, image.width).saturating_sub(x);
    let h = crop(p.row.saturating_add(p.rect.height), p.rows, image.height).saturating_sub(y);
    queue!(out, cursor::MoveTo(p.rect.x, p.rect.y))?;
    let z = if under { ",z=-1" } else { "" };
    write!(
        out,
        "\x1b_Ga=p,i={},p={n},x={x},y={y},w={w},h={h},c={},r={},C=1,q=2{z}\x1b\\",
        image.id.0, p.rect.width, p.rect.height
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use greed_core::render::Rect;
    use greed_core::scene::SceneId;

    fn image() -> ImageData {
        ImageData {
            id: ImageId(7),
            width: 100,
            height: 40,
            png: "A".repeat(CHUNK + 10),
        }
    }

    fn text(out: &[u8]) -> String {
        String::from_utf8_lossy(out).into_owned()
    }

    #[test]
    fn images_are_sent_once_then_placed_cropped() {
        let mut graphics = Graphics::new(Some(Protocol::Kitty));
        graphics.add(image());
        // The bottom half of a 10 by 4 cell image, at (5, 2).
        let placement = ImagePlacement {
            id: ImageId(7),
            rect: Rect {
                x: 5,
                y: 2,
                width: 10,
                height: 2,
            },
            col: 0,
            row: 2,
            cols: 10,
            rows: 4,
        };
        let mut out = Vec::new();
        graphics.draw(&mut out, &[placement]).unwrap();
        let sent = text(&out);
        assert!(sent.contains("a=t,f=100,t=d,i=7,q=2,m=1;"), "{sent}");
        assert!(
            sent.contains("\x1b_Gm=0;AAAAAAAAAA\x1b\\"),
            "the rest in a second chunk"
        );
        assert!(
            sent.contains("a=p,i=7,p=1,x=0,y=20,w=100,h=20,c=10,r=2,C=1"),
            "{sent}"
        );

        let mut again = Vec::new();
        graphics.draw(&mut again, &[placement]).unwrap();
        assert!(again.is_empty(), "nothing changed");

        graphics.cleared();
        let mut after = Vec::new();
        graphics.draw(&mut after, &[placement]).unwrap();
        let after = text(&after);
        assert!(!after.contains("a=t"), "the data is already there");
        assert!(after.contains("a=p,i=7"));
    }

    fn scene(version: u64) -> SceneData {
        SceneData {
            id: SceneId(3),
            version,
            spec: serde_json::json!({ "alt": "bars", "items": [
                { "kind": "rect", "at": [0, 0], "size": [2, 1], "fill": "chart.series.1" },
                { "kind": "text", "at": [3, 0], "text": "12", "style": "chart.label" },
            ] }),
        }
    }

    fn scene_placement(version: u64) -> ScenePlacement {
        ScenePlacement {
            id: SceneId(3),
            version,
            rect: Rect {
                x: 2,
                y: 1,
                width: 5,
                height: 1,
            },
            col: 0,
            row: 0,
            cols: 5,
            rows: 1,
        }
    }

    #[test]
    fn a_scene_is_drawn_into_an_image_under_the_text_and_again_as_it_changes() {
        let mut graphics = Graphics::new(Some(Protocol::Kitty));
        graphics.set_cell((10, 20));
        graphics.add_scene(scene(1));
        let theme = Theme::default();
        let mut out = Vec::new();
        let shown = graphics
            .scenes(&mut out, &[scene_placement(1)], &theme)
            .unwrap();
        assert_eq!(shown.len(), 1);
        let first = shown[0].image;
        assert!(first.id.0 >= SCENE_IMAGES && first.rect == scene_placement(1).rect);
        assert_eq!(
            graphics.uncovered(&shown[0]),
            [(2, 1), (3, 1), (4, 1)],
            "its text, in its fourth and fifth cells, stays"
        );
        graphics.draw(&mut out, &[first]).unwrap();
        let sent = text(&out);
        assert!(
            sent.contains(&format!("a=t,f=100,t=d,i={}", first.id.0)),
            "{sent}"
        );
        assert!(sent.contains(",z=-1"), "under the text: {sent}");

        // The same version isn't drawn again.
        let mut again = Vec::new();
        let same = graphics
            .scenes(&mut again, &[scene_placement(1)], &theme)
            .unwrap();
        assert_eq!(same[0].image.id, first.id);
        assert!(again.is_empty());

        // A new version is, and the old image goes from the terminal.
        graphics.add_scene(scene(2));
        let mut changed = Vec::new();
        let next = graphics
            .scenes(&mut changed, &[scene_placement(2)], &theme)
            .unwrap();
        assert_ne!(next[0].image.id, first.id);
        let changed = text(&changed);
        assert!(
            changed.contains(&format!("a=d,d=I,i={}", first.id.0)),
            "{changed}"
        );
    }

    #[test]
    fn scenes_wait_for_the_cell_size_and_a_protocol() {
        let mut none = Graphics::new(None);
        none.set_cell((10, 20));
        none.add_scene(scene(1));
        let mut out = Vec::new();
        assert!(
            none.scenes(&mut out, &[scene_placement(1)], &Theme::default())
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn without_a_protocol_nothing_is_drawn() {
        let mut graphics = Graphics::new(None);
        graphics.add(image());
        let mut out = Vec::new();
        graphics.draw(&mut out, &[]).unwrap();
        assert!(out.is_empty());
    }
}
