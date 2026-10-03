//! Command line commands plugins add with `kern.cli`.

use kern_core::Editor;
use kern_core::luau::Host;
use kern_text::ClientId;

const COMMANDS: &str = r#"
local kern = require("@kern")
kern.cli({
    name = "greet",
    doc = "Say hello",
    usage = "[NAME]",
    run = function(args)
        kern.echo("thinking")
        kern.sleep(0.01)
        local done = kern.process.run({ "echo", args[1] or "there" })
        return "hello " .. string.gsub(done.stdout, "\n", "")
    end,
})
kern.cli({ name = "quiet", run = function() end })
kern.cli({ name = "fail", run = function() error("no luck", 0) end })
kern.cli({
    name = "stuck",
    run = function()
        kern.signal().wait()
    end,
})
"#;

fn host() -> Host {
    let host = Host::new(Editor::new(ClientId(1))).unwrap();
    host.load_str("user/commands", COMMANDS).unwrap();
    host
}

fn run(host: &Host, name: &str, args: &[&str]) -> (Result<Option<String>, String>, Vec<String>) {
    let mut said = Vec::new();
    let args = args.iter().map(ToString::to_string).collect();
    let returned = host
        .run_cli(name, args, &mut |message| said.push(message.to_owned()))
        .map_err(|err| err.brief());
    (returned, said)
}

#[test]
fn a_command_waits_and_its_echoes_and_answer_come_back() {
    let (returned, said) = run(&host(), "greet", &["world"]);
    assert_eq!(returned, Ok(Some("hello world".to_owned())));
    assert_eq!(said, ["thinking"]);
}

#[test]
fn a_command_returning_nothing_or_failing_says_so() {
    let host = host();
    assert_eq!(run(&host, "quiet", &[]).0, Ok(None));
    assert_eq!(run(&host, "fail", &[]).0, Err("no luck".to_owned()));
    let (stuck, _) = run(&host, "stuck", &[]);
    assert!(stuck.unwrap_err().contains("nothing will bring"));
    assert!(
        run(&host, "missing", &[])
            .0
            .unwrap_err()
            .contains("no command")
    );
}

#[test]
fn commands_are_listed_and_go_with_their_plugin() {
    let host = host();
    let names: Vec<_> = host.cli_commands().into_iter().map(|(n, _, _)| n).collect();
    assert_eq!(names, ["fail", "greet", "quiet", "stuck"]);
    let (_, usage, doc) = &host.cli_commands()[1];
    assert_eq!((usage.as_str(), doc.as_str()), ("[NAME]", "Say hello"));
    host.unload("user/commands").unwrap();
    assert!(host.cli_commands().is_empty());
}
