use greed_core::keymap::{Key, KeyCode, Keymap, Layer, Mods, ParseError, Resolution};

fn keys(s: &str) -> Vec<Key> {
    Key::parse_sequence(s).unwrap()
}

#[test]
fn parses_plain_named_and_modified_keys() {
    assert_eq!(Key::parse("g"), Ok(Key::char('g')));
    assert_eq!(Key::parse("G"), Ok(Key::char('G')));
    assert_eq!(Key::parse("space"), Ok(Key::char(' ')));
    assert_eq!(Key::parse("enter"), Ok(Key::named(KeyCode::Enter)));
    assert_eq!(Key::parse("f5"), Ok(Key::named(KeyCode::F(5))));
    assert_eq!(
        Key::parse("ctrl-alt-x"),
        Ok(Key {
            code: KeyCode::Char('x'),
            mods: Mods::CTRL | Mods::ALT,
        })
    );
    assert_eq!(Key::parse("ctrl--"), Ok(Key::char('-').with(Mods::CTRL)));
    assert_eq!(Key::parse("-"), Ok(Key::char('-')));
}

#[test]
fn rejects_unknown_keys() {
    assert_eq!(
        Key::parse("hyper-x"),
        Err(ParseError::UnknownModifier("hyper".into()))
    );
    assert_eq!(
        Key::parse("enterr"),
        Err(ParseError::UnknownKey("enterr".into()))
    );
    assert_eq!(Key::parse(""), Err(ParseError::Empty));
    assert_eq!(Key::parse_sequence("   "), Err(ParseError::Empty));
}

#[test]
fn keys_display_in_parse_syntax() {
    for s in [
        "g",
        "space",
        "ctrl-alt-x",
        "enter",
        "f12",
        "shift-tab",
        "ctrl--",
    ] {
        assert_eq!(Key::parse(s).unwrap().to_string(), s);
    }
}

#[test]
fn resolves_sequences_through_a_trie() {
    let mut km = Keymap::default();
    km.bind(Layer::mode("normal"), &keys("g g"), "goto-start", "core")
        .unwrap();
    km.bind(Layer::mode("normal"), &keys("g e"), "goto-end", "core")
        .unwrap();
    km.bind(Layer::mode("normal"), &keys("w"), "next-word", "core")
        .unwrap();

    let normal = |s: &str| km.resolve("normal", "file", &keys(s));
    assert_eq!(normal("w"), Resolution::Command("next-word".into()));
    assert_eq!(normal("g"), Resolution::Pending);
    assert_eq!(normal("g g"), Resolution::Command("goto-start".into()));
    assert_eq!(normal("g x"), Resolution::Unbound);
    assert_eq!(normal("x"), Resolution::Unbound);
    assert_eq!(
        km.resolve("insert", "file", &keys("w")),
        Resolution::Unbound
    );
}

#[test]
fn more_specific_layers_win() {
    let mut km = Keymap::default();
    km.bind(Layer::global(), &keys("ctrl-s"), "save", "core")
        .unwrap();
    km.bind(Layer::mode("normal"), &keys("q"), "quit", "core")
        .unwrap();
    km.bind(Layer::kind("terminal"), &keys("q"), "term-q", "term")
        .unwrap();
    km.bind(
        Layer::mode_kind("normal", "terminal"),
        &keys("ctrl-s"),
        "term-save",
        "term",
    )
    .unwrap();

    assert_eq!(
        km.resolve("normal", "file", &keys("q")),
        Resolution::Command("quit".into())
    );
    assert_eq!(
        km.resolve("insert", "terminal", &keys("q")),
        Resolution::Command("term-q".into())
    );
    assert_eq!(
        km.resolve("normal", "terminal", &keys("q")),
        Resolution::Command("quit".into())
    );
    assert_eq!(
        km.resolve("normal", "terminal", &keys("ctrl-s")),
        Resolution::Command("term-save".into())
    );
    assert_eq!(
        km.resolve("insert", "file", &keys("ctrl-s")),
        Resolution::Command("save".into())
    );
}

#[test]
fn a_prefix_in_any_layer_keeps_the_sequence_pending() {
    let mut km = Keymap::default();
    km.bind(Layer::global(), &keys("space f"), "files", "core")
        .unwrap();
    km.bind(Layer::mode("normal"), &keys("x"), "x", "core")
        .unwrap();
    assert_eq!(
        km.resolve("normal", "file", &keys("space")),
        Resolution::Pending
    );
}

#[test]
fn binding_through_an_existing_command_or_prefix_fails() {
    let mut km = Keymap::default();
    let normal = Layer::mode("normal");
    km.bind(normal.clone(), &keys("g"), "g", "core").unwrap();
    assert!(km.bind(normal.clone(), &keys("g g"), "gg", "core").is_err());
    km.bind(normal.clone(), &keys("z z"), "zz", "core").unwrap();
    assert!(km.bind(normal.clone(), &keys("z"), "z", "core").is_err());
}

