use kern_core::render::{
    CellWidth, Decorations, Frame, Plain, Position, Renderer, Row, Size, Span, Status, StatusLine,
    Tag,
};
use kern_core::{Editor, Scroll, parse_marked};
use kern_text::ClientId;

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
    assert_eq!(f.cursor, Some(Position { col: 7, row: 0 }));
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
    ed.view_mut(view).selection = kern_text::Selection::point(end);

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

    ed.view_mut(view).selection = kern_text::Selection::point(0);
    let f = frame(&mut ed, 20, 5);
    assert_eq!(rows(&f)[0], " 1 line 0");
    assert_eq!(ed.view(view).scroll, Scroll::default());
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
    use kern_core::syntax::Highlight;
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
    use kern_core::{Anchor, Extent, FloatOptions};
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
    let span = |text: &str, tag: Tag| Span {
        text: text.into(),
        tags: [tag].into_iter().collect(),
    };
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
    highlights: Vec<kern_core::syntax::Highlight>,
    diagnostics: Vec<(std::ops::Range<usize>, u8)>,
}

impl Decorations for Fixed {
    fn highlights(
        &self,
        _: kern_core::BufferId,
        _: &kern_text::Rope,
        _: std::ops::Range<usize>,
    ) -> Vec<kern_core::syntax::Highlight> {
        self.highlights.clone()
    }

    fn diagnostics(&self, _: kern_core::BufferId) -> &[(std::ops::Range<usize>, u8)] {
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
    use kern_core::Mark;
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
    use kern_core::Mark;
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
    use kern_core::Mark;
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
    use kern_core::Mark;
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
    use kern_core::{Anchor, Extent, FloatOptions};
    let mut ed = editor("|main");
    let float = |x: Option<Extent>, y: Option<Extent>| FloatOptions {
        title: None,
        width: Extent::Percent(50),
        height: Extent::Cells(4),
        anchor: Anchor::Center,
        focus: false,
        x,
        y,
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
    use kern_core::{Extent, PanelOptions, Side};
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
    use kern_core::{Extent, PanelOptions, Side};
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
    use kern_core::Mark;
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
