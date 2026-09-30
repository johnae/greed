//! Drives the default `core` plugin with real key presses.
//!
//! Buffers are written with markers: `|` is a range's head and `^` its
//! anchor (omitted for cursors). `"^hello |world"` selects `hello `.

use std::path::Path;

use kern_core::Editor;
use kern_core::luau::Host;
use kern_text::{ClientId, Range, Selection};

fn parse(marked: &str) -> (String, Selection) {
    let mut text = String::new();
    let mut ranges = Vec::new();
    let mut anchor = None;
    for c in marked.chars() {
        match c {
            '^' => anchor = Some(text.len()),
            '|' => {
                ranges.push(Range::new(anchor.take().unwrap_or(text.len()), text.len()));
            }
            c => text.push(c),
        }
    }
    (
        text,
        Selection::new(ranges, 0).expect("at least one cursor"),
    )
}

fn editor(marked: &str) -> Host {
    let (text, selection) = parse(marked);
    let mut editor = Editor::new(ClientId(1));
    editor.open("file", &text, None);
    let host = Host::new(editor).unwrap();
    host.load_dir(&Path::new(env!("CARGO_MANIFEST_DIR")).join("../../runtime/plugins/core"))
        .unwrap();
    host.with_editor_mut(|ed| {
        let v = ed.focus();
        ed.view_mut(v).selection = selection;
    });
    host
}

#[track_caller]
fn check(before: &str, keys: &str, after: &str) {
    let host = editor(before);
    host.press_keys(keys).unwrap();
    assert_eq!(
        host.with_editor(|ed| ed.marked_text(ed.focus())),
        after,
        "{before:?} + {keys:?}"
    );
}

#[test]
fn character_moves_stay_on_the_line() {
    check("a|bc\ndef", "l l l", "abc|\ndef");
    check("abc\nd|ef", "h h h", "abc\n|def");
}

#[test]
fn line_moves_keep_the_column() {
    check("ab|cd\nx\nwxyz", "j", "abcd\nx|\nwxyz");
    check("ab|cd\nx\nwxyz", "j j", "abcd\nx\nwx|yz");
    check("abcd\nwx|yz", "k", "ab|cd\nwxyz");
    check("ab|cd", "k", "ab|cd");
    check("é|é\néé", "j", "éé\né|é");
}

#[test]
fn word_motions_select_what_they_move_over() {
    check("|hello world", "w", "^hello |world");
    check("|hello world", "w w", "hello ^world|");
    check("|foo.bar", "w", "^foo|.bar");
    check("|héllo wörld", "w", "^héllo |wörld");
    check("hello wor|ld", "b", "hello |wor^ld");
    check("hello |world", "b", "|hello ^world");
    check("|hello world", "e", "^hello| world");
    check("hello| world", "e", "hello^ world|");
}

#[test]
fn line_and_buffer_jumps() {
    check("ab|c\ndef", "g l", "abc|\ndef");
    check("ab|c\ndef", "g h", "|abc\ndef");
    check("abc\nde|f", "g g", "|abc\ndef");
    check("a|bc\ndef", "g e", "abc\ndef|");
}

#[test]
fn select_line_includes_the_line_break() {
    check("a|bc\ndef", "x", "^abc\n|def");
    check("abc\nd|ef", "x", "abc\n^def|");
}

#[test]
fn collapse_and_flip() {
    check("^hello |world", ";", "hello |world");
    check("^hello |world", "alt-;", "|hello ^world");
}

#[test]
fn typing_in_insert_mode() {
    check("ab|c", "i x y esc", "abxy|c");
    check("a|bc", "a Z", "abZ|c");
    check("ab|c", "i backspace", "a|c");
    check("ab|c", "i enter", "ab\n|c");
    check("^hello |world", "i >", ">|hello world");
}

#[test]
fn typing_at_every_cursor() {
    check("a|b a|b", "i -", "a-|b a-|b");
}

#[test]
fn delete_and_change() {
    check("^hello |world", "d", "|world");
    check("a|bc", "d", "a|c");
    check("^hello |world", "c b y e space", "bye |world");
}

#[test]
fn undo_and_redo() {
    check("^hello |world", "d u", "^hello |world");
    check("^hello |world", "d u U", "|world");
}

#[test]
fn open_lines() {
    check("a|bc\ndef", "o x", "abc\nx|\ndef");
    check("abc\nd|ef", "O x", "abc\nx|\ndef");
}