#[test]
fn rebinding_replaces_and_removing_a_plugin_restores() {
    let mut km = Keymap::default();
    let normal = Layer::mode("normal");
    km.bind(normal.clone(), &keys("w"), "next-word", "core")
        .unwrap();
    km.bind(normal.clone(), &keys("w"), "my-word", "user/me")
        .unwrap();
    km.bind(normal.clone(), &keys("m m"), "mine", "user/me")
        .unwrap();
    assert_eq!(
        km.resolve("normal", "file", &keys("w")),
        Resolution::Command("my-word".into())
    );

    km.remove_owned_by("user/me");
    assert_eq!(
        km.resolve("normal", "file", &keys("w")),
        Resolution::Command("next-word".into())
    );
    assert_eq!(
        km.resolve("normal", "file", &keys("m")),
        Resolution::Unbound
    );
}

#[test]
fn describe_lists_where_a_key_is_bound() {
    let mut km = Keymap::default();
    km.bind(Layer::global(), &keys("q"), "quit", "core")
        .unwrap();
    km.bind(Layer::mode("normal"), &keys("q"), "quit-normal", "user/me")
        .unwrap();
    let found = km.describe("normal", "file", &keys("q"));
    let summary: Vec<(String, &str, &str)> = found
        .iter()
        .map(|b| (b.layer.to_string(), &*b.command, &*b.owner))
        .collect();
    assert_eq!(
        summary,
        [
            ("normal".to_string(), "quit-normal", "user/me"),
            ("global".to_string(), "quit", "core"),
        ]
    );
}

#[test]
fn fallbacks_are_per_mode_and_owned() {
    let mut km = Keymap::default();
    km.set_fallback("insert", "insert-key", "core");
    km.set_fallback("insert", "my-insert", "user/me");
    assert_eq!(km.fallback("insert").map(|c| &**c), Some("my-insert"));
    assert_eq!(km.fallback("normal"), None);
    km.remove_owned_by("user/me");
    assert_eq!(km.fallback("insert").map(|c| &**c), Some("insert-key"));
    km.remove_owned_by("core");
    assert_eq!(km.fallback("insert"), None);
}

#[test]
fn continuations_list_what_can_follow_a_prefix() {
    use greed_core::keymap::Next;
    let mut km = Keymap::default();
    km.bind(Layer::mode("normal"), &keys("space f"), "files", "core")
        .unwrap();
    km.bind(Layer::mode("normal"), &keys("space w v"), "split", "core")
        .unwrap();
    km.bind(Layer::global(), &keys("space f"), "shadowed", "core")
        .unwrap();
    km.bind(Layer::global(), &keys("space q"), "quit", "core")
        .unwrap();
    km.bind(
        Layer::mode("insert"),
        &keys("space x"),
        "other-mode",
        "core",
    )
    .unwrap();

    let next: Vec<(String, Next)> = km
        .continuations("normal", "file", &keys("space"))
        .into_iter()
        .map(|(k, n)| (k.to_string(), n))
        .collect();
    assert_eq!(
        next,
        [
            ("f".to_string(), Next::Command("files".into())),
            ("q".to_string(), Next::Command("quit".into())),
            ("w".to_string(), Next::Prefix),
        ]
    );
    assert!(km.continuations("normal", "file", &keys("x")).is_empty());
}

#[test]
fn bindings_for_a_command_are_found_in_every_layer() {
    let mut km = Keymap::default();
    km.bind(Layer::mode("normal"), &keys("g g"), "goto-start", "core")
        .unwrap();
    km.bind(
        Layer::mode("insert"),
        &keys("ctrl-home"),
        "goto-start",
        "core",
    )
    .unwrap();
    km.bind(Layer::mode("normal"), &keys("w"), "next-word", "core")
        .unwrap();
    km.bind(Layer::mode("normal"), &keys("x"), "goto-start", "core")
        .unwrap();
    km.bind(Layer::mode("normal"), &keys("x"), "other", "user/me")
        .unwrap();

    let mut found: Vec<String> = km
        .bindings_for("goto-start")
        .into_iter()
        .map(|(layer, keys)| {
            let keys: Vec<String> = keys.iter().map(ToString::to_string).collect();
            format!("{layer}: {}", keys.join(" "))
        })
        .collect();
    found.sort();
    // "x" was rebound, so it no longer runs goto-start.
    assert_eq!(found, ["insert: ctrl-home", "normal: g g"]);
}

