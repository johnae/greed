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

/// The fonts a frame's options ask for: `gui-font`, the grid's family, and
/// `gui-font-prose`, prose's (none, or empty, for the system's monospaced
/// and sans-serif fonts), at `gui-font-size`.
#[derive(Debug, Clone, PartialEq)]
pub struct Choice {
    pub family: Option<String>,
    pub prose: Option<String>,
    pub size: f32,
}

impl Default for Choice {
    fn default() -> Self {
        Choice {
            family: None,
            prose: None,
            size: DEFAULT_SIZE,
        }
    }
}

/// What `options` choose.
pub fn chosen(options: &BTreeMap<String, String>) -> Choice {
    let family = |name: &str| {
        options
            .get(name)
            .map(|f| f.trim())
            .filter(|f| !f.is_empty())
            .map(str::to_owned)
    };
    let size = options
        .get("gui-font-size")
        .and_then(|s| s.trim().parse::<f32>().ok())
        .filter(|s| (4.0..=200.0).contains(s))
        .unwrap_or(DEFAULT_SIZE);
    Choice {
        family: family("gui-font"),
        prose: family("gui-font-prose"),
        size,
    }
}

/// How a run of text is drawn: its weight and slant, how many times bigger,
/// and whether in the prose font.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub struct TextStyle {
    pub bold: bool,
    pub italic: bool,
    pub scale: u8,
    pub prose: bool,
}

/// Monospaced families to draw in when none is chosen, or the one chosen
/// isn't installed, best first: ones most systems have.
const MONOSPACED: [&str; 11] = [
    "DejaVu Sans Mono",
    "Noto Sans Mono",
    "Liberation Mono",
    "Menlo",
    "SF Mono",
    "Monaco",
    "Consolas",
    "Cascadia Mono",
    "Ubuntu Mono",
    "Source Code Pro",
    "Fira Mono",
];

/// The same for prose.
const PROSE: [&str; 9] = [
    "Noto Sans",
    "DejaVu Sans",
    "Liberation Sans",
    "Helvetica Neue",
    "Helvetica",
    "Arial",
    "Segoe UI",
    "Ubuntu",
    "Cantarell",
];

/// Nerd Font icons, behind whatever font text is drawn in, so the icons the
/// file tree, status line and the rest can use show in the window on any
/// system (fonts/OFL.txt has its license).
const SYMBOLS: &[u8] = include_bytes!("../fonts/SymbolsNerdFontMono-Regular.ttf");

/// The family of [`SYMBOLS`], which draws private-use characters first, so
/// a system font that puts something else at a Nerd Font icon's place
/// doesn't win.
const SYMBOLS_FAMILY: &str = "Symbols Nerd Font Mono";

/// Whether `c` is a private-use character, as Nerd Font icons are.
fn private_use(c: char) -> bool {
    matches!(u32::from(c), 0xE000..=0xF8FF | 0xF_0000..=0xF_FFFD | 0x10_0000..=0x10_FFFD)
}

/// The tables of face `index` in the font file `data`: each one's tag and
/// where it starts.
fn tables(data: &[u8], index: u32) -> Option<Vec<([u8; 4], usize)>> {
    let u16_at = |at: usize| {
        data.get(at..at + 2)
            .map(|b| u16::from_be_bytes([b[0], b[1]]))
    };
    let u32_at = |at: usize| {
        let b = data.get(at..at + 4)?;
        usize::try_from(u32::from_be_bytes([b[0], b[1], b[2], b[3]])).ok()
    };
    let start = if data.get(..4) == Some(b"ttcf") {
        u32_at(12 + 4 * usize::try_from(index).ok()?)?
    } else {
        0
    };
    (0..usize::from(u16_at(start + 4)?))
        .map(|i| {
            let record = start + 12 + 16 * i;
            let tag: [u8; 4] = data.get(record..record + 4)?.try_into().ok()?;
            Some((tag, u32_at(record + 8)?))
        })
        .collect()
}

/// Whether face `index` of `data` has colored glyphs the rasterizer can't
/// draw, leaving a gap where they go: only `COLRv1` layers (and SVG), with no
/// bitmaps and no `COLRv0` glyphs, as the Noto Color Emoji some font packages
/// ship has. Taken out, its glyphs fall back to a face that draws, such as
/// the bitmap Noto Color Emoji, or the plain Noto Emoji.
fn undrawable(data: &[u8], index: u32) -> bool {
    let Some(tables) = tables(data, index) else {
        return false;
    };
    let Some(&(_, colr)) = tables.iter().find(|(tag, _)| tag == b"COLR") else {
        return false;
    };
    let bitmaps = tables
        .iter()
        .any(|(tag, _)| tag == b"CBDT" || tag == b"sbix");
    // Version 1, and no base glyph records for version 0.
    data.get(colr..colr + 4) == Some(&[0, 1, 0, 0]) && !bitmaps
}

