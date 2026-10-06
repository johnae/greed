use greed_core::registry::{Command, OptionDef, Registry, Source, Value};

type Reg = Registry<&'static str>;

fn cmd(name: &str, owner: &str, handler: &'static str) -> Command<&'static str> {
    Command {
        name: name.into(),
        doc: format!("{name} from {owner}").into(),
        args: Vec::new(),
        owner: owner.into(),
        source: Some(Source {
            file: format!("{owner}/init.luau").into(),
            line: 1,
        }),
        handler,
    }
}

#[test]
fn commands_are_found_by_name() {
    let mut reg = Reg::default();
    reg.add_command(cmd("save", "core", "save-v1"));
    let save = reg.command("save").unwrap();
    assert_eq!(save.handler, "save-v1");
    assert_eq!(&*save.owner, "core");
    assert!(reg.command("nope").is_none());
}

#[test]
fn later_definitions_override_and_are_listed() {
    let mut reg = Reg::default();
    reg.add_command(cmd("save", "core", "core"));
    reg.add_command(cmd("save", "user/me", "mine"));
    assert_eq!(reg.command("save").unwrap().handler, "mine");
    let owners: Vec<&str> = reg.definitions("save").iter().map(|c| &*c.owner).collect();
    assert_eq!(owners, ["core", "user/me"]);
}

#[test]
fn removing_a_plugin_restores_what_it_overrode() {
    let mut reg = Reg::default();
    reg.add_command(cmd("save", "core", "core"));
    reg.add_command(cmd("save", "user/me", "mine"));
    reg.add_command(cmd("mine-only", "user/me", "x"));
    reg.remove_owned_by("user/me");
    assert_eq!(reg.command("save").unwrap().handler, "core");
    assert!(reg.command("mine-only").is_none());
}

#[test]
fn commands_are_listed_sorted() {
    let mut reg = Reg::default();
    reg.add_command(cmd("b", "core", ""));
    reg.add_command(cmd("a", "core", ""));
    reg.add_command(cmd("b", "user/me", ""));
    let names: Vec<&str> = reg.commands().map(|c| &*c.name).collect();
    assert_eq!(names, ["a", "b"]);
}

#[test]
fn event_handlers_run_in_registration_order_and_are_owned() {
    let mut reg = Reg::default();
    reg.on("buffer.saved", "core", None, "first");
    reg.on("buffer.saved", "user/me", None, "second");
    reg.on("buffer.opened", "core", None, "other");
    let handlers: Vec<&str> = reg
        .handlers("buffer.saved")
        .iter()
        .map(|h| h.handler)
        .collect();
    assert_eq!(handlers, ["first", "second"]);
    reg.remove_owned_by("user/me");
    assert_eq!(reg.handlers("buffer.saved").len(), 1);
    assert!(reg.handlers("mode.changed").is_empty());
}

#[test]
fn options_are_typed() {
    let mut reg = Reg::default();
    reg.define_option(OptionDef {
        name: "tab-width".into(),
        doc: "Spaces per tab".into(),
        owner: "core".into(),
        source: None,
        default: Value::Int(4),
    });
    assert_eq!(reg.option("tab-width"), Some(&Value::Int(4)));
    reg.set_option("tab-width", Value::Int(2)).unwrap();
    assert_eq!(reg.option("tab-width"), Some(&Value::Int(2)));
    assert!(reg.set_option("tab-width", Value::Bool(true)).is_err());
    assert!(reg.set_option("missing", Value::Int(1)).is_err());
}

#[test]
fn removing_the_owner_removes_its_options() {
    let mut reg = Reg::default();
    reg.define_option(OptionDef {
        name: "wrap".into(),
        doc: String::new().into(),
        owner: "user/me".into(),
        source: None,
        default: Value::Bool(false),
    });
    reg.remove_owned_by("user/me");
    assert_eq!(reg.option("wrap"), None);
}

fn option(name: &str, owner: &str, default: Value) -> OptionDef {
    OptionDef {
        name: name.into(),
        doc: String::new().into(),
        owner: owner.into(),
        source: None,
        default,
    }
}

#[test]
fn defining_an_option_again_keeps_what_it_was_set_to() {
    let mut reg = Reg::default();
    reg.define_option(option("width", "user/me", Value::Int(4)));
    reg.set_option_by("width", Value::Int(2), Some("config".into()))
        .unwrap();
    // As when the plugin reloads.
    reg.remove_owned_by("user/me");
    reg.define_option(option("width", "user/me", Value::Int(8)));
    assert_eq!(reg.option("width"), Some(&Value::Int(2)));
    let state = reg.option_states().next().unwrap();
    assert_eq!(state.set_by.map(|by| &**by), Some("config"));
    // Without removing it first, too.
    reg.define_option(option("width", "user/me", Value::Int(8)));
    assert_eq!(reg.option("width"), Some(&Value::Int(2)));
}

#[test]
fn an_option_never_set_takes_its_new_default() {
    let mut reg = Reg::default();
    reg.define_option(option("width", "user/me", Value::Int(4)));
    reg.remove_owned_by("user/me");
    reg.define_option(option("width", "user/me", Value::Int(8)));
    assert_eq!(reg.option("width"), Some(&Value::Int(8)));
    assert!(reg.option_states().next().unwrap().set_by.is_none());
}

#[test]
fn an_option_defined_again_with_another_type_takes_its_default() {
    let mut reg = Reg::default();
    reg.define_option(option("wrap", "user/me", Value::Int(1)));
    reg.set_option("wrap", Value::Int(0)).unwrap();
    reg.remove_owned_by("user/me");
    reg.define_option(option("wrap", "user/me", Value::Bool(true)));
    assert_eq!(reg.option("wrap"), Some(&Value::Bool(true)));
    reg.set_option("wrap", Value::Bool(false)).unwrap();
    reg.define_option(option("wrap", "user/me", Value::String("on".into())));
    assert_eq!(reg.option("wrap"), Some(&Value::String("on".into())));
}