#[test]
fn newer_bindings_from_another_plugin_replace_conflicting_ones() {
    let mut km = Keymap::default();
    let normal = Layer::mode("normal");
    km.bind(normal.clone(), &keys("d"), "delete", "core")
        .unwrap();
    km.bind(normal.clone(), &keys("d d"), "delete-line", "vim")
        .unwrap();
    assert_eq!(
        km.resolve("normal", "file", &keys("d")),
        Resolution::Pending
    );
    assert_eq!(
        km.resolve("normal", "file", &keys("d d")),
        Resolution::Command("delete-line".into())
    );
    km.bind(normal.clone(), &keys("d"), "delete-again", "user/me")
        .unwrap();
    assert_eq!(
        km.resolve("normal", "file", &keys("d")),
        Resolution::Command("delete-again".into())
    );

    km.remove_owned_by("user/me");
    km.remove_owned_by("vim");
    assert_eq!(
        km.resolve("normal", "file", &keys("d")),
        Resolution::Command("delete".into())
    );
}

#[test]
fn unbinding_hides_a_key_until_its_owner_goes() {
    let mut km = Keymap::default();
    let normal = Layer::mode("normal");
    km.bind(normal.clone(), &keys("w"), "next-word", "core")
        .unwrap();
    km.bind(normal.clone(), &keys("g g"), "goto-start", "core")
        .unwrap();
    km.unbind(normal.clone(), &keys("w"), "user/me");
    km.unbind(normal.clone(), &keys("g"), "user/me");
    assert_eq!(
        km.resolve("normal", "file", &keys("w")),
        Resolution::Unbound
    );
    assert_eq!(
        km.resolve("normal", "file", &keys("g")),
        Resolution::Unbound
    );
    assert!(km.bindings_for("next-word").is_empty());

    km.remove_owned_by("user/me");
    assert_eq!(
        km.resolve("normal", "file", &keys("w")),
        Resolution::Command("next-word".into())
    );
    assert_eq!(
        km.resolve("normal", "file", &keys("g g")),
        Resolution::Command("goto-start".into())
    );
}

#[test]
fn bindings_made_one_by_one_match_their_log_replayed() {
    let mut km = Keymap::default();
    let normal = Layer::mode("normal");
    km.bind(normal.clone(), &keys("w"), "next-word", "core")
        .unwrap();
    km.bind(normal.clone(), &keys("g g"), "goto-start", "core")
        .unwrap();
    km.bind(normal.clone(), &keys("g e"), "goto-end", "core")
        .unwrap();
    km.unbind(normal.clone(), &keys("g e"), "user/me");
    km.bind(normal.clone(), &keys("g"), "go", "user/other")
        .unwrap();
    km.clear(Layer::global(), "user/me");
    km.bind(Layer::global(), &keys("q"), "quit", "core")
        .unwrap();
    km.bind(normal.clone(), &keys("x"), "delete", "user/me")
        .unwrap();
    let sorted = |km: &Keymap| {
        let mut all: Vec<String> = km
            .bindings()
            .into_iter()
            .map(|binding| format!("{binding:?}"))
            .collect();
        all.sort();
        all
    };
    let one_by_one = sorted(&km);
    assert_eq!(one_by_one.len(), 4, "{one_by_one:?}");
    // Removing a plugin rebuilds the layers it touched from their logs.
    km.bind(normal.clone(), &keys("z"), "later", "user/later")
        .unwrap();
    km.bind(Layer::global(), &keys("z"), "later", "user/later")
        .unwrap();
    km.remove_owned_by("user/later");
    assert_eq!(sorted(&km), one_by_one);
}

#[test]
fn clearing_a_layer_hides_what_was_bound_before() {
    let mut km = Keymap::default();
    let normal = Layer::mode("normal");
    km.bind(normal.clone(), &keys("w"), "next-word", "core")
        .unwrap();
    km.bind(normal.clone(), &keys("x"), "select-line", "core")
        .unwrap();
    km.bind(Layer::global(), &keys("ctrl-s"), "save", "core")
        .unwrap();
    km.clear(normal.clone(), "vim");
    km.bind(normal.clone(), &keys("w"), "vim-word", "vim")
        .unwrap();
    km.bind(normal.clone(), &keys("x"), "delete-char", "user/me")
        .unwrap();
    assert_eq!(
        km.resolve("normal", "file", &keys("w")),
        Resolution::Command("vim-word".into())
    );
    assert_eq!(
        km.resolve("normal", "file", &keys("x")),
        Resolution::Command("delete-char".into())
    );
    // Other layers are untouched.
    assert_eq!(
        km.resolve("normal", "file", &keys("ctrl-s")),
        Resolution::Command("save".into())
    );

    km.remove_owned_by("vim");
    assert_eq!(
        km.resolve("normal", "file", &keys("w")),
        Resolution::Command("next-word".into())
    );
    assert_eq!(
        km.resolve("normal", "file", &keys("x")),
        Resolution::Command("delete-char".into())
    );
}

