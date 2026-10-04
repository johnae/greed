//! PDF documents: their pages rendered to images the editor can show, and
//! the text on them, for reading in a terminal without images and for
//! search. hayro does the work, on the CPU, in pure Rust.

use std::sync::Arc;

use hayro::hayro_interpret::font::{Glyph, GlyphRun};
use hayro::hayro_interpret::hayro_cmap::BfString;
use hayro::hayro_interpret::hayro_syntax::Pdf;
use hayro::hayro_interpret::hayro_syntax::page::Page;
use hayro::hayro_interpret::util::TransformExt;
use hayro::hayro_interpret::{
    BlendMode, ClipPath, Context, Device, DrawMode, DrawProps, Image as PdfImage, ImageDrawProps,
    InterpreterCache, InterpreterSettings, SoftMask, interpret_page,
};
use hayro::kurbo::{Affine, BezPath, Point, Rect};
use hayro::vello_cpu::color::palette::css::WHITE;
use hayro::{PixmapSettings, RenderCache, RenderSettings, render};

use crate::image::Image;

/// The most pixels along a rendered page's longer side.
const MAX_SIDE: f32 = 8_000.0;

/// A PDF file's bytes, parsed again for each page: hayro's documents borrow
/// from the bytes, and pages are rendered one at a time on other threads.
pub struct Document {
    bytes: Arc<Vec<u8>>,
    /// Each page's size in points (1/72 inch), as it's shown.
    sizes: Vec<(f32, f32)>,
}

fn parse(bytes: &Arc<Vec<u8>>) -> Result<Pdf, String> {
    Pdf::new(bytes.clone()).map_err(|err| format!("can't read the PDF: {err:?}"))
}

impl Document {
    /// Reads a PDF from its bytes. Fails for what isn't one, or one that's
    /// encrypted.
    pub fn new(bytes: Vec<u8>) -> Result<Self, String> {
        let bytes = Arc::new(bytes);
        let sizes = parse(&bytes)?
            .pages()
            .iter()
            .map(Page::render_dimensions)
            .collect();
        Ok(Self { bytes, sizes })
    }

    pub fn pages(&self) -> usize {
        self.sizes.len()
    }

    /// Page `page`'s size in points, counting from 0.
    pub fn size(&self, page: usize) -> Option<(f32, f32)> {
        self.sizes.get(page).copied()
    }

    fn with_page<T>(&self, page: usize, f: impl FnOnce(&Page<'_>) -> T) -> Result<T, String> {
        let pdf = parse(&self.bytes)?;
        let pages = pdf.pages();
        let page = pages
            .get(page)
            .ok_or_else(|| format!("there is no page {}", page + 1))?;
        Ok(f(page))
    }

    /// Page `page` drawn at `scale` pixels per point, on white.
    pub fn render(&self, page: usize, scale: f32) -> Result<Image, String> {
        let png = self.with_page(page, |page| {
            let (w, h) = page.render_dimensions();
            // A page too big at this scale is drawn as big as allowed.
            let scale = scale.min(MAX_SIDE / w.max(h).max(1.0)).max(0.01);
            let pixmap = render(
                page,
                &RenderCache::new(),
                &InterpreterSettings::default(),
                &RenderSettings::default(),
                &PixmapSettings {
                    x_scale: scale,
                    y_scale: scale,
                    bg_color: WHITE,
                },
            );
            pixmap.into_png()
        })?;
        let png = png.map_err(|err| err.to_string())?;
        Image::from_file_bytes(&png).map_err(|err| err.to_string())
    }

    /// The text on page `page`, line by line from the top, as well as the
    /// file says what its glyphs are.
    pub fn text(&self, page: usize) -> Result<String, String> {
        self.with_page(page, |page| {
            let cache = InterpreterCache::new();
            let (w, h) = page.render_dimensions();
            let transform = page.initial_transform(true).to_kurbo();
            let mut context = Context::new(
                transform,
                Rect::new(0.0, 0.0, f64::from(w), f64::from(h)),
                &cache,
                page.xref(),
                InterpreterSettings::default(),
            );
            let mut device = TextDevice::default();
            interpret_page(page, &mut context, &mut device);
            device.lines()
        })
    }
}

/// A character on the page: where it starts and ends (y down) and how big.
struct Placed {
    x: f64,
    end: f64,
    y: f64,
    size: f64,
    text: String,
}

/// A device that keeps the text glyphs draw and ignores the rest.
#[derive(Default)]
struct TextDevice {
    placed: Vec<Placed>,
}

impl TextDevice {
    /// The characters as lines: grouped by height on the page, each line
    /// read left to right, with spaces where the gaps are wide.
    fn lines(mut self) -> String {
        self.placed.sort_by(|a, b| a.y.total_cmp(&b.y));
        let mut lines: Vec<Vec<Placed>> = Vec::new();
        for p in self.placed {
            match lines.last_mut() {
                Some(line) if (p.y - line[0].y).abs() < line[0].size.max(p.size) * 0.5 => {
                    line.push(p);
                }
                _ => lines.push(vec![p]),
            }
        }
        let mut out = String::new();
        for mut line in lines {
            line.sort_by(|a, b| a.x.total_cmp(&b.x));
            let mut previous: Option<&Placed> = None;
            for p in &line {
                // A gap wider than a sixth of the text's size is a space the
                // file didn't spell out.
                if let Some(prev) = previous
                    && p.x - prev.end > prev.size.min(p.size) / 6.0
                    && !prev.text.ends_with(' ')
                    && !p.text.starts_with(' ')
                {
                    out.push(' ');
                }
                out.push_str(&p.text);
                previous = Some(p);
            }
            out.push('\n');
        }
        out
    }
}

impl<'a> Device<'a> for TextDevice {
    fn draw_glyph_run(&mut self, run: &GlyphRun<'_, 'a>, props: DrawProps<'a>, _: &DrawMode) {
        for glyph in run.glyphs() {
            let Some(text) = glyph.as_unicode() else {
                continue;
            };
            // Glyph space has 1000 units to the em.
            let placed: Affine = props.transform * glyph.transform();
            let at = placed * Point::ORIGIN;
            let advance = match &**glyph {
                Glyph::Outline(outline) => outline.advance_width(),
                Glyph::Type3(_) => None,
            };
            let end = placed * Point::new(f64::from(advance.unwrap_or(500.0)), 0.0);
            let top = placed * Point::new(0.0, 1000.0);
            self.placed.push(Placed {
                x: at.x,
                end: end.x,
                y: at.y,
                size: (top - at).hypot().max(1.0),
                text: match text {
                    BfString::Char(c) => c.to_string(),
                    BfString::String(s) => s,
                },
            });
        }
    }

