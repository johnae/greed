//! Tracked positions and ranges: `buffer:track` and `buffer:track_range`
//! follow edits without being drawn.

use std::time::{Duration, Instant};

use greed_core::Editor;
use greed_core::luau::Host;
use greed_text::ClientId;

fn host(text: &str) -> Host {
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", text, None);
    let h = Host::new(editor).unwrap();
    h.eval("greed = require('@greed') b = greed.view():buffer()")
        .unwrap();
    h
}

fn eval(h: &Host, code: &str) -> String {
    h.eval(code).unwrap()
}

fn insert(h: &Host, pos: usize, text: &str) {
    eval(
        h,
        &format!("b:edit(function(e) e:insert({pos}, {text:?}) end)"),
    );
}

fn delete(h: &Host, from: usize, to: usize) {
    eval(
        h,
        &format!("b:edit(function(e) e:delete({from}, {to}) end)"),
    );
}

#[test]
fn positions_follow_inserts_before_and_after() {
    let h = host("hello world");
    eval(&h, "a = b:track(6)");
    insert(&h, 0, ">> ");
    assert_eq!(eval(&h, "a:pos()"), "9");
    insert(&h, 10, "!");
    assert_eq!(eval(&h, "a:pos()"), "9");
}

#[test]
fn gravity_decides_inserts_exactly_at_a_position() {
    let h = host("hello world");
    eval(
        &h,
        "right = b:track(5) left = b:track(5, { gravity = 'left' })",
    );
    insert(&h, 5, "XX");
    assert_eq!(eval(&h, "right:pos()"), "7");
    assert_eq!(eval(&h, "left:pos()"), "5");
    let err = h
        .eval("b:track(0, { gravity = 'up' })")
        .unwrap_err()
        .to_string();
    assert!(err.contains("\"left\" or \"right\""), "{err}");
}

#[test]
fn a_deleted_position_moves_to_where_the_deletion_was() {
    let h = host("hello world");
    eval(&h, "a = b:track(8)");
    delete(&h, 5, 11);
    assert_eq!(eval(&h, "a:pos()"), "5");
}

#[test]
fn range_edges_keep_inserts_outside_unless_told() {
    let h = host("hello world");
    eval(
        &h,
        "out = b:track_range(6, 11) inside = b:track_range(6, 11, { from = 'left', to = 'right' })",
    );
    insert(&h, 11, "!");
    insert(&h, 6, "big ");
    assert_eq!(eval(&h, "table.concat({ out:range() }, ' ')"), "10 15");
    assert_eq!(eval(&h, "table.concat({ inside:range() }, ' ')"), "6 16");
}

#[test]
fn a_range_is_deleted_when_all_its_text_goes() {
    let h = host("hello world");
    eval(
        &h,
        "r = b:track_range(6, 11) part = b:track_range(0, 5) empty = b:track_range(3, 3)",
    );
    delete(&h, 1, 3);
    assert_eq!(eval(&h, "part:deleted()"), "false");
    assert_eq!(eval(&h, "table.concat({ part:range() }, ' ')"), "0 3");
    delete(&h, 4, 9);
    assert_eq!(eval(&h, "r:deleted()"), "true");
    assert_eq!(eval(&h, "r:range() == nil"), "true");
    assert_eq!(eval(&h, "r:pos() == nil"), "true");
    assert_eq!(eval(&h, "empty:deleted()"), "false");
    // Undo brings the text back, but the range stays deleted.
    eval(&h, "greed.view():undo()");
    assert_eq!(eval(&h, "r:deleted()"), "true");
}

#[test]
fn undo_and_redo_move_them_back() {
    let h = host("hello world");
    eval(&h, "a = b:track(6) r = b:track_range(6, 11)");
    insert(&h, 0, "abc");
    assert_eq!(eval(&h, "a:pos()"), "9");
    eval(&h, "greed.view():undo()");
    assert_eq!(eval(&h, "a:pos()"), "6");
    assert_eq!(eval(&h, "table.concat({ r:range() }, ' ')"), "6 11");
    eval(&h, "greed.view():redo()");
    assert_eq!(eval(&h, "a:pos()"), "9");
    assert_eq!(eval(&h, "table.concat({ r:range() }, ' ')"), "9 14");
    // A deleted position comes back to the deletion's start on undo.
    delete(&h, 7, 14);
    assert_eq!(eval(&h, "a:pos()"), "7");
    eval(&h, "greed.view():undo()");
    assert_eq!(eval(&h, "a:pos()"), "14");
}

#[test]
fn forgotten_or_closed_ones_are_gone() {
    let h = host("hello world");
    eval(&h, "a = b:track(3) a:forget()");
    assert_eq!(eval(&h, "a:pos() == nil"), "true");
    eval(
        &h,
        "s = greed.create_buffer('scratch', 'abc') t = s:track_range(0, 3) s:close()",
    );
    assert_eq!(eval(&h, "t:deleted()"), "true");
    assert_eq!(eval(&h, "t:range() == nil"), "true");
    let err = h.eval("b:track_range(5, 3)").unwrap_err().to_string();
    assert!(err.contains("can't track"), "{err}");
    let err = h.eval("b:track(99)").unwrap_err().to_string();
    assert!(err.contains("can't track"), "{err}");
}

#[test]
fn unloading_a_plugin_forgets_what_it_tracked() {
    let h = host("hello world");
    h.load_str(
        "tracker",
        "local b = require('@greed').view():buffer() return { mine = b:track(3) }",
    )
    .unwrap();
    eval(&h, "theirs = b:track(4) mine = require('@tracker').mine");
    assert_eq!(eval(&h, "mine:pos()"), "3");
    h.unload("tracker").unwrap();
    assert_eq!(eval(&h, "mine:pos() == nil"), "true");
    assert_eq!(eval(&h, "theirs:pos()"), "4");
}

#[test]
fn many_anchors_stay_cheap() {
    let h = host(&"word ".repeat(20_000));
    eval(
        &h,
        "list = {} for i = 0, 9999 do list[i + 1] = b:track(i * 10) end",
    );
    let start = Instant::now();
    for _ in 0..100 {
        insert(&h, 0, "x");
    }
    assert_eq!(eval(&h, "list[10000]:pos()"), "100090");
    assert!(
        start.elapsed() < Duration::from_secs(2),
        "{:?}",
        start.elapsed()
    );
}