#[test]
fn a_mode_can_fall_back_to_another_under_some_prefixes() {
    use greed_core::keymap::Next;
    let command = |km: &Keymap, mode: &str, k: &str| match km.resolve(mode, "file", &keys(k)) {
        Resolution::Command(c) => Some(c.to_string()),
        Resolution::Pending | Resolution::Unbound => None,
    };
    let mut km = Keymap::default();
    for (k, c) in [
        ("space f", "files"),
        ("w", "next-word"),
        ("g d", "definition"),
        ("g g", "start"),
    ] {
        km.bind(Layer::mode("normal"), &keys(k), c, "core").unwrap();
    }
    km.bind(Layer::mode("vim"), &keys("w"), "vim-word", "vim")
        .unwrap();
    km.inherit("vim", "normal", vec![keys("space"), keys("g d")], "vim");

    assert_eq!(command(&km, "vim", "space f").as_deref(), Some("files"));
    assert_eq!(command(&km, "vim", "g d").as_deref(), Some("definition"));
    assert_eq!(
        command(&km, "vim", "w").as_deref(),
        Some("vim-word"),
        "its own come first"
    );
    assert_eq!(command(&km, "vim", "g g"), None, "outside the prefixes");
    let after_g: Vec<(String, Next)> = km
        .continuations("vim", "file", &keys("g"))
        .into_iter()
        .map(|(k, n)| (k.to_string(), n))
        .collect();
    assert_eq!(
        after_g,
        [("d".to_string(), Next::Command("definition".into()))]
    );

    km.inherit("all", "normal", Vec::new(), "other");
    assert_eq!(
        command(&km, "all", "g g").as_deref(),
        Some("start"),
        "no prefixes: everything"
    );

    km.remove_owned_by("vim");
    assert_eq!(command(&km, "vim", "space f"), None, "gone with its owner");
    assert_eq!(command(&km, "all", "w").as_deref(), Some("next-word"));
}

#[test]
fn a_mode_can_use_another_modes_keys_for_buffer_kinds_first() {
    let mut km = Keymap::default();
    km.bind(
        Layer::mode_kind("normal", "tree"),
        &keys("q"),
        "tree-close",
        "tree",
    )
    .unwrap();
    km.bind(Layer::mode("vim"), &keys("q"), "vim-macro", "vim")
        .unwrap();
    km.inherit_kinds("vim", "normal", "vim");

    let resolve = |km: &Keymap, kind: &str| match km.resolve("vim", kind, &keys("q")) {
        Resolution::Command(command) => Some(command.to_string()),
        _ => None,
    };
    assert_eq!(resolve(&km, "tree").as_deref(), Some("tree-close"));
    assert_eq!(resolve(&km, "file").as_deref(), Some("vim-macro"));
    km.remove_owned_by("vim");
    assert_eq!(resolve(&km, "tree"), None, "gone with its owner");
}

#[test]
fn a_mode_without_a_fallback_uses_the_one_of_a_mode_it_inherits_in_full() {
    let mut km = Keymap::default();
    km.set_fallback("insert", "insert-char", "core");
    km.inherit("completion-insert", "insert", vec![], "lsp");
    km.inherit("vim", "insert", vec![keys("space")], "vim");
    assert_eq!(
        km.fallback("completion-insert").map(|c| &**c),
        Some("insert-char")
    );
    assert_eq!(km.fallback("vim"), None, "only some keys are inherited");
    km.set_fallback("completion-insert", "own", "lsp");
    assert_eq!(km.fallback("completion-insert").map(|c| &**c), Some("own"));
    km.inherit("a", "b", vec![], "x");
    km.inherit("b", "a", vec![], "x");
    assert_eq!(km.fallback("a"), None, "a loop ends");
}

#[test]
fn inheriting_kinds_twice_for_one_owner_adds_it_once() {
    let mut km = Keymap::default();
    km.bind(
        Layer::mode_kind("normal", "tree"),
        &keys("q"),
        "tree-close",
        "tree",
    )
    .unwrap();
    km.inherit_kinds("mine", "normal", "core");
    km.inherit_kinds("mine", "normal", "core");
    km.inherit_kinds("mine", "normal", "mine");
    km.remove_owned_by("mine");
    assert!(matches!(
        km.resolve("mine", "tree", &keys("q")),
        Resolution::Command(_)
    ));
    km.remove_owned_by("core");
    assert!(matches!(
        km.resolve("mine", "tree", &keys("q")),
        Resolution::Unbound
    ));
}
