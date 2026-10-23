//! A service's session: started in the background by another session,
//! working from a folder of its own, named apart from projects, and never
//! the hub.

mod common;

use std::process::{Child, Command, Stdio};

use common::{GREED, World, kill_sessions, running};

fn serve(world: &World, project: &std::path::Path) -> Child {
    let mut command = Command::new(GREED);
    command
        .arg("serve")
        .arg(project)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    world.env(&mut command);
    command.spawn().unwrap()
}

#[test]
fn a_session_starts_a_service_in_the_background_beside_a_project_of_its_name() {
    let Some(world) = World::new("services") else {
        return;
    };
    // A project called chat: the chat service mustn't take its name.
    let project = world.project("chat", &[]);
    let mut server = serve(&world, &project);
    world.wait_for("the project's session", running);

    // Starting waits, which eval can't; twice at once makes one.
    let start =
        "local g = require('@greed') for _ = 1, 2 do g.spawn(g.session.start, 'chat.service') end";
    world.eval("chat", start);
    world.wait_for("the service's session", |w| {
        w.sessions().lines().count() == 2
    });
    let listed = world.sessions();
    assert!(
        listed.lines().any(|l| l.starts_with("chat ")),
        "the project's: {listed}"
    );
    assert!(
        listed
            .lines()
            .any(|l| l.starts_with("chat.service") && l.contains("(service)")),
        "the service's, marked: {listed}"
    );

    let service = world.eval(
        "chat",
        "for _, s in require('@greed').session.list() do if s.service then return s.name .. ' ' .. s.service end end",
    );
    assert_eq!(service, "chat.service chat");
    // It works from its own folder, wherever it was started from.
    let root = world.eval(
        "chat.service",
        "return require('@greed').project.current().root",
    );
    // Both as the file system has them: macOS's /tmp is /private/tmp.
    let own = std::fs::canonicalize(world.root.join("data/greed/services/chat")).unwrap();
    let root = std::fs::canonicalize(&root).unwrap();
    assert_eq!(root, own, "{}", root.display());
    // Started again, it's found running.
    world.eval("chat", start);
    std::thread::sleep(std::time::Duration::from_millis(500));
    assert_eq!(world.sessions().lines().count(), 2, "{}", world.sessions());
    // The project's session is the hub; the service never is.
    let hub = world.eval("chat.service", "return require('@hub').hub()");
    assert_eq!(hub, "chat");

    world.eval("chat", "require('@greed').quit()");
    let _ = server.wait();
    kill_sessions(&world.root.join("run/greed"), |_| true);
}

/// The counter from the plugin guide, as a plugin in your config.
const COUNTER: &str = r#"
local greed = require("@greed")
local service = require("@service")

service.define({ name = "counter", start = "use" })

if service.owner("counter") then
	local count = 0
	local offer: service.Offer
	offer = service.offer("counter", {
		version = 1,
		handle = function(method: string, params: any): (any, string?)
			if method == "get" then
				return { count = count }
			elseif method == "add" then
				count += params.by
				offer:notify("count", { count = count })
				return { count = count }
			end
			return nil, `no {method}`
		end,
	})
end

local shown = -1
local counter = service.use("counter", {
	version = 1,
	topics = { "count" },
	on = function(_, params: any)
		shown = params.count
	end,
	reset = function(view: service.View)
		local now = view:request("get")
		if now then
			shown = now.count
		end
	end,
})

greed.command({
	name = "counter-add",
	run = function()
		counter:request("add", { by = 1 })
	end,
})

return {
	shown = function(): number
		return shown
	end,
}
"#;

#[test]
fn a_view_in_a_project_starts_the_owner_asks_it_hears_it_and_comes_back_after_it_went() {
    let Some(world) = World::new("counter") else {
        return;
    };
    let plugin = world.root.join("config/greed/plugins/counter");
    std::fs::create_dir_all(&plugin).unwrap();
    std::fs::write(
        plugin.join("plugin.toml"),
        "name = \"counter\"\nrequires = [\"service\"]\n",
    )
    .unwrap();
    std::fs::write(plugin.join("init.luau"), COUNTER).unwrap();
    let project = world.project("work", &[]);
    let mut server = serve(&world, &project);
    world.wait_for("the project's session", running);
    let shown = |session: &str| world.eval(session, "return require('@counter').shown()");

    // Adding from the project starts the counter's session, and the change
    // comes back to the view.
    world.eval("work", "require('@greed').run('counter-add')");
    world.wait_for("the count shown in the project", |_| shown("work") == "1");
    assert!(
        world.sessions().contains("counter.service"),
        "{}",
        world.sessions()
    );

    // Adding in the owner's own session reaches the project's view too.
    world.eval("counter.service", "require('@greed').run('counter-add')");
    world.wait_for("the owner's change shown in the project", |_| {
        shown("work") == "2"
    });
    assert_eq!(shown("counter.service"), "2", "and in the owner's session");

    // The owner went: the view, which listens, starts it again and fetches
    // what's there now.
    world.eval("counter.service", "require('@greed').quit()");
    world.wait_for("the count fetched again", |_| shown("work") == "0");

    world.eval("work", "require('@greed').quit()");
    let _ = server.wait();
    kill_sessions(&world.root.join("run/greed"), |_| true);
}
