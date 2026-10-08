local test = require("@greed/test")
local greed = require("@greed")
local acp = require("@acp")

local FAKE: acp.Agent = {
	name = "fake",
	title = "Fake",
	commands = { { "sh", `{greed.plugin.dirs().acp}/test/fake-agent.sh` } },
}

-- Registered, so sessions with it can be taken up again.
acp.register(FAKE)

-- A session of the fake agent in `root`, its transcript shown and ready.
local function start(t: test.TestContext, root: string, own: boolean?): any
	local s, err = acp.start(FAKE, root, own)
	assert(s, err)
	acp.show(s)
	t:wait_for(function()
		return s.status == "idle" or s.status == "exited"
	end)
	t:wait(30)
	return s
end

-- Types `text` at the transcript's prompt and sends it, then waits for the
-- agent's turn to end, or for it to ask something.
local function send(t: test.TestContext, s: any, text: string)
	local view = greed.view()
	local pos = view:buffer():len()
	view:set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
	local keys = {}
	for char in string.gmatch(text, ".") do
		table.insert(keys, if char == " " then "space" else char)
	end
	t:keys(`i {table.concat(keys, " ")} esc alt-enter`)
	t:wait_for(function()
		return s.status == "idle" or s.status == "waiting" or s.status == "exited"
	end)
	t:wait(30)
end

local function shown(): string
	return greed.view():buffer():text()
end

test("a message goes to the agent and its reply streams into the transcript", function(t)
	local dir = t:tempdir({})
	local s = start(t, dir)
	assert(greed.view():buffer():kind() == "agent-transcript")
	send(t, s, "hello")
	local text = shown()
	assert(string.find(text, "  You\n  hello\n", 1, true), text)
	assert(string.find(text, "  Fake\n  Hello there\n", 1, true), text)
	local prompt = string.match(text, "alt%-enter sends · ctrl%-c stops ─╮\n(.*)$")
	assert(prompt == "", "the box is empty again: " .. tostring(prompt))
end)

test("the agent asks before an edit; enter answers, and an open file is edited", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a\n" })
	local file = greed.load(dir .. "/a.txt")
	local s = start(t, dir)
	send(t, s, "edit a.txt")
	-- Through a local, so the check doesn't pin `s.status` for the code after it.
	local status = s.status
	assert(status == "waiting", status)
	assert(string.find(shown(), "  ? Allow Edit a.txt?\n", 1, true), shown())
	assert(
		string.find(shown(), "─╮\nAllow Edit a.txt?  [y] Allow once  [n] Reject\n", 1, true),
		shown()
	)
	local view = greed.view()
	view:set_selection({ ranges = { { anchor = 0, head = 0 } }, primary = 1 })
	t:keys("enter")
	t:wait_for(function()
		return s.status == "idle"
	end)
	t:wait(30)
	assert(file:text() == "edited\n", file:text())
	assert(not file:modified(), "and saved")
	local text = shown()
	assert(string.find(text, "? Edit a.txt: Allow once", 1, true), text)
	assert(string.find(text, "  ✓ Edit a.txt · +1 -1\n", 1, true), text)
	assert(string.find(text, "Edited it.", 1, true), text)
end)

test("rejecting an edit leaves the file alone", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a\n" })
	local s = start(t, dir)
	send(t, s, "edit a.txt")
	t:keys("alt-p n")
	t:wait_for(function()
		return s.status == "idle"
	end)
	t:wait(30)
	assert(greed.fs.read(dir .. "/a.txt") == "a\n")
	assert(string.find(shown(), "  ✗ Edit a.txt\n", 1, true), shown())
	assert(string.find(shown(), "Left it alone.", 1, true), shown())
end)

test("the agent reads what's in an open file, unsaved edits included", function(t)
	local dir = t:tempdir({ ["a.txt"] = "on disk" })
	local file = greed.load(dir .. "/a.txt")
	file:edit(function(e)
		e:replace(0, file:len(), "unsaved")
	end)
	local s = start(t, dir)
	send(t, s, "read a.txt")
	assert(string.find(shown(), "It says unsaved", 1, true), shown())
end)

