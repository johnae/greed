//! HTML mail as lines of styled text, laid out for a width in cells: what
//! a message reads as in Greed. html2text does the layout (tables that are
//! for layout come out as text, tables of data as columns), with the
//! message's own CSS, so what it hides (a preheader, a tracking block)
//! stays hidden. Nothing is fetched: an image is its alt text, and links
//! are kept with their targets for the reader to open.

use std::path::{Path, PathBuf};

use html2text::render::RichAnnotation;
use serde::Serialize;

/// A piece of a line: its text, how it's styled (`strong`, `emphasis`,
/// `code`, `strike`, `link`, `image`), and for a link which of the
/// rendered message's links it is.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Span {
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub style: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub link: Option<usize>,
}

/// A message's HTML as it reads: its lines, and the targets its links go
/// to, each once, in the order they first come.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Rendered {
    pub lines: Vec<Vec<Span>>,
    pub links: Vec<String>,
}

/// `html` laid out `width` cells wide. Lines lose the spaces they end
/// with, and runs of empty lines become one.
pub fn render(html: &str, width: usize) -> Rendered {
    let width = width.clamp(20, 200);
    let lines = html2text::config::rich()
        .use_doc_css()
        .no_table_borders()
        .link_footnotes(false)
        .lines_from_read(html.as_bytes(), width)
        .unwrap_or_default();
    let mut out = Rendered::default();
    for line in lines {
        let mut spans: Vec<Span> = Vec::new();
        for piece in line.tagged_strings() {
            let mut span = Span {
                text: piece.s.clone(),
                ..Span::default()
            };
            for annotation in &piece.tag {
                match annotation {
                    RichAnnotation::Link(target) => {
                        span.style = Some("link");
                        span.link = Some(link_number(&mut out.links, target));
                    }
                    RichAnnotation::Image(_) => span.style = span.style.or(Some("image")),
                    RichAnnotation::Strong => span.style = span.style.or(Some("strong")),
                    RichAnnotation::Emphasis => span.style = span.style.or(Some("emphasis")),
                    RichAnnotation::Code | RichAnnotation::Preformat(_) => {
                        span.style = span.style.or(Some("code"));
                    }
                    RichAnnotation::Strikeout => span.style = span.style.or(Some("strike")),
                    _ => {}
                }
            }
            match spans.last_mut() {
                Some(last) if last.style == span.style && last.link == span.link => {
                    last.text.push_str(&span.text);
                }
                _ => spans.push(span),
            }
        }
        trim_end(&mut spans);
        if spans.is_empty() && out.lines.last().is_none_or(Vec::is_empty) {
            continue;
        }
        out.lines.push(spans);
    }
    while out.lines.last().is_some_and(Vec::is_empty) {
        out.lines.pop();
    }
    out
}

/// Which of `links` `target` is, added at the end if it's new.
fn link_number(links: &mut Vec<String>, target: &str) -> usize {
    links.iter().position(|l| l == target).unwrap_or_else(|| {
        links.push(target.to_string());
        links.len() - 1
    })
}

/// Takes the spaces off the end of a line, and spans left empty.
fn trim_end(spans: &mut Vec<Span>) {
    while let Some(last) = spans.last_mut() {
        let kept = last.text.trim_end().len();
        last.text.truncate(kept);
        if !last.text.is_empty() {
            break;
        }
        spans.pop();
    }
}

/// What a page opened in a browser may load: nothing from anywhere, so no
/// script runs and no image or style tells the sender it was read. Styles
/// in the page and images in it as data still show.
const LOCKED: &str = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; \
     style-src 'unsafe-inline'; img-src data:; font-src data:\">";

/// Writes `html` as a page for a browser into `dir`, under a name from
/// `key`, with `LOCKED` at its head; gives where.
pub fn page(html: &str, dir: &Path, key: &str) -> Result<PathBuf, String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("couldn't make {}: {e}", dir.display()))?;
    let path = dir.join(format!("{:016x}.html", name(key)));
    // First in its head, before anything it says itself can load.
    let lower = html.to_ascii_lowercase();
    let page = match lower
        .find("<head")
        .and_then(|at| html[at..].find('>').map(|end| at + end + 1))
    {
        Some(at) => format!("{}{LOCKED}{}", &html[..at], &html[at..]),
        None => format!("<head>{LOCKED}</head>{html}"),
    };
    std::fs::write(&path, page).map_err(|e| format!("couldn't write {}: {e}", path.display()))?;
    Ok(path)
}

