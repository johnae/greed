use kern_core::keymap::{Key, Layer};
use kern_core::{Editor, KeyOutcome};
use kern_text::{AgentId, Author, ChangeSet, ClientId, Range, Selection};

fn editor(text: &str) -> Editor {
    let mut ed = Editor::new(ClientId(1));
    ed.open("file", text, None);
    ed
}

fn text(ed: &Editor) -> String {
    ed.buffer(ed.view(ed.focus()).buffer).text().to_string()
}

fn keys(s: &str) -> Vec<Key> {
    Key::parse_sequence(s).unwrap()
}

#[test]
fn open_focuses_a_new_view() {
    let mut ed = Editor::new(ClientId(1));
    let (b1, v1) = ed.open("file", "one", None);
    let (b2, v2) = ed.open("scratch", "two", None);
    assert_ne!(b1, b2);
    assert_eq!(ed.focus(), v2);
    assert_eq!(ed.view(v1).buffer, b1);
    assert_eq!(ed.buffer(b2).kind(), "scratch");
    assert_eq!(ed.view(v2).selection, Selection::point(0));
}

#[test]
fn edits_map_other_views_on_the_same_buffer() {
    let mut ed = editor("hello world");
    let v1 = ed.focus();
    let v2 = ed.split(v1);
    ed.view_mut(v2).selection = Selection::single(6, 11);

    let changes = ChangeSet::from_changes(11, [(0, 0, Some(">> "))]).unwrap();
    ed.apply(v1, changes, Author::User(ClientId(1)), Some("test"), None)
        .unwrap();
    assert_eq!(text(&ed), ">> hello world");
    assert_eq!(ed.view(v1).selection.primary(), Range::point(3));
    assert_eq!(ed.view(v2).selection.primary(), Range::new(9, 14));
}

#[test]
fn apply_records_author_and_cause() {
    let mut ed = editor("");
    let v = ed.focus();
    let agent = Author::Agent(AgentId(2));
    let changes = ChangeSet::from_changes(0, [(0, 0, Some("x"))]).unwrap();
    ed.apply(v, changes, agent.clone(), Some("edit.propose"), None)
        .unwrap();
    let buffer = ed.buffer(ed.view(v).buffer);
    let tx = buffer.history().log().last().unwrap();
    assert_eq!(tx.meta.author, agent);
    assert_eq!(tx.meta.cause.as_deref(), Some("edit.propose"));
}

#[test]
fn undo_and_redo_map_other_views() {
    let mut ed = editor("abc");
    let v1 = ed.focus();
    let v2 = ed.split(v1);
    ed.view_mut(v2).selection = Selection::point(3);
    let changes = ChangeSet::from_changes(3, [(0, 0, Some("xx"))]).unwrap();
    ed.apply(v1, changes, Author::User(ClientId(1)), None, None)
        .unwrap();
    assert_eq!(ed.view(v2).selection.primary(), Range::point(5));

    assert!(ed.undo(v1).unwrap());
    assert_eq!(text(&ed), "abc");
    assert_eq!(ed.view(v2).selection.primary(), Range::point(3));
    assert!(ed.redo(v1).unwrap());
    assert_eq!(text(&ed), "xxabc");
    assert!(!ed.redo(v1).unwrap());
}

#[test]
fn mode_changes_report_whether_anything_changed() {
    let mut ed = editor("");
    assert_eq!(ed.mode(), "normal");
    assert!(ed.set_mode("insert"));
    assert!(!ed.set_mode("insert"));
    assert_eq!(ed.mode(), "insert");
}

#[test]
fn keys_resolve_through_pending_sequences() {
    let mut ed = editor("");
    ed.keymap_mut()
        .bind(Layer::mode("normal"), &keys("g g"), "goto-start", "core")
        .unwrap();
    assert_eq!(ed.press(Key::char('g')), KeyOutcome::Pending);
    assert_eq!(
        ed.press(Key::char('g')),
        KeyOutcome::Command {
            name: "goto-start".into(),
            keys: keys("g g"),
        }
    );
    assert_eq!(ed.press(Key::char('g')), KeyOutcome::Pending);
    assert_eq!(ed.press(Key::char('x')), KeyOutcome::Unbound(keys("g x")));
    assert_eq!(ed.pending(), &[]);
}

