use greed_core::delta::{FrameDelta, SurfaceDelta};
use greed_core::layout::Direction;
use greed_core::render::{CellWidth, Frame, Plain, Renderer, Size, Status, SurfaceId};
use greed_core::theme::{Entry, Style};
use greed_core::{Anchor, Editor, Extent, FloatOptions, ViewId, parse_marked};
use greed_text::ClientId;

fn editor(marked: &str) -> Editor {
    let (text, selection) = parse_marked(marked).unwrap();
    let mut ed = Editor::new(ClientId(1));
    let (_, view) = ed.open("file", &text, Some("notes.md".into()));
    ed.view_mut(view).selection = selection;
    ed
}

fn frame(ed: &mut Editor) -> Frame {
    frame_sized(ed, 30, 40)
}

fn frame_sized(ed: &mut Editor, width: u16, height: u16) -> Frame {
    Renderer::new(CellWidth).frame(
        ed,
        Size { width, height },
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

/// The delta from `before` to `after`, checked to turn one into the other,
/// also after a trip through JSON as it goes to a client.
fn delta(before: &Frame, after: &Frame) -> FrameDelta {
    let delta = FrameDelta::between(before, after).expect("something changed");
    let sent: FrameDelta = serde_json::from_str(&serde_json::to_string(&delta).unwrap()).unwrap();
    let mut applied = before.clone();
    assert!(
        sent.apply(&mut applied),
        "it fits the frame it was made against"
    );
    assert_eq!(&applied, after, "{delta:#?}");
    delta
}

/// The changes to the surface `id` in `delta`, if it has any.
fn changes(delta: &FrameDelta, id: SurfaceId) -> Option<&SurfaceDelta> {
    delta.surfaces.iter().find(|s| s.id == id)
}

fn changed_rows(surface: &SurfaceDelta) -> Vec<u16> {
    surface.rows.iter().map(|(i, _)| *i).collect()
}

#[test]
fn changing_only_rulers_survives_delta_serialization_and_clear() {
    let mut ed = editor("|one\n");
    let before = frame(&mut ed);
    let columns: std::sync::Arc<[usize]> = [5].into();
    let after = Renderer::new(CellWidth).frame(
        &mut ed,
        Size {
            width: 30,
            height: 40,
        },
        &Status::Default { message: None },
        &columns,
    );
    delta(&before, &after);
    let cleared = frame(&mut ed);
    delta(&after, &cleared);
    assert_eq!(before.surfaces, cleared.surfaces);
}

/// Whether `surface` changed in its rows and nothing else.
fn only_rows(surface: &SurfaceDelta) -> bool {
    surface.role.is_none()
        && surface.rect.is_none()
        && surface.content.is_none()
        && surface.note.is_none()
        && surface.row_count.is_none()
}

/// An editor with two panes side by side showing different files, the
/// left one focused.
fn two_panes() -> (Editor, ViewId, ViewId) {
    let mut ed = editor("|one\ntwo\nthree");
    let left = ed.focus();
    let other = ed.create_buffer("file", "alpha\nbeta");
    let right = ed.split_pane(left, Direction::Right, Some(other)).unwrap();
    ed.set_focus(left);
    (ed, left, right)
}

fn float_at(x: u16) -> FloatOptions {
    FloatOptions {
        title: Some("pick".into()),
        width: Extent::Cells(12),
        height: Extent::Cells(4),
        anchor: Anchor::Center,
        focus: false,
        x: Some(Extent::Cells(x)),
        y: Some(Extent::Cells(2)),
        tab: false,
        label: None,
        footer: None,
        border: true,
        hidden: false,
        shared: false,
    }
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
    let main = ed.focus();
    let before = frame(&mut ed);
    insert(&mut ed, 4, "X");
    let after = frame(&mut ed);
    let delta = delta(&before, &after);
    assert_eq!(
        delta.surfaces.len(),
        1,
        "only the pane; the status line stayed the same"
    );
    let pane = changes(&delta, SurfaceId::View(main)).unwrap();
    assert!(only_rows(pane));
    assert_eq!(changed_rows(pane), [1], "only the edited line");
    assert!(delta.theme.is_none(), "the theme didn't change");
    assert!(delta.order.is_none() && delta.removed.is_empty());
}

#[test]
fn moving_the_cursor_sends_the_cursor_and_the_rows_it_left_and_reached() {
    let mut ed = editor("|one\ntwo\nthree");
    let before = frame(&mut ed);
    let view = ed.focus();
    ed.view_mut(view).selection = greed_text::Selection::point(5);
    let after = frame(&mut ed);
    let delta = delta(&before, &after);
    assert!(delta.cursor.is_some());
}

#[test]
fn typing_in_one_pane_of_two_sends_only_that_panes_rows() {
    let (mut ed, left, right) = two_panes();
    let before = frame(&mut ed);
    insert(&mut ed, 4, "X");
    let after = frame(&mut ed);
    let delta = delta(&before, &after);
    assert!(
        changes(&delta, SurfaceId::View(right)).is_none(),
        "{delta:#?}"
    );
    let pane = changes(&delta, SurfaceId::View(left)).unwrap();
    assert!(only_rows(pane));
    assert_eq!(changed_rows(pane), [1]);
    let ids: Vec<SurfaceId> = delta.surfaces.iter().map(|s| s.id).collect();
    assert_eq!(ids, [SurfaceId::View(left)], "nothing else changed");
    assert!(delta.order.is_none() && delta.lines.is_none());
}

#[test]
fn focusing_another_pane_sends_their_roles() {
    let (mut ed, left, right) = two_panes();
    let before = frame(&mut ed);
    ed.set_focus(right);
    let after = frame(&mut ed);
    let delta = delta(&before, &after);
    for pane in [left, right] {
        let pane = changes(&delta, SurfaceId::View(pane)).unwrap();
        assert!(pane.role.is_some(), "{pane:#?}");
        assert!(pane.rect.is_none() && pane.row_count.is_none());
        assert!(pane.rows.is_empty(), "the rows are the same: {pane:#?}");
    }
    // Besides the roles, only what follows the focus: the status line,
    // which shows the focused file, and the cursor.
    let others: Vec<SurfaceId> = (delta.surfaces.iter())
        .map(|s| s.id)
        .filter(|id| ![SurfaceId::View(left), SurfaceId::View(right)].contains(id))
        .collect();
    assert_eq!(others, [SurfaceId::Status]);
    assert!(delta.order.is_none() && delta.lines.is_none());
}

#[test]
fn moving_a_float_sends_only_its_rect() {
    let mut ed = editor("|one\ntwo\nthree");
    let list = ed.create_buffer("picker", "a\nb");
    let float = ed.float(list, float_at(2));
    let before = frame(&mut ed);
    ed.configure_float(float, float_at(10));
    let after = frame(&mut ed);
    let delta = delta(&before, &after);
    assert_eq!(delta.surfaces.len(), 1, "{delta:#?}");
    let moved = changes(&delta, SurfaceId::View(float)).unwrap();
    assert!(moved.rect.is_some());
    assert!(moved.role.is_none() && moved.rows.is_empty() && moved.row_count.is_none());
    assert!(delta.order.is_none());
}

#[test]
fn closing_a_pane_lists_it_as_removed() {
    let (mut ed, left, right) = two_panes();
    let before = frame(&mut ed);
    assert!(ed.close(right));
    let after = frame(&mut ed);
    let delta = delta(&before, &after);
    assert_eq!(delta.removed, [SurfaceId::View(right)]);
    let order = delta.order.as_ref().unwrap();
    assert!(!order.contains(&SurfaceId::View(right)));
    assert!(changes(&delta, SurfaceId::View(right)).is_none());
    let left = changes(&delta, SurfaceId::View(left)).unwrap();
    assert!(left.rect.is_some(), "the pane left takes the room");
    assert_eq!(delta.lines, Some(Vec::new()), "no line between panes");
}

#[test]
fn a_new_surface_comes_whole() {
    let mut ed = editor("|one");
    let before = frame(&mut ed);
    let list = ed.create_buffer("picker", "a\nb");
    let float = ed.float(list, float_at(2));
    let after = frame(&mut ed);
    let delta = delta(&before, &after);
    let new = changes(&delta, SurfaceId::View(float)).unwrap();
    assert!(new.role.is_some() && new.rect.is_some());
    // Four rows high outside its border, two inside.
    assert_eq!(new.row_count, Some(2));
    assert_eq!(changed_rows(new), [0, 1]);
    assert_eq!(
        delta.order.as_ref().unwrap().last(),
        Some(&SurfaceId::View(float))
    );
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
    let delta = delta(&before, &after);
    assert!(delta.surfaces.is_empty() && delta.theme.is_some());
}

/// A step that changes what's on screen, as an editor would take it, and
/// the screen size to draw after it.
type Step = (&'static str, fn(&mut Editor), (u16, u16));

/// The float on screen.
fn float(ed: &mut Editor) -> ViewId {
    ed.floats_hidden_too()
        .first()
        .map(|f| f.view)
        .expect("a float")
}

/// Edits, splits, floats, resizes and tabs, one after another.
fn steps() -> [Step; 16] {
    [
        ("type", |ed| insert(ed, 0, "fn "), (30, 10)),
        (
            "split",
            |ed| {
                let pane = ed.focus();
                ed.split_pane(pane, Direction::Right, None);
            },
            (30, 10),
        ),
        ("type in the new pane", |ed| insert(ed, 3, "main"), (30, 10)),
        (
            "split down",
            |ed| {
                let pane = ed.focus();
                let other = ed.create_buffer("file", "below\nthe line");
                ed.split_pane(pane, Direction::Down, Some(other));
            },
            (30, 10),
        ),
        (
            "float",
            |ed| {
                let list = ed.create_buffer("picker", "one\ntwo\nthree");
                ed.float(list, float_at(4));
            },
            (30, 10),
        ),
        (
            "move the float",
            |ed| {
                let view = float(ed);
                ed.configure_float(view, float_at(12));
            },
            (30, 10),
        ),
        ("resize", |_| {}, (44, 14)),
        ("type under the float", |ed| insert(ed, 0, "x"), (44, 14)),
        (
            "new tab",
            |ed| {
                let buffer = ed.view(ed.focus()).buffer;
                ed.new_tab(Some(buffer));
            },
            (44, 14),
        ),
        ("type in the tab", |ed| insert(ed, 0, "// "), (44, 14)),
        (
            "back to the first tab",
            |ed| {
                let first = ed.tabs()[0].id();
                ed.switch_tab(first);
            },
            (44, 14),
        ),
        (
            "focus the float",
            |ed| {
                let view = float(ed);
                ed.set_focus(view);
            },
            (44, 14),
        ),
        (
            "close the float",
            |ed| {
                let view = float(ed);
                ed.close(view);
            },
            (44, 14),
        ),
        (
            "close a pane",
            |ed| {
                let pane = ed.focus();
                ed.close(pane);
            },
            (44, 14),
        ),
        ("smaller", |_| {}, (20, 6)),
        (
            "a new theme",
            |ed| {
                ed.theme_mut().set("ui.text", Entry::new(Style::default()));
            },
            (20, 6),
        ),
    ]
}

#[test]
fn deltas_turn_each_frame_into_the_next_through_edits_splits_floats_resizes_and_tabs() {
    let mut ed = editor("|line one\nline two\nline three");
    let mut before = frame_sized(&mut ed, 30, 10);
    for (name, step, (width, height)) in steps() {
        step(&mut ed);
        let after = frame_sized(&mut ed, width, height);
        if let Some(delta) = FrameDelta::between(&before, &after) {
            let sent: FrameDelta =
                serde_json::from_str(&serde_json::to_string(&delta).unwrap()).unwrap();
            let mut applied = before.clone();
            assert!(sent.apply(&mut applied), "after {name:?}");
            assert_eq!(applied, after, "after {name:?}");
        } else {
            assert_eq!(before, after, "after {name:?}");
        }
        assert!(FrameDelta::between(&after, &after).is_none());
        before = after;
    }
}

#[test]
fn deltas_are_much_smaller_than_frames() {
    // Lines short enough not to wrap in a pane half the screen wide, so an
    // edit changes one row of each pane.
    let text: Vec<String> = (0..40).map(|n| format!("line {n}")).collect();
    let mut ed = editor(&format!("|{}", text.join("\n")));
    let pane = ed.focus();
    ed.split_pane(pane, Direction::Right, None);
    let list = ed.create_buffer("picker", &text.join("\n"));
    ed.float(list, float_at(2));
    let mut before = frame(&mut ed);
    for (at, typed) in [(0, "X"), (3, "Y"), (40, "Z")] {
        insert(&mut ed, at, typed);
        let after = frame(&mut ed);
        let delta = delta(&before, &after);
        let full = serde_json::to_string(&after).unwrap().len();
        let small = serde_json::to_string(&delta).unwrap().len();
        assert!(small * 5 < full, "{small} bytes against {full}");
        before = after;
    }
}

#[test]
fn window_options_go_along_when_they_change() {
    let mut ed = editor("|one");
    let before = frame(&mut ed);
    let mut after = frame(&mut ed);
    after
        .gui
        .insert("gui-font".to_owned(), "Fira Code".to_owned());
    let delta = delta(&before, &after);
    assert!(delta.surfaces.is_empty() && delta.gui.is_some());
}

#[test]
fn a_broken_frame_or_delta_from_a_session_is_drawn_as_far_as_it_makes_sense() {
    use greed_core::render::grid::{compose, screen_rows};
    use greed_core::render::{Rect, Role, Surface};
    use greed_core::theme::Medium;
    let mut ed = editor("hel|lo");
    let mut f = frame(&mut ed);
    let rect = Rect {
        x: 0,
        y: 0,
        width: 5,
        height: 2,
    };
    // A bordered float and a titled panel with no room left for either.
    let float = Role::Float {
        border: true,
        title: Some("t".into()),
        label: Vec::new(),
        footer: Vec::new(),
    };
    let panel = Role::Panel {
        separator: 0,
        title: Some("p".into()),
    };
    f.surfaces.extend([
        Surface::new(SurfaceId::View(ViewId(98)), float, rect, Vec::new()),
        Surface::new(SurfaceId::View(ViewId(99)), panel, rect, Vec::new()),
    ]);
    for medium in [Medium::Tui, Medium::Gui] {
        compose(&f, medium);
    }
    // No surfaces at all and the biggest size.
    let delta: FrameDelta =
        serde_json::from_str(r#"{ "order": [], "size": { "width": 65535, "height": 65535 } }"#)
            .unwrap();
    assert!(delta.apply(&mut f));
    assert!(f.surfaces.is_empty());
    compose(&f, Medium::Tui);
    screen_rows(&f);
    // A pane and a tab line far off the screen, ending past what a u16
    // holds, more rows than a u16 numbers, a line as long, and changes to
    // a surface that isn't there.
    let delta: FrameDelta = serde_json::from_str(&format!(
        r#"{{ "order": [{{ "view": 1 }}, "tabline"],
          "surfaces": [
            {{ "id": {{ "view": 1 }}, "role": {{ "kind": "pane", "active": false }},
              "rect": {{ "x": 65000, "y": 65000, "width": 65535, "height": 65535 }},
              "row_count": {},
              "rows": [[0, {{ "spans": [{{ "text": "x", "tags": [] }}], "tags": [] }}]] }},
            {{ "id": "tabline", "role": {{ "kind": "tabline" }},
              "rect": {{ "x": 0, "y": 65535, "width": 65535, "height": 1 }} }},
            {{ "id": "status", "row_count": 3 }}
          ],
          "lines": [{{ "x": 65535, "y": 65535, "len": 65535, "down": true }}] }}"#,
        usize::MAX
    ))
    .unwrap();
    assert!(!delta.apply(&mut f), "the status line isn't there");
    assert_eq!(f.surfaces.len(), 2);
    assert_eq!(f.surfaces[0].rows.len(), usize::from(u16::MAX));
    screen_rows(&f);
    let grid = compose(&f, Medium::Tui);
    assert_eq!(grid.len(), usize::from(Size::MAX.height));
}

#[test]
fn what_goes_away_goes_away_after_a_trip_through_json() {
    use greed_core::render::Size;
    let mut ed = editor("|hello");
    let before = frame(&mut ed);
    // The cursor goes, and a surface stops being laid out at a size of its
    // own, as a terminal does when its client's screen is the size again.
    let mut sized = before.clone();
    sized.surfaces[0].content = Some(Size {
        width: 40,
        height: 12,
    });
    sized.surfaces[0].note = Some("40×12 for tui@desk".to_owned());
    let mut after = before.clone();
    after.cursor = None;
    let d = delta(&sized, &after);
    let pane = &d.surfaces[0];
    assert_eq!(
        (pane.content, pane.note.as_ref()),
        (Some(None), Some(&None))
    );
    assert_eq!(d.cursor, Some(None));
}

/// The frames of a pane being split and typed in, numbered as a session
/// sends them.
fn numbered() -> [Frame; 3] {
    let mut ed = editor("|one\ntwo");
    let mut first = frame(&mut ed);
    let pane = ed.focus();
    ed.split_pane(pane, Direction::Right, None);
    let mut split = frame(&mut ed);
    insert(&mut ed, 0, "x");
    let mut typed = frame(&mut ed);
    (first.seq, split.seq, typed.seq) = (1, 2, 3);
    [first, split, typed]
}

#[test]
fn a_delta_says_which_frame_it_was_made_against_and_fits_only_that_one() {
    let [first, split, typed] = numbered();
    let next = delta(&split, &typed);
    assert_eq!((next.base, next.seq), (2, 3));
    let mut behind = first.clone();
    assert!(
        !next.clone().apply(&mut behind),
        "made against another frame"
    );
    let mut caught_up = first.clone();
    assert!(delta(&first, &split).apply(&mut caught_up));
    assert_eq!(caught_up.seq, 2);
    assert!(next.apply(&mut caught_up));
    assert_eq!(caught_up, typed);
}

#[test]
fn a_delta_changing_a_surface_the_client_doesnt_have_doesnt_fit() {
    // From a session that doesn't count frames, a client that missed the
    // split has no new pane for the typing to change.
    let [mut first, mut split, mut typed] = numbered();
    for frame in [&mut first, &mut split, &mut typed] {
        frame.seq = 0;
    }
    let missed = FrameDelta::between(&split, &typed).unwrap();
    assert!(!missed.apply(&mut first));
    // Nor does one removing a surface it doesn't have.
    let mut closed = first.clone();
    closed.surfaces.retain(|s| s.id != SurfaceId::Status);
    let gone = FrameDelta::between(&first, &closed).unwrap();
    let mut without = closed.clone();
    assert!(!gone.apply(&mut without));
}

#[test]
fn a_client_asks_once_for_a_whole_frame_when_a_delta_doesnt_fit() {
    use greed_core::delta::Latest;
    let [first, split, typed] = numbered();
    let mut latest = Latest::default();
    assert!(latest.delta(delta(&first, &split)), "no frame yet");
    latest.whole(first.clone());
    let next = delta(&split, &typed);
    assert!(latest.delta(next.clone()), "it missed the split");
    assert!(!latest.delta(next), "it asked already");
    latest.whole(typed);
    assert!(
        latest.delta(delta(&first, &split)),
        "after a whole frame it asks again"
    );
    latest.whole(first.clone());
    assert!(!latest.delta(delta(&first, &split)));
    assert_eq!(latest.frame(), Some(&split));
}

/// An editor showing 200 numbered lines, the cursor on line 20.
fn long_file() -> Editor {
    let text: Vec<String> = (0..200).map(|n| format!("line {n}")).collect();
    let mut ed = editor(&format!("|{}", text.join("\n")));
    let view = ed.focus();
    let at = ed.buffer(ed.view(view).buffer).text().line_to_byte(20);
    ed.view_mut(view).selection = greed_text::Selection::point(at);
    ed
}

#[test]
fn scrolling_moves_the_rows_a_client_has_and_sends_only_the_new_ones() {
    let mut ed = long_file();
    let view = ed.focus();
    let before = frame(&mut ed);
    ed.view_mut(view).scroll.line = 3;
    let after = frame(&mut ed);
    let delta = delta(&before, &after);
    let pane = changes(&delta, SurfaceId::View(view)).expect("the pane changed");
    assert_eq!(pane.shift, 3, "{pane:#?}");
    assert!(pane.rows.len() <= 4, "{:?}", changed_rows(pane));
    // And back up.
    let delta = self::delta(&after, &before);
    let pane = changes(&delta, SurfaceId::View(view)).expect("the pane changed");
    assert_eq!(pane.shift, -3, "{pane:#?}");
    assert!(pane.rows.len() <= 4, "{:?}", changed_rows(pane));
}

#[test]
fn an_edit_moves_no_rows() {
    let mut ed = long_file();
    let view = ed.focus();
    let before = frame(&mut ed);
    insert(&mut ed, 0, "X");
    let delta = delta(&before, &frame(&mut ed));
    let pane = changes(&delta, SurfaceId::View(view)).expect("the pane changed");
    assert_eq!(pane.shift, 0, "{pane:#?}");
}