/// Takes the emoji faces out of `system` that [`undrawable`] says it can't
/// draw. Only emoji families are looked at, as reading every font's tables
/// would slow the start.
fn drop_undrawable(system: &mut FontSystem) {
    let db = system.db();
    let undrawn: Vec<_> = db
        .faces()
        .filter(|face| {
            face.families
                .iter()
                .any(|(name, _)| name.to_lowercase().contains("emoji"))
        })
        .filter(|face| db.with_face_data(face.id, undrawable).unwrap_or(false))
        .map(|face| face.id)
        .collect();
    for id in undrawn {
        system.db_mut().remove_face(id);
    }
}

/// The installed families named in `wanted`, the first found, or else with
/// `monospaced` any installed family with monospaced faces.
fn pick(installed: &Installed, wanted: &[&str], monospaced: bool) -> Option<String> {
    wanted
        .iter()
        .find(|name| installed.names.contains(**name))
        .map(|name| (*name).to_owned())
        .or_else(|| monospaced.then(|| installed.monospaced.clone()).flatten())
}

/// What the system has: every family's name, and one with monospaced faces.
struct Installed {
    names: std::collections::HashSet<String>,
    monospaced: Option<String>,
}

impl Installed {
    fn of(system: &FontSystem) -> Self {
        let mut names = std::collections::HashSet::new();
        let mut monospaced = None;
        for face in system.db().faces() {
            for (name, _) in &face.families {
                // The icons are behind the text, never the text itself.
                let icons = name.starts_with("Symbols Nerd Font");
                if face.monospaced && monospaced.is_none() && !icons {
                    monospaced = Some(name.clone());
                }
                names.insert(name.clone());
            }
        }
        Self { names, monospaced }
    }
}

/// The monospaced font text is drawn in, and the cell it sets.
pub struct Fonts {
    system: FontSystem,
    cache: SwashCache,
    buffer: Buffer,
    family: Option<String>,
    /// Prose's family, or the system's sans-serif.
    prose: Option<String>,
    /// The families drawn in when none is chosen or the chosen one isn't
    /// installed. Asking for "the system's monospaced font" by kind makes
    /// cosmic-text look through every font for each glyph when its idea of
    /// that font isn't installed, as on most Linux systems: about 30 times
    /// slower per line, on every frame.
    installed: Installed,
    default_family: Option<String>,
    default_prose: Option<String>,
    /// Lines shaped before, by their text and style: a frame draws mostly
    /// what the one before did, and shaping a line with glyphs from
    /// fallback fonts takes milliseconds. Emptied when the fonts change.
    shaped: HashMap<(String, TextStyle), (Vec<LayoutGlyph>, f32)>,
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
        system.db_mut().load_font_data(SYMBOLS.to_vec());
        drop_undrawable(&mut system);
        let metrics = Metrics::new(size, size);
        let mut buffer = Buffer::new(&mut system, metrics);
        buffer.set_wrap(Wrap::None);
        let installed = Installed::of(&system);
        let default_family = pick(&installed, &MONOSPACED, true);
        let default_prose = pick(&installed, &PROSE, false);
        let mut fonts = Self {
            system,
            cache: SwashCache::new(),
            buffer,
            family: None,
            prose: None,
            installed,
            default_family,
            default_prose,
            shaped: HashMap::new(),
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
        self.shaped.clear();
        self.cell_w = size * 0.6;
        self.cell_h = line;
        self.baseline = size;
        // A cell is as wide as a digit; the baseline is where the font puts it.
        let (glyphs, baseline) = self.shape("0", TextStyle::default());
        if let Some(glyph) = glyphs.first() {
            self.cell_w = glyph.w;
        }
        self.baseline = baseline;
    }

    /// Switches prose to `family`, or the system's sans-serif.
    pub fn set_prose(&mut self, family: Option<String>) {
        if self.prose != family {
            self.shaped.clear();
        }
        self.prose = family;
    }

    /// The family text is drawn in: `chosen` when it's installed, else
    /// `default`; nil when neither is, for the font system's own choice.
    fn in_use<'a>(&self, chosen: Option<&'a str>, default: Option<&'a str>) -> Option<&'a str> {
        chosen
            .filter(|name| self.installed.names.contains(*name))
            .or(default)
    }

    /// The monospaced family the grid is drawn in, if one is installed.
    pub fn grid_family(&self) -> Option<&str> {
        self.in_use(self.family.as_deref(), self.default_family.as_deref())
    }

