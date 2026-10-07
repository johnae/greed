use std::path::{Path, PathBuf};

use greed_core::Editor;
use greed_core::luau::{Host, HostError};
use greed_text::ClientId;

/// A temporary folder for one test, removed when dropped.
struct Temp(PathBuf);

impl Temp {
    fn new(label: &str) -> Temp {
        let dir =
            std::env::temp_dir().join(format!("greed-approvals-{label}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Temp(dir)
    }

    /// A plugin called `name` in a folder of its own, declaring
    /// `capabilities` and requiring `requires`.
    fn plugin(&self, name: &str, capabilities: &str, requires: &str) -> PathBuf {
        let dir = self.0.join(name);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("plugin.toml"),
            format!(
                "name = \"{name}\"\nrequires = [{requires}]\ncapabilities = [{capabilities}]\n"
            ),
        )
        .unwrap();
        std::fs::write(dir.join("init.luau"), "return {}\n").unwrap();
        dir
    }
}

impl Drop for Temp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn host(store: &Path, shipped: &Path) -> Host {
    let host = Host::new(Editor::new(ClientId(1))).unwrap();
    host.require_approval(store.to_owned(), vec![shipped.to_owned()]);
    host
}

fn loaded(host: &Host) -> String {
    host.eval("table.concat(require('@greed').plugin.list(), ',')")
        .unwrap()
}

#[test]
fn a_plugin_declaring_capabilities_waits_until_approved() {
    let temp = Temp::new("wait");
    let store = temp.0.join("state/approved.json");
    let plain = temp.plugin("plain", "", "");
    let runner = temp.plugin("runner", "\"proc\"", "");
    let host = host(&store, &temp.0.join("shipped"));
    host.load_dirs(&[plain, runner.clone()]).unwrap();
    assert_eq!(
        loaded(&host),
        "plain",
        "a plugin using nothing loads at once"
    );

    let waiting = host
        .eval("require('@greed').plugin.pending()[1].missing[1]")
        .unwrap();
    assert_eq!(waiting, "proc");
    let approved = host
        .eval(&format!(
            "require('@greed').plugin.approve({:?})",
            runner.to_str().unwrap()
        ))
        .unwrap();
    assert_eq!(approved, "runner");
    assert_eq!(
        host.eval("#require('@greed').plugin.pending()").unwrap(),
        "0"
    );

    // Remembered: a new editor loads it straight away.
    let again = self::host(&store, &temp.0.join("shipped"));
    again.load_dirs(std::slice::from_ref(&runner)).unwrap();
    assert_eq!(loaded(&again), "runner");

    // Asking for more waits again.
    temp.plugin("runner", "\"proc\", \"net\"", "");
    let more = self::host(&store, &temp.0.join("shipped"));
    match more.load_dir(&runner) {
        Err(HostError::NotApproved { missing, .. }) => assert_eq!(missing, ["net"]),
        other => panic!("expected to wait for net, got {other:?}"),
    }
}

#[test]
fn shipped_plugins_need_no_approval_and_dependents_wait_with_the_plugin() {
    let temp = Temp::new("deps");
    let store = temp.0.join("approved.json");
    let shipped = temp.0.join("shipped");
    std::fs::create_dir_all(&shipped).unwrap();
    let own = {
        let dir = shipped.join("own");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("plugin.toml"),
            "name = \"own\"\ncapabilities = [\"proc\"]\n",
        )
        .unwrap();
        std::fs::write(dir.join("init.luau"), "return {}\n").unwrap();
        dir
    };
    let base = temp.plugin("base", "\"fs.read\"", "");
    let user = temp.plugin("user", "", "\"base\"");
    let host = host(&store, &shipped);
    host.load_dirs(&[own, base.clone(), user]).unwrap();
    assert_eq!(loaded(&host), "own");
    host.eval(&format!(
        "require('@greed').plugin.approve({:?})",
        base.to_str().unwrap()
    ))
    .unwrap();
    assert_eq!(
        loaded(&host),
        "base,own,user",
        "approving base loads what waited for it"
    );
}

