use kern_core::keymap::{Key, KeyCode, Keymap, Layer, Mods, ParseError, Resolution};

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
