use greed_core::render::{
    CellWidth, Decorations, Frame, Plain, Position, Renderer, Row, Size, Span, Status, StatusLine,
    Tag,
};
use greed_core::{Editor, Scroll, parse_marked};
use greed_text::ClientId;

fn editor(marked: &str) -> Editor {
    let (text, selection) = parse_marked(marked).unwrap();
    let mut ed = Editor::new(ClientId(1));
    let (_, view) = ed.open("file", &text, Some("notes.md".into()));
    ed.view_mut(view).selection = selection;
    ed
}

fn frame(ed: &mut Editor, width: u16, height: u16) -> Frame {
    Renderer::new(CellWidth).frame(
        ed,
        Size { width, height },
        &Status::Default { message: None },
        &Plain,
    )
}

/// The text of each row, without the status line.
fn rows(frame: &Frame) -> Vec<String> {
    let n = frame.rows.len() - 1;
    frame.rows[..n].iter().map(Row::text).collect()
}

/// The text of every span in `frame` carrying `tag`.
fn tagged(frame: &Frame, tag: &Tag) -> Vec<String> {
    frame
        .rows
        .iter()
        .flat_map(|r| &r.spans)
        .filter(|s| s.tags.contains(tag))
        .map(|s| s.text.clone())
        .collect()
}

#[test]
fn lines_get_numbers_and_empty_rows_stay_empty() {
    let mut ed = editor("|hello\nworld");
    let f = frame(&mut ed, 20, 4);
    assert_eq!(rows(&f), ["1 hello", "2 world", ""]);
    assert_eq!(tagged(&f, &Tag::GUTTER), ["1 ", "2 "]);
}

#[test]
fn the_gutter_fits_the_largest_line_number() {
    let text = (1..=10)
        .map(|n| n.to_string())
        .collect::<Vec<_>>()
        .join("\n");
    let mut ed = editor(&format!("|{text}"));
    let f = frame(&mut ed, 20, 11);
    assert_eq!(rows(&f)[0], " 1 1");
    assert_eq!(rows(&f)[9], "10 10");
}

#[test]
fn long_lines_wrap_at_word_boundaries() {
    let mut ed = editor("|the quick brown fox\nend");
    let f = frame(&mut ed, 12, 5);
    assert_eq!(rows(&f), ["1 the quick ", "  brown fox", "2 end", ""]);
}

#[test]
fn words_longer_than_the_row_break_anywhere() {
    let mut ed = editor("|abcdefghijkl");
    let f = frame(&mut ed, 7, 4);
    assert_eq!(rows(&f), ["1 abcde", "  fghij", "  kl"]);
}

#[test]
fn wide_characters_and_tabs_take_their_width() {
    let mut ed = editor("|\tx\n日本語");
    let f = frame(&mut ed, 7, 4);
    assert_eq!(rows(&f), ["1     x", "2 日本", "  語"]);
}

#[test]
fn selections_and_cursors_are_tagged() {
    let mut ed = editor("^hello| wo|rld");
    let f = frame(&mut ed, 20, 2);
    assert_eq!(tagged(&f, &Tag::SELECTION), ["hello"]);
    assert_eq!(tagged(&f, &Tag::CURSOR), ["r"]);
    // A block cursor sits on the selection's last character, as in Helix.
    assert_eq!(f.cursor, Some(Position { col: 6, row: 0 }));
}

#[test]
fn a_bar_cursor_sits_between_characters_and_shows_only_on_cursors() {
    let mut ed = editor("^hello| ^wo|rld");
    ed.set_cursor_shape("normal", greed_core::CursorShape::Bar);
    let f = frame(&mut ed, 20, 2);
    assert_eq!(f.cursor, Some(Position { col: 7, row: 0 }));
    assert!(
        tagged(&f, &Tag::CURSOR).is_empty(),
        "no cursors drawn on selections"
    );
    ed.set_cursor_shape("normal", greed_core::CursorShape::Block);
    let f = frame(&mut ed, 20, 2);
    assert_eq!(
        tagged(&f, &Tag::CURSOR),
        ["o"],
        "each selection shows its cursor"
    );
}

#[test]
fn a_cursor_at_the_end_of_a_line_sits_after_it() {
    let mut ed = editor("ab|\ncd");
    let f = frame(&mut ed, 20, 3);
    assert_eq!(f.cursor, Some(Position { col: 4, row: 0 }));
    assert_eq!(rows(&f), ["1 ab", "2 cd"]);
}

