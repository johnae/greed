use greed_core::keymap::{Key, Layer};
use greed_core::{CursorShape, Editor, KeyOutcome};
use greed_text::{AgentId, Author, ChangeSet, ClientId, Range, Selection};

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
    assert_eq!(ed.mode(), "helix");
    assert!(ed.set_mode("insert"));
    assert!(!ed.set_mode("insert"));
    assert_eq!(ed.mode(), "insert");
}

#[test]
fn keys_resolve_through_pending_sequences() {
    let mut ed = editor("");
    ed.keymap_mut()
        .bind(Layer::mode("helix"), &keys("g g"), "goto-start", "core")
        .unwrap();
    assert_eq!(ed.press(Key::char('g')), KeyOutcome::Pending);
    assert_eq!(
        ed.press(Key::char('g')),
        KeyOutcome::Command {
            name: "goto-start".into(),
            keys: keys("g g"),
            count: None,
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
            count: None,
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
fn keys_bound_for_a_buffer_come_first_while_it_has_focus() {
    let mut ed = editor("");
    let first = ed.view(ed.focus()).buffer;
    ed.keymap_mut().set_fallback("insert", "insert-key", "core");
    ed.keymap_mut()
        .bind(Layer::mode("insert"), &keys("ctrl-x y"), "save", "core")
        .unwrap();
    ed.set_mode("insert");
    ed.set_buffer_keys(first, [(Key::char('y'), "answer".into())].into());
    let command = |name: &str, keys_: &str| KeyOutcome::Command {
        name: name.into(),
        keys: keys(keys_),
        count: None,
    };
    assert_eq!(ed.press(Key::char('y')), command("answer", "y"));
    assert_eq!(ed.press(Key::char('a')), command("insert-key", "a"));
    // Inside a sequence the key is the sequence's.
    ed.press(Key::parse("ctrl-x").unwrap());
    assert_eq!(ed.press(Key::char('y')), command("save", "ctrl-x y"));
    // Only in that buffer.
    ed.open("file", "", None);
    assert_eq!(ed.press(Key::char('y')), command("insert-key", "y"));
    ed.set_buffer_keys(first, std::collections::HashMap::new());
    assert!(ed.buffer(first).key(Key::char('y')).is_none());
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

fn float_options() -> greed_core::FloatOptions {
    greed_core::FloatOptions {
        title: Some("pick".into()),
        width: greed_core::Extent::percent(50),
        height: greed_core::Extent::Cells(5),
        anchor: greed_core::Anchor::Center,
        focus: true,
        x: None,
        y: None,
        tab: false,
        label: None,
        footer: None,
        border: true,
        hidden: false,
        shared: false,
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
    let dir = std::env::temp_dir().join(format!("greed-open-file-{}", std::process::id()));
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

    // A file that isn't text opens read-only, so saving can't mangle it,
    // and plugins can show it their own way (a PDF, an image).
    std::fs::write(dir.join("b.bin"), b"%PDF\xff\xfe").unwrap();
    let binary = ed.open_file(&dir.join("b.bin")).unwrap();
    assert!(ed.buffer(binary).is_readonly());
    assert_eq!(ed.buffer(binary).text().to_string(), "%PDF\u{fffd}\u{fffd}");
    assert!(!ed.buffer(first).is_readonly());
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn every_spelling_of_a_file_is_one_buffer() {
    let dir = std::env::temp_dir().join(format!("greed-spellings-{}", std::process::id()));
    std::fs::create_dir_all(dir.join("src")).unwrap();
    let path = dir.join("src/a.txt");
    std::fs::write(&path, "a").unwrap();

    let mut ed = editor("");
    let buffer = ed.open_file(&path).unwrap();
    let roundabout = dir.join("src/../src/./a.txt");
    assert_eq!(ed.open_file(&roundabout).unwrap(), buffer);
    assert_eq!(ed.buffer_for(&roundabout), Some(buffer));
    assert_eq!(ed.buffer_for(&dir.join("x/../src//a.txt")), Some(buffer));
    assert_eq!(ed.buffer(buffer).path(), Some(path.as_path()), "kept clean");
    assert_eq!(ed.buffer_for(&dir.join("src/b.txt")), None);
    assert!(
        !ed.buffers()
            .any(|b| b.path() == Some(dir.join("src/b.txt").as_path())),
        "finding doesn't open"
    );

    // Saving under a new name keeps that name clean too.
    let scratch = ed.create_buffer("file", "s");
    ed.save_as(scratch, &dir.join("src/../b.txt")).unwrap();
    assert_eq!(ed.buffer(scratch).path(), Some(dir.join("b.txt").as_path()));
    assert_eq!(ed.buffer_for(&dir.join("b.txt")), Some(scratch));

    // A relative path is from the current directory.
    let cwd = std::env::current_dir().unwrap();
    assert_eq!(
        greed_core::file_path(std::path::Path::new("./x/../y.txt")).unwrap(),
        cwd.join("y.txt")
    );
    let mut started = Editor::new(ClientId(1));
    started.open("file", "", Some("./x/../y.txt".into()));
    let first = started.view(started.focus()).buffer;
    assert_eq!(
        started.buffer(first).path(),
        Some(cwd.join("y.txt").as_path())
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn extents_resolve_against_the_screen() {
    use greed_core::Extent;
    assert_eq!(Extent::Cells(10).resolve(80), 10);
    assert_eq!(Extent::Cells(100).resolve(80), 80);
    assert_eq!(Extent::percent(50).resolve(81), 40);
    assert_eq!(Extent::percent(150).resolve(80), 80);
}

#[test]
fn floats_can_leave_focus_where_it_was() {
    let mut ed = editor("");
    let main = ed.main();
    let hints = ed.create_buffer("hints", "");
    ed.float(
        hints,
        greed_core::FloatOptions {
            focus: false,
            ..float_options()
        },
    );
    assert_eq!(ed.focus(), main);
    assert_eq!(ed.floats().len(), 1);
}

#[test]
fn closing_a_float_gives_focus_back_to_the_view_that_had_it() {
    use greed_core::{Extent, PanelOptions, Side};
    let mut ed = editor("");
    let results = ed.create_buffer("grep", "");
    let panel = ed.panel(
        results,
        PanelOptions {
            side: Side::Right,
            width: Extent::Cells(20),
            title: None,
            focus: true,
        },
    );
    let prompt = ed.create_buffer("prompt", "");
    let float = ed.float(prompt, float_options());
    assert_eq!(ed.focus(), float);
    ed.close(float);
    assert_eq!(ed.focus(), panel);

    // If that view went away in the meantime, it goes to the top float left,
    // or with none, the main view.
    let prompt = ed.create_buffer("prompt", "");
    let float = ed.float(prompt, float_options());
    ed.close(panel);
    ed.close(float);
    assert_eq!(ed.focus(), ed.main());
}

#[test]
fn the_clipboard_keeps_recent_copies() {
    let mut ed = editor("");
    assert_eq!(ed.clipboard(), None);
    ed.copy(vec!["a".into()]);
    ed.copy(vec!["b".into(), "c".into()]);
    assert_eq!(
        ed.clipboard(),
        Some(&["b".to_string(), "c".to_string()][..])
    );
    for i in 0..30 {
        ed.copy(vec![i.to_string()]);
    }
    let history: Vec<&[String]> = ed.clipboard_history().collect();
    assert_eq!(history.len(), 20);
    assert_eq!(history[0], ["29".to_string()]);
}

#[test]
fn read_only_buffers_refuse_the_users_edits_but_not_plugins() {
    let mut ed = editor("");
    let tree = ed.create_buffer("tree", "a");
    let view = ed.float(tree, float_options());
    ed.set_readonly(tree, true);
    assert!(ed.buffer(tree).is_readonly());

    let insert = || ChangeSet::from_changes(1, [(0, 0, Some("x"))]).unwrap();
    let user = Author::User(ClientId(1));
    let err = ed
        .apply(view, insert(), user.clone(), None, None)
        .unwrap_err();
    assert!(err.to_string().contains("read-only"), "{err}");
    let err = ed
        .apply_to_buffer(tree, insert(), user.clone(), None, None)
        .unwrap_err();
    assert!(err.to_string().contains("read-only"), "{err}");

    let plugin = Author::Plugin("tree".into());
    ed.apply(view, insert(), plugin, None, None).unwrap();
    assert_eq!(ed.buffer(tree).text().to_string(), "xa");
    // Undo is the user's, so it's refused too.
    assert!(ed.undo(view).is_err());

    ed.set_readonly(tree, false);
    ed.apply(
        view,
        ChangeSet::from_changes(2, [(2, 2, Some("!"))]).unwrap(),
        user,
        None,
        None,
    )
    .unwrap();
    assert_eq!(ed.buffer(tree).text().to_string(), "xa!");
}

#[test]
fn a_read_only_start_refuses_the_users_edits_there_and_moves_with_edits() {
    let mut ed = editor("");
    let log = ed.create_buffer("log", "out\n> ");
    let view = ed.float(log, float_options());
    ed.set_readonly_before(log, Some(4));
    let user = Author::User(ClientId(1));
    let plugin = Author::Plugin("log".into());
    let change = |len, from, to, text| ChangeSet::from_changes(len, [(from, to, text)]).unwrap();

    // Before the line, or deleting back over its start, is refused.
    let err = ed
        .apply(view, change(6, 0, 0, Some("x")), user.clone(), None, None)
        .unwrap_err();
    assert!(err.to_string().contains("read-only"), "{err}");
    let err = ed
        .apply(view, change(6, 3, 4, None), user.clone(), None, None)
        .unwrap_err();
    assert!(err.to_string().contains("read-only"), "{err}");

    // From it on, typing goes in, and stays writable.
    ed.apply(view, change(6, 4, 4, Some("ls")), user.clone(), None, None)
        .unwrap();
    assert_eq!(ed.buffer(log).text().to_string(), "out\nls> ");
    assert_eq!(ed.buffer(log).readonly_before(), Some(4));

    // What a plugin puts there joins the read-only part.
    ed.apply_unrecorded(view, change(8, 4, 4, Some("more\n")), plugin, None)
        .unwrap();
    assert_eq!(ed.buffer(log).readonly_before(), Some(9));

    // Undo is the user's: it can take back typing, which is after the line.
    ed.undo(view).unwrap();
    assert_eq!(ed.buffer(log).text().to_string(), "out\nmore\n> ");

    ed.set_readonly_before(log, None);
    ed.apply(view, change(11, 0, 0, Some("!")), user, None, None)
        .unwrap();
    assert_eq!(ed.buffer(log).text().to_string(), "!out\nmore\n> ");
}

#[test]
fn undoing_an_edit_made_without_a_view_keeps_the_cursor() {
    let mut ed = editor("hello world");
    let v = ed.focus();
    let b = ed.view(v).buffer;
    ed.view_mut(v).selection = Selection::point(8);
    let changes = ChangeSet::from_changes(11, [(0, 0, Some(">> "))]).unwrap();
    let plugin = Author::Plugin("p".into());
    ed.apply_to_buffer(b, changes, plugin, None, None).unwrap();
    assert_eq!(ed.view(v).selection.primary(), Range::point(11));

    assert!(ed.undo(v).unwrap());
    assert_eq!(text(&ed), "hello world");
    assert_eq!(ed.view(v).selection.primary(), Range::point(8));
    assert!(ed.redo(v).unwrap());
    assert_eq!(text(&ed), ">> hello world");
    assert_eq!(ed.view(v).selection.primary(), Range::point(11));
}

#[test]
fn redoing_an_edit_made_without_a_view_restores_the_selection_it_set() {
    let mut ed = editor("hello world");
    let v = ed.focus();
    let b = ed.view(v).buffer;
    ed.view_mut(v).selection = Selection::point(8);
    let changes = ChangeSet::from_changes(11, [(11, 11, Some("!"))]).unwrap();
    let plugin = Author::Plugin("p".into());
    let set = Some(Selection::single(0, 5));
    ed.apply_to_buffer(b, changes, plugin, None, set).unwrap();
    assert_eq!(ed.view(v).selection.primary(), Range::new(0, 5));

    assert!(ed.undo(v).unwrap());
    assert_eq!(text(&ed), "hello world");
    assert_eq!(ed.view(v).selection.primary(), Range::new(0, 5));
    ed.view_mut(v).selection = Selection::point(2);
    assert!(ed.redo(v).unwrap());
    assert_eq!(ed.view(v).selection.primary(), Range::new(0, 5));
}

#[test]
fn buffers_take_their_language_from_the_file_unless_given_one() {
    let mut ed = Editor::new(ClientId(1));
    let (file, _) = ed.open("file", "", Some("main.rs".into()));
    assert_eq!(ed.buffer(file).language(), Some("rust"));
    let preview = ed.create_buffer("preview", "fn main() {}");
    assert_eq!(ed.buffer(preview).language(), None);
    ed.set_language(preview, Some("rust".into()));
    assert_eq!(ed.buffer(preview).language(), Some("rust"));
    ed.set_language(file, Some("markdown".into()));
    assert_eq!(ed.buffer(file).language(), Some("markdown"));
    ed.set_language(file, None);
    assert_eq!(ed.buffer(file).language(), Some("rust"));
}

#[test]
fn buffers_save_to_a_new_path_and_keep_it() {
    let dir = std::env::temp_dir().join(format!("greed-save-as-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let mut ed = editor("fn main() {}");
    let buffer = ed.view(ed.focus()).buffer;
    assert!(ed.save(buffer).is_err(), "no file yet");

    let path = dir.join("main.rs");
    ed.save_as(buffer, &path).unwrap();
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "fn main() {}");
    assert_eq!(ed.buffer(buffer).path(), Some(path.as_path()));
    assert_eq!(ed.buffer(buffer).language(), Some("rust"));
    assert!(!ed.buffer(buffer).is_modified());
    std::fs::remove_dir_all(&dir).unwrap();
}

fn temp_dir(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("greed-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn dir_entries(dir: &std::path::Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

#[test]
fn files_that_arent_utf8_cant_be_saved_over_but_can_be_saved_elsewhere() {
    let dir = temp_dir("lossy");
    let path = dir.join("data.txt");
    std::fs::write(&path, b"ab\xffcd").unwrap();
    let mut ed = editor("");
    let buffer = ed.open_file(&path).unwrap();
    assert!(ed.buffer(buffer).is_lossy());

    let err = ed.save(buffer).unwrap_err();
    assert!(err.to_string().contains("isn't UTF-8"), "{err}");
    let err = ed.save_as(buffer, &path).unwrap_err();
    assert!(err.to_string().contains("isn't UTF-8"), "{err}");
    assert_eq!(std::fs::read(&path).unwrap(), b"ab\xffcd");

    let copy = dir.join("copy.txt");
    ed.save_as(buffer, &copy).unwrap();
    assert_eq!(std::fs::read_to_string(&copy).unwrap(), "ab\u{fffd}cd");
    assert!(!ed.buffer(buffer).is_lossy());
    ed.save(buffer).unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), b"ab\xffcd");
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_failed_save_elsewhere_keeps_a_file_that_isnt_utf8_from_being_saved_over() {
    let dir = temp_dir("lossy-failed");
    let path = dir.join("data.txt");
    std::fs::write(&path, b"ab\xffcd").unwrap();
    let mut ed = editor("");
    let buffer = ed.open_file(&path).unwrap();
    assert!(ed.save_as(buffer, &dir.join("missing/copy.txt")).is_err());
    assert_eq!(ed.buffer(buffer).path(), Some(path.as_path()));
    assert!(ed.save(buffer).is_err());
    std::fs::remove_dir_all(&dir).unwrap();
}

#[cfg(unix)]
#[test]
fn saving_replaces_the_file_whole_keeping_permissions_and_symlinks() {
    use std::os::unix::fs::PermissionsExt;
    let dir = temp_dir("atomic-save");
    let target = dir.join("real.sh");
    std::fs::write(&target, "old").unwrap();
    std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o750)).unwrap();
    let link = dir.join("link.sh");
    std::os::unix::fs::symlink("real.sh", &link).unwrap();

    let mut ed = editor("");
    let buffer = ed.open_file(&link).unwrap();
    let insert = ChangeSet::from_changes(3, [(3, 3, Some(" new"))]).unwrap();
    let user = Author::User(ClientId(1));
    ed.apply_to_buffer(buffer, insert, user, None, None)
        .unwrap();
    ed.save(buffer).unwrap();

    assert!(
        std::fs::symlink_metadata(&link)
            .unwrap()
            .file_type()
            .is_symlink()
    );
    assert_eq!(std::fs::read_to_string(&target).unwrap(), "old new");
    let mode = std::fs::metadata(&target).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o750);
    assert_eq!(
        dir_entries(&dir),
        ["link.sh", "real.sh"],
        "no temp file left"
    );

    // A symlink to a file that doesn't exist yet creates it.
    let dangling = dir.join("dangling.txt");
    std::os::unix::fs::symlink("new.txt", &dangling).unwrap();
    ed.save_as(buffer, &dangling).unwrap();
    assert_eq!(
        std::fs::read_to_string(dir.join("new.txt")).unwrap(),
        "old new"
    );
    assert!(
        std::fs::symlink_metadata(&dangling)
            .unwrap()
            .file_type()
            .is_symlink()
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn each_mode_has_a_cursor_shape() {
    let mut ed = editor("");
    assert_eq!(ed.cursor_shape(), CursorShape::Block);
    ed.set_cursor_shape("insert", CursorShape::Bar);
    ed.set_mode("insert");
    assert_eq!(ed.cursor_shape(), CursorShape::Bar);
    ed.set_mode("visual");
    assert_eq!(ed.cursor_shape(), CursorShape::Block);
}

#[test]
fn counts_before_a_command_reach_it() {
    let mut ed = editor("");
    let normal = Layer::mode("helix");
    ed.keymap_mut()
        .bind(normal.clone(), &keys("j"), "down", "core")
        .unwrap();
    ed.keymap_mut()
        .bind(normal.clone(), &keys("0"), "line-start", "core")
        .unwrap();
    ed.keymap_mut()
        .bind(normal, &keys("g g"), "top", "core")
        .unwrap();
    let press = |ed: &mut Editor, s: &str| {
        let mut outcome = None;
        for key in keys(s) {
            outcome = Some(ed.press(key));
        }
        outcome.unwrap()
    };
    let command = |name: &str, keys_: &str, count: Option<u32>| KeyOutcome::Command {
        name: name.into(),
        keys: keys(keys_),
        count,
    };

    // Without counts turned on, digits are plain keys.
    assert_eq!(press(&mut ed, "3"), KeyOutcome::Unbound(keys("3")));

    ed.keymap_mut().enable_counts("helix", "core");
    assert_eq!(press(&mut ed, "1 2 j"), command("down", "j", Some(12)));
    assert_eq!(press(&mut ed, "j"), command("down", "j", None));
    // A leading 0 is a key; after a digit it's part of the count.
    assert_eq!(press(&mut ed, "0"), command("line-start", "0", None));
    assert_eq!(press(&mut ed, "1 0 j"), command("down", "j", Some(10)));
    assert_eq!(press(&mut ed, "5 g g"), command("top", "g g", Some(5)));
    // An unbound key or a mode change drops the count.
    press(&mut ed, "4 z");
    assert_eq!(press(&mut ed, "j"), command("down", "j", None));
    press(&mut ed, "4");
    ed.set_mode("insert");
    ed.set_mode("helix");
    assert_eq!(press(&mut ed, "j"), command("down", "j", None));

    ed.keymap_mut().remove_owned_by("core");
    assert_eq!(press(&mut ed, "3"), KeyOutcome::Unbound(keys("3")));
}

#[test]
fn decorations_follow_edits_and_are_replaced_per_namespace() {
    use greed_core::Mark;
    let mut ed = editor("hello world");
    let view = ed.focus();
    let buffer = ed.view(view).buffer;
    let mark = |from, to, style: &str| Mark {
        range: from..to,
        style: style.into(),
        ..Mark::default()
    };
    ed.decorate(buffer, "search", vec![mark(6, 11, "match")]);
    ed.decorate(buffer, "spell", vec![mark(0, 5, "spelling")]);
    let ranges = |ed: &Editor, ns: &str| -> Vec<(usize, usize)> {
        ed.buffer(buffer)
            .marks(ns)
            .iter()
            .map(|m| (m.range.start, m.range.end))
            .collect()
    };
    let user = Author::User(ClientId(1));
    let edit = |ed: &mut Editor, len, change: (usize, usize, Option<&str>)| {
        let changes = ChangeSet::from_changes(len, [change]).unwrap();
        ed.apply(view, changes, user.clone(), None, None).unwrap();
    };

    edit(&mut ed, 11, (0, 0, Some(">> ")));
    assert_eq!(ranges(&ed, "search"), [(9, 14)]);
    // Text typed at either edge stays outside the mark.
    edit(&mut ed, 14, (9, 9, Some("_")));
    edit(&mut ed, 15, (15, 15, Some("!")));
    assert_eq!(ranges(&ed, "search"), [(10, 15)]);
    // A mark whose text is deleted goes away.
    edit(&mut ed, 16, (9, 16, None));
    assert!(ranges(&ed, "search").is_empty());
    assert_eq!(ranges(&ed, "spell"), [(3, 8)]);

    ed.decorate(buffer, "spell", Vec::new());
    assert!(ranges(&ed, "spell").is_empty());
}

#[test]
fn file_types_come_from_a_table_plugins_can_change() {
    let mut ed = Editor::new(ClientId(1));
    let (rust, _) = ed.open("file", "", Some("src/main.rs".into()));
    let (rb, _) = ed.open("file", "", Some("tool.rb".into()));
    let (make, _) = ed.open("file", "", Some("Makefile".into()));
    assert_eq!(ed.buffer(rust).language(), Some("rust"), "built in");
    assert_eq!(ed.buffer(rb).language(), None);

    ed.set_file_type("ruby", &["rb".into(), "rake".into()], &[]);
    ed.set_file_type("make", &[], &["Makefile".into()]);
    assert_eq!(
        ed.buffer(rb).language(),
        Some("ruby"),
        "open buffers follow"
    );
    assert_eq!(ed.buffer(make).language(), Some("make"));
    assert_eq!(
        ed.file_type(std::path::Path::new("a/b.rake")).as_deref(),
        Some("ruby")
    );

    // Setting a language again replaces its extensions.
    ed.set_file_type("ruby", &["gemspec".into()], &[]);
    assert_eq!(ed.buffer(rb).language(), None);
    // A language set on the buffer still wins.
    ed.set_language(rust, Some("text".into()));
    ed.set_file_type("rust", &["rs".into()], &[]);
    assert_eq!(ed.buffer(rust).language(), Some("text"));
}

fn panel_options() -> greed_core::PanelOptions {
    greed_core::PanelOptions {
        side: greed_core::Side::Left,
        width: greed_core::Extent::Cells(10),
        title: None,
        focus: false,
    }
}

#[test]
fn the_first_view_starts_a_project() {
    let ed = editor("text");
    assert_eq!(ed.projects().len(), 1);
    assert_eq!(ed.current_project().main(), ed.main());
}

#[test]
fn projects_each_have_a_main_view_and_panels() {
    let mut ed = editor("first");
    let first = ed.current_project().id();
    let first_main = ed.main();
    let tree = ed.create_buffer("tree", "");
    ed.panel(tree, panel_options());

    let second = ed.open_project("/elsewhere".into());
    assert_eq!(ed.current_project().id(), second);
    assert_eq!(
        ed.current_project().root(),
        std::path::Path::new("/elsewhere")
    );
    assert_ne!(ed.main(), first_main, "a project has its own main view");
    assert_eq!(ed.focus(), ed.main());
    assert!(ed.panels().is_empty(), "panels stay with their project");

    assert!(ed.switch_project(first));
    assert_eq!(ed.main(), first_main);
    assert_eq!(ed.focus(), first_main);
    assert_eq!(ed.panels().len(), 1);
    assert!(!ed.switch_project(greed_core::ProjectId(999)));
}

#[test]
fn buffers_belong_to_the_project_they_were_opened_in() {
    let mut ed = editor("first");
    let first = ed.current_project().id();
    let in_first = ed.create_buffer("file", "a");
    let second = ed.open_project("/other".into());
    let in_second = ed.create_buffer("file", "b");
    assert_eq!(ed.buffer_project(in_first), Some(first));
    assert_eq!(ed.buffer_project(in_second), Some(second));
}

#[test]
fn closing_a_project_takes_its_views_and_buffers_but_not_the_last_one() {
    let mut ed = editor("first");
    let first = ed.current_project().id();
    let second = ed.open_project("/other".into());
    let second_main = ed.main();
    let buffer = ed.create_buffer("file", "only here");
    ed.show(second_main, buffer);
    let tree = ed.create_buffer("tree", "");
    let panel = ed.panel(tree, panel_options());

    assert!(ed.close_project(second));
    assert_eq!(
        ed.current_project().id(),
        first,
        "another project takes over"
    );
    assert!(ed.find_view(second_main).is_none() && ed.find_view(panel).is_none());
    assert!(
        !ed.buffers().any(|b| b.id() == buffer),
        "its buffers go too"
    );
    assert!(!ed.close_project(first), "the last project stays");
}

#[test]
fn the_main_view_of_any_project_can_not_be_closed() {
    let mut ed = editor("first");
    let first_main = ed.main();
    ed.open_project("/other".into());
    assert!(
        !ed.close(first_main),
        "even when it isn't the current project's"
    );
}

#[test]
fn closing_the_shown_project_shows_the_next_one_or_else_the_one_before() {
    let mut ed = editor("first");
    let first = ed.current_project().id();
    let second = ed.open_project("/b".into());
    let third = ed.open_project("/c".into());
    assert!(ed.switch_project(second));
    assert!(ed.close_project(second));
    assert_eq!(ed.current_project().id(), third, "the next one");
    assert!(ed.close_project(third));
    assert_eq!(
        ed.current_project().id(),
        first,
        "the one before, at the end"
    );
    assert_eq!(ed.focus(), ed.main());
}

#[test]
fn closing_a_project_that_isnt_shown_keeps_the_shown_one() {
    let mut ed = editor("first");
    let first = ed.current_project().id();
    let second = ed.open_project("/b".into());
    assert!(ed.close_project(first));
    assert_eq!(ed.current_project().id(), second);
}

#[test]
fn tabs_of_a_project_that_isnt_shown_work_by_id() {
    let mut ed = editor("first");
    let first = ed.current_project().id();
    let kept = ed.tabs()[0].id();
    let tab = ed.new_tab(None);
    let pane = ed.current_tab().active();
    let second = ed.open_project("/b".into());
    let second_main = ed.main();

    assert!(ed.rename_tab(tab, Some("logs".into())));
    assert_eq!(ed.project_tabs(first).unwrap()[1].name(), Some("logs"));
    let layout = ed.tab_layout(tab).cloned().unwrap();
    assert_eq!(layout.panes(), [pane]);
    ed.set_tab_layout(tab, layout).unwrap();
    assert_eq!(ed.current_project().id(), second, "none of those switch");

    assert!(ed.switch_tab(kept));
    assert_eq!(ed.current_project().id(), first);
    assert_eq!(ed.current_tab().id(), kept);
    assert_eq!(ed.focus(), ed.main());

    assert!(ed.switch_project(second));
    assert_eq!(ed.close_tab(tab), Some(vec![pane]));
    assert!(ed.find_view(pane).is_none());
    assert_eq!(ed.focus(), second_main, "the shown project keeps focus");
    assert_eq!(ed.close_tab(kept), None, "a project's last tab stays");
    assert!(!ed.switch_tab(tab) && !ed.rename_tab(tab, None));
    assert!(ed.tab_layout(tab).is_none());
}

#[test]
fn focusing_a_view_of_another_project_shows_that_project() {
    let mut ed = editor("first");
    let first = ed.current_project().id();
    let first_main = ed.main();
    let tree = ed.create_buffer("tree", "");
    let panel = ed.panel(tree, panel_options());
    let other_tab = ed.new_tab(None);
    let pane = ed.current_tab().active();
    assert!(ed.switch_tab(ed.tabs()[0].id()));
    let second = ed.open_project("/b".into());

    ed.set_focus(pane);
    assert_eq!(ed.current_project().id(), first);
    assert_eq!(ed.current_tab().id(), other_tab);
    assert_eq!(ed.focus(), pane);

    assert!(ed.switch_project(second));
    ed.set_focus(panel);
    assert_eq!(ed.current_project().id(), first);
    assert_eq!(ed.focus(), panel);

    assert!(ed.switch_project(second));
    let float = ed.float(tree, float_options());
    ed.set_focus(float);
    assert_eq!(ed.current_project().id(), second, "floats show over any");
    assert_ne!(first_main, ed.main());
}

#[test]
fn files_opened_belong_to_the_shown_project() {
    let dir = std::env::temp_dir().join(format!("greed-project-file-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("a.txt"), "a").unwrap();
    let mut ed = editor("");
    let project = ed.open_project(dir.clone());
    let buffer = ed.open_file(&dir.join("a.txt")).unwrap();
    assert_eq!(ed.buffer_project(buffer), Some(project));
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_file_is_one_buffer_however_its_path_is_written() {
    let cwd = std::env::current_dir().unwrap();
    let mut ed = editor("");
    let relative = ed.open_file(std::path::Path::new("Cargo.toml")).unwrap();
    let absolute = ed.open_file(&cwd.join("Cargo.toml")).unwrap();
    let dotted = ed.open_file(std::path::Path::new("./Cargo.toml")).unwrap();
    assert_eq!(relative, absolute);
    assert_eq!(relative, dotted);
    assert_eq!(
        ed.buffer(relative).path(),
        Some(cwd.join("Cargo.toml").as_path())
    );
}

#[test]
fn isolated_modes_use_only_their_own_keys() {
    let mut ed = editor("");
    ed.keymap_mut()
        .bind(Layer::global(), &keys("ctrl-s"), "save", "core")
        .unwrap();
    ed.keymap_mut()
        .bind(Layer::mode("terminal"), &keys("ctrl-\\"), "leave", "term")
        .unwrap();
    ed.keymap_mut().set_fallback("terminal", "send", "term");
    ed.set_mode("terminal");
    let command = |name: &str, keys_: &str| KeyOutcome::Command {
        name: name.into(),
        keys: keys(keys_),
        count: None,
    };
    assert_eq!(ed.press(keys("ctrl-s")[0]), command("save", "ctrl-s"));
    ed.keymap_mut().isolate("terminal", "term");
    assert_eq!(ed.press(keys("ctrl-s")[0]), command("send", "ctrl-s"));
    assert_eq!(ed.press(keys("ctrl-\\")[0]), command("leave", "ctrl-\\"));
    // It goes with the plugin that asked for it.
    ed.keymap_mut().remove_owned_by("term");
    assert_eq!(ed.press(keys("ctrl-s")[0]), command("save", "ctrl-s"));
}

mod panes {
    use greed_core::layout::Direction;
    use greed_core::render::{CellWidth, Plain, Renderer, Size, Status};
    use greed_core::{Editor, ViewId};

    fn draw(ed: &mut Editor, width: u16, height: u16) {
        Renderer::new(CellWidth).frame(
            ed,
            Size { width, height },
            &Status::Default { message: None },
            &Plain,
        );
    }

    /// Three panes: `a` on the left, `b` above `c` on the right.
    fn three() -> (Editor, ViewId, ViewId, ViewId) {
        let mut ed = super::editor("text");
        let a = ed.main();
        let b = ed.split_pane(a, Direction::Right, None).unwrap();
        let c = ed.split_pane(b, Direction::Down, None).unwrap();
        draw(&mut ed, 41, 11);
        (ed, a, b, c)
    }

    #[test]
    fn moving_between_panes_goes_back_where_it_came_from() {
        let (mut ed, a, b, c) = three();
        assert_eq!(ed.neighbor(a, Direction::Left), None);
        assert_eq!(ed.neighbor(c, Direction::Up), Some(b));
        // c was active last, so going right from a picks c over b.
        assert_eq!(ed.neighbor(a, Direction::Right), Some(c));
        ed.set_focus(b);
        assert_eq!(ed.neighbor(a, Direction::Right), Some(b));
        assert_eq!(ed.neighbor(b, Direction::Left), Some(a));
    }

    #[test]
    fn closing_a_pane_makes_the_last_active_one_active() {
        let (mut ed, a, b, c) = three();
        ed.set_focus(a);
        ed.set_focus(c);
        assert!(ed.close(c));
        assert_eq!(ed.main(), a);
        assert_eq!(ed.focus(), a);
        assert_eq!(ed.current_tab().panes(), [a, b]);
        assert!(ed.close(a));
        assert!(!ed.close(b), "the last pane stays");
    }

    #[test]
    fn closing_a_tabs_last_pane_closes_the_tab() {
        let mut ed = super::editor("text");
        let first = ed.current_tab().id();
        let main = ed.main();
        let second = ed.new_tab(None);
        assert_eq!(ed.tabs().len(), 2);
        assert!(ed.close(ed.main()));
        assert_eq!(ed.tabs().len(), 1);
        assert_eq!(ed.current_tab().id(), first);
        assert_eq!(ed.focus(), main);
        assert!(!ed.switch_tab(second));
    }

    #[test]
    fn closing_a_tab_closes_its_panes_and_shows_a_neighbor() {
        let mut ed = super::editor("text");
        let main = ed.main();
        let tab = ed.new_tab(None);
        let pane = ed.main();
        let other = ed.split_pane(pane, Direction::Down, None).unwrap();
        assert_eq!(ed.close_tab(tab), Some(vec![pane, other]));
        assert_eq!(ed.focus(), main);
        assert!(ed.find_view(pane).is_none());
        assert_eq!(
            ed.close_tab(ed.current_tab().id()),
            None,
            "the last tab stays"
        );
    }

    #[test]
    fn focusing_a_pane_in_another_tab_shows_that_tab() {
        let mut ed = super::editor("text");
        let main = ed.main();
        let first = ed.current_tab().id();
        ed.new_tab(None);
        ed.set_focus(main);
        assert_eq!(ed.current_tab().id(), first);
    }

    #[test]
    fn resizing_moves_the_line_between_panes() {
        let (mut ed, a, b, _) = three();
        assert!(ed.resize_pane(a, Direction::Right, 5));
        draw(&mut ed, 41, 11);
        assert_eq!(ed.view(a).area.map(|r| r.width), Some(25));
        assert_eq!(ed.view(b).area.map(|r| r.width), Some(15));
        assert!(!ed.resize_pane(a, Direction::Left, 5));
    }

    #[test]
    fn panels_are_neighbors_of_the_panes_beside_them() {
        let (mut ed, a, b, _) = three();
        let tree = ed.create_buffer("tree", "");
        let panel = ed.panel(tree, super::panel_options());
        draw(&mut ed, 52, 11);
        assert_eq!(ed.neighbor(a, Direction::Left), Some(panel));
        assert_eq!(ed.neighbor(panel, Direction::Right), Some(a));
        assert_eq!(ed.neighbor(panel, Direction::Left), None);
        assert_eq!(ed.neighbor(b, Direction::Left), Some(a));
    }
    #[test]
    fn a_panel_resizes_toward_the_main_view_only() {
        let mut ed = super::editor("text");
        let tree = ed.create_buffer("tree", "");
        let left = ed.panel(tree, super::panel_options());
        let notes = ed.create_buffer("notes", "");
        let right = ed.panel(
            notes,
            greed_core::PanelOptions {
                side: greed_core::Side::Right,
                width: greed_core::Extent::percent(25),
                ..super::panel_options()
            },
        );
        draw(&mut ed, 80, 10);
        assert!(ed.resize_pane(left, Direction::Right, 4));
        assert!(ed.resize_pane(right, Direction::Left, -5));
        assert!(!ed.resize_pane(left, Direction::Left, 4));
        assert!(!ed.resize_pane(right, Direction::Up, 4));
        draw(&mut ed, 80, 10);
        assert_eq!(ed.view(left).area.map(|r| r.width), Some(14));
        assert_eq!(ed.view(right).area.map(|r| r.width), Some(15));
    }

    #[test]
    fn the_mouse_finds_the_lines_between_panes_and_panels() {
        let (mut ed, a, b, _) = three();
        let tree = ed.create_buffer("tree", "");
        let panel = ed.panel(tree, super::panel_options());
        let renderer = Renderer::new(CellWidth);
        renderer.frame(
            &mut ed,
            Size {
                width: 52,
                height: 11,
            },
            &Status::Default { message: None },
            &Plain,
        );
        let edge = |col, row| {
            let hit = renderer.hit(&ed, col, row);
            (hit.view, hit.edge)
        };
        assert_eq!(edge(10, 3), (Some(panel), Some("right")));
        let a_area = ed.view(a).area.unwrap();
        assert_eq!(edge(a_area.x + a_area.width, 3), (Some(a), Some("right")));
        let b_area = ed.view(b).area.unwrap();
        assert_eq!(
            edge(b_area.x + 2, b_area.y + b_area.height),
            (Some(b), Some("down"))
        );
        assert_eq!(edge(a_area.x + 1, 3).1, None);
    }
}

#[test]
fn a_group_undoes_across_buffers_as_one_step() {
    let mut ed = editor("main");
    let other = ed.create_buffer("file", "other");
    let main = ed.view(ed.focus()).buffer;
    let user = Author::User(ClientId(1));
    let append = |ed: &mut Editor, buffer, s: &str| {
        let len = ed.buffer(buffer).text().len_bytes();
        let changes = ChangeSet::from_changes(len, [(len, len, Some(s))]).unwrap();
        ed.apply_to_buffer(buffer, changes, user.clone(), None, None)
            .unwrap();
    };
    let group = ed.new_group();
    ed.set_group(Some(group));
    assert_eq!(ed.group(), Some(group));
    append(&mut ed, main, "!");
    append(&mut ed, other, "!");
    ed.set_group(None);
    assert_eq!(ed.undo_group(group, &user).unwrap(), [main, other]);
    assert_eq!(ed.buffer(main).text().to_string(), "main");
    assert_eq!(ed.buffer(other).text().to_string(), "other");
    assert!(
        ed.undo_group(group, &user).unwrap().is_empty(),
        "already undone"
    );

    // Something on top of the group in one buffer stops the whole undo.
    let group = ed.new_group();
    ed.set_group(Some(group));
    append(&mut ed, main, "?");
    append(&mut ed, other, "?");
    ed.set_group(None);
    append(&mut ed, other, "later");
    assert!(matches!(
        ed.undo_group(group, &user),
        Err(greed_core::Error::GroupChanged)
    ));
    assert_eq!(ed.buffer(main).text().to_string(), "main?");
}

#[test]
fn edits_carry_the_cause_they_were_made_for() {
    let mut ed = editor("");
    let v = ed.focus();
    let user = Author::User(ClientId(1));
    ed.set_cause(Some("format".into()));
    let changes = ChangeSet::from_changes(0, [(0, 0, Some("x"))]).unwrap();
    ed.apply(v, changes, user.clone(), None, None).unwrap();
    ed.set_cause(None);
    let changes = ChangeSet::from_changes(1, [(1, 1, Some("y"))]).unwrap();
    ed.apply(v, changes, user, Some("paste"), None).unwrap();
    let log = ed.buffer(ed.view(v).buffer).history().log();
    assert_eq!(log[0].meta.cause.as_deref(), Some("format"));
    assert_eq!(log[1].meta.cause.as_deref(), Some("paste"));
}

#[test]
fn reloading_a_file_is_an_external_edit_undo_takes_back() {
    let dir = std::env::temp_dir().join(format!("greed-reload-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("a.txt");
    std::fs::write(&path, "one\ntwo\n").unwrap();
    let mut ed = editor("");
    let id = ed.open_file(&path).unwrap();
    assert!(!ed.reload(id).unwrap(), "nothing changed on disk");
    std::fs::write(&path, "one\nTWO\n").unwrap();
    assert!(ed.reload(id).unwrap());
    let buffer = ed.buffer(id);
    assert_eq!(buffer.text().to_string(), "one\nTWO\n");
    assert!(!buffer.is_modified(), "the buffer matches its file again");
    let tx = buffer.history().log().last().unwrap();
    assert_eq!(tx.meta.author, Author::External);
    assert_eq!(tx.meta.cause.as_deref(), Some("reload"));
    let v = ed.focus();
    ed.show(v, id);
    assert!(ed.undo(v).unwrap());
    assert_eq!(ed.buffer(id).text().to_string(), "one\ntwo\n");
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_buffer_that_forgets_its_history_counts_edits_and_still_maps_other_views() {
    let mut ed = editor("hello world");
    let v1 = ed.focus();
    let v2 = ed.split(v1);
    ed.view_mut(v2).selection = Selection::single(6, 11);
    let buffer = ed.view(v1).buffer;
    let changes = ChangeSet::from_changes(11, [(0, 0, Some("a "))]).unwrap();
    ed.apply(v1, changes, Author::User(ClientId(1)), None, None)
        .unwrap();
    ed.forget_history(buffer);
    assert!(
        ed.buffer(buffer).history().log().is_empty(),
        "what was kept goes"
    );
    let changes = ChangeSet::from_changes(13, [(0, 0, Some(">> "))]).unwrap();
    ed.apply(v1, changes, Author::User(ClientId(1)), None, None)
        .unwrap();
    assert_eq!(text(&ed), ">> a hello world");
    assert!(
        ed.buffer(buffer).history().log().is_empty(),
        "and nothing new is kept"
    );
    assert_eq!(
        ed.buffer(buffer).history().applied(),
        2,
        "but every edit counts"
    );
    assert_eq!(ed.view(v2).selection.primary(), Range::new(11, 16));
    assert!(!ed.undo(v1).unwrap(), "there's nothing to undo");
}

#[test]
fn clearing_a_buffers_history_keeps_what_comes_after() {
    let mut ed = editor("hello");
    let v = ed.focus();
    let buffer = ed.view(v).buffer;
    let changes = ChangeSet::from_changes(5, [(0, 0, Some("a "))]).unwrap();
    ed.apply(v, changes, Author::User(ClientId(1)), None, None)
        .unwrap();
    ed.clear_history(buffer);
    assert!(
        ed.buffer(buffer).history().log().is_empty(),
        "what was kept goes"
    );
    assert!(!ed.undo(v).unwrap(), "undo can't go back past the clear");
    let changes = ChangeSet::from_changes(7, [(7, 7, Some("!"))]).unwrap();
    ed.apply(v, changes, Author::User(ClientId(1)), None, None)
        .unwrap();
    assert_eq!(
        ed.buffer(buffer).history().applied(),
        2,
        "every edit counts"
    );
    assert!(ed.undo(v).unwrap(), "an edit after it is kept");
    assert_eq!(text(&ed), "a hello");
    assert!(!ed.undo(v).unwrap(), "and only that one");
}

#[test]
fn hidden_floats_give_up_focus_and_take_it_back_when_focused() {
    let mut ed = editor("main text");
    let main = ed.main();
    let a = ed.create_buffer("terminal", "a");
    let b = ed.create_buffer("terminal", "b");
    let va = ed.float(a, float_options());
    let vb = ed.float(b, float_options());
    let hide = |ed: &mut greed_core::Editor, view, hidden| {
        let options = ed.float_options(view).unwrap().clone();
        ed.configure_float(view, greed_core::FloatOptions { hidden, ..options })
    };

    // Hiding the focused one gives focus to where it came from.
    assert!(hide(&mut ed, vb, true));
    assert_eq!(ed.focus(), va);
    assert_eq!(ed.floats().iter().map(|f| f.view).collect::<Vec<_>>(), [va]);
    assert_eq!(ed.floats_hidden_too().len(), 2);

    // With what it came from hidden too, the main view gets it.
    assert!(hide(&mut ed, va, true));
    assert_eq!(ed.focus(), main);
    assert!(ed.floats().is_empty());

    // Focusing a hidden one shows it.
    ed.set_focus(vb);
    assert!(!ed.float_options(vb).unwrap().hidden);
    assert_eq!(ed.floats().iter().map(|f| f.view).collect::<Vec<_>>(), [vb]);

    // Closing it skips the hidden one it came from.
    ed.close(vb);
    assert_eq!(ed.focus(), main);

    // One opened hidden doesn't take focus.
    let c = ed.create_buffer("terminal", "c");
    let vc = ed.float(
        c,
        greed_core::FloatOptions {
            hidden: true,
            ..float_options()
        },
    );
    assert_eq!(ed.focus(), main);
    assert!(ed.float_options(vc).unwrap().hidden);
}

mod clients {
    use greed_core::layout::Direction;
    use greed_core::render::{CellWidth, Plain, Rect, Renderer, Size, Status, grid};
    use greed_core::{
        Anchor, ClientInfo, ClientLayout, Editor, Extent, FIRST_CLIENT, FloatOptions, Scroll,
    };
    use greed_text::{Author, ChangeSet, ClientId, Selection};

    const SECOND: ClientId = ClientId(2);

    /// An editor showing `text`, with a second client seeing what the
    /// first one does.
    fn two_clients(text: &str) -> Editor {
        let mut ed = super::editor(text);
        assert!(ed.add_client(SECOND));
        assert!(!ed.add_client(SECOND), "one client per id");
        ed
    }

    /// Inserts `text` at `at` in the focused view, as the acting client.
    fn type_at(ed: &mut Editor, at: usize, text: &str) {
        let view = ed.focus();
        let len = super::text(ed).len();
        let changes = ChangeSet::from_changes(len, [(at, at, Some(text))]).unwrap();
        let author = Author::User(ed.client());
        ed.apply(view, changes, author, None, None).unwrap();
    }

    /// Where the acting client's cursor is.
    fn cursor(ed: &Editor) -> usize {
        ed.view(ed.focus()).selection.primary().head
    }

    #[test]
    fn acting_for_another_client_gives_back_the_one_before() {
        let mut ed = two_clients("hello");
        let before = ed.act_as(SECOND);
        assert_eq!((before, ed.client()), (FIRST_CLIENT, SECOND));
        ed.act_as(before);
        assert_eq!(ed.client(), FIRST_CLIENT, "acting for the first again");
    }

    #[test]
    fn clients_see_one_view_with_selections_of_their_own() {
        let mut ed = two_clients("hello world");
        let view = ed.focus();
        assert_eq!(ed.client(), FIRST_CLIENT);
        assert!(ed.set_acting(SECOND));
        assert_eq!(ed.focus(), view, "it sees what the first one does");
        ed.view_mut(view).selection = Selection::single(6, 11);
        ed.set_acting(FIRST_CLIENT);
        assert_eq!(ed.view(view).selection, Selection::point(0));
        ed.set_acting(SECOND);
        assert_eq!(ed.view(view).selection, Selection::single(6, 11));
        assert!(!ed.set_acting(ClientId(3)), "no such client");
        assert_eq!((ed.client(), ed.last_active()), (SECOND, SECOND));
    }

    #[test]
    fn an_edit_by_one_client_moves_the_others_cursor() {
        let mut ed = two_clients("hello world");
        let view = ed.focus();
        ed.set_acting(SECOND);
        ed.view_mut(view).selection = Selection::point(6);
        ed.set_acting(FIRST_CLIENT);
        type_at(&mut ed, 0, ">> ");
        assert_eq!(cursor(&ed), 3);
        ed.set_acting(SECOND);
        assert_eq!(cursor(&ed), 9, "still before \"world\"");
    }

    #[test]
    fn undo_puts_back_the_authors_selection_and_moves_the_others() {
        let mut ed = two_clients("one two");
        let view = ed.focus();
        // The first client replaces "one" it has selected; the second has
        // its cursor on "two".
        ed.view_mut(view).selection = Selection::single(0, 3);
        ed.set_acting(SECOND);
        ed.view_mut(view).selection = Selection::point(4);
        ed.set_acting(FIRST_CLIENT);
        let changes = ChangeSet::from_changes(7, [(0, 3, Some("three"))]).unwrap();
        ed.apply(view, changes, Author::User(FIRST_CLIENT), None, None)
            .unwrap();
        ed.set_acting(SECOND);
        assert_eq!(cursor(&ed), 6);

        // Undone by its author: its selection is back as it was, and the
        // other's cursor goes back with the text.
        ed.set_acting(FIRST_CLIENT);
        assert!(ed.undo(view).unwrap());
        assert_eq!(super::text(&ed), "one two");
        assert_eq!(ed.view(view).selection, Selection::single(0, 3));
        ed.set_acting(SECOND);
        assert_eq!(cursor(&ed), 4);

        // Redone and undone again by the other client: its own cursor moves
        // with the text each time, rather than to the author's selection.
        assert!(ed.redo(view).unwrap());
        assert_eq!(super::text(&ed), "three two");
        assert_eq!(cursor(&ed), 6);
        ed.view_mut(view).selection = Selection::point(7);
        assert!(ed.undo(view).unwrap());
        assert_eq!(super::text(&ed), "one two");
        assert_eq!(
            ed.view(view).selection,
            Selection::point(5),
            "still on the w"
        );
    }

    #[test]
    fn undo_groups_of_two_clients_stay_apart() {
        let mut ed = two_clients("");
        let view = ed.focus();
        ed.start_group();
        let first = ed.group();
        type_at(&mut ed, 0, "a");
        ed.set_acting(SECOND);
        assert_eq!(ed.group(), None, "the first client's group is its own");
        ed.start_group();
        assert!(ed.group().is_some() && ed.group() != first);
        type_at(&mut ed, 1, "b");
        ed.set_acting(FIRST_CLIENT);
        assert_eq!(ed.group(), first);
        // "b" went into a step of its own, not into the first client's.
        assert!(ed.undo(view).unwrap());
        assert_eq!(super::text(&ed), "a");
        assert!(ed.undo(view).unwrap());
        assert_eq!(super::text(&ed), "");
    }

    #[test]
    fn a_plugins_selection_goes_to_the_acting_client_alone() {
        let mut ed = two_clients("one two");
        let view = ed.focus();
        let buffer = ed.view(view).buffer;
        ed.set_acting(SECOND);
        ed.view_mut(view).selection = Selection::point(4);
        ed.set_acting(FIRST_CLIENT);
        let changes = ChangeSet::from_changes(7, [(0, 0, Some(">"))]).unwrap();
        let author = Author::Plugin("agent".into());
        ed.apply_to_buffer(buffer, changes, author, None, Some(Selection::point(1)))
            .unwrap();
        assert_eq!(cursor(&ed), 1, "the acting client's");
        ed.set_acting(SECOND);
        assert_eq!(cursor(&ed), 5, "the other's moved with the text");
    }

    #[test]
    fn parked_clients_come_back_by_name_and_new_ones_follow() {
        let mut ed = super::editor("hello");
        let info = |name: &str| ClientInfo {
            name: name.to_owned(),
            kind: "tui".to_owned(),
            remote: false,
        };
        let a = ed.attach_client(info("tui@a"));
        ed.set_acting(a);
        let view = ed.focus();
        ed.view_mut(view).selection = Selection::point(3);
        ed.set_mode("insert");
        assert!(ed.park_client(a));
        assert!(
            ed.clients().all(|c| c.id() != a),
            "a parked client isn't listed"
        );
        let b = ed.attach_client(info("tui@b"));
        assert_ne!(a, b);
        ed.set_acting(b);
        ed.view_mut(view).selection = Selection::point(0);
        assert_eq!(ed.attach_client(info("tui@a")), a, "back by its name");
        ed.set_acting(a);
        assert_eq!((cursor(&ed), ed.mode()), (3, "insert"));
    }

    #[test]
    fn each_client_scrolls_on_its_own() {
        let lines: Vec<String> = (1..=30).map(|n| format!("line {n}")).collect();
        let mut ed = two_clients(&lines.join("\n"));
        let view = ed.focus();
        let first_row = |ed: &mut Editor| {
            let frame = Renderer::new(CellWidth).frame(
                ed,
                Size {
                    width: 20,
                    height: 6,
                },
                &Status::Default { message: None },
                &Plain,
            );
            grid::text_rows(&frame).swap_remove(0)
        };
        ed.set_acting(SECOND);
        let line_20 = lines[..19].iter().map(|l| l.len() + 1).sum::<usize>();
        ed.view_mut(view).selection = Selection::point(line_20);
        assert!(
            first_row(&mut ed).ends_with("line 16"),
            "line 20 at the bottom"
        );
        assert_eq!(ed.view(view).scroll, Scroll { line: 15, row: 0 });
        ed.set_acting(FIRST_CLIENT);
        assert!(first_row(&mut ed).ends_with("line 1"));
        assert_eq!(ed.view(view).scroll, Scroll::default());
        ed.set_acting(SECOND);
        assert!(first_row(&mut ed).ends_with("line 16"), "it stayed there");
    }

    #[test]
    fn followers_share_the_shown_tab_and_each_keeps_its_own_focus() {
        let mut ed = two_clients("hello");
        let first_tab = ed.current_tab().id();
        let pane = ed.focus();
        // The second splits; the first keeps its focus, and sees both.
        ed.set_acting(SECOND);
        let split = ed.split_pane(pane, Direction::Right, None).unwrap();
        assert_eq!(ed.focus(), split);
        ed.set_acting(FIRST_CLIENT);
        assert_eq!(ed.focus(), pane, "its own focus");
        assert_eq!(ed.current_tab().panes(), [pane, split]);

        // The first opens a tab: the second is shown it too, and its focus
        // moves there, as what it had focused isn't shown any more.
        let tab = ed.new_tab(None);
        let new_pane = ed.focus();
        ed.set_acting(SECOND);
        assert_eq!(ed.current_tab().id(), tab);
        assert_eq!(ed.focus(), new_pane);

        // Back to the first tab: the first follows, with focus on its own
        // active pane there.
        assert!(ed.switch_tab(first_tab));
        assert_eq!(ed.focus(), split, "the second's active pane");
        ed.set_acting(FIRST_CLIENT);
        assert_eq!(ed.current_tab().id(), first_tab);
        assert_eq!(ed.focus(), pane, "the first's");
    }

    #[test]
    fn followers_share_the_shown_project() {
        let mut ed = two_clients("hello");
        let first = ed.current_project().id();
        let second = ed.open_project("/elsewhere".into());
        ed.set_acting(SECOND);
        assert_eq!(ed.current_project().id(), second);
        assert_eq!(ed.focus(), ed.main());
        assert!(ed.switch_project(first));
        ed.set_acting(FIRST_CLIENT);
        assert_eq!(ed.current_project().id(), first);
    }

    #[test]
    fn zoom_is_each_clients_own_even_while_following() {
        let mut ed = two_clients("hello");
        let pane = ed.focus();
        ed.split_pane(pane, Direction::Down, None).unwrap();
        ed.set_zoomed(true);
        assert!(ed.current_tab().zoomed());
        ed.set_acting(SECOND);
        assert!(!ed.current_tab().zoomed(), "the other's isn't");
        let area = Rect {
            x: 0,
            y: 0,
            width: 20,
            height: 9,
        };
        assert_eq!(ed.current_tab().place(area).0.len(), 2);
    }

    #[test]
    fn an_independent_client_lays_out_on_its_own_from_a_copy() {
        let mut ed = two_clients("hello");
        let pane = ed.focus();
        let buffer = ed.view(pane).buffer;
        ed.set_acting(SECOND);
        ed.view_mut(pane).selection = Selection::point(3);
        let change = ed.set_layout(SECOND, ClientLayout::Independent).unwrap();
        assert!(
            ed.set_layout(SECOND, ClientLayout::Independent).is_none(),
            "it is already"
        );
        assert_eq!(
            ed.client_state(SECOND).unwrap().layout(),
            ClientLayout::Independent
        );
        let [(original, copy)] = change.opened[..] else {
            panic!("one pane copied: {change:?}");
        };
        assert_eq!(original, pane);
        assert_ne!(copy, pane);
        // Its focus and cursor went over to the copy, of the same buffer.
        assert_eq!(ed.focus(), copy);
        assert_eq!(ed.view(copy).buffer, buffer);
        assert_eq!(cursor(&ed), 3);

        // Its tabs and panes are its own now.
        let tab = ed.new_tab(None);
        ed.split_pane(ed.focus(), Direction::Right, None).unwrap();
        ed.set_acting(FIRST_CLIENT);
        assert_eq!(ed.tabs().len(), 1, "the first has one tab still");
        assert_eq!(ed.current_tab().panes(), [pane]);
        assert!(!ed.switch_tab(tab), "another layout's tab");
        let own = ed.new_tab(None);
        ed.set_acting(SECOND);
        assert_eq!(ed.current_tab().id(), tab, "the first's tab isn't shown");
        assert_eq!(ed.tabs().len(), 2);
        assert!(ed.tabs().iter().all(|t| t.id() != own));
    }

    #[test]
    fn going_back_to_following_closes_its_own_views_and_keeps_their_buffers() {
        let mut ed = two_clients("hello");
        let pane = ed.focus();
        ed.set_acting(SECOND);
        ed.set_layout(SECOND, ClientLayout::Independent).unwrap();
        let copy = ed.focus();
        let scratch = ed.create_buffer("scratch", "notes");
        ed.new_tab(Some(scratch));
        let in_tab = ed.focus();
        let change = ed.set_layout(SECOND, ClientLayout::Follow).unwrap();
        let mut closed = change.closed.clone();
        closed.sort();
        assert_eq!(closed, [copy, in_tab]);
        assert!(change.opened.is_empty());
        assert!(ed.find_view(copy).is_none() && ed.find_view(in_tab).is_none());
        assert!(ed.find_buffer(scratch).is_some(), "the buffer stays");
        assert_eq!(ed.focus(), pane, "back on the shared pane");
        assert_eq!(
            ed.client_state(SECOND).unwrap().layout(),
            ClientLayout::Follow
        );
        ed.set_acting(FIRST_CLIENT);
        assert_eq!(ed.focus(), pane);
    }

    #[test]
    fn floats_of_a_tab_are_copied_with_it_and_floats_over_every_tab_are_not() {
        let mut ed = two_clients("hello");
        let terminal = ed.create_buffer("terminal", "");
        // One belonging to the tab, and one shared over every tab.
        let options = |tab| FloatOptions {
            title: None,
            width: Extent::Cells(10),
            height: Extent::Cells(3),
            anchor: Anchor::Center,
            focus: false,
            x: None,
            y: None,
            tab,
            label: None,
            footer: None,
            border: true,
            hidden: false,
            shared: !tab,
        };
        let in_tab = ed.float(terminal, options(true));
        let over_all = ed.float(terminal, options(false));
        let change = ed.set_layout(SECOND, ClientLayout::Independent).unwrap();
        let float_copy = change
            .opened
            .iter()
            .find(|(original, _)| *original == in_tab)
            .map(|(_, copy)| *copy)
            .expect("the tab's float is copied");
        assert!(
            change
                .opened
                .iter()
                .all(|(original, _)| *original != over_all)
        );
        let shown = |ed: &Editor| ed.floats().iter().map(|f| f.view).collect::<Vec<_>>();
        assert_eq!(shown(&ed), [in_tab, over_all], "the first's");
        ed.set_acting(SECOND);
        assert_eq!(shown(&ed), [over_all, float_copy], "the second's");
        let change = ed.set_layout(SECOND, ClientLayout::Follow).unwrap();
        assert!(change.closed.contains(&float_copy));
        assert_eq!(shown(&ed), [in_tab, over_all]);
    }

    #[test]
    fn an_independent_clients_cursor_shows_where_it_works_in_the_same_buffer() {
        let mut ed = two_clients("hello");
        let pane = ed.focus();
        ed.set_acting(SECOND);
        ed.set_layout(SECOND, ClientLayout::Independent).unwrap();
        let copy = ed.focus();
        ed.view_mut(copy).selection = Selection::point(4);
        ed.set_acting(FIRST_CLIENT);
        let peers: Vec<_> = ed
            .peers(pane)
            .map(|(c, v)| (c.id(), v.selection.primary().head))
            .collect();
        assert_eq!(peers, [(SECOND, 4)]);
        ed.set_acting(SECOND);
        let peers: Vec<_> = ed.peers(copy).map(|(c, _)| c.id()).collect();
        assert_eq!(peers, [FIRST_CLIENT], "the first's, in its own pane");
    }

    #[test]
    fn a_new_client_follows_even_when_the_last_active_one_is_independent() {
        let mut ed = super::editor("hello");
        let pane = ed.focus();
        ed.set_layout(FIRST_CLIENT, ClientLayout::Independent)
            .unwrap();
        let info = ClientInfo {
            name: "tui@b".to_owned(),
            kind: "tui".to_owned(),
            remote: false,
        };
        let b = ed.attach_client(info);
        ed.set_acting(b);
        assert_eq!(ed.client_state(b).unwrap().layout(), ClientLayout::Follow);
        assert_eq!(ed.focus(), pane, "on the shared pane");
    }

    #[test]
    fn two_clients_of_one_kind_on_one_machine_get_names_apart_and_come_back_by_them() {
        let mut ed = super::editor("hello");
        let info = |name: &str| ClientInfo {
            name: name.to_owned(),
            kind: "tui".to_owned(),
            remote: false,
        };
        let name = |ed: &Editor, id| ed.client_state(id).unwrap().name().to_owned();
        let a = ed.attach_client(info("tui@desk"));
        let b = ed.attach_client(info("tui@desk"));
        let c = ed.attach_client(info("tui@desk"));
        assert_eq!(
            [name(&ed, a), name(&ed, b), name(&ed, c)],
            ["tui@desk", "tui@desk#2", "tui@desk#3"]
        );
        ed.set_acting(b);
        ed.set_mode("insert");
        // The second leaves and comes back: its name is the first free one,
        // with its state.
        ed.park_client(b);
        assert_eq!(ed.attach_client(info("tui@desk")), b);
        ed.set_acting(b);
        assert_eq!((name(&ed, b).as_str(), ed.mode()), ("tui@desk#2", "insert"));
        // With the first gone, a new one takes its name and state.
        ed.park_client(a);
        assert_eq!(ed.attach_client(info("tui@desk")), a);
        assert_eq!(name(&ed, a), "tui@desk");
    }

    #[test]
    fn a_focus_moved_by_another_client_drops_half_typed_keys_and_says_so() {
        let mut ed = two_clients("hello");
        ed.keymap_mut()
            .bind(
                greed_core::keymap::Layer::mode("helix"),
                &super::keys("g g"),
                "goto-start",
                "core",
            )
            .unwrap();
        ed.set_acting(SECOND);
        assert_eq!(
            ed.press(greed_core::keymap::Key::char('g')),
            greed_core::KeyOutcome::Pending
        );
        // Its own moves aren't moves under it.
        let pane = ed.focus();
        ed.split_pane(pane, Direction::Right, None).unwrap();
        assert!(!ed.take_moved());
        assert_eq!(ed.pending().len(), 1, "still half typed");
        // The first shows another tab, so the second's focus moves under it.
        ed.set_acting(FIRST_CLIENT);
        ed.new_tab(None);
        let new_pane = ed.focus();
        assert!(!ed.take_moved(), "the first's focus moved by its own doing");
        ed.set_acting(SECOND);
        assert_eq!(ed.focus(), new_pane);
        assert!(ed.pending().is_empty(), "what it typed halfway is dropped");
        assert!(ed.take_moved());
        assert!(!ed.take_moved(), "told once");
    }

    #[test]
    fn a_focus_still_shown_stays_where_it_is() {
        let mut ed = two_clients("hello");
        let pane = ed.focus();
        ed.set_acting(SECOND);
        let split = ed.split_pane(pane, Direction::Right, None).unwrap();
        ed.set_acting(FIRST_CLIENT);
        ed.split_pane(pane, Direction::Down, None).unwrap();
        assert!(ed.close(pane));
        ed.set_acting(SECOND);
        assert_eq!(ed.focus(), split);
        assert!(!ed.take_moved());
        // Closing what it has focused moves it.
        ed.set_acting(FIRST_CLIENT);
        assert!(ed.close(split));
        ed.set_acting(SECOND);
        assert_ne!(ed.focus(), split);
        assert!(ed.take_moved());
    }

    #[test]
    fn following_again_goes_on_in_the_same_buffer_where_the_others_show_it() {
        let mut ed = two_clients("hello");
        let pane = ed.focus();
        let notes = ed.create_buffer("file", "notes");
        let beside = ed.split_pane(pane, Direction::Right, Some(notes)).unwrap();
        ed.set_focus(pane);
        ed.set_acting(SECOND);
        ed.set_layout(SECOND, ClientLayout::Independent).unwrap();
        // In its own copy of the pane with the notes.
        let copy = ed
            .current_tab()
            .panes()
            .into_iter()
            .find(|v| ed.view(*v).buffer == notes)
            .unwrap();
        ed.set_focus(copy);
        ed.set_layout(SECOND, ClientLayout::Follow).unwrap();
        assert_eq!(ed.focus(), beside, "the shared pane with the notes");
        assert_eq!(ed.current_tab().active(), beside);
        assert!(ed.take_moved());
    }
}