    /// Shapes one line as `style` says: its glyphs, each knowing the byte
    /// range of the text it draws, and the baseline from the line's top.
    pub fn shape(&mut self, text: &str, style: TextStyle) -> (Vec<LayoutGlyph>, f32) {
        /// How many lines are kept: a few screens' worth, then they start over.
        const KEPT: usize = 4096;
        let key = (text.to_owned(), style);
        if let Some(shaped) = self.shaped.get(&key) {
            return shaped.clone();
        }
        let shaped = self.shape_now(text, style);
        if self.shaped.len() >= KEPT {
            self.shaped.clear();
        }
        self.shaped.insert(key, shaped.clone());
        shaped
    }

    /// [`Fonts::shape`], without the lines kept from before.
    fn shape_now(&mut self, text: &str, style: TextStyle) -> (Vec<LayoutGlyph>, f32) {
        let family = if style.prose {
            self.in_use(self.prose.as_deref(), self.default_prose.as_deref())
                .map_or(Family::SansSerif, Family::Name)
        } else {
            self.in_use(self.family.as_deref(), self.default_family.as_deref())
                .map_or(Family::Monospace, Family::Name)
        };
        let attrs = Attrs::new()
            .family(family)
            .weight(if style.bold {
                Weight::BOLD
            } else {
                Weight::NORMAL
            })
            .style(if style.italic {
                Style::Italic
            } else {
                Style::Normal
            });
        let k = f32::from(style.scale.max(1));
        self.buffer.set_metrics(Metrics::new(
            self.metrics.font_size * k,
            self.metrics.line_height * k,
        ));
        if text.chars().any(private_use) {
            // Icons from the bundled symbols, the rest as asked.
            let icons = attrs.clone().family(Family::Name(SYMBOLS_FAMILY));
            let mut spans: Vec<(&str, Attrs)> = Vec::new();
            let mut from = 0;
            let mut icon = false;
            for (at, c) in text.char_indices() {
                let is_icon = private_use(c);
                if is_icon != icon && at > from {
                    spans.push((
                        &text[from..at],
                        if icon { icons.clone() } else { attrs.clone() },
                    ));
                    from = at;
                }
                icon = is_icon;
            }
            spans.push((&text[from..], if icon { icons } else { attrs.clone() }));
            self.buffer
                .set_rich_text(spans, &attrs, Shaping::Advanced, None);
        } else {
            self.buffer.set_text(text, &attrs, Shaping::Advanced, None);
        }
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

    fn installed(names: &[&str], monospaced: Option<&str>) -> Installed {
        Installed {
            names: names.iter().map(|name| (*name).to_owned()).collect(),
            monospaced: monospaced.map(str::to_owned),
        }
    }

    #[test]
    fn the_default_font_is_one_that_is_installed() {
        let some = installed(
            &["Liberation Mono", "Noto Sans Mono", "Inter"],
            Some("Odd Mono"),
        );
        assert_eq!(
            pick(&some, &MONOSPACED, true).as_deref(),
            Some("Noto Sans Mono")
        );
        let none_known = installed(&["Odd Mono", "Inter"], Some("Odd Mono"));
        assert_eq!(
            pick(&none_known, &MONOSPACED, true).as_deref(),
            Some("Odd Mono")
        );
        assert_eq!(
            pick(&none_known, &PROSE, false),
            None,
            "prose takes no stranger"
        );
        assert_eq!(pick(&installed(&[], None), &MONOSPACED, true), None);
    }

    #[test]
    fn nerd_font_icons_show_in_any_font() {
        let mut fonts = Fonts::new(None, 15.0);
        // A folder, a git branch and a round cap, as the tree and the status
        // line draw them.
        for icon in ["\u{f07b}", "\u{e725}", "\u{e0b6}"] {
            let (glyphs, _) = fonts.shape(icon, TextStyle::default());
            assert!(
                glyphs.first().is_some_and(|g| g.glyph_id != 0),
                "{icon:?} has a glyph, not a box"
            );
        }
        assert_ne!(fonts.grid_family(), Some("Symbols Nerd Font Mono"));
    }

    #[test]
    fn nerd_font_icons_come_from_the_bundled_symbols_first() {
        let mut fonts = Fonts::new(None, 15.0);
        // The git branch, which other fonts put something else at, among
        // text drawn as usual.
        let (glyphs, _) = fonts.shape("a \u{e0a0} b", TextStyle::default());
        let family = |glyph: &LayoutGlyph| {
            fonts
                .system
                .db()
                .face(glyph.font_id)
                .map(|face| face.families[0].0.clone())
        };
        let icon = glyphs.iter().find(|g| g.start == 2).expect("the icon");
        assert_eq!(family(icon).as_deref(), Some(SYMBOLS_FAMILY));
        let text = glyphs.iter().find(|g| g.start == 0).expect("the a");
        assert_ne!(family(text).as_deref(), Some(SYMBOLS_FAMILY));
        assert_eq!(glyphs.last().map(|g| g.start), Some(6), "every glyph");
    }

    /// A font file of `tables`, each a tag and its bytes.
    fn font_file(tables: &[(&[u8; 4], &[u8])]) -> Vec<u8> {
        let count = u16::try_from(tables.len()).unwrap();
        let mut file = vec![0, 1, 0, 0];
        file.extend(count.to_be_bytes());
        file.extend([0; 6]);
        let mut at = 12 + 16 * tables.len();
        for (tag, bytes) in tables {
            file.extend(*tag);
            file.extend([0; 4]);
            file.extend(u32::try_from(at).unwrap().to_be_bytes());
            file.extend(u32::try_from(bytes.len()).unwrap().to_be_bytes());
            at += bytes.len();
        }
        for (_, bytes) in tables {
            file.extend(*bytes);
        }
        file
    }

    #[test]
    fn color_fonts_with_only_colr_v1_glyphs_are_undrawable() {
        let v1 = [0, 1, 0, 0];
        let v1_with_v0_glyphs = [0, 1, 0, 3];
        let v0 = [0, 0, 0, 3];
        assert!(undrawable(&font_file(&[(b"COLR", &v1)]), 0));
        assert!(!undrawable(
            &font_file(&[(b"COLR", &v1), (b"CBDT", &[0])]),
            0
        ));
        assert!(!undrawable(&font_file(&[(b"COLR", &v1_with_v0_glyphs)]), 0));
        assert!(!undrawable(&font_file(&[(b"COLR", &v0)]), 0));
        assert!(!undrawable(&font_file(&[(b"glyf", &[0])]), 0));
        assert!(!undrawable(b"not a font", 0));
    }

    #[test]
    fn an_installed_emoji_font_draws_its_emoji() {
        let mut fonts = Fonts::new(None, 15.0);
        let (glyphs, _) = fonts.shape("\u{1f4c5}", TextStyle::default());
        let Some(glyph) = glyphs.first().filter(|g| g.glyph_id != 0) else {
            // No emoji font on this system.
            return;
        };
        let key = glyph.physical((0.0, 0.0), 1.0).cache_key;
        assert!(fonts.rasterize(key).is_some(), "drawn, not a gap");
    }

    #[test]
    fn a_line_is_shaped_once_until_the_fonts_change() {
        let mut fonts = Fonts::new(None, 15.0);
        let style = TextStyle::default();
        let first = fonts.shape("let x = 1;", style);
        assert_eq!(fonts.shaped.len(), 2, "with the 0 measuring the cell");
        let again = fonts.shape("let x = 1;", style);
        assert_eq!(first.0.len(), again.0.len());
        assert_eq!(fonts.shaped.len(), 2, "kept, not shaped again");
        fonts.shape(
            "let x = 1;",
            TextStyle {
                bold: true,
                ..style
            },
        );
        assert_eq!(fonts.shaped.len(), 3, "another style is another line");
        fonts.set(None, 20.0);
        assert_eq!(fonts.shaped.len(), 1, "a new size starts over, with its 0");
    }

    #[test]
    fn a_chosen_font_that_is_not_installed_gives_way_to_the_default() {
        let mut fonts = Fonts::new(None, 15.0);
        let default = fonts.grid_family().map(str::to_owned);
        if let Some(default) = &default {
            assert!(
                fonts.installed.names.contains(default),
                "{default} is installed"
            );
        }
        fonts.set(Some("No Such Font Anywhere".to_owned()), 15.0);
        assert_eq!(fonts.grid_family().map(str::to_owned), default);
        if let Some(installed) = default {
            fonts.set(Some(installed.clone()), 15.0);
            assert_eq!(fonts.grid_family(), Some(installed.as_str()));
        }
    }

    fn options(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
            .collect()
    }

    #[test]
    fn the_options_choose_the_fonts_and_their_size() {
        assert_eq!(chosen(&options(&[])), Choice::default());
        assert_eq!(
            chosen(&options(&[
                ("gui-font", "Fira Code"),
                ("gui-font-prose", "Inter"),
                ("gui-font-size", "13.5")
            ])),
            Choice {
                family: Some("Fira Code".to_owned()),
                prose: Some("Inter".to_owned()),
                size: 13.5
            }
        );
        assert_eq!(
            chosen(&options(&[("gui-font", " "), ("gui-font-size", "0")])),
            Choice::default(),
            "empty and silly values are the defaults"
        );
        assert_eq!(
            chosen(&options(&[("gui-font-size", "big")])).size,
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
