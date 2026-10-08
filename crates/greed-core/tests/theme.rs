use greed_core::theme::{Color, Entry, Medium, Style, Theme, Underline};

fn fg(color: Color) -> Style {
    Style {
        fg: Some(color),
        ..Style::default()
    }
}

#[test]
fn colors_parse_from_names_and_hex() {
    assert_eq!(Color::parse("red"), Some(Color::Ansi(1)));
    assert_eq!(Color::parse("bright-red"), Some(Color::Ansi(9)));
    assert_eq!(Color::parse("grey"), Some(Color::Ansi(8)));
    assert_eq!(Color::parse("white"), Some(Color::Ansi(7)));
    assert_eq!(Color::parse("#ff8000"), Some(Color::Rgb(255, 128, 0)));
    assert_eq!(Color::parse("default"), Some(Color::Default));
    assert_eq!(Color::parse("#ff80"), None);
    assert_eq!(Color::parse("chartreuse"), None);
}

#[test]
fn names_fall_back_to_their_parents() {
    let mut theme = Theme::default();
    theme.set("markup", Entry::new(fg(Color::Ansi(4))));
    theme.set("markup.heading.1", Entry::new(fg(Color::Ansi(1))));
    assert_eq!(
        theme.style("markup.heading.1", Medium::Tui).fg,
        Some(Color::Ansi(1))
    );
    assert_eq!(
        theme.style("markup.heading.2", Medium::Tui).fg,
        Some(Color::Ansi(4))
    );
    assert_eq!(
        theme.style("markup.link", Medium::Tui).fg,
        Some(Color::Ansi(4))
    );
    assert_eq!(theme.style("keyword", Medium::Tui), Style::default());
}

#[test]
fn media_override_the_shared_part() {
    let mut theme = Theme::default();
    let mut entry = Entry::new(Style {
        fg: Some(Color::Ansi(2)),
        bold: Some(true),
        ..Style::default()
    });
    entry.tui = fg(Color::Ansi(10));
    theme.set("string", entry);
    let tui = theme.style("string", Medium::Tui);
    assert_eq!((tui.fg, tui.bold), (Some(Color::Ansi(10)), Some(true)));
    assert_eq!(theme.style("string", Medium::Gui).fg, Some(Color::Ansi(2)));
}

#[test]
fn layered_styles_keep_what_the_top_one_leaves_unset() {
    let base = Style {
        fg: Some(Color::Ansi(7)),
        bg: Some(Color::Ansi(0)),
        ..Style::default()
    };
    let over = Style {
        bg: Some(Color::Ansi(4)),
        underline: Some(Underline::Curl),
        underline_color: Some(Color::Ansi(1)),
        ..Style::default()
    };
    let merged = base.patch(&over);
    assert_eq!(merged.fg, Some(Color::Ansi(7)));
    assert_eq!(merged.bg, Some(Color::Ansi(4)));
    assert_eq!(merged.underline, Some(Underline::Curl));
}

#[test]
fn an_empty_theme_still_shows_selections_and_the_status_line() {
    let theme = Theme::default();
    assert_eq!(theme.style("ui.selection", Medium::Tui).reverse, Some(true));
    assert_eq!(
        theme.style("ui.statusline", Medium::Tui).reverse,
        Some(true)
    );
}

#[test]
fn other_clients_cursors_fall_back_to_the_cursor_and_selection() {
    let mut theme = Theme::default();
    // With no entries, they look like the client's own: reversed.
    assert_eq!(
        theme.style("ui.cursor.peer.3", Medium::Tui),
        theme.style("ui.cursor", Medium::Tui)
    );
    assert_eq!(
        theme.style("ui.selection.peer.2", Medium::Tui).reverse,
        Some(true)
    );
    theme.set("ui.cursor", Entry::new(fg(Color::Ansi(2))));
    theme.set("ui.cursor.peer.1", Entry::new(fg(Color::Ansi(5))));
    assert_eq!(
        theme.style("ui.cursor.peer.1", Medium::Tui).fg,
        Some(Color::Ansi(5))
    );
    assert_eq!(
        theme.style("ui.cursor.peer.4", Medium::Tui).fg,
        Some(Color::Ansi(2)),
        "a color without its own entry"
    );
}
