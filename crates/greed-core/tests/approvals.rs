use std::path::{Path, PathBuf};

use greed_core::luau::{Host, HostError};
use greed_core::{Editor, FIRST_CLIENT};
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
                for _, warning in report.warnings do
                    greed.echo('warning: ' .. warning)
                end
            end }})",
            dir.to_str().unwrap()
        ),
    )
    .unwrap();
    host.with_editor_mut(|editor| editor.open("file", "", None));
    host.run(FIRST_CLIENT, "check-it").unwrap();
    host.settle().unwrap();
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
        let err = host.run(FIRST_CLIENT, command).unwrap_err().brief();
        // Refused for user, through the stack or the limit it started.
        assert!(
            err.starts_with("tools can't run programs")
                && (err.contains("for user") || err.contains("user started it")),
            "{command}: {err}"
        );
    }
    let err = host.run(FIRST_CLIENT, "user-peek").unwrap_err().brief();
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
    // Nor make a folder in its place, which would keep it from being written.
    let err = host
        .eval(&format!(
            "require('@greed').fs.mkdir({:?})",
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

#[test]
fn checking_a_plugin_warns_of_replaced_commands_and_keys_to_missing_ones() {
    let temp = Temp::new("check-warnings");
    let shipped = temp.0.join("shipped");
    std::fs::create_dir_all(&shipped).unwrap();
    let base = shipped.join("base");
    std::fs::create_dir_all(&base).unwrap();
    std::fs::write(base.join("plugin.toml"), "name = \"base\"\n").unwrap();
    std::fs::write(
        base.join("init.luau"),
        "require('@greed').command({ name = 'save-it', run = function() end })\n",
    )
    .unwrap();
    let dir = temp.plugin("mine", "", "\"base\"");
    std::fs::write(
        dir.join("init.luau"),
        "local greed = require('@greed')
        greed.command({ name = 'save-it', run = function() end })
        greed.keymap.bind('helix', { ['g z'] = 'nowhere' })
        return {}\n",
    )
    .unwrap();
    let host = host(&temp.0.join("approved.json"), &shipped);
    host.load_dirs(&[base]).unwrap();
    let said = check(&host, &dir);
    assert_eq!(
        said,
        [
            "passed 0",
            "warning: the mine plugin replaces the base plugin's command save-it",
            "warning: g z in helix runs nowhere, which doesn't exist",
        ]
    );
}

#[test]
fn checking_a_plugin_works_with_a_config_loaded_from_its_folder() {
    let temp = Temp::new("check-config");
    let store = temp.0.join("approved.json");
    let shipped = temp.0.join("shipped");
    std::fs::create_dir_all(&shipped).unwrap();
    // A config folder holds an init.luau and no plugin.toml.
    let config = temp.0.join("config");
    std::fs::create_dir_all(&config).unwrap();
    std::fs::write(config.join("init.luau"), "return {}\n").unwrap();
    let dir = temp.plugin("plain", "", "");
    std::fs::create_dir_all(dir.join("test")).unwrap();
    std::fs::write(
        dir.join("test/basic.luau"),
        "local test = require('@greed/test')\ntest('runs', function() end)\n",
    )
    .unwrap();
    let host = host(&store, &shipped);
    host.load_file("user/file", &config.join("init.luau"))
        .unwrap();
    assert_eq!(check(&host, &dir), ["passed 1"]);
}

#[test]
fn choosing_a_waiting_plugin_in_plugins_approve_approves_and_loads_it() {
    let temp = Temp::new("approve-picker");
    let store = temp.0.join("approved.json");
    let shipped = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../runtime/plugins");
    let runner = temp.plugin("runner", "\"proc\"", "");
    let host = host(&store, &shipped);
    host.load_dirs(&[
        shipped.join("core"),
        shipped.join("picker"),
        shipped.join("approvals"),
        runner,
    ])
    .unwrap();
    host.with_editor_mut(|editor| editor.open("file", "", None));
    assert!(!loaded(&host).contains("runner"), "it waits");
    host.run(FIRST_CLIENT, "plugins-approve").unwrap();
    host.settle().unwrap();
    host.press_keys("enter").unwrap();
    host.settle().unwrap();
    let said = host.with_editor_mut(Editor::take_messages);
    assert!(
        loaded(&host).contains("runner"),
        "approved and loaded: {said:?}"
    );
}

/// Lets the plugin watcher see what changed in the plugins folder and
/// settle it, as the session does while time goes by.
fn watch_settle(host: &Host) {
    host.check_watches().unwrap();
    host.settle().unwrap();
    std::thread::sleep(std::time::Duration::from_millis(400));
    host.fire_timers(std::time::Instant::now()).unwrap();
    host.settle().unwrap();
}

#[test]
fn a_plugin_appearing_or_asking_for_more_waits_for_you_and_the_review_opens() {
    let temp = Temp::new("watch");
    let store = temp.0.join("approved.json");
    let shipped = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../runtime/plugins");
    let folder = temp.0.join("plugins");
    std::fs::create_dir_all(&folder).unwrap();
    let host = host(&store, &shipped);
    host.load_dirs(&[
        shipped.join("core"),
        shipped.join("picker"),
        shipped.join("approvals"),
    ])
    .unwrap();
    host.with_editor_mut(|editor| editor.open("file", "", None));
    host.eval(&format!(
        "local approvals = require('@approvals')
        approvals.watched = function() return {{ {:?} }} end
        approvals.rescan(false)",
        folder.to_str().unwrap()
    ))
    .unwrap();

    // A new plugin that runs programs doesn't load; the review opens.
    let dir = folder.join("runner");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("plugin.toml"),
        "name = \"runner\"\ncapabilities = [\"proc\"]\n",
    )
    .unwrap();
    std::fs::write(dir.join("init.luau"), "return {}\n").unwrap();
    watch_settle(&host);
    assert!(!loaded(&host).contains("runner"), "it waits");
    let kind = host
        .eval("require('@greed').view():buffer():kind()")
        .unwrap();
    assert_eq!(kind, "picker", "the review opened");
    host.press_keys("enter").unwrap();
    host.settle().unwrap();
    assert!(loaded(&host).contains("runner"), "approved, it loads");

    // Asking for more later waits again, the approved version still running.
    std::fs::write(
        dir.join("plugin.toml"),
        "name = \"runner\"\ncapabilities = [\"proc\", \"fs.read\"]\n",
    )
    .unwrap();
    watch_settle(&host);
    assert!(loaded(&host).contains("runner"), "it runs as it was");
    let waiting = host.eval("#require('@greed').plugin.pending()").unwrap();
    assert_eq!(waiting, "1", "and waits for fs.read");
}

#[test]
fn checking_a_plugin_leaves_what_the_plugins_it_requires_vouch_for_theirs() {
    let temp = Temp::new("check-vouch");
    let store = temp.0.join("approved.json");
    let shipped = temp.0.join("shipped");
    std::fs::create_dir_all(&shipped).unwrap();
    let notes = temp.0.join("notes");
    std::fs::create_dir_all(&notes).unwrap();
    // A service keeping its own files whichever plugin asks: at once, in a
    // task it starts, and after waiting; and running code handed to it.
    let tools = temp.plugin("tools", "\"fs.write\"", "");
    std::fs::write(
        tools.join("init.luau"),
        format!(
            "local greed = require('@greed')
            local dir = {:?}
            local function keep(name)
                assert(greed.fs.write(dir .. '/' .. name, name))
            end
            return {{
                now = function() greed.vouch(keep, 'now') end,
                task = function() greed.spawn(greed.vouch, keep, 'task') end,
                later = function()
                    greed.vouch(function() greed.sleep(1) keep('later') end)
                end,
                theirs = function(f) greed.vouch(f) end,
                dir = dir,
            }}\n",
            notes.to_str().unwrap()
        ),
    )
    .unwrap();
    let dir = temp.plugin("user", "", "\"tools\"");
    std::fs::write(
        dir.join("init.luau"),
        "local greed = require('@greed')
        local tools = require('@tools')
        return {
            sneak = function()
                tools.theirs(function() greed.fs.write(tools.dir .. '/sneak', 'x') end)
            end,
        }\n",
    )
    .unwrap();
    std::fs::create_dir_all(dir.join("test")).unwrap();
    std::fs::write(
        dir.join("test/keep.luau"),
        "local test = require('@greed/test')
        local tools = require('@tools')
        test('now', function() tools.now() end)
        test('in a task', function() tools.task() end)
        test('after waiting', function() tools.later() end)
        test('its own code still counts', function() require('@user').sneak() end)\n",
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
    assert_eq!(said[0], "passed 3", "{said:?}");
    assert!(
        said[1].contains("you haven't approved \"fs.write\" for user"),
        "{said:?}"
    );
    for name in ["now", "task", "later"] {
        assert!(notes.join(name).is_file(), "{name} wasn't kept: {said:?}");
    }
    assert!(!notes.join("sneak").exists(), "{said:?}");
}

fn shipped_plugin(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../runtime/plugins")
        .join(name)
}

#[test]
fn checking_a_plugin_that_runs_lines_in_the_shell_charges_it_only_its_programs() {
    let temp = Temp::new("check-shell");
    let store = temp.0.join("approved.json");
    let work = temp.0.join("work");
    std::fs::create_dir_all(&work).unwrap();
    // Declares only proc: the shell's history, wrapper files, environment
    // and prompt are the shell's own.
    let dir = temp.plugin("runner", "\"proc\"", "\"shell\"");
    std::fs::create_dir_all(dir.join("test")).unwrap();
    std::fs::write(
        dir.join("test/run.luau"),
        format!(
            "local test = require('@greed/test')
            local shell = require('@shell')
            local function run(t, line, options)
                t:buffer('|')
                local sh = shell.open({{ cwd = {:?}, show = false }})
                local block = shell.wait(assert(shell.run(sh, line, options)))
                assert(block.status == 'done', `{{block.status}}: {{block.stderr}}`)
                assert(#t:messages() == 0, table.concat(t:messages(), '\\n'))
                return block
            end
            test('a line of yours', function(t) run(t, 'echo hi', nil) end)
            test('a pipe', function(t)
                local block = run(t, 'echo hi | tr h H', {{ by = 'agent', runner = 'pipe' }})
                assert(block.stdout == 'Hi\\n', block.stdout)
            end)\n",
            work.to_str().unwrap()
        ),
    )
    .unwrap();
    let host = host(&store, &shipped_plugin(""));
    host.load_dirs(&["core", "picker", "terminal", "shell"].map(shipped_plugin))
        .unwrap();
    let failures = |said: &[String]| -> Vec<String> {
        said[1..]
            .iter()
            .filter(|m| !m.starts_with("warning: "))
            .cloned()
            .collect()
    };
    // Before it's approved, only running its programs waits for that.
    let said = check(&host, &dir);
    assert_eq!(said[0], "passed 0", "{said:?}");
    let failed = failures(&said);
    assert_eq!(failed.len(), 2, "{said:?}");
    for message in &failed {
        assert!(
            message.contains("you haven't approved \"proc\" for runner"),
            "{said:?}"
        );
    }
    host.eval(&format!(
        "require('@greed').plugin.approve({:?})",
        dir.to_str().unwrap()
    ))
    .unwrap();
    let said = check(&host, &dir);
    assert_eq!(said[0], "passed 2", "{said:?}");
    assert!(failures(&said).is_empty(), "{said:?}");
}