#[test]
fn the_view_scrolls_to_keep_the_cursor_visible() {
    let text: Vec<String> = (0..50).map(|n| format!("line {n}")).collect();
    let mut ed = editor(&format!("|{}", text.join("\n")));
    let view = ed.focus();
    let end = ed.buffer(ed.view(view).buffer).text().len_bytes();
    ed.view_mut(view).selection = greed_text::Selection::point(end);

    let f = frame(&mut ed, 20, 5);
    assert_eq!(
        rows(&f),
        [
            "46 line 45",
            "47 line 46",
            "48 line 47",
            "49 line 48",
            "50 line 49"
        ][1..]
    );
    assert_eq!(ed.view(view).scroll, Scroll { line: 46, row: 0 });
    assert_eq!(f.cursor, Some(Position { col: 10, row: 3 }));

    ed.view_mut(view).selection = greed_text::Selection::point(0);
    let f = frame(&mut ed, 20, 5);
    assert_eq!(rows(&f)[0], " 1 line 0");
    assert_eq!(ed.view(view).scroll, Scroll::default());
}

#[test]
fn views_remember_which_bytes_they_showed() {
    let text: Vec<String> = (0..50).map(|n| format!("line {n}")).collect();
    let mut ed = editor(&format!("|{}", text.join("\n")));
    let view = ed.focus();
    assert_eq!(ed.view(view).visible, None);

    frame(&mut ed, 20, 5);
    let shown = "line 0\nline 1\nline 2\nline 3".len();
    assert_eq!(ed.view(view).visible, Some(0..shown));

    // Wrapped rows leave room for fewer lines.
    let mut ed = editor("|aaaa bbbb cccc dddd\nx\ny\nz");
    let view = ed.focus();
    frame(&mut ed, 12, 5);
    assert_eq!(
        ed.view(view).visible,
        Some(0.."aaaa bbbb cccc dddd\nx\ny".len())
    );
}

#[test]
fn scrolling_counts_wrapped_rows() {
    let mut ed = editor("aaaa bbbb cccc dddd\n|x");
    let f = frame(&mut ed, 8, 3);
    // The first line wraps into four rows; only the last fits above "x".
    assert_eq!(rows(&f), ["  dddd", "2 x"]);
    assert_eq!(ed.view(ed.focus()).scroll, Scroll { line: 0, row: 3 });
}

#[test]
fn the_status_line_shows_mode_file_and_position() {
    let mut ed = editor("ab\nc|d");
    let f = frame(&mut ed, 24, 3);
    let status = f.rows.last().unwrap();
    assert_eq!(status.text(), " NORMAL  notes.md   2:2 ");
    assert_eq!(tagged(&f, &Tag::MODE), [" NORMAL "]);

    let f = Renderer::new(CellWidth).frame(
        &mut ed,
        Size {
            width: 24,
            height: 3,
        },
        &Status::Default {
            message: Some("saved"),
        },
        &Plain,
    );
    assert_eq!(f.rows.last().unwrap().text(), " NORMAL  saved      2:2 ");
}

#[test]
fn long_paths_keep_their_end_on_the_status_line() {
    let (text, selection) = parse_marked("|x").unwrap();
    let mut ed = Editor::new(ClientId(1));
    let (_, view) = ed.open(
        "file",
        &text,
        Some("/very/long/path/to/some/notes.md".into()),
    );
    ed.view_mut(view).selection = selection;
    let f = frame(&mut ed, 30, 2);
    let status = f.rows.last().unwrap().text();
    assert_eq!(status, " NORMAL  …o/some/notes.md 1:1 ");
    assert_eq!(status.chars().count(), 30);
}

#[test]
fn highlights_tag_text_with_inner_and_first_captures_winning() {
    use greed_core::syntax::Highlight;
    use std::sync::Arc;

    let mut ed = editor("|let s = \"a\\n\";");
    let h = |range: std::ops::Range<usize>, capture: &str| Highlight {
        range,
        capture: Arc::from(capture),
    };
    let highlights = vec![
        h(8..13, "string"),
        h(0..3, "keyword"),
        h(0..3, "keyword.storage"),
        h(10..12, "escape"),
    ];
    let f = Renderer::new(CellWidth).frame(
        &mut ed,
        Size {
            width: 30,
            height: 2,
        },
        &Status::Default { message: None },
        &Fixed {
            highlights: highlights.clone(),
            diagnostics: Vec::new(),
        },
    );
    let syntax: Vec<(String, String)> = f.rows[0]
        .spans
        .iter()
        .filter_map(|s| {
            let tag = s.tags.first().filter(|t| !t.name().starts_with("ui."))?;
            Some((s.text.clone(), tag.name().to_owned()))
        })
        .collect();
    assert_eq!(
        syntax,
        [
            ("let".to_string(), "keyword".to_string()),
            ("\"a".to_string(), "string".to_string()),
            ("\\n".to_string(), "escape".to_string()),
            ("\"".to_string(), "string".to_string()),
        ]
    );
}

