//! Web pages as text to read: the main content of a page as Markdown,
//! without its menus, footers and banners, as a browser's reader view
//! shows it (`dom_smoothie`, a port of Firefox's Readability). A page with
//! no article in it, like a search form or a list of links, comes as all
//! of its text instead.

use dom_smoothie::{Config, Readability, TextMode};

/// What a page reads as.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Page {
    pub title: Option<String>,
    pub byline: Option<String>,
    /// The page's own summary of itself, when it has one.
    pub excerpt: Option<String>,
    /// The text, as Markdown: links, lists, tables and code kept.
    pub text: String,
    /// Whether `text` is an article found in the page, rather than all of
    /// the page's text.
    pub article: bool,
}

/// What the page `html` reads as. `url` is where it came from, for its
/// links.
pub fn read(html: &str, url: Option<&str>) -> Page {
    let config = Config {
        text_mode: TextMode::Markdown,
        ..Config::default()
    };
    // Readability finds an article in any page if asked, a list of links
    // too, and keeps a part of it; so only in a page that looks like one.
    let article = Readability::new(html, url, Some(config))
        .ok()
        .filter(Readability::is_probably_readable)
        .and_then(|mut page| page.parse().ok())
        .filter(|article| !article.text_content.trim().is_empty());
    if let Some(article) = article {
        return Page {
            title: some(&article.title),
            byline: article.byline.as_deref().and_then(some),
            excerpt: article.excerpt.as_deref().and_then(some),
            text: article.text_content.trim().to_string(),
            article: true,
        };
    }
    let doc = dom_query::Document::from(html);
    let skip = [
        "script", "style", "meta", "head", "noscript", "svg", "template",
    ];
    Page {
        title: some(&doc.select("title").text()),
        text: doc.md(Some(&skip)).trim().to_string(),
        ..Page::default()
    }
}

fn some(text: &str) -> Option<String> {
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    const ARTICLE: &str = r#"<!DOCTYPE html><html><head><title>Caching</title>
        <meta name="description" content="How caches keep pages."></head><body>
        <nav><a href="/">Home</a> <a href="/docs">Docs</a> <a href="/blog">Blog</a></nav>
        <react-partial data-ssr="true"><tool-tip>Dismiss</tool-tip></react-partial>
        <article><h1>Caching</h1>
        <p>A cache keeps a copy of a response, so the next request for it is answered
        without asking the server again. That saves time and bandwidth for everyone.</p>
        <p>Headers say how long a copy may be kept, and whether it may be shared between
        people, as a proxy would, or only kept in one browser.</p>
        <pre><code>Cache-Control: max-age=3600</code></pre>
        <p>Read <a href="https://example.com/more">more about headers</a> elsewhere.</p>
        </article><footer>© Example. Privacy. Terms. Cookies.</footer>
        <script>track()</script></body></html>"#;

    #[test]
    fn an_article_comes_as_markdown_without_the_page_around_it() {
        let page = read(ARTICLE, Some("https://example.com/caching"));
        assert!(page.article);
        assert_eq!(page.title.as_deref(), Some("Caching"));
        assert_eq!(page.excerpt.as_deref(), Some("How caches keep pages."));
        for kept in [
            "A cache keeps a copy",
            "```\nCache-Control: max-age=3600\n```",
            "[more about headers](https://example.com/more)",
        ] {
            assert!(page.text.contains(kept), "{kept:?} in {}", page.text);
        }
        for gone in ["Home", "Dismiss", "Privacy", "track()", "<"] {
            assert!(!page.text.contains(gone), "{gone:?} in {}", page.text);
        }
    }

    #[test]
    fn a_page_without_an_article_comes_as_all_its_text() {
        let page = read(
            r#"<html><head><title>Search</title><style>p{}</style></head><body>
            <form><input name="q"></form><ul><li><a href="/a">A</a></li><li>B &amp; C</li></ul>
            <script>evil()</script></body></html>"#,
            None,
        );
        assert!(!page.article);
        assert_eq!(page.title.as_deref(), Some("Search"));
        assert!(page.text.contains("B & C"), "{}", page.text);
        assert!(
            !page.text.contains("evil") && !page.text.contains("p{}"),
            "{}",
            page.text
        );
    }

    #[test]
    fn nothing_and_broken_html_read_as_nothing_without_failing() {
        assert_eq!(read("", None).text, "");
        let page = read("<div><p>Unclosed <b>bold <i>both</div></span>", None);
        assert!(page.text.contains("Unclosed"), "{}", page.text);
    }
}