test("the agent runs programs in terminals it asks for", function(t)
	local s = start(t, t:tempdir({}))
	send(t, s, "run")
	assert(string.find(shown(), "It printed: from a terminal", 1, true), shown())
end)

test("ctrl-c stops the agent's turn", function(t)
	local s = start(t, t:tempdir({}))
	local view = greed.view()
	local pos = view:buffer():len()
	view:set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
	t:keys("i w a i t esc alt-enter")
	local status = s.status
	assert(status == "working", status)
	t:keys("ctrl-c")
	t:wait_for(function()
		return s.status == "idle"
	end)
	t:wait(30)
	assert(string.find(shown(), "stopped: cancelled", 1, true), shown())
end)

test("plans and failed tool calls show in the transcript", function(t)
	local s = start(t, t:tempdir({}))
	send(t, s, "plan")
	local text = shown()
	assert(
		string.find(text, "✓ look around", 1, true) and string.find(text, "› fix it", 1, true),
		text
	)
	assert(string.find(text, "  ✗ Run tests · 3 lines ▸\n", 1, true), text)
	local _, headings = string.gsub(text, "\n  Fake\n", "")
	assert(headings == 1, "one heading for the agent's turn: " .. text)
	-- tab on the tool call shows all its output, without the code fences.
	local view = greed.view()
	local at = (string.find(text, "✗ Run tests", 1, true) :: number) - 1
	view:set_selection({ ranges = { { anchor = at, head = at } }, primary = 1 })
	t:keys("tab")
	text = shown()
	assert(
		string.find(
			text,
			"✗ Run tests · 3 lines ▾\n    1 test failed\n    at pager.rs:3\n    expected 2\n",
			1,
			true
		),
		text
	)
	assert(not string.find(text, "```", 1, true), text)
	t:keys("tab")
	assert(string.find(shown(), "✗ Run tests · 3 lines ▸\n", 1, true), "folded again")
end)

test("when the agent exits, the transcript says so with what it said last", function(t)
	local s = start(t, t:tempdir({}))
	send(t, s, "quit")
	t:wait_for(function()
		return s.status == "exited"
	end)
	t:wait(30)
	assert(string.find(shown(), "the agent exited: bye from the fake agent", 1, true), shown())
end)