#[test]
fn floating_views_get_a_box_and_the_cursor_when_focused() {
    use greed_core::{Anchor, Extent, FloatOptions};
    let mut ed = editor("|main");
    let list = ed.create_buffer("picker", "one\ntwo");
    ed.float(
        list,
        FloatOptions {
            title: Some("Files".into()),
            width: Extent::Cells(12),
            height: Extent::Cells(4),
            anchor: Anchor::Center,
            focus: true,
            x: None,
            y: None,
            tab: false,
        },
    );
    let f = frame(&mut ed, 20, 9);
    assert_eq!(f.floats.len(), 1);
    let float = &f.floats[0];
    // 12x4 outside the border, centred in the 20x8 above the status line.
    assert_eq!(
        (
            float.rect.x,
            float.rect.y,
            float.rect.width,
            float.rect.height
        ),
        (5, 3, 10, 2)
    );
    assert_eq!(float.title.as_deref(), Some("Files"));
    let rows: Vec<String> = float.rows.iter().map(Row::text).collect();
    assert_eq!(rows, ["one", "two"]);
    assert_eq!(f.cursor, Some(Position { col: 5, row: 3 }));
    // The main view still renders underneath, with its status line.
    assert_eq!(f.rows[0].text(), "1 main");
}

#[test]
fn plugin_status_lines_are_padded_and_trimmed() {
    let span = |text: &str, tag: Tag| Span::new(text, [tag].into_iter().collect());
    let line = StatusLine {
        left: vec![
            span(" N ", Tag::MODE),
            span(" a/long/path/file.rs", Tag::STATUS),
        ],
        right: vec![span("3:4 ", Tag::STATUS)],
    };
    let render = |width| {
        let mut ed = editor("|x");
        let f = Renderer::new(CellWidth).frame(
            &mut ed,
            Size { width, height: 2 },
            &Status::Line(line.clone()),
            &Plain,
        );
        f.rows.last().unwrap().text()
    };
    assert_eq!(render(32), " N  a/long/path/file.rs     3:4 ");
    assert_eq!(render(20), " N …ath/file.rs 3:4 ");
}

/// Decorations given up front, for tests.
struct Fixed {
    highlights: Vec<greed_core::syntax::Highlight>,
    diagnostics: Vec<(std::ops::Range<usize>, u8)>,
}

impl Decorations for Fixed {
    fn highlights(
        &self,
        _: greed_core::BufferId,
        _: &greed_text::Rope,
        _: std::ops::Range<usize>,
    ) -> Vec<greed_core::syntax::Highlight> {
        self.highlights.clone()
    }

    fn diagnostics(&self, _: greed_core::BufferId) -> &[(std::ops::Range<usize>, u8)] {
        &self.diagnostics
    }
}

#[test]
fn diagnostics_mark_their_text_and_line_number() {
    let mut ed = editor("|let x = bad;\nok\nworse");
    let f = Renderer::new(CellWidth).frame(
        &mut ed,
        Size {
            width: 30,
            height: 4,
        },
        &Status::Default { message: None },
        &Fixed {
            highlights: Vec::new(),
            diagnostics: vec![(8..11, 2), (9..10, 1), (16..16, 3)],
        },
    );
    let marked: Vec<(String, String)> = f
        .rows
        .iter()
        .flat_map(|r| &r.spans)
        .filter_map(|s| {
            s.tags
                .iter()
                .find(|t| t.name().contains("diagnostic."))
                .map(|t| (s.text.clone(), t.name().to_owned()))
        })
        .collect();
    // The worst severity wins where marks overlap; empty marks cover one
    // character. Line numbers get the gutter's names.
    let expected = [
        ("1 ", "ui.gutter.diagnostic.error"),
        ("b", "diagnostic.warning"),
        ("a", "diagnostic.error"),
        ("d", "diagnostic.warning"),
        ("3 ", "ui.gutter.diagnostic.info"),
        ("w", "diagnostic.info"),
    ]
    .map(|(text, name)| (text.to_owned(), name.to_owned()));
    assert_eq!(marked, expected);
}

#[test]
fn decorations_tag_their_text_and_lines_style_whole_rows() {
    use greed_core::Mark;
    let mut ed = editor("|one\ntwo");
    let buffer = ed.view(ed.focus()).buffer;
    ed.decorate(
        buffer,
        "picker",
        vec![
            Mark {
                range: 4..7,
                style: "picker.current".into(),
                line: true,
                ..Mark::default()
            },
            Mark {
                range: 5..6,
                style: "match".into(),
                ..Mark::default()
            },
        ],
    );
    let f = frame(&mut ed, 20, 3);
    assert_eq!(tagged(&f, &Tag::from("match")), ["w"]);
    assert!(f.rows[0].tags.is_empty());
    assert_eq!(f.rows[1].tags.as_slice(), [Tag::from("picker.current")]);
}

