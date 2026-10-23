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