/// A name for `key` that's the same each time (FNV-1a).
fn name(key: &str) -> u64 {
    key.bytes().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(rendered: &Rendered) -> String {
        rendered
            .lines
            .iter()
            .map(|line| line.iter().map(|s| s.text.as_str()).collect::<String>())
            .collect::<Vec<_>>()
            .join("\n")
    }

    const NEWSLETTER: &str = r#"<html><head><style>.pre{display:none}</style></head><body>
        <div class="pre">A preheader nobody should see.</div>
        <table role="presentation" width="100%"><tr><td>
          <img src="https://cdn.example.com/logo.png" alt="Example Weekly" width="200">
          <h1>This week</h1>
          <p>The <b>tomato</b> season is <i>over</i>.</p>
          <p><a href="https://example.com/beans">Read about beans</a> or
             <a href="https://example.com/beans">read on</a>.</p>
        </td></tr></table>
        <img src="https://t.example.com/open.gif" width="1" height="1" alt="">
        </body></html>"#;

    #[test]
    fn a_newsletter_reads_as_text_with_what_it_hides_hidden() {
        let rendered = render(NEWSLETTER, 60);
        let text = text(&rendered);
        assert!(!text.contains("preheader"), "{text}");
        assert!(
            text.contains("Example Weekly"),
            "an image is its alt: {text}"
        );
        assert!(text.contains("This week"), "{text}");
        assert!(text.contains("The tomato season is over."), "{text}");
        assert!(!text.contains("open.gif"), "{text}");
        assert!(!text.contains("\n\n\n"), "one empty line at most: {text:?}");
        assert!(
            text.lines().all(|l| !l.ends_with(' ')),
            "no spaces at the ends: {text:?}"
        );
        let styled: Vec<(&str, Option<&str>)> = rendered
            .lines
            .iter()
            .flatten()
            .filter(|s| s.style.is_some())
            .map(|s| (s.text.as_str(), s.style))
            .collect();
        assert!(styled.contains(&("tomato", Some("strong"))), "{styled:?}");
        assert!(styled.contains(&("over", Some("emphasis"))), "{styled:?}");
        assert_eq!(
            rendered.links,
            ["https://example.com/beans"],
            "each target once"
        );
        let linked: Vec<&str> = rendered
            .lines
            .iter()
            .flatten()
            .filter(|s| s.link == Some(0))
            .map(|s| s.text.as_str())
            .collect();
        assert_eq!(linked, ["Read about beans", "read on"]);
    }

    #[test]
    fn a_receipts_table_keeps_its_columns() {
        let html = "<table><thead><tr><th>Item</th><th>Price</th></tr></thead>
            <tr><td>Bean seeds</td><td>4.00</td></tr>
            <tr><td>Watering can, green</td><td>18.50</td></tr></table>";
        let text = text(&render(html, 60));
        let lines: Vec<&str> = text.lines().collect();
        let column = |line: &str, word: &str| line.find(word).unwrap();
        let price = lines.iter().position(|l| l.contains("Price")).unwrap();
        assert_eq!(
            column(lines[price], "Price"),
            column(lines[price + 2], "18.50"),
            "{text}"
        );
    }

    #[test]
    fn lines_fit_the_width() {
        let html = format!("<p>{}</p>", "word ".repeat(100));
        let rendered = render(&html, 40);
        let widest = text(&rendered).lines().map(str::len).max().unwrap();
        assert!(widest <= 40, "{widest}");
    }

    #[test]
    fn a_page_for_the_browser_may_load_nothing() {
        let dir = std::env::temp_dir().join(format!("gm-html-{}", std::process::id()));
        let path = page(
            "<html><HEAD><script src=x></script></HEAD><body>hi</body></html>",
            &dir,
            "m:1:a",
        )
        .unwrap();
        let written = std::fs::read_to_string(&path).unwrap();
        let locked = written.find("Content-Security-Policy").unwrap();
        assert!(locked < written.find("<script").unwrap(), "{written}");
        assert_eq!(
            path,
            page("<p>again</p>", &dir, "m:1:a").unwrap(),
            "one page a message"
        );
        let bare = std::fs::read_to_string(path).unwrap();
        assert!(bare.starts_with("<head><meta"), "{bare}");
        let _ = std::fs::remove_dir_all(dir);
    }
}