#[test]
fn marks_add_text_that_isnt_in_the_buffer() {
    use greed_core::Mark;
    let mut ed = editor("let x = 1|;\nfoo()");
    let buffer = ed.view(ed.focus()).buffer;
    ed.decorate(
        buffer,
        "hints",
        vec![
            Mark {
                range: 5..5,
                style: "hint".into(),
                text: Some(": i32".into()),
                ..Mark::default()
            },
            Mark {
                range: 11..14,
                style: "diagnostic.error".into(),
                text: Some("not found".into()),
                eol: true,
                ..Mark::default()
            },
        ],
    );
    let f = frame(&mut ed, 30, 3);
    assert_eq!(rows(&f), ["1 let x: i32 = 1;", "2 foo() not found"]);
    assert_eq!(tagged(&f, &Tag::from("hint")), [": i32"]);
    assert_eq!(
        tagged(&f, &Tag::from("diagnostic.error")),
        ["foo", " not found"]
    );
    // The cursor counts the inserted text's width but can't land in it.
    assert_eq!(f.cursor, Some(Position { col: 16, row: 0 }));

    // Text past the edge is cut off rather than wrapped.
    let f = frame(&mut ed, 12, 6);
    assert!(
        rows(&f).contains(&"2 foo() not".to_string()),
        "{:?}",
        rows(&f)
    );
}

#[test]
fn signs_get_a_column_before_the_line_numbers() {
    use greed_core::Mark;
    let mut ed = editor("|a\nb\nc");
    let buffer = ed.view(ed.focus()).buffer;
    let f = frame(&mut ed, 20, 4);
    assert_eq!(rows(&f), ["1 a", "2 b", "3 c"], "no column without signs");
    ed.decorate(
        buffer,
        "lsp",
        vec![Mark {
            range: 2..3,
            style: "diagnostic.error".into(),
            sign: Some("E".into()),
            ..Mark::default()
        }],
    );
    let f = frame(&mut ed, 20, 4);
    assert_eq!(rows(&f), ["  1 a", "E 2 b", "  3 c"]);
    assert_eq!(tagged(&f, &Tag::from("diagnostic.error")), ["E ", "b"]);
}

#[test]
fn marks_can_draw_above_the_selection() {
    use greed_core::Mark;
    let mut ed = editor("^abc|");
    let buffer = ed.view(ed.focus()).buffer;
    let mark = |style: &str, above| Mark {
        range: 0..3,
        style: style.into(),
        above,
        ..Mark::default()
    };
    ed.decorate(buffer, "x", vec![mark("under", false), mark("flash", true)]);
    let f = frame(&mut ed, 20, 2);
    let span = f.rows[0].spans.iter().find(|s| s.text == "abc").unwrap();
    let names: Vec<&str> = span.tags.iter().map(Tag::name).collect();
    assert_eq!(names, ["under", "ui.selection", "flash"]);
}

#[test]
fn floats_can_be_placed_side_by_side() {
    use greed_core::{Anchor, Extent, FloatOptions};
    let mut ed = editor("|main");
    let float = |x: Option<Extent>, y: Option<Extent>| FloatOptions {
        title: None,
        width: Extent::Percent(50),
        height: Extent::Cells(4),
        anchor: Anchor::Center,
        focus: false,
        x,
        y,
        tab: false,
    };
    let left = ed.create_buffer("picker", "a");
    let right = ed.create_buffer("preview", "b");
    ed.float(left, float(Some(Extent::Cells(0)), Some(Extent::Cells(1))));
    ed.float(
        right,
        float(Some(Extent::Percent(50)), Some(Extent::Cells(1))),
    );
    let f = frame(&mut ed, 20, 9);
    let rects: Vec<_> = f
        .floats
        .iter()
        .map(|f| (f.rect.x, f.rect.y, f.rect.width, f.rect.height))
        .collect();
    // Positions are of the outside of the border, which is one cell wide.
    assert_eq!(rects, [(1, 2, 8, 2), (11, 2, 8, 2)]);

    // A box that would hang off the edge is moved back on screen.
    let edge = ed.create_buffer("x", "c");
    ed.float(edge, float(Some(Extent::Cells(18)), None));
    let f = frame(&mut ed, 20, 9);
    assert_eq!(f.floats[2].rect.x, 11);
}

#[test]
fn panels_take_room_from_the_main_view() {
    use greed_core::{Extent, PanelOptions, Side};
    let mut ed = editor("hello|");
    let main = ed.main();
    let tree = ed.create_buffer("tree", "src/\nREADME.md");
    let panel = ed.panel(
        tree,
        PanelOptions {
            side: Side::Left,
            width: Extent::Cells(8),
            title: Some("Files".into()),
            focus: false,
        },
    );
    let f = frame(&mut ed, 30, 5);
    // The panel is 8 wide, then a separator column, then the main view.
    assert_eq!(f.panels.len(), 1);
    let p = &f.panels[0];
    assert_eq!(
        (p.rect.x, p.rect.y, p.rect.width, p.rect.height),
        (0, 1, 8, 3)
    );
    assert_eq!(p.separator, 8);
    assert_eq!(p.title.as_deref(), Some("Files"));
    assert_eq!(p.rows[0].text(), "src/");
    assert_eq!((f.main.x, f.main.width, f.main.height), (9, 21, 4));
    assert_eq!(f.rows[0].text(), "1 hello");
    // The cursor sits in the main view, after the panel.
    assert_eq!(f.cursor, Some(Position { col: 9 + 7, row: 0 }));
    // The status line still spans the screen.
    assert_eq!(f.rows.last().unwrap().text().chars().count(), 30);

    ed.set_focus(panel);
    assert_eq!(ed.focus(), panel);
    assert!(ed.close(panel));
    assert_eq!(ed.focus(), main);
    let f = frame(&mut ed, 30, 5);
    assert!(f.panels.is_empty());
    assert_eq!((f.main.x, f.main.width), (0, 30));
}