    fn draw_path(&mut self, _: &BezPath, _: DrawProps<'a>, _: &DrawMode) {}
    fn push_clip_path(&mut self, _: &ClipPath) {}
    fn push_transparency_group(&mut self, _: f32, _: Option<SoftMask<'a>>, _: BlendMode) {}
    fn draw_image(&mut self, _: PdfImage<'a, '_>, _: ImageDrawProps<'a>) {}
    fn pop_clip(&mut self) {}
    fn pop_transparency_group(&mut self) {}
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fmt::Write;

    /// A small PDF with a page of text on each of `pages`, made the way a
    /// writer would: objects, then a cross-reference table of their offsets.
    fn sample(pages: &[&str]) -> Vec<u8> {
        let mut objects: Vec<String> = Vec::new();
        let n = pages.len();
        let kids: Vec<String> = (0..n).map(|i| format!("{} 0 R", 4 + i * 2)).collect();
        objects.push("<< /Type /Catalog /Pages 2 0 R >>".to_owned());
        objects.push(format!(
            "<< /Type /Pages /Kids [{}] /Count {n} >>",
            kids.join(" ")
        ));
        objects.push("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".to_owned());
        for (i, text) in pages.iter().enumerate() {
            let content = format!("BT /F1 24 Tf 72 720 Td ({text}) Tj ET");
            objects.push(format!(
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents {} 0 R >>",
                5 + i * 2
            ));
            objects.push(format!(
                "<< /Length {} >>\nstream\n{content}\nendstream",
                content.len()
            ));
        }
        let mut out = String::from("%PDF-1.4\n");
        let mut offsets = Vec::new();
        for (i, object) in objects.iter().enumerate() {
            offsets.push(out.len());
            let _ = write!(out, "{} 0 obj\n{object}\nendobj\n", i + 1);
        }
        let xref = out.len();
        let size = objects.len() + 1;
        let _ = write!(out, "xref\n0 {size}\n0000000000 65535 f \n");
        for offset in offsets {
            let _ = writeln!(out, "{offset:010} 00000 n ");
        }
        let _ = write!(
            out,
            "trailer\n<< /Size {size} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n"
        );
        out.into_bytes()
    }

    #[test]
    fn a_documents_pages_have_sizes_text_and_render_to_images() {
        let doc = Document::new(sample(&["Hello PDF", "Second page"])).unwrap();
        assert_eq!(doc.pages(), 2);
        assert_eq!(doc.size(0), Some((612.0, 792.0)));
        assert_eq!(doc.text(0).unwrap().trim(), "Hello PDF");
        assert_eq!(doc.text(1).unwrap().trim(), "Second page");
        let image = doc.render(0, 0.5).unwrap();
        assert_eq!((image.width, image.height), (306, 396));
        assert!(doc.render(2, 1.0).is_err(), "no third page");
    }

    #[test]
    fn what_isnt_a_pdf_says_so() {
        assert!(Document::new(b"not a pdf".to_vec()).is_err());
    }
}
