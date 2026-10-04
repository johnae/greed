//! Fonts: shaping runs of text with cosmic-text (ligatures, fallback for
//! missing glyphs) and rasterizing glyphs into an atlas the GPU draws from.

use std::collections::HashMap;

use cosmic_text::{
    Attrs, Buffer, CacheKey, Family, FontSystem, LayoutGlyph, Metrics, Shaping, Style, SwashCache,
    SwashContent, Weight, Wrap,
};

/// The monospaced font text is drawn in, and the cell it sets.
pub struct Fonts {
    system: FontSystem,
    cache: SwashCache,
    buffer: Buffer,
    family: Option<String>,
    /// A cell's width and height in pixels.
    pub cell_w: f32,
    pub cell_h: f32,
    /// Where the baseline is from a cell's top.
    pub baseline: f32,
}

impl Fonts {
    /// `family` at `size` pixels, or the system's monospaced font.
    pub fn new(family: Option<String>, size: f32) -> Self {
        let mut system = FontSystem::new();
        let line = (size * 1.3).round();
        let mut buffer = Buffer::new(&mut system, Metrics::new(size, line));
        buffer.set_wrap(Wrap::None);
        let mut fonts = Self {
            system,
            cache: SwashCache::new(),
            buffer,
            family,
            cell_w: size * 0.6,
            cell_h: line,
            baseline: size,
        };
        // A cell is as wide as a digit; the baseline is where the font puts it.
        let (glyphs, baseline) = fonts.shape("0", false, false);
        if let Some(glyph) = glyphs.first() {
            fonts.cell_w = glyph.w;
        }
        fonts.baseline = baseline;
        fonts
    }

    /// Shapes one line: its glyphs, each knowing the byte range of the text
    /// it draws, and the baseline from the line's top.
    pub fn shape(&mut self, text: &str, bold: bool, italic: bool) -> (Vec<LayoutGlyph>, f32) {
        let family = self
            .family
            .as_deref()
            .map_or(Family::Monospace, Family::Name);
        let attrs = Attrs::new()
            .family(family)
            .weight(if bold { Weight::BOLD } else { Weight::NORMAL })
            .style(if italic { Style::Italic } else { Style::Normal });
        self.buffer.set_text(text, &attrs, Shaping::Advanced, None);
        self.buffer.shape_until_scroll(&mut self.system, false);
        let mut glyphs = Vec::new();
        let mut baseline = self.baseline;
        for run in self.buffer.layout_runs() {
            baseline = run.line_y;
            glyphs.extend(run.glyphs.iter().cloned());
        }
        (glyphs, baseline)
    }

    /// The glyph `key` rasterized: where it sits from its origin, and its
    /// pixels as RGBA, white with coverage as alpha unless it has colors
    /// of its own (an emoji).
    fn rasterize(&mut self, key: CacheKey) -> Option<Raster> {
        let image = self.cache.get_image(&mut self.system, key).as_ref()?;
        let (w, h) = (image.placement.width, image.placement.height);
        if w == 0 || h == 0 {
            return None;
        }
        let (rgba, color) = match image.content {
            SwashContent::Color => (image.data.clone(), true),
            SwashContent::Mask => (
                image
                    .data
                    .iter()
                    .flat_map(|&a| [255, 255, 255, a])
                    .collect(),
                false,
            ),
            SwashContent::SubpixelMask => (
                image
                    .data
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .flat_map(|p| {
                        let a =
                            u8::try_from((u16::from(p[0]) + u16::from(p[1]) + u16::from(p[2])) / 3)
                                .unwrap_or(255);
                        [255, 255, 255, a]
                    })
                    .collect(),
                false,
            ),
        };
        Some(Raster {
            w,
            h,
            left: image.placement.left,
            top: image.placement.top,
            rgba,
            color,
        })
    }
}

struct Raster {
    w: u32,
    h: u32,
    left: i32,
    top: i32,
    rgba: Vec<u8>,
    color: bool,
}

/// Where a glyph is in the atlas, and how it sits from its origin.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Slot {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
    pub left: i32,
    pub top: i32,
    /// Drawn with its own colors rather than the text's.
    pub color: bool,
}

/// Glyphs packed into one RGBA texture, in shelves. What's new since the
/// last frame waits in `uploads` for the GPU.
pub struct Atlas {
    pub size: u32,
    x: u32,
    y: u32,
    shelf: u32,
    slots: HashMap<CacheKey, Option<Slot>>,
    pub uploads: Vec<(Slot, Vec<u8>)>,
}

impl Atlas {
    pub fn new(size: u32) -> Self {
        Self {
            size,
            x: 0,
            y: 0,
            shelf: 0,
            slots: HashMap::new(),
            uploads: Vec::new(),
        }
    }

    /// Forgets every glyph, for when the atlas is full or the font changed.
    pub fn clear(&mut self) {
        self.x = 0;
        self.y = 0;
        self.shelf = 0;
        self.slots.clear();
        self.uploads.clear();
    }

    /// Where glyph `key` is, rasterizing and packing it the first time.
    /// `None` for glyphs with no pixels (a space), `Full` when the atlas
    /// has no room left.
    pub fn slot(&mut self, key: CacheKey, fonts: &mut Fonts) -> Result<Option<Slot>, Full> {
        if let Some(slot) = self.slots.get(&key) {
            return Ok(*slot);
        }
        let Some(raster) = fonts.rasterize(key) else {
            self.slots.insert(key, None);
            return Ok(None);
        };
        // A pixel of space around each glyph keeps sampling from bleeding.
        if self.x + raster.w + 1 > self.size {
            self.x = 0;
            self.y += self.shelf + 1;
            self.shelf = 0;
        }
        if self.y + raster.h + 1 > self.size || raster.w + 1 > self.size {
            return Err(Full);
        }
        let slot = Slot {
            x: self.x,
            y: self.y,
            w: raster.w,
            h: raster.h,
            left: raster.left,
            top: raster.top,
            color: raster.color,
        };
        self.x += raster.w + 1;
        self.shelf = self.shelf.max(raster.h);
        self.slots.insert(key, Some(slot));
        self.uploads.push((slot, raster.rgba));
        Ok(Some(slot))
    }
}

/// The atlas has no room left.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Full;