#[test]
fn right_panels_sit_after_the_main_view() {
    use greed_core::{Extent, PanelOptions, Side};
    let mut ed = editor("|x");
    let b = ed.create_buffer("outline", "fn main");
    ed.panel(
        b,
        PanelOptions {
            side: Side::Right,
            width: Extent::Percent(25),
            title: None,
            focus: true,
        },
    );
    let f = frame(&mut ed, 40, 4);
    let p = &f.panels[0];
    assert_eq!((p.rect.x, p.rect.y, p.rect.width), (30, 0, 10));
    assert_eq!(p.separator, 29);
    assert_eq!((f.main.x, f.main.width), (0, 29));
    // The focused panel has the cursor.
    assert_eq!(f.cursor, Some(Position { col: 30, row: 0 }));
}

#[test]
fn overlay_marks_draw_over_the_text_without_moving_it() {
    use greed_core::Mark;
    let mut ed = editor("hello |world\nfoo");
    let buffer = ed.view(ed.focus()).buffer;
    let label = |at: usize, text: &str| Mark {
        range: at..at,
        style: "jump.label".into(),
        text: Some(text.into()),
        overlay: true,
        ..Mark::default()
    };
    ed.decorate(buffer, "jump", vec![label(6, "ab"), label(12, "c")]);
    let f = frame(&mut ed, 20, 3);
    assert_eq!(rows(&f), ["1 hello abrld", "2 coo"]);
    assert_eq!(tagged(&f, &Tag::from("jump.label")), ["ab", "c"]);
    // The cursor is where it was; the text didn't move.
    assert_eq!(f.cursor, Some(Position { col: 8, row: 0 }));
}

#[test]
fn a_float_anchored_at_the_cursor_opens_below_it_or_above_near_the_bottom() {
    use greed_core::{Anchor, Extent, FloatOptions};
    let options = FloatOptions {
        title: None,
        width: Extent::Cells(8),
        height: Extent::Cells(4),
        anchor: Anchor::Cursor,
        focus: false,
        x: None,
        y: None,
        tab: false,
    };
    let mut ed = editor("ab|c\nd");
    let cursor = frame(&mut ed, 30, 10)
        .cursor
        .expect("the cursor is on screen");
    let menu = ed.create_buffer("menu", "item");
    ed.float(menu, options.clone());
    let f = frame(&mut ed, 30, 10);
    let rect = f.floats[0].rect;
    // The list's text starts under the cursor, on the row below it.
    assert_eq!((rect.x, rect.y), (cursor.col, cursor.row + 2), "{rect:?}");
    assert_eq!(f.cursor, Some(cursor), "the cursor stays in the text");

    let mut ed = editor("a\nb\nc\nd\ne\nf\ng\nh|");
    let cursor = frame(&mut ed, 30, 10).cursor.unwrap();
    let menu = ed.create_buffer("menu", "item");
    ed.float(menu, options);
    let rect = frame(&mut ed, 30, 10).floats[0].rect;
    assert_eq!(
        rect.y + rect.height + 1,
        cursor.row,
        "above the cursor: {rect:?}"
    );
}

#[test]
fn a_float_anchored_above_the_cursor_opens_above_it_or_below_near_the_top() {
    use greed_core::{Anchor, Extent, FloatOptions};
    let options = FloatOptions {
        title: None,
        width: Extent::Cells(8),
        height: Extent::Cells(3),
        anchor: Anchor::AboveCursor,
        focus: false,
        x: None,
        y: None,
        tab: false,
    };
    let mut ed = editor("a\nb\nc\nd\ne|");
    let cursor = frame(&mut ed, 30, 10).cursor.unwrap();
    let help = ed.create_buffer("signature", "fn f()");
    ed.float(help, options.clone());
    let rect = frame(&mut ed, 30, 10).floats[0].rect;
    assert_eq!(rect.y + rect.height + 1, cursor.row, "above: {rect:?}");

    let mut ed = editor("ab|c\nd");
    let cursor = frame(&mut ed, 30, 10).cursor.unwrap();
    let help = ed.create_buffer("signature", "fn f()");
    ed.float(help, options);
    let rect = frame(&mut ed, 30, 10).floats[0].rect;
    assert_eq!(rect.y, cursor.row + 2, "no room above, so below: {rect:?}");
}

