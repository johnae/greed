//! Images the editor can show: in a note, a file preview, or from a program
//! in a terminal. Each is kept as PNG, whatever it came as, which is what
//! clients send on to the terminal they draw in.

use std::collections::HashMap;
use std::io::Cursor;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use serde::{Deserialize, Serialize};

#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize,
)]
pub struct ImageId(pub u64);

impl ImageId {
    /// A new id, unique in this process, so images from terminals and
    /// plugins never clash.
    pub fn next() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        ImageId(NEXT.fetch_add(1, Ordering::Relaxed))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Image {
    pub id: ImageId,
    pub png: Arc<[u8]>,
    /// In pixels.
    pub width: u32,
    pub height: u32,
}

#[derive(Debug)]
pub enum Error {
    /// Not a PNG, JPEG or GIF, or a broken one.
    Decode(String),
    TooBig {
        width: u32,
        height: u32,
    },
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Decode(why) => write!(f, "can't read the image: {why}"),
            Error::TooBig { width, height } => {
                write!(f, "the image is too big ({width}x{height} pixels)")
            }
        }
    }
}

impl std::error::Error for Error {}

/// The most pixels along either side an image may have.
const MAX_SIDE: u32 = 10_000;

impl Image {
    /// An image from the bytes of a PNG, JPEG or GIF file (a GIF's first
    /// frame).
    pub fn from_file_bytes(bytes: &[u8]) -> Result<Self, Error> {
        let format = image::guess_format(bytes).map_err(|e| Error::Decode(e.to_string()))?;
        if format == image::ImageFormat::Png {
            let (width, height) = image::ImageReader::with_format(Cursor::new(bytes), format)
                .into_dimensions()
                .map_err(|e| Error::Decode(e.to_string()))?;
            check(width, height)?;
            return Ok(Self::new(bytes.into(), width, height));
        }
        let decoded = image::load_from_memory_with_format(bytes, format)
            .map_err(|e| Error::Decode(e.to_string()))?;
        Self::from_rgba(&decoded.into_rgba8())
    }

    /// An image from raw pixels, `channels` (3 or 4) bytes each.
    pub fn from_pixels(width: u32, height: u32, channels: u8, data: &[u8]) -> Result<Self, Error> {
        check(width, height)?;
        let expected = u64::from(width) * u64::from(height) * u64::from(channels);
        if data.len() as u64 != expected {
            return Err(Error::Decode(format!(
                "{} bytes for {width}x{height} pixels of {channels} bytes each",
                data.len()
            )));
        }
        let rgba = match channels {
            3 => image::RgbImage::from_raw(width, height, data.to_vec())
                .map(|rgb| image::DynamicImage::ImageRgb8(rgb).into_rgba8()),
            4 => image::RgbaImage::from_raw(width, height, data.to_vec()),
            _ => None,
        }
        .ok_or_else(|| Error::Decode(format!("{channels} bytes per pixel")))?;
        Self::from_rgba(&rgba)
    }

    fn from_rgba(rgba: &image::RgbaImage) -> Result<Self, Error> {
        check(rgba.width(), rgba.height())?;
        let mut png = Vec::new();
        rgba.write_to(&mut Cursor::new(&mut png), image::ImageFormat::Png)
            .map_err(|e| Error::Decode(e.to_string()))?;
        Ok(Self::new(png.into(), rgba.width(), rgba.height()))
    }

    fn new(png: Arc<[u8]>, width: u32, height: u32) -> Self {
        Self {
            id: ImageId::next(),
            png,
            width,
            height,
        }
    }

    /// How many cells it covers at its own size, for cells `cell` pixels
    /// wide and high, at least one each way.
    pub fn cells(&self, cell: (u16, u16)) -> (u16, u16) {
        let across = |pixels: u32, size: u16| {
            u16::try_from(pixels.div_ceil(u32::from(size.max(1))).max(1)).unwrap_or(u16::MAX)
        };
        (across(self.width, cell.0), across(self.height, cell.1))
    }
}

fn check(width: u32, height: u32) -> Result<(), Error> {
    if width == 0 || height == 0 || width > MAX_SIDE || height > MAX_SIDE {
        return Err(Error::TooBig { width, height });
    }
    Ok(())
}

/// The images the editor knows, by id.
#[derive(Debug, Default)]
pub struct Images {
    images: HashMap<ImageId, Arc<Image>>,
}

impl Images {
    pub fn insert(&mut self, image: Arc<Image>) -> ImageId {
        let id = image.id;
        self.images.insert(id, image);
        id
    }

    pub fn get(&self, id: ImageId) -> Option<&Arc<Image>> {
        self.images.get(&id)
    }

    pub fn contains(&self, id: ImageId) -> bool {
        self.images.contains_key(&id)
    }

    pub fn remove(&mut self, id: ImageId) {
        self.images.remove(&id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pixels_become_a_png_of_the_same_size() {
        let image = Image::from_pixels(2, 1, 3, &[255, 0, 0, 0, 255, 0]).unwrap();
        assert_eq!((image.width, image.height), (2, 1));
        let again = Image::from_file_bytes(&image.png).unwrap();
        assert_eq!((again.width, again.height), (2, 1));
        assert_ne!(again.id, image.id);
        assert!(
            Image::from_pixels(2, 2, 3, &[0; 6]).is_err(),
            "too few bytes"
        );
        assert!(Image::from_file_bytes(b"not an image").is_err());
    }

    #[test]
    fn an_image_covers_whole_cells() {
        let image = Image::from_pixels(25, 33, 4, &[0; 25 * 33 * 4]).unwrap();
        assert_eq!(image.cells((10, 20)), (3, 2));
        assert_eq!(image.cells((0, 0)), (25, 33));
    }
}
