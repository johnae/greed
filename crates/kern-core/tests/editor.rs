use kern_core::keymap::{Key, Layer};
use kern_core::{CursorShape, Editor, KeyOutcome};
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
        focus: true,
        x: None,
        y: None,
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

#[test]
fn floats_can_leave_focus_where_it_was() {
    let mut ed = editor("");
    let main = ed.main();
    let hints = ed.create_buffer("hints", "");
    ed.float(
        hints,
        kern_core::FloatOptions {
            focus: false,
            ..float_options()
        },
    );
    assert_eq!(ed.focus(), main);
    assert_eq!(ed.floats().len(), 1);
}

#[test]
fn closing_a_float_gives_focus_back_to_the_view_that_had_it() {
    use kern_core::{Extent, PanelOptions, Side};
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
    let dir = std::env::temp_dir().join(format!("kern-save-as-{}", std::process::id()));
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
    let normal = Layer::mode("normal");
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

    ed.keymap_mut().enable_counts("normal", "core");
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
    ed.set_mode("normal");
    assert_eq!(press(&mut ed, "j"), command("down", "j", None));

    ed.keymap_mut().remove_owned_by("core");
    assert_eq!(press(&mut ed, "3"), KeyOutcome::Unbound(keys("3")));
}

#[test]
fn decorations_follow_edits_and_are_replaced_per_namespace() {
    use kern_core::Mark;
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
    let (py, _) = ed.open("file", "", Some("tool.py".into()));
    let (make, _) = ed.open("file", "", Some("Makefile".into()));
    assert_eq!(ed.buffer(rust).language(), Some("rust"), "built in");
    assert_eq!(ed.buffer(py).language(), None);

    ed.set_file_type("python", &["py".into(), "pyi".into()], &[]);
    ed.set_file_type("make", &[], &["Makefile".into()]);
    assert_eq!(
        ed.buffer(py).language(),
        Some("python"),
        "open buffers follow"
    );
    assert_eq!(ed.buffer(make).language(), Some("make"));
    assert_eq!(
        ed.file_type(std::path::Path::new("a/b.pyi")).as_deref(),
        Some("python")
    );

    // Setting a language again replaces its extensions.
    ed.set_file_type("python", &["pyw".into()], &[]);
    assert_eq!(ed.buffer(py).language(), None);
    // A language set on the buffer still wins.
    ed.set_language(rust, Some("text".into()));
    ed.set_file_type("rust", &["rs".into()], &[]);
    assert_eq!(ed.buffer(rust).language(), Some("text"));
}

fn panel_options() -> kern_core::PanelOptions {
    kern_core::PanelOptions {
        side: kern_core::Side::Left,
        width: kern_core::Extent::Cells(10),
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
    assert!(!ed.switch_project(kern_core::ProjectId(999)));
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
fn files_opened_belong_to_the_shown_project() {
    let dir = std::env::temp_dir().join(format!("kern-project-file-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("a.txt"), "a").unwrap();
    let mut ed = editor("");
    let project = ed.open_project(dir.clone());
    let buffer = ed.open_file(&dir.join("a.txt")).unwrap();
    assert_eq!(ed.buffer_project(buffer), Some(project));
    std::fs::remove_dir_all(&dir).unwrap();
}