/// Each row's text without the gutter (line numbers and signs).
fn body(frame: &Frame) -> Vec<String> {
    rows(frame)
        .iter()
        .map(|row| {
            let row = row.trim_start();
            let row = row.trim_start_matches(|c: char| c.is_ascii_digit());
            row.strip_prefix(' ').unwrap_or(row).to_owned()
        })
        .collect()
}
#[test]
fn concealed_text_is_hidden_except_on_lines_with_a_cursor() {
    use greed_core::Mark;
    let mut ed = editor("|top\na **b** [[note]]");
    let buffer = ed.view(ed.main()).buffer;
    let hide = |from, to, text: Option<&str>| Mark {
        range: from..to,
        style: "markup".into(),
        conceal: true,
        text: text.map(Into::into),
        ..Mark::default()
    };
    // "a **b** [[note]]" starts at byte 4.
    ed.decorate(
        buffer,
        "md",
        vec![
            hide(6, 8, None),
            hide(9, 11, None),
            hide(12, 20, Some("note")),
        ],
    );
    assert_eq!(body(&frame(&mut ed, 20, 3))[1], "a b note");

    let main = ed.main();
    ed.view_mut(main).selection = greed_text::Selection::point(5);
    assert_eq!(
        body(&frame(&mut ed, 30, 3))[1],
        "a **b** [[note]]",
        "the cursor's line shows everything"
    );
}

#[test]
fn folded_lines_are_hidden_until_a_cursor_goes_in() {
    use greed_core::Mark;
    let mut ed = editor("# A\none\ntwo\n# B|");
    let buffer = ed.view(ed.main()).buffer;
    ed.decorate(
        buffer,
        "fold",
        vec![Mark {
            range: 0..11,
            style: "fold".into(),
            fold: true,
            ..Mark::default()
        }],
    );
    assert_eq!(body(&frame(&mut ed, 20, 5))[..3], ["# A", "# B", ""]);

    let main = ed.main();
    ed.view_mut(main).selection = greed_text::Selection::point(5);
    assert_eq!(
        body(&frame(&mut ed, 20, 5))[..4],
        ["# A", "one", "two", "# B"],
        "a cursor inside opens it"
    );
}

#[test]
fn virtual_lines_show_under_their_line_and_count_when_scrolling() {
    use greed_core::Mark;
    let mut ed = editor("a\nb\nc\nd|");
    let buffer = ed.view(ed.main()).buffer;
    ed.decorate(
        buffer,
        "notes",
        vec![Mark {
            range: 0..1,
            style: "note".into(),
            lines: vec!["x".into(), "y".into()],
            ..Mark::default()
        }],
    );
    assert_eq!(
        body(&frame(&mut ed, 20, 7))[..6],
        ["a", "x", "y", "b", "c", "d"]
    );
    // On a short screen the cursor's line stays in view.
    let f = frame(&mut ed, 20, 4);
    assert!(body(&f).contains(&"d".to_owned()), "{:?}", body(&f));
}

#[test]
fn parts_of_virtual_lines_can_have_styles_of_their_own() {
    use greed_core::{Mark, VirtualLine};
    let mut ed = editor("a|");
    let buffer = ed.view(ed.main()).buffer;
    let line = VirtualLine {
        text: "let x = 2;".into(),
        styles: vec![(8..9, "diff.plus.change".into())],
    };
    ed.decorate(
        buffer,
        "diff",
        vec![Mark {
            range: 0..0,
            style: "diff.plus".into(),
            lines: vec![line],
            ..Mark::default()
        }],
    );
    let f = frame(&mut ed, 20, 3);
    assert_eq!(body(&f)[1], "let x = 2;");
    assert_eq!(tagged(&f, &Tag::from("diff.plus")).concat(), "let x = 2;");
    assert_eq!(tagged(&f, &Tag::from("diff.plus.change")), ["2"]);
}

#[test]
fn a_buffer_can_go_without_line_numbers() {
    let mut ed = editor("|one\ntwo");
    let buffer = ed.view(ed.main()).buffer;
    assert_eq!(rows(&frame(&mut ed, 12, 3))[0], "1 one");
    ed.set_line_numbers(buffer, false);
    assert_eq!(rows(&frame(&mut ed, 12, 3))[0], "one");
}

#[test]
fn views_remember_the_room_they_had() {
    let mut ed = editor("|one");
    let main = ed.main();
    assert_eq!(ed.view(main).size, None);
    let buffer = ed.view(main).buffer;
    ed.set_line_numbers(buffer, false);
    frame(&mut ed, 30, 10);
    // The status line takes a row.
    assert_eq!(ed.view(main).size, Some((9, 30)));
}

