use greed_core::delta::FrameDelta;
use greed_core::render::{CellWidth, Frame, Plain, Renderer, Size, Status};
use greed_core::theme::{Entry, Style};
use greed_core::{Editor, parse_marked};
use greed_text::ClientId;

fn editor(marked: &str) -> Editor {
    let (text, selection) = parse_marked(marked).unwrap();
    let mut ed = Editor::new(ClientId(1));
    let (_, view) = ed.open("file", &text, Some("notes.md".into()));
    ed.view_mut(view).selection = selection;
    ed
}

fn frame(ed: &mut Editor) -> Frame {
    Renderer::new(CellWidth).frame(
        ed,
        Size {
            width: 30,
            height: 40,
        },
        &Status::Default { message: None },
        &Plain,
    )
}

fn insert(ed: &mut Editor, pos: usize, text: &str) {
    let view = ed.focus();
    let len = ed.buffer(ed.view(view).buffer).text().len_bytes();
    let changes = greed_text::ChangeSet::from_changes(len, [(pos, pos, Some(text))]).unwrap();
    ed.apply(
        view,
        changes,
        greed_text::Author::User(ClientId(1)),
        None,
        None,
    )
    .unwrap();
}

#[test]
fn nothing_changed_means_no_delta() {
    let mut ed = editor("|one\ntwo\nthree");
    let before = frame(&mut ed);
    assert!(FrameDelta::between(&before, &frame(&mut ed)).is_none());
}

#[test]
fn an_edit_sends_only_the_rows_it_changed() {
    let mut ed = editor("|one\ntwo\nthree");
    let before = frame(&mut ed);
    insert(&mut ed, 4, "X");
    let after = frame(&mut ed);
    let delta = FrameDelta::between(&before, &after).unwrap();
    let rows: Vec<u16> = delta.rows.iter().map(|(i, _)| *i).collect();
    assert_eq!(
        rows,
        [1],
        "only the edited line; the status line stayed the same"
    );
    assert!(delta.theme.is_none(), "the theme didn't change");

    let mut applied = before.clone();
    delta.apply(&mut applied);
    assert_eq!(applied, after);
}

#[test]
fn moving_the_cursor_sends_the_cursor_and_the_rows_it_left_and_reached() {
    let mut ed = editor("|one\ntwo\nthree");
    let before = frame(&mut ed);
    let view = ed.focus();
    ed.view_mut(view).selection = greed_text::Selection::point(5);
    let after = frame(&mut ed);
    let delta = FrameDelta::between(&before, &after).unwrap();
    assert!(delta.cursor.is_some());
    let mut applied = before.clone();
    delta.apply(&mut applied);
    assert_eq!(applied, after);
}

#[test]
fn a_new_theme_goes_along_once() {
    let mut ed = editor("|one");
    let before = frame(&mut ed);
    ed.theme_mut().set(
        "keyword",
        Entry::new(Style {
            bold: Some(true),
            ..Style::default()
        }),
    );
    let after = frame(&mut ed);
    let delta = FrameDelta::between(&before, &after).unwrap();
    assert!(delta.rows.is_empty() && delta.theme.is_some());
    let mut applied = before.clone();
    delta.apply(&mut applied);
    assert_eq!(applied, after);
}

#[test]
fn deltas_are_much_smaller_than_frames() {
    let text: Vec<String> = (0..40)
        .map(|n| format!("line number {n} with some text"))
        .collect();
    let mut ed = editor(&format!("|{}", text.join("\n")));
    let before = frame(&mut ed);
    insert(&mut ed, 0, "X");
    let after = frame(&mut ed);
    let delta = FrameDelta::between(&before, &after).unwrap();
    let full = serde_json::to_string(&after).unwrap().len();
    let small = serde_json::to_string(&delta).unwrap().len();
    assert!(small * 3 < full, "{small} bytes against {full}");
}

#[test]
fn window_options_go_along_when_they_change() {
    let mut ed = editor("|one");
    let before = frame(&mut ed);
    let mut after = frame(&mut ed);
    after
        .gui
        .insert("gui-font".to_owned(), "Fira Code".to_owned());
    let delta = FrameDelta::between(&before, &after).unwrap();
    assert!(delta.rows.is_empty() && delta.gui.is_some());
    let mut applied = before.clone();
    delta.apply(&mut applied);
    assert_eq!(applied, after);
}

#[test]
fn a_broken_frame_or_delta_from_a_session_is_drawn_as_far_as_it_makes_sense() {
    use greed_core::render::grid::compose;
    use greed_core::render::{FloatFrame, PanelFrame, Rect};
    use greed_core::theme::Surface;
    let mut ed = editor("hel|lo");
    let mut f = frame(&mut ed);
    let rect = Rect {
        x: 0,
        y: 0,
        width: 5,
        height: 2,
    };
    // A bordered float and a titled panel with no room left for either.
    f.floats.push(FloatFrame {
        rect,
        title: Some("t".into()),
        rows: Vec::new(),
        label: Vec::new(),
        footer: Vec::new(),
        border: true,
    });
    f.panels.push(PanelFrame {
        rect,
        separator: 0,
        title: Some("p".into()),
        rows: Vec::new(),
    });
    for surface in [Surface::Tui, Surface::Gui] {
        compose(&f, surface);
    }
    // No rows at all, then more than a screen has and the biggest size.
    let delta: FrameDelta =
        serde_json::from_str(r#"{ "row_count": 0, "size": { "width": 65535, "height": 65535 } }"#)
            .unwrap();
    delta.apply(&mut f);
    compose(&f, Surface::Tui);
    let delta: FrameDelta =
        serde_json::from_str(&format!(r#"{{ "row_count": {} }}"#, usize::MAX)).unwrap();
    delta.apply(&mut f);
    let grid = compose(&f, Surface::Tui);
    assert_eq!(grid.len(), usize::from(Size::MAX.height));
}
