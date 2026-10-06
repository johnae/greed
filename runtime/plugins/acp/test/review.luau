local test = require("@greed/test")
local greed = require("@greed")
local acp = require("@acp")
local agent = require("@agent")

local FAKE: acp.Agent = {
	name = "fake",
	title = "Fake",
	commands = { { "sh", `{greed.plugin.dirs().acp}/test/fake-agent.sh` } },
}

local function apply(text: string, changes: { any }): string
	for i = #changes, 1, -1 do
		local c = changes[i]
		text = string.sub(text, 1, c.from) .. c.text .. string.sub(text, c.to + 1)
	end
	return text
end

test("the agent's changes move past lines you changed since", function()
	local base = "one\ntwo\nthree\nfour\n"
	local theirs = "one\ntwo\nthree\nFOUR\n"
	local mine = "zero\none\ntwo\nthree\nfour\n"
	local changes, clashes = acp.review.merge(base, theirs, mine)
	assert(clashes == 0, tostring(clashes))
	assert(apply(mine, changes) == "zero\none\ntwo\nthree\nFOUR\n", apply(mine, changes))
end)

test("changes to lines you changed too are left out and counted", function()
	local base = "one\ntwo\nthree\nfour\n"
	local theirs = "one\nTWO\nthree\nFOUR\n"
	local changes, clashes = acp.review.merge(base, theirs, "one\ntwo\nthree\n4\n")
	assert(clashes == 1, tostring(clashes))
	assert(#changes == 1 and changes[1].text == "TWO\n", greed.json.encode(changes))
end)

test("what you already have isn't proposed again", function()
	local base = "one\ntwo\n"
	local changes, clashes = acp.review.merge(base, "one\nTWO\n", "one\nTWO\n")
	assert(#changes == 0 and clashes == 0)
end)

test("a new file is all one change, and so is a file you don't have", function()
	local changes = acp.review.merge("", "hello\n", "")
	assert(#changes == 1 and changes[1].text == "hello\n" and changes[1].from == 0)
end)

test("an agent's workspace changes come to your files as proposals", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a\n" })
	for _, args in { { "init", "-q" }, { "add", "." }, { "commit", "-q", "-m", "first" } } do
		local done = greed.process.run(
			{ "git", "-c", "user.name=t", "-c", "user.email=t@t", table.unpack(args) },
			{ cwd = dir }
		)
		assert(done and done.code == 0, done and done.stderr)
	end
	local s = assert(acp.start(FAKE, dir, true))
	t:wait_for(function()
		return s.status == "idle"
	end)
	acp.prompt(s, "edit a.txt")
	t:wait_for(function()
		return s.status == "idle"
	end)
	local ws = assert(s.workspace)
	assert(greed.fs.read(ws.path .. "/a.txt") == "edited\n")
	t:run("agents")
	t:keys("g g j j r")
	t:wait_for(function()
		return agent.pending() > 0
	end)
	local buffer = greed.load(dir .. "/a.txt")
	assert(buffer:text() == "a\n", "nothing changes before you accept")
	greed.view():show(buffer)
	t:keys("space o A")
	t:wait_for(function()
		return agent.pending() == 0
	end)
	assert(buffer:text() == "edited\n", buffer:text())
	assert(greed.fs.read(ws.path .. "/a.txt") == "edited\n", "its workspace keeps its change")
	acp.close(s)
end)

test("with nothing left to take, review says so", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a\n" })
	for _, args in { { "init", "-q" }, { "add", "." }, { "commit", "-q", "-m", "first" } } do
		local done = greed.process.run(
			{ "git", "-c", "user.name=t", "-c", "user.email=t@t", table.unpack(args) },
			{ cwd = dir }
		)
		assert(done and done.code == 0, done and done.stderr)
	end
	local s = assert(acp.start(FAKE, dir, true))
	t:wait_for(function()
		return s.status == "idle"
	end)
	local reviewed = assert(acp.review.review(s))
	assert(reviewed.decided == nil and #reviewed.left == 0)
	acp.close(s)
end)