#[test]
fn panes_share_the_screen_with_a_line_between() {
    use greed_core::layout::Direction;
    let mut ed = editor("|left\ntwo");
    let main = ed.main();
    let buffer = ed.view(main).buffer;
    ed.set_line_numbers(buffer, false);
    let other = ed.create_buffer("scratch", "right");
    ed.set_line_numbers(other, false);
    let right = ed.split_pane(main, Direction::Right, Some(other)).unwrap();
    assert_eq!(ed.main(), right, "the new pane is active");
    let f = frame(&mut ed, 21, 4);
    assert_eq!(
        rows(&f),
        [
            "left      │right     ",
            "two       │          ",
            "          │          "
        ]
    );
    let below = ed.split_pane(right, Direction::Down, None).unwrap();
    let f = frame(&mut ed, 21, 6);
    assert_eq!(
        rows(&f),
        [
            "left      │right     ",
            "two       │          ",
            "          │──────────",
            "          │right     ",
            "          │          ",
        ]
    );
    // The cursor is in the focused pane.
    assert_eq!(f.cursor, Some(Position { col: 11, row: 3 }));
    assert_eq!(ed.view(below).area.map(|a| (a.x, a.y)), Some((11, 3)));
}

#[test]
fn a_zoomed_tab_shows_only_its_active_pane() {
    use greed_core::layout::Direction;
    let mut ed = editor("|one");
    let main = ed.main();
    let buffer = ed.view(main).buffer;
    ed.set_line_numbers(buffer, false);
    ed.split_pane(main, Direction::Right, None);
    ed.set_zoomed(true);
    assert_eq!(rows(&frame(&mut ed, 12, 2)), ["one"]);
}

#[test]
fn more_than_one_tab_shows_the_tabs_above() {
    let mut ed = editor("|one");
    let main = ed.main();
    let buffer = ed.view(main).buffer;
    ed.set_line_numbers(buffer, false);
    let first = ed.current_tab().id();
    ed.new_tab(Some(buffer));
    let f = frame(&mut ed, 30, 4);
    assert_eq!(rows(&f)[0], " 1 notes.md  2 notes.md       ");
    let active: Vec<_> = f.rows[0]
        .spans
        .iter()
        .filter(|s| s.tags.contains(&Tag::TABLINE_ACTIVE))
        .map(|s| s.text.as_str())
        .collect();
    assert_eq!(active, [" 2 notes.md "]);
    ed.rename_tab(first, Some("work".into()));
    ed.switch_tab(first);
    assert_eq!(
        rows(&frame(&mut ed, 30, 4))[0],
        " 1 work  2 notes.md           "
    );
    assert_eq!(rows(&frame(&mut ed, 30, 4))[1].trim_end(), "one");
}

#[test]
fn image_marks_place_their_image_cut_to_the_view() {
    use greed_core::image::Image;
    use greed_core::render::{ImagePlacement, Rect};
    use greed_core::{Mark, MarkImage};
    use std::sync::Arc;

    let text: String = (0..20)
        .map(|i| format!("line {i}\n"))
        .collect::<Vec<_>>()
        .concat();
    let mut ed = editor(&format!("|{text}"));
    let buffer = ed.view(ed.main()).buffer;
    ed.set_line_numbers(buffer, false);
    let image = Image::from_pixels(4, 3, 3, &[0; 36]).unwrap();
    let id = ed.images_mut().insert(Arc::new(image));
    // An image 4 cells wide and 3 high from line 1, column 2.
    let start = "line 0\n".len() + 2;
    ed.decorate(
        buffer,
        "pictures",
        vec![Mark {
            range: start..start + "line 1\nline 2\nline".len(),
            style: "image".into(),
            image: Some(MarkImage {
                id,
                cols: 4,
                rows: 3,
                col: 0,
                row: 0,
            }),
            ..Mark::default()
        }],
    );
    let placed = |ed: &mut Editor| frame(ed, 20, 6).images;
    let rect = |x, y, width, height| Rect {
        x,
        y,
        width,
        height,
    };
    assert_eq!(
        placed(&mut ed),
        [ImagePlacement {
            id,
            rect: rect(2, 1, 4, 3),
            col: 0,
            row: 0,
            cols: 4,
            rows: 3
        }]
    );
    // Scrolled down to line 2, the image loses its first row.
    let main = ed.main();
    let line = |n: usize| (0..n).map(|i| format!("line {i}\n").len()).sum::<usize>();
    ed.view_mut(main).selection = greed_text::Selection::point(line(4));
    ed.view_mut(main).scroll = Scroll { line: 2, row: 0 };
    let shown = placed(&mut ed);
    assert_eq!(shown.len(), 1);
    assert_eq!((shown[0].rect, shown[0].row), (rect(2, 0, 4, 2), 1));
    // Scrolled past it, it's gone; an image nobody has is never placed.
    ed.view_mut(main).selection = greed_text::Selection::point(line(7));
    ed.view_mut(main).scroll = Scroll { line: 5, row: 0 };
    assert_eq!(placed(&mut ed), []);
}