#[test]
fn unbound_single_keys_go_to_the_mode_fallback() {
    let mut ed = editor("");
    ed.keymap_mut().set_fallback("insert", "insert-key", "core");
    ed.keymap_mut()
        .bind(
            Layer::mode("insert"),
            &keys("ctrl-x ctrl-s"),
            "save",
            "core",
        )
        .unwrap();
    ed.set_mode("insert");
    assert_eq!(
        ed.press(Key::char('a')),
        KeyOutcome::Command {
            name: "insert-key".into(),
            keys: keys("a"),
        }
    );
    // Only lone keys fall back; a broken sequence is just unbound.
    ed.press(Key::parse("ctrl-x").unwrap());
    assert_eq!(
        ed.press(Key::char('a')),
        KeyOutcome::Unbound(keys("ctrl-x a"))
    );
}

#[test]
fn messages_are_collected_and_taken() {
    let mut ed = editor("");
    ed.echo("hello");
    ed.echo("again");
    assert_eq!(ed.take_messages(), ["hello", "again"]);
    assert!(ed.take_messages().is_empty());
}

#[test]
fn marked_text_shows_heads_and_anchors() {
    let mut ed = editor("hello world");
    let v = ed.focus();
    ed.view_mut(v).selection =
        Selection::new([Range::new(0, 5), Range::point(8), Range::new(11, 9)], 0).unwrap();
    assert_eq!(ed.marked_text(v), "^hello| wo|r|ld^");
}

#[test]
fn grouped_edits_undo_as_one_step() {
    let mut ed = editor("");
    let v = ed.focus();
    let user = Author::User(ClientId(1));
    let insert = |ed: &mut Editor, pos: usize, s: &str| {
        let len = ed.buffer(ed.view(v).buffer).text().len_bytes();
        let changes = ChangeSet::from_changes(len, [(pos, pos, Some(s))]).unwrap();
        ed.apply(v, changes, user.clone(), None, None).unwrap();
    };
    insert(&mut ed, 0, "a");
    ed.start_group();
    insert(&mut ed, 1, "b");
    ed.start_group();
    insert(&mut ed, 2, "c");
    ed.end_group();
    insert(&mut ed, 3, "d");
    ed.start_group();
    insert(&mut ed, 4, "e");
    ed.end_group();

    let mut steps = Vec::new();
    while ed.undo(v).unwrap() {
        steps.push(text(&ed));
    }
    assert_eq!(steps, ["abcd", "abc", "a", ""]);
}

fn float_options() -> kern_core::FloatOptions {
    kern_core::FloatOptions {
        title: Some("pick".into()),
        width: kern_core::Extent::Percent(50),
        height: kern_core::Extent::Cells(5),
        anchor: kern_core::Anchor::Center,
    }
}

#[test]
fn floating_views_take_focus_and_give_it_back() {
    let mut ed = editor("main text");
    let main = ed.main();
    let list = ed.create_buffer("picker", "a\nb");
    let prompt = ed.create_buffer("prompt", "");
    let v1 = ed.float(list, float_options());
    let v2 = ed.float(prompt, float_options());
    assert_eq!(ed.focus(), v2);
    assert_eq!(
        ed.floats().iter().map(|f| f.view).collect::<Vec<_>>(),
        [v1, v2]
    );

    assert!(ed.close(v2));
    assert_eq!(ed.focus(), v1);
    assert!(ed.close(v1));
    assert_eq!(ed.focus(), main);
    assert!(!ed.close(main));
    assert!(ed.floats().is_empty());
}

#[test]
fn scratch_buffers_go_away_with_their_last_view() {
    let mut ed = editor("");
    let scratch = ed.create_buffer("picker", "x");
    let view = ed.float(scratch, float_options());
    assert!(ed.buffers().any(|b| b.id() == scratch));
    ed.close(view);
    assert!(!ed.buffers().any(|b| b.id() == scratch));
}

#[test]
fn files_open_once_and_show_in_a_view() {
    let dir = std::env::temp_dir().join(format!("kern-open-file-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("a.txt");
    std::fs::write(&path, "from disk").unwrap();

    let mut ed = editor("");
    let first = ed.open_file(&path).unwrap();
    let again = ed.open_file(&path).unwrap();
    assert_eq!(first, again);
    let main = ed.main();
    ed.show(main, first);
    assert_eq!(text(&ed), "from disk");
    assert_eq!(ed.view(main).selection, Selection::point(0));

    let missing = ed.open_file(&dir.join("new.txt")).unwrap();
    assert_eq!(ed.buffer(missing).text().len_bytes(), 0);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn extents_resolve_against_the_screen() {
    use kern_core::Extent;
    assert_eq!(Extent::Cells(10).resolve(80), 10);
    assert_eq!(Extent::Cells(100).resolve(80), 80);
    assert_eq!(Extent::Percent(50).resolve(81), 40);
    assert_eq!(Extent::Percent(150).resolve(80), 80);
}