/// Checks the plugin in `dir` from a command, as an agent trying it does,
/// and returns the messages the tests' failures left.
fn check(host: &Host, dir: &Path) -> Vec<String> {
    host.load_str(
        "user/config",
        &format!(
            "local greed = require('@greed')
            greed.command({{ name = 'check-it', run = function()
                local report = greed.plugin.check({:?})
                assert(report.tests.passed, report.tests.error)
                greed.echo('passed ' .. report.tests.passed)
                for _, failed in report.tests.failed or {{}} do
                    greed.echo(failed.message)
                end
            end }})",
            dir.to_str().unwrap()
        ),
    )
    .unwrap();
    host.with_editor_mut(|editor| editor.open("file", "", None));
    host.run("check-it").unwrap();
    let job = host
        .finished_jobs()
        .recv_timeout(std::time::Duration::from_secs(60))
        .unwrap();
    host.finish_job(job).unwrap();
    host.with_editor_mut(Editor::take_messages)
}

#[test]
fn checking_a_plugin_runs_it_with_only_what_you_approved() {
    let temp = Temp::new("check");
    let store = temp.0.join("approved.json");
    let shipped = temp.0.join("shipped");
    std::fs::create_dir_all(&shipped).unwrap();
    let dir = temp.plugin("runner", "\"proc\"", "");
    std::fs::write(
        dir.join("init.luau"),
        "local greed = require('@greed')
        greed.command({ name = 'runner-go', run = function() greed.process.run({ 'true' }) end })
        return {}\n",
    )
    .unwrap();
    std::fs::create_dir_all(dir.join("test")).unwrap();
    std::fs::write(
        dir.join("test/run.luau"),
        "local test = require('@greed/test')
        local greed = require('@greed')
        test('its command', function(t) t:run('runner-go') end)
        test('the test itself', function(t) greed.process.run({ 'true' }) end)\n",
    )
    .unwrap();
    let host = host(&store, &shipped);
    let said = check(&host, &dir);
    assert_eq!(said[0], "passed 0", "{said:?}");
    assert_eq!(said.len(), 3, "{said:?}");
    for message in &said[1..] {
        assert!(
            message.starts_with("needs approval: it would run programs")
                && message.contains("you haven't approved \"proc\" for runner"),
            "{message}"
        );
    }

    // Once approved, its tests get what you approved.
    host.eval(&format!(
        "require('@greed').plugin.approve({:?})",
        dir.to_str().unwrap()
    ))
    .unwrap();
    assert_eq!(check(&host, &dir), ["passed 2"]);
}

#[test]
fn checking_a_plugin_greed_ships_runs_it_with_what_it_declares() {
    let temp = Temp::new("check-shipped");
    let shipped = temp.0.join("shipped");
    std::fs::create_dir_all(&shipped).unwrap();
    let dir = shipped.join("own");
    std::fs::create_dir_all(dir.join("test")).unwrap();
    std::fs::write(
        dir.join("plugin.toml"),
        "name = \"own\"\ncapabilities = [\"proc\"]\n",
    )
    .unwrap();
    std::fs::write(dir.join("init.luau"), "return {}\n").unwrap();
    std::fs::write(
        dir.join("test/run.luau"),
        "local test = require('@greed/test')
        local greed = require('@greed')
        test('runs', function(t) assert(greed.process.run({ 'true' })) end)\n",
    )
    .unwrap();
    let host = host(&temp.0.join("approved.json"), &shipped);
    assert_eq!(check(&host, &dir), ["passed 1"]);
}

#[test]
fn checking_a_plugin_covers_what_it_calls_in_the_plugins_it_requires() {
    let temp = Temp::new("check-reach");
    let store = temp.0.join("approved.json");
    let shipped = temp.0.join("shipped");
    std::fs::create_dir_all(&shipped).unwrap();
    let tools = temp.plugin("tools", "\"proc\"", "");
    std::fs::write(
        tools.join("init.luau"),
        "local greed = require('@greed')
        return { run = function() return greed.process.run({ 'true' }) end }\n",
    )
    .unwrap();
    let dir = temp.plugin("user", "", "\"tools\"");
    std::fs::create_dir_all(dir.join("test")).unwrap();
    std::fs::write(
        dir.join("test/run.luau"),
        "local test = require('@greed/test')
        test('through tools', function(t) require('@tools').run() end)\n",
    )
    .unwrap();
    let host = host(&store, &shipped);
    host.eval(&format!(
        "require('@greed').plugin.approve({:?})",
        tools.to_str().unwrap()
    ))
    .unwrap();
    let said = check(&host, &dir);
    assert_eq!(said.len(), 2, "{said:?}");
    assert!(
        said[1].contains("you haven't approved \"proc\" for user"),
        "{said:?}"
    );
}