/// `ranges` of the focused buffer drawn `scale` times bigger.
fn scaled(ed: &mut Editor, ranges: &[(std::ops::Range<usize>, u8)]) {
    use greed_core::Mark;
    let buffer = ed.view(ed.focus()).buffer;
    let marks = ranges
        .iter()
        .map(|(range, scale)| Mark {
            range: range.clone(),
            style: "markup.heading".into(),
            scale: *scale,
            ..Mark::default()
        })
        .collect();
    ed.decorate(buffer, "rich", marks);
}

/// Each row's spans as (text, scale), without the gutter.
fn scales(row: &Row) -> Vec<(String, u8)> {
    row.spans
        .iter()
        .filter(|s| !s.tags.contains(&Tag::GUTTER))
        .map(|s| (s.text.clone(), s.scale))
        .collect()
}

#[test]
fn scaled_text_takes_that_many_cells_across_and_rows_down() {
    let mut ed = editor("|# Big\nnext");
    scaled(&mut ed, &[(0..5, 2)]);
    let f = frame(&mut ed, 20, 5);
    assert_eq!(rows(&f), ["1 # Big", "", "2 next", ""]);
    assert_eq!(scales(&f.rows[0]), [("# Big".to_owned(), 2)]);
    assert_eq!(f.rows[0].covers, 1, "the row below is part of it");
    assert_eq!(f.rows[1].covers, 0);
    assert_eq!(f.rows[2].covers, 0);
}

#[test]
fn sizes_mix_in_a_line_and_the_row_is_as_tall_as_the_largest() {
    let mut ed = editor("|ab cd");
    scaled(&mut ed, &[(0..2, 3)]);
    let f = frame(&mut ed, 20, 5);
    assert_eq!(
        scales(&f.rows[0]),
        [("ab".to_owned(), 3), (" cd".to_owned(), 1)]
    );
    assert_eq!(f.rows[0].covers, 2);
    assert_eq!(rows(&f), ["1 ab cd", "", "", ""]);
}

#[test]
fn scaled_text_wraps_by_the_cells_it_takes() {
    // Eight cells of text: four characters at twice the size.
    let mut ed = editor("|abcdefgh");
    scaled(&mut ed, &[(0..8, 2)]);
    let f = frame(&mut ed, 10, 5);
    assert_eq!(rows(&f), ["1 abcd", "", "  efgh", ""]);
    assert_eq!((f.rows[0].covers, f.rows[2].covers), (1, 1));
}

#[test]
fn scrolling_counts_the_rows_scaled_lines_take() {
    let text = "one\ntwo\nthree\nfour\nfive";
    let mut ed = editor(&format!("{text}|"));
    let ranges: Vec<_> = [0..3, 4..7, 8..13, 14..18, 19..23]
        .into_iter()
        .map(|r| (r, 2))
        .collect();
    scaled(&mut ed, &ranges);
    let f = frame(&mut ed, 20, 5);
    assert_eq!(rows(&f), ["4 four", "", "5 five", ""]);
    assert_eq!(f.cursor.map(|c| c.row), Some(2));
    assert_eq!(ed.view(ed.focus()).scroll, Scroll { line: 3, row: 0 });
}

#[test]
fn the_mouse_finds_scaled_text_in_any_of_its_cells() {
    let mut ed = editor("|ab\ncd");
    scaled(&mut ed, &[(0..2, 2)]);
    let renderer = Renderer::new(CellWidth);
    renderer.frame(
        &mut ed,
        Size {
            width: 20,
            height: 5,
        },
        &Status::Default { message: None },
        &Plain,
    );
    let view = ed.focus();
    // "a" takes text cells 0-1 and "b" 2-3, on rows 0 and 1.
    assert_eq!(renderer.byte_at(&ed, view, 1, 0), Some(0));
    assert_eq!(renderer.byte_at(&ed, view, 2, 1), Some(1));
    assert_eq!(renderer.byte_at(&ed, view, 0, 2), Some(3), "the next line");
}

#[test]
fn a_scaled_button_is_clicked_on_any_row_it_takes() {
    use greed_core::Mark;
    let mut ed = editor("|x");
    let buffer = ed.view(ed.focus()).buffer;
    ed.decorate(
        buffer,
        "rich",
        vec![Mark {
            range: 0..0,
            style: "button".into(),
            text: Some("go".into()),
            action: Some("run-it".into()),
            scale: 2,
            ..Mark::default()
        }],
    );
    let renderer = Renderer::new(CellWidth);
    renderer.frame(
        &mut ed,
        Size {
            width: 20,
            height: 5,
        },
        &Status::Default { message: None },
        &Plain,
    );
    // "1 " is the gutter, then "go" takes columns 2-5 on rows 0 and 1.
    for row in [0, 1] {
        let hit = renderer.hit(&ed, 3, row);
        assert_eq!(hit.action.as_deref(), Some("run-it"), "row {row}");
    }
    assert_eq!(renderer.hit(&ed, 3, 2).action, None);
}