test("agents get greed mcp for this session, unless the option is off", function(t)
	local servers = acp.servers("work", "/bin/greed")
	assert(#servers == 1, "one server")
	local server = servers[1]
	assert(server.command == "/bin/greed" and server.args[1] == "mcp", "greed mcp")
	assert(
		server.env[1].name == "GREED_SESSION" and server.env[1].value == "work",
		"for this session"
	)
	assert(#acp.servers(nil, "/bin/greed") == 0, "outside a session there's nothing to connect to")
	greed.option.set("agent-greed-tools", false)
	assert(#acp.servers("work", "/bin/greed") == 0, "the option turns it off")
	greed.option.set("agent-greed-tools", true)
	-- Tests don't run as a session, so the agent is given none, as an array.
	local s = start(t, t:tempdir({}))
	send(t, s, "servers")
	assert(string.find(shown(), "servers: 0", 1, true), shown())
end)

test("the file you're in goes with a prompt as a block before it, once", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a\n" })
	greed.open(dir .. "/a.txt")
	local s = start(t, dir)
	send(t, s, "context")
	assert(string.find(shown(), "  with context\n", 1, true), shown())
	send(t, s, "context")
	assert(string.find(shown(), "  without context\n", 1, true), "unchanged: " .. shown())
end)

test("alt-m picks the agent's mode, and the transcript says which it's in", function(t)
	local s = start(t, t:tempdir({}))
	assert(string.find(shown(), "╭─ Fake · Manual · Small ─"), shown())
	t:keys("alt-m")
	t:keys("P l a n enter")
	t:wait_for(function()
		return s.mode == "plan"
	end)
	t:wait(30)
	assert(string.find(shown(), "╭─ Fake · Plan · Small ─"), shown())
end)

test("alt-M picks the agent's model, and the transcript says which", function(t)
	local s = start(t, t:tempdir({}))
	local model = s.model
	assert(model == "small" and #s.models == 2, tostring(model))
	assert(string.find(shown(), "╭─ Fake · Manual · Small ─"), shown())
	t:keys("alt-M")
	t:keys("B i g enter")
	t:wait_for(function()
		return s.model == "berget/big"
	end)
	t:wait(30)
	assert(string.find(shown(), "╭─ Fake · Manual · Big ─"), shown())
end)

test("an agent registered with a model starts with it", function(t)
	local agent: acp.Agent = table.clone(FAKE)
	agent.model = "berget/big"
	local s = assert(acp.start(agent, t:tempdir({})))
	t:wait_for(function()
		return s.status ~= "starting"
	end)
	t:wait(200)
	t:wait_for(function()
		return s.model == "berget/big"
	end)
end)

test("agents that offer models as a config option get theirs picked that way", function(t)
	local agent: acp.Agent = {
		name = "fake-config",
		commands = { { "sh", `{greed.plugin.dirs().acp}/test/fake-agent.sh`, "config" } },
		model = "berget/big",
	}
	local s = assert(acp.start(agent, t:tempdir({})))
	t:wait_for(function()
		return s.status ~= "starting"
	end)
	t:wait(200)
	t:wait_for(function()
		return s.model == "berget/big"
	end)
	assert(s.model_option == "model" and #s.models == 2, tostring(s.model_option))
end)

test("policies answer questions for you; rules added later come first", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a\n" })
	local remove = acp.policy(function(_, permission)
		if permission.title == "Edit a.txt" then
			for _, option in permission.options do
				if option.kind == "reject_once" then
					return option.id
				end
			end
		end
		return nil
	end)
	local s = start(t, dir)
	send(t, s, "edit a.txt")
	assert(s.status == "idle", "nothing to wait for")
	assert(string.find(shown(), "? Edit a.txt: Reject (by policy)", 1, true), shown())
	assert(greed.fs.read(dir .. "/a.txt") == "a\n")
	remove()
end)

test("where an agent works shows in your file and the status line while it works", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a\n" })
	local file = greed.load(dir .. "/a.txt")
	local s = start(t, dir)
	assert(acp.status() == nil, "nothing to say while it's idle")
	send(t, s, "edit a.txt")
	local marks = file:decorations("agents")
	assert(#marks == 1, "a mark in the file it works on")
	assert(marks[1].sign == "◆" and marks[1].eol, "a sign and a note at the end of the line")
	assert(marks[1].text == "  ◆ Fake: waiting for you", tostring(marks[1].text))
	assert(acp.status() == "◆ 1 waiting for you", tostring(acp.status()))
	t:keys("alt-p y")
	t:wait_for(function()
		return s.status == "idle"
	end)
	t:wait(30)
	assert(#file:decorations("agents") == 0, "gone once it's done")
	assert(acp.status() == nil)
	acp.close(s)
end)

test("sessions are kept to take up again, until closed", function(t)
	local dir = t:tempdir({})
	local s = start(t, dir)
	send(t, s, "hello")
	local saved = acp.saved(dir)
	assert(#saved == 0, "a running session isn't offered")
	-- As after a restart: the agent stopped, but the session was kept.
	acp.stop(s)
	saved = acp.saved(dir)
	assert(#saved == 1 and saved[1].title == "hello" and saved[1].agent == "fake", "kept")
	local again, err = acp.resume(saved[1])
	assert(again, err)
	acp.show(again)
	t:wait_for(function()
		return again.status == "idle"
	end)
	t:wait(30)
	local text = shown()
	assert(string.find(text, "  You\n  an earlier question\n", 1, true), text)
	assert(string.find(text, "  Fake 2\n  an earlier answer\n", 1, true), text)
	acp.close(again)
	acp.close(s)
	assert(#acp.saved(dir) == 0, "closing forgets it")
end)

test("a fork starts with everything said so far", function(t)
	local dir = t:tempdir({})
	local s = start(t, dir)
	send(t, s, "hello")
	local fork, err = acp.fork(s)
	assert(fork, err)
	acp.show(fork)
	t:wait_for(function()
		return fork.status == "idle"
	end)
	t:wait(30)
	assert(fork.session_id == "s2", tostring(fork.session_id))
	local text = shown()
	assert(
		string.find(text, "Hello there", 1, true) and string.find(text, "forked from Fake", 1, true),
		text
	)
	acp.close(fork)
	acp.close(s)
end)

test("a fork of an agent in a jj workspace gets a workspace with its edits", function(t)
	if greed.which("jj") == nil then
		return
	end
	local dir = t:repo("jj", { ["a.txt"] = "a\n" })
	local s = start(t, dir, true)
	send(t, s, "edit a.txt")
	local fork, err = acp.fork(s)
	assert(fork, err)
	local ws = fork.workspace
	assert(ws and s.workspace and ws.path ~= s.workspace.path, "a workspace of its own")
	assert(greed.fs.read(ws.path .. "/a.txt") == "edited\n", "with the edits made so far")
	acp.close(fork)
	acp.close(s)
end)

test("an agent that isn't installed says what it needs", function(t)
	local s, err = acp.start(
		{ name = "nope", commands = { { "no-such-agent-here", "--acp" } } },
		t:tempdir({})
	)
	assert(s == nil and err == "nope isn't installed; it needs no-such-agent-here --acp", err)
end)

test("in a jj workspace of its own, the agent's change is brought in with b", function(t)
	if greed.which("jj") == nil then
		return
	end
	local dir = t:repo("jj", { ["a.txt"] = "a\n" })
	local s = start(t, dir, true)
	local ws = s.workspace
	assert(ws and ws.kind == "jj" and greed.fs.stat(ws.path), "it has a workspace")
	assert(s.cwd == ws.path)
	send(t, s, "edit a.txt")
	assert(
		string.find(shown(), "? Edit a.txt: Allow once (by policy)", 1, true),
		"its own edits needn't wait: " .. shown()
	)
	t:wait_for(function()
		return s.status == "idle"
	end)
	assert(greed.fs.read(ws.path .. "/a.txt") == "edited\n", "it edits its own copy")
	assert(greed.fs.read(dir .. "/a.txt") == "a\n", "not yours")
	t:run("agent-list")
	local listed = shown()
	assert(string.find(listed, "Fake  edit a.txt  idle", 1, true), listed)
	assert(string.find(listed, `workspace {ws.name}`, 1, true), listed)
	t:keys("g g j j j d")
	assert(string.find(shown(), "+edited", 1, true), shown())
	acp.list(dir)
	t:keys("g g j j j b")
	local done = greed.process.run({ "jj", "file", "show", "-r", "@", "a.txt" }, { cwd = dir })
	assert(done and done.stdout == "edited\n", done and done.stdout)
	t:keys("x y")
	assert(not greed.fs.stat(ws.path), "x removes its workspace")
	assert(#acp.sessions() == 0)
	local list = greed.process.run({ "jj", "workspace", "list" }, { cwd = dir })
	assert(list and not string.find(list.stdout, ws.name, 1, true), list and list.stdout)
end)

test("in a git worktree of its own, b applies what the agent changed", function(t)
	local dir = t:repo("git", { ["a.txt"] = "a\n" })
	local s = start(t, dir, true)
	local ws = s.workspace
	assert(ws and ws.kind == "git", "a worktree")
	send(t, s, "edit a.txt")
	t:wait_for(function()
		return s.status == "idle"
	end)
	local ok, err = acp.bring(s)
	assert(ok, err)
	assert(greed.fs.read(dir .. "/a.txt") == "edited\n", "brought in")
	acp.close(s)
	assert(not greed.fs.stat(ws.path))
end)

-- Runs the subagent tool with `args`, as an agent's call would.
local function subagent(args: { [string]: any }): (boolean, any)
	for _, tool in require("@agent").tools() do
		if tool.name == "subagent" then
			return pcall(tool.run, args, require("@agent").caller())
		end
	end
	error("no subagent tool")
end

test("a subagent works on a task in a session of its own and reports back", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a\n" })
	greed.open(`{dir}/a.txt`)
	local ok, result = subagent({ task = "hello", agent = "fake", here = true })
	assert(ok, tostring(result))
	assert(result.report == "Hello there", result.report)
	assert(result.note == nil, "no workspace")
	local s = acp.sessions()[#acp.sessions()]
	assert(s.name == result.session and s.status == "idle", s.status)
	local sent = s.entries[1].text or ""
	assert(string.find(sent, "^hello\n\n%(You're a helper"), sent)
end)

test("subagents are limited, so they can't start an endless chain", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a\n" })
	greed.open(`{dir}/a.txt`)
	local limit = acp.subagent.LIMIT
	for _ = 1, limit do
		greed.spawn(function()
			subagent({ task = "wait", agent = "fake", here = true })
		end)
	end
	t:wait(100)
	local ok, err = subagent({ task = "hello", agent = "fake", here = true })
	assert(not ok and string.find(tostring(err), "working already", 1, true), tostring(err))
	for _, s in acp.sessions() do
		acp.stop(s)
	end
	t:wait(100)
end)

test("asking for an agent that isn't installed says so", function(t)
	local ok, err = subagent({ task = "hello", agent = "nobody" })
	assert(not ok and string.find(tostring(err), "nobody isn't installed", 1, true), tostring(err))
end)

test("a subagent that exits as it starts says so, without waiting on", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a\n" })
	greed.open(`{dir}/a.txt`)
	acp.register({ name = "quitter", commands = { { "sh", "-c", "exit 1" } } })
	local ok, err = subagent({ task = "hello", agent = "quitter", here = true })
	assert(not ok and string.find(tostring(err), "didn't start", 1, true), tostring(err))
	for _, s in acp.sessions() do
		acp.close(s)
	end
end)

-- The question `s` waits on, if any.
local function question(s: any): any
	for _, entry in s.entries do
		if entry.kind == "permission" and entry.chosen == nil then
			return entry.permission
		end
	end
	return nil
end

-- Waits for `s` to ask something, and returns the question.
local function asked(t: test.TestContext, s: any): any
	t:wait_for(function()
		return question(s) ~= nil
	end)
	return question(s)
end

test("an agent in a worktree of its own is let edit only there", function(t)
	local root = t:tempdir({ ["repo/a.txt"] = "a\n" })
	local dir = root .. "/repo"
	local git = t:vcs("git", dir)
	git("init", "-q")
	git("add", ".")
	git("commit", "-q", "-m", "first")
	local s = start(t, dir, true)
	local ws = assert(s.workspace)
	local outside = `../{string.match(ws.path, "[^/]+$")}-escape.txt`
	send(t, s, `edit {outside}`)
	local q = asked(t, s)
	local escaped = require("@core").project.clean(`{ws.path}/{outside}`)
	assert(q.locations and q.locations[1] == escaped, "it asks, saying where")
	q.answer:send("yes")
	t:wait_for(function()
		return s.status == "idle"
	end)
	assert(greed.fs.read(escaped) == nil, "and even allowed, the editor won't write there")
	acp.close(s)
end)

test("an agent in the project asks again before writing outside it", function(t)
	local root = t:tempdir({ ["repo/a.txt"] = "a\n" })
	local dir = root .. "/repo"
	local s = start(t, dir)
	send(t, s, "edit ../out.txt")
	asked(t, s).answer:send("yes")
	local again = asked(t, s)
	assert(string.find(again.title, "outside the project", 1, true), again.title)
	again.answer:send("no")
	t:wait_for(function()
		return s.status == "idle"
	end)
	assert(greed.fs.read(root .. "/out.txt") == nil, "not written")
	send(t, s, "edit ../out.txt")
	asked(t, s).answer:send("yes")
	asked(t, s).answer:send("once")
	t:wait_for(function()
		return s.status == "idle"
	end)
	assert(greed.fs.read(root .. "/out.txt") == "edited\n", "written once you let it")
	acp.close(s)
end)

test(
	"an agent that isn't installed says how to install it, before asking where it works",
	function(t)
		acp.register({
			name = "missing",
			title = "Missing",
			commands = { { "greed-test-no-such-agent" } },
			install = "npm install -g greed-test-no-such-agent",
		})
		t:buffer("|x")
		t:run("agent-new")
		t:keys("M i s s i n g enter")
		t:wait(10)
		local messages = t:messages()
		assert(
			messages[#messages]
				== "Missing isn't installed; install it with: npm install -g greed-test-no-such-agent",
			messages[#messages]
		)
		assert(#t:floats() == 0, "nothing more is asked")
	end
)
