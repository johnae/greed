use std::path::{Path, PathBuf};

use greed_core::Editor;
use greed_core::luau::{Host, HostError};
use greed_text::ClientId;

/// A temporary folder for one test, removed when dropped.
struct Temp(PathBuf);

impl Temp {
    fn new(label: &str) -> Temp {
        let dir =
            std::env::temp_dir().join(format!("kern-approvals-{label}-{}", std::process::id()));
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
    host.eval("table.concat(require('@kern').plugin.list(), ',')")
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
        .eval("require('@kern').plugin.pending()[1].missing[1]")
        .unwrap();
    assert_eq!(waiting, "proc");
    let approved = host
        .eval(&format!(
            "require('@kern').plugin.approve({:?})",
            runner.to_str().unwrap()
        ))
        .unwrap();
    assert_eq!(approved, "runner");
    assert_eq!(
        host.eval("#require('@kern').plugin.pending()").unwrap(),
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
        "require('@kern').plugin.approve({:?})",
        base.to_str().unwrap()
    ))
    .unwrap();
    assert_eq!(
        loaded(&host),
        "base,own,user",
        "approving base loads what waited for it"
    );
}

#[test]
fn plugins_cant_write_the_approvals_file() {
    let temp = Temp::new("guard");
    let store = temp.0.join("state/approved.json");
    let host = host(&store, &temp.0.join("shipped"));
    let err = host
        .eval(&format!(
            "require('@kern').fs.write({:?}, '{{}}')",
            store.to_str().unwrap()
        ))
        .unwrap_err();
    assert!(
        err.to_string().contains("can't write Kern's approvals"),
        "{err}"
    );
    assert!(!store.exists());
}
