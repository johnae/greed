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
