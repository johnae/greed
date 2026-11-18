//! What a window shows of an agent's transcript while the agent streams:
//! every frame the session sends, not just where it settles.

use std::io::{BufRead, Write};

use greed_core::Editor;
use greed_core::control::{self, Client};
use greed_core::delta::Latest;
use greed_core::keymap::Key;
use greed_core::luau::Host;
use greed_core::render::Size;
use greed_core::render::grid::text_rows;
use greed_core::server::{self, Input, Output};
use greed_text::ClientId;

mod sessions;

/// A plugin that, once loaded, shows a session of Greed's agent with a long
/// history (so drawing it takes more than a time slice) in the main view,
/// then streams a thought and an answer into it in small pieces, as a
/// model's answer comes in.
const STREAMER: &str = r#"
local greed = require("@greed")
local acp = require("@acp")

greed.option.set("setup-first-start", false)

local function stream(s: any)
	s.status = "working"
	local thought = { kind = "thought", text = "", since = greed.now() }
	table.insert(s.entries, thought)
	for i = 1, 25 do
		thought.text ..= `weighing step {i} of the plan, `
		s.changed()
		greed.sleep(8)
	end
	local answer = { kind = "agent", text = "" }
	table.insert(s.entries, answer)
	for i = 1, 60 do
		answer.text ..= if i % 6 == 0 then `**word {i}**.\n\n` else `word {i} `
		s.changed()
		greed.sleep(8)
	end
	s.status = "idle"
	s.changed()
end

greed.spawn(function()
	greed.sleep(100)
	local s = assert(acp.start({ name = "greed", title = "Greed", commands = {}, native = true }, ROOT))
	for i = 1, 150 do
		table.insert(s.entries, { kind = "user", text = `question {i}` })
		table.insert(s.entries, {
			kind = "agent",
			text = `Answer {i}, with **bold**, some \`code\` and a list:\n\n- one\n- two\n\nDone.`,
		})
	end
	acp.show(s)
	local panel = greed.view()
	local buffer = panel:buffer()
	panel:close()
	greed.view():show(buffer)
	greed.view():set_cursor(buffer:len())
	greed.sleep(300)
	stream(s)
end)

return {}
"#;

/// What a window attached to the session showed while the agent streamed.
struct Seen {
    /// Each frame, as rows without the status line, from the thought's
    /// first piece until the answer is done.
    frames: Vec<Vec<String>>,
    /// The changes sent to it, and those that didn't fit the frame it had,
    /// which would have it ask for a whole frame.
    deltas: usize,
    misfits: usize,
}

fn stream(label: &str) -> Seen {
    sessions::private();
    let temp =
        std::env::temp_dir().join(format!("greed-transcript-{label}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&temp);
    let (root, home, plugin) = (
        temp.join("project"),
        temp.join("home"),
        temp.join("streamer"),
    );
    for dir in [&root, &home, &plugin] {
        std::fs::create_dir_all(dir).unwrap();
    }
    std::fs::write(
        plugin.join("plugin.toml"),
        "name = \"streamer\"\nrequires = [\"acp\"]\n",
    )
    .unwrap();
    let code = STREAMER.replace("ROOT", &format!("{:?}", root.to_string_lossy()));
    std::fs::write(plugin.join("init.luau"), code).unwrap();
    let mut all = sessions::default_plugins();
    all.push(plugin);
    let name = format!("transcript-{label}-{}", std::process::id());
    let session = control::listen(&name, None).unwrap();
    let conn = server::spawn_with_session(
        move || {
            let mut editor = Editor::new(ClientId(1));
            editor.open("file", "", None);
            let host = Host::new(editor)?;
            host.use_test_home(home);
            host.quiet_stalls();
            host.set_lsp_launcher(Box::new(|_, _| Ok(None)));
            host.load_dirs(&all)?;
            Ok(host)
        },
        Some(session),
    );
    let (socket, token_file) = control::session_files(&name);
    let token = std::fs::read_to_string(token_file).unwrap();
    let attachment = Client::connect(&socket, &token)
        .unwrap()
        .attach_with(&control::attach_params("gui"))
        .unwrap();
    let (mut reader, mut writer) = (attachment.reader, attachment.writer);
    let mut send = |input: &Input| {
        writeln!(writer, "{}", serde_json::to_string(input).unwrap()).unwrap();
    };
    send(&Input::Resize(Size {
        width: 80,
        height: 24,
    }));
    let mut seen = Seen {
        frames: Vec::new(),
        deltas: 0,
        misfits: 0,
    };
    let (mut latest, mut line) = (Latest::default(), String::new());
    let (mut at_end, mut started) = (false, false);
    loop {
        line.clear();
        assert!(reader.read_line(&mut line).unwrap() > 0, "the session went");
        match serde_json::from_str(&line).unwrap() {
            Output::Frame(frame) => latest.whole(frame),
            Output::Delta(delta) => {
                seen.deltas += 1;
                seen.misfits += usize::from(latest.delta(delta));
            }
            Output::Exit | Output::Detached => {
                panic!("the session stopped: {:?}", conn.server.join())
            }
            _ => continue,
        }
        let mut rows = text_rows(latest.frame().unwrap());
        rows.pop();
        let shows = |text: &str| rows.iter().any(|row| row.contains(text));
        // At the box, the window follows what comes in.
        if !at_end && shows("question 1") {
            at_end = true;
            for key in Key::parse_sequence("g e j").unwrap() {
                send(&Input::Key(key));
            }
        }
        started |= shows("weighing step 1 ");
        if shows("word 60") && !shows("working") {
            break;
        }
        if started {
            seen.frames.push(rows);
        }
    }
    conn.input.send(Input::Quit).unwrap();
    let _ = conn.server.join();
    std::fs::remove_dir_all(&temp).unwrap();
    seen
}

/// What's wrong with a frame of the transcript: its box once, a card whose
/// rows all have its bar, and the agent's answer above it.
fn wrong_with(rows: &[String]) -> Option<String> {
    let card: Vec<usize> = (0..rows.len())
        .filter(|&i| rows[i].starts_with('▎'))
        .collect();
    let (Some(&first), Some(&last)) = (card.first(), card.last()) else {
        return Some("no box".into());
    };
    if last - first + 1 != card.len() {
        return Some(format!("the box's rows aren't together: {card:?}"));
    }
    // Its top, the line you write in and the line under it.
    if card.len() < 3 {
        return Some(format!("the box has {} rows", card.len()));
    }
    // The agent's answer streaming in, between your message and the box.
    let asked = rows[..first].iter().rposition(|row| row.starts_with('›'))?;
    if rows[asked + 1..first]
        .iter()
        .all(|row| row.trim().is_empty())
    {
        return Some("nothing of the answer above the box".into());
    }
    None
}

#[test]
fn every_frame_while_an_agent_streams_shows_the_whole_transcript() {
    let seen = stream("whole");
    let frames = &seen.frames;
    assert!(frames.len() > 20, "only {} frames", frames.len());
    let wrong: Vec<String> = frames
        .iter()
        .enumerate()
        .filter_map(|(n, rows)| {
            wrong_with(rows).map(|why| format!("frame {n}: {why}\n{}", rows.join("\n")))
        })
        .collect();
    assert!(
        wrong.is_empty(),
        "{} of {} frames show a transcript half drawn; the first:\n{}",
        wrong.len(),
        frames.len(),
        wrong[0]
    );
    // An attached window keeps up with changes alone, never needing a whole
    // frame.
    assert!(seen.deltas > 20, "only {} changes", seen.deltas);
    assert_eq!(seen.misfits, 0, "of {} changes", seen.deltas);
}
