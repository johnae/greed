local test = require("@greed/test")
local greed = require("@greed")
local acp = require("@acp")

local FAKE: acp.Agent = {
	name = "fake",
	title = "Fake",
	commands = { { "sh", `{greed.plugin.dirs().acp}/test/fake-agent.sh` } },
}

-- A session of the fake agent in `root`, its transcript shown and ready.
local function start(t: test.TestContext, root: string, own: boolean?): any
	local s, err = acp.start(FAKE, root, own)
	assert(s, err)
	acp.show(s)
	t:wait_for(function()
		return s.status == "idle" or s.status == "exited"
	end)
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
	assert(string.find(text, "▍ You\n  hello\n", 1, true), text)
	assert(string.find(text, "▍ Fake\n  Hello there\n", 1, true), text)
	local prompt = string.match(text, "── alt%-enter sends · ctrl%-c stops ──\n(.*)$")
	assert(prompt == "", "the prompt is empty again: " .. tostring(prompt))
end)

test("the agent asks before an edit; enter answers, and an open file is edited", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a\n" })
	local file = greed.load(dir .. "/a.txt")
	local s = start(t, dir)
	send(t, s, "edit a.txt")
	assert(s.status == "waiting", s.status)
	assert(string.find(shown(), "? Allow Edit a.txt?   enter to answer", 1, true), shown())
	local view = greed.view()
	view:set_selection({ ranges = { { anchor = 0, head = 0 } }, primary = 1 })
	t:keys("enter")
	local menu = t:floats()[1]
	assert(
		string.find(menu, "y     Allow once", 1, true)
			and string.find(menu, "n     Reject", 1, true),
		menu
	)
	t:keys("y")
	t:wait_for(function()
		return s.status == "idle"
	end)
	t:wait(30)
	assert(file:text() == "edited\n", file:text())
	assert(not file:modified(), "and saved")
	local text = shown()
	assert(string.find(text, "? Edit a.txt: Allow once", 1, true), text)
	assert(string.find(text, "· Edit a.txt   completed", 1, true), text)
	assert(string.find(text, "    a.txt  +1 -1", 1, true), text)
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
	assert(string.find(shown(), "· Edit a.txt   failed", 1, true), shown())
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
	assert(s.status == "working", s.status)
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
	assert(string.find(text, "▸ Run tests   failed", 1, true), text)
	assert(string.find(text, "    1 test failed  (+2 lines, tab shows them)", 1, true), text)
	local _, headings = string.gsub(text, "▍ Fake", "")
	assert(headings == 1, "one heading for the agent's turn: " .. text)
	-- tab on the tool call shows all its output, without the code fences.
	local view = greed.view()
	local at = (string.find(text, "▸ Run tests", 1, true) :: number) - 1
	view:set_selection({ ranges = { { anchor = at, head = at } }, primary = 1 })
	t:keys("tab")
	text = shown()
	assert(
		string.find(
			text,
			"▾ Run tests   failed\n    1 test failed\n    at pager.rs:3\n    expected 2\n",
			1,
			true
		),
		text
	)
	assert(not string.find(text, "```", 1, true), text)
	t:keys("tab")
	assert(string.find(shown(), "▸ Run tests", 1, true), "folded again")
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

test("an agent that isn't installed says how it would run", function(t)
	local s, err = acp.start(
		{ name = "nope", commands = { { "no-such-agent-here", "--acp" } } },
		t:tempdir({})
	)
	assert(s == nil and err == "nope isn't installed: no-such-agent-here --acp", err)
end)

-- A jj repository with a.txt committed, as a project.
local function jj_repo(t: test.TestContext): string
	local dir = t:tempdir({ ["a.txt"] = "a\n" })
	for _, args in { { "git", "init" }, { "commit", "-m", "first" } } do
		local done = greed.process.run(
			{ "jj", "--config", "user.name=t", "--config", "user.email=t@t", table.unpack(args) },
			{ cwd = dir }
		)
		assert(done and done.code == 0, done and done.stderr)
	end
	return dir
end

test("in a jj workspace of its own, the agent's change is brought in with b", function(t)
	if greed.which("jj") == nil then
		return
	end
	local dir = jj_repo(t)
	local s = start(t, dir, true)
	local ws = s.workspace
	assert(ws and ws.kind == "jj" and greed.fs.stat(ws.path), "it has a workspace")
	assert(s.cwd == ws.path)
	send(t, s, "edit a.txt")
	t:keys("alt-p y")
	t:wait_for(function()
		return s.status == "idle"
	end)
	assert(greed.fs.read(ws.path .. "/a.txt") == "edited\n", "it edits its own copy")
	assert(greed.fs.read(dir .. "/a.txt") == "a\n", "not yours")
	t:run("agents")
	local overview = shown()
	assert(string.find(overview, "Fake  ready", 1, true), overview)
	assert(string.find(overview, `workspace {ws.name}`, 1, true), overview)
	t:keys("g g j j d")
	assert(string.find(shown(), "+edited", 1, true), shown())
	t:run("agents")
	t:keys("g g j j b")
	local done = greed.process.run({ "jj", "file", "show", "-r", "@", "a.txt" }, { cwd = dir })
	assert(done and done.stdout == "edited\n", done and done.stdout)
	t:keys("x y")
	assert(not greed.fs.stat(ws.path), "x removes its workspace")
	assert(#acp.sessions() == 0)
	local list = greed.process.run({ "jj", "workspace", "list" }, { cwd = dir })
	assert(list and not string.find(list.stdout, ws.name, 1, true), list and list.stdout)
end)

test("in a git worktree of its own, b applies what the agent changed", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a\n" })
	for _, args in { { "init", "-q" }, { "add", "." }, { "commit", "-q", "-m", "first" } } do
		local done = greed.process.run(
			{ "git", "-c", "user.name=t", "-c", "user.email=t@t", table.unpack(args) },
			{ cwd = dir }
		)
		assert(done and done.code == 0, done and done.stderr)
	end
	local s = start(t, dir, true)
	local ws = s.workspace
	assert(ws and ws.kind == "git", "a worktree")
	send(t, s, "edit a.txt")
	t:keys("alt-p y")
	t:wait_for(function()
		return s.status == "idle"
	end)
	local ok, err = acp.bring(s)
	assert(ok, err)
	assert(greed.fs.read(dir .. "/a.txt") == "edited\n", "brought in")
	acp.close(s)
	assert(not greed.fs.stat(ws.path))
end)

test("the overview shows what each agent is doing and what it waits on", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a\n" })
	local first = start(t, dir)
	local second = start(t, dir)
	send(t, second, "edit a.txt")
	t:run("agents")
	local text = shown()
	assert(string.find(text, "Fake  ready   in the project", 1, true), text)
	assert(
		string.find(text, "Fake 2  waiting for you   ▸ Edit a.txt   1 question", 1, true),
		text
	)
	acp.close(first)
	acp.close(second)
end)
