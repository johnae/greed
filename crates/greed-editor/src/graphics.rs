//! Images in the terminal Kern runs in, drawn with the kitty graphics
//! protocol (kitty, Ghostty, `WezTerm`, Konsole). Each image is sent once and
//! then placed, cropped and scaled, wherever a frame puts it.

use std::collections::{HashMap, HashSet};
use std::io::{self, Write};

use crossterm::{cursor, queue};
use greed_core::image::ImageId;
use greed_core::render::ImagePlacement;
use greed_core::server::ImageData;

/// How much base64 goes in one escape sequence; the protocol's limit.
const CHUNK: usize = 4096;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Protocol {
    Kitty,
}

/// The image protocol this terminal speaks, from `$KERN_IMAGES` ("kitty"
/// or "none") or the variables terminals set.
pub fn detect() -> Option<Protocol> {
    let var = |name: &str| std::env::var(name).unwrap_or_default();
    match var("KERN_IMAGES").as_str() {
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

#[derive(Default)]
pub struct Graphics {
    protocol: Option<Protocol>,
    images: HashMap<ImageId, ImageData>,
    /// Images the terminal has the data of.
    sent: HashSet<ImageId>,
    /// What's on screen now.
    placed: Vec<ImagePlacement>,
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

    /// The screen was cleared, and the images on it with it.
    pub fn cleared(&mut self) {
        self.placed.clear();
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
            place(out, image, placement, n + 1)?;
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
/// placement `n` of the image.
fn place(out: &mut impl Write, image: &ImageData, p: &ImagePlacement, n: usize) -> io::Result<()> {
    // The part shown, in the image's pixels.
    let crop = |cell: u16, cells: u16, pixels: u32| {
        u32::try_from(u64::from(cell) * u64::from(pixels) / u64::from(cells.max(1)))
            .unwrap_or(pixels)
    };
    let x = crop(p.col, p.cols, image.width);
    let y = crop(p.row, p.rows, image.height);
    let w = crop(p.col + p.rect.width, p.cols, image.width) - x;
    let h = crop(p.row + p.rect.height, p.rows, image.height) - y;
    queue!(out, cursor::MoveTo(p.rect.x, p.rect.y))?;
    write!(
        out,
        "\x1b_Ga=p,i={},p={n},x={x},y={y},w={w},h={h},c={},r={},C=1,q=2\x1b\\",
        image.id.0, p.rect.width, p.rect.height
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use greed_core::render::Rect;

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

    #[test]
    fn without_a_protocol_nothing_is_drawn() {
        let mut graphics = Graphics::new(None);
        graphics.add(image());
        let mut out = Vec::new();
        graphics.draw(&mut out, &[]).unwrap();
        assert!(out.is_empty());
    }
}
