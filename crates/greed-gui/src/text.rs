//! Fonts: shaping runs of text with cosmic-text (ligatures, fallback for
//! missing glyphs) and rasterizing glyphs into an atlas the GPU draws from.

use std::collections::{BTreeMap, HashMap};

use cosmic_text::{
    Attrs, Buffer, CacheKey, Family, FontSystem, LayoutGlyph, Metrics, Shaping, Style, SwashCache,
    SwashContent, Weight, Wrap,
};

/// The font size in logical pixels, before the screen's scale, unless the
/// `gui-font-size` option says otherwise.
pub const DEFAULT_SIZE: f32 = 15.0;

/// The font a frame's options ask for: `gui-font`, a family (none, or
/// empty, for the system's monospaced font), and `gui-font-size`.
pub fn chosen(options: &BTreeMap<String, String>) -> (Option<String>, f32) {
    let family = options
        .get("gui-font")
        .map(|f| f.trim())
        .filter(|f| !f.is_empty())
        .map(str::to_owned);
    let size = options
        .get("gui-font-size")
        .and_then(|s| s.trim().parse::<f32>().ok())
        .filter(|s| (4.0..=200.0).contains(s))
        .unwrap_or(DEFAULT_SIZE);
    (family, size)
}

/// The monospaced font text is drawn in, and the cell it sets.
pub struct Fonts {
    system: FontSystem,
    cache: SwashCache,
    buffer: Buffer,
    family: Option<String>,
    /// The size and line height at scale 1.
    metrics: Metrics,
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
        let metrics = Metrics::new(size, size);
        let mut buffer = Buffer::new(&mut system, metrics);
        buffer.set_wrap(Wrap::None);
        let mut fonts = Self {
            system,
            cache: SwashCache::new(),
            buffer,
            family: None,
            metrics,
            cell_w: 0.0,
            cell_h: 0.0,
            baseline: 0.0,
        };
        fonts.set(family, size);
        fonts
    }

    /// Switches to `family` at `size` pixels, keeping the fonts the system
    /// has, which take a while to find.
    pub fn set(&mut self, family: Option<String>, size: f32) {
        let line = (size * 1.3).round();
        self.metrics = Metrics::new(size, line);
        self.family = family;
        self.cell_w = size * 0.6;
        self.cell_h = line;
        self.baseline = size;
        // A cell is as wide as a digit; the baseline is where the font puts it.
        let (glyphs, baseline) = self.shape("0", false, false, 1);
        if let Some(glyph) = glyphs.first() {
            self.cell_w = glyph.w;
        }
        self.baseline = baseline;
    }

    /// Shapes one line `scale` times the size: its glyphs, each knowing the
    /// byte range of the text it draws, and the baseline from the line's top.
    pub fn shape(
        &mut self,
        text: &str,
        bold: bool,
        italic: bool,
        scale: u8,
    ) -> (Vec<LayoutGlyph>, f32) {
        let family = self
            .family
            .as_deref()
            .map_or(Family::Monospace, Family::Name);
        let attrs = Attrs::new()
            .family(family)
            .weight(if bold { Weight::BOLD } else { Weight::NORMAL })
            .style(if italic { Style::Italic } else { Style::Normal });
        let k = f32::from(scale.max(1));
        self.buffer.set_metrics(Metrics::new(
            self.metrics.font_size * k,
            self.metrics.line_height * k,
        ));
        self.buffer.set_text(text, &attrs, Shaping::Advanced, None);
        self.buffer.shape_until_scroll(&mut self.system, false);
        let mut glyphs = Vec::new();
        let mut baseline = self.baseline * k;
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

#[cfg(test)]
mod tests {
    use super::*;

    fn options(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
            .collect()
    }

    #[test]
    fn the_options_choose_the_font_and_its_size() {
        assert_eq!(chosen(&options(&[])), (None, DEFAULT_SIZE));
        assert_eq!(
            chosen(&options(&[
                ("gui-font", "Fira Code"),
                ("gui-font-size", "13.5")
            ])),
            (Some("Fira Code".to_owned()), 13.5)
        );
        assert_eq!(
            chosen(&options(&[("gui-font", " "), ("gui-font-size", "0")])),
            (None, DEFAULT_SIZE),
            "empty and silly values are the defaults"
        );
        assert_eq!(
            chosen(&options(&[("gui-font-size", "big")])).1,
            DEFAULT_SIZE
        );
    }

    #[test]
    fn switching_size_sets_the_cells_a_new_font_would() {
        let mut fonts = Fonts::new(None, 15.0);
        let small = (fonts.cell_w, fonts.cell_h);
        fonts.set(None, 30.0);
        let fresh = Fonts::new(None, 30.0);
        assert_eq!(
            (fonts.cell_w, fonts.cell_h, fonts.baseline),
            (fresh.cell_w, fresh.cell_h, fresh.baseline)
        );
        assert!(fonts.cell_w > small.0 && fonts.cell_h > small.1);
    }
}