#[test]
fn code_a_plugin_loads_counts_as_its_own_whatever_its_named() {
    let temp = Temp::new("loadstring");
    let store = temp.0.join("approved.json");
    let shipped = temp.0.join("shipped");
    std::fs::create_dir_all(&shipped).unwrap();
    let tools = temp.plugin("tools", "\"proc\"", "");
    std::fs::write(
        tools.join("init.luau"),
        "local greed = require('@greed')
        return { run = function() return greed.process.run({ 'true' }) end }\n",
    )
    .unwrap();
    // Declares nothing, so it loads without approval, and names what it
    // loads after tools to pass as tools' code: as a command, the only
    // frames on the stack would be tools'.
    let user = temp.plugin("user", "", "\"tools\"");
    std::fs::write(
        user.join("init.luau"),
        "local greed = require('@greed')
        local sneak = loadstring('require(\"@tools\").run()', '@tools/x')
        greed.command({ name = 'user-go', run = sneak })
        greed.command({ name = 'user-spawn', run = function() greed.spawn(sneak) end })
        greed.command({ name = 'user-peek', run = function() getfenv(require('@tools').run) end })
        return {}\n",
    )
    .unwrap();
    let host = host(&store, &shipped);
    host.with_editor_mut(|editor| editor.open("file", "", None));
    host.eval(&format!(
        "require('@greed').plugin.approve({:?})",
        tools.to_str().unwrap()
    ))
    .unwrap();
    host.load_dir(&user).unwrap();
    for command in ["user-go", "user-spawn"] {
        let err = host.run(command).unwrap_err().brief();
        // Refused for user, through the stack or the limit it started.
        assert!(
            err.starts_with("tools can't run programs")
                && (err.contains("for user") || err.contains("user started it")),
            "{command}: {err}"
        );
    }
    let err = host.run("user-peek").unwrap_err().brief();
    assert!(err.contains("getfenv isn't available to plugins"), "{err}");
}

#[test]
fn plugins_cant_write_the_approvals_file() {
    let temp = Temp::new("guard");
    let store = temp.0.join("state/approved.json");
    let host = host(&store, &temp.0.join("shipped"));
    let err = host
        .eval(&format!(
            "require('@greed').fs.write({:?}, '{{}}')",
            store.to_str().unwrap()
        ))
        .unwrap_err();
    assert!(
        err.to_string().contains("can't write Greed's approvals"),
        "{err}"
    );
    assert!(!store.exists());
}

#[test]
fn plugins_cant_remove_move_or_replace_the_approvals_file() {
    let temp = Temp::new("guard-tree");
    let store = temp.0.join("state/approved.json");
    std::fs::create_dir_all(store.parent().unwrap()).unwrap();
    std::fs::write(&store, "{}").unwrap();
    std::fs::write(temp.0.join("other.json"), "{}").unwrap();
    let host = host(&store, &temp.0.join("shipped"));
    let (state, other) = (temp.0.join("state"), temp.0.join("other.json"));
    for (call, why) in [
        (
            format!("remove({store:?})"),
            "can't write Greed's approvals",
        ),
        (
            format!("remove({state:?}, {{ recursive = true }})"),
            "holds Greed's own files",
        ),
        (
            format!("rename({state:?}, {:?})", temp.0.join("moved")),
            "holds Greed's own files",
        ),
        (
            format!("rename({other:?}, {store:?})"),
            "can't write Greed's approvals",
        ),
        (
            format!("copy({other:?}, {store:?})"),
            "can't write Greed's approvals",
        ),
    ] {
        let err = host
            .eval(&format!("require('@greed').fs.{call}"))
            .unwrap_err()
            .to_string();
        assert!(err.contains(why), "{call}: {err}");
    }
    assert!(store.exists());
}
