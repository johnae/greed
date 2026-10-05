local test = require("@greed/test")
local greed = require("@greed")
local agent = require("@agent")

local MINUTE = 60 * 1000

-- A project with two files, the first open.
local function project(t: any): string
	local dir = t:tempdir({
		[".git/HEAD"] = "ref: refs/heads/main\n",
		["a.txt"] = "one\ntwo\nthree\n",
		["b.txt"] = "four\n",
	})
	greed.open(`{dir}/a.txt`)
	return dir
end

local function entry(path: string): agent.WorkingEntry?
	for _, e in agent.working.list() do
		if e.path == path then
			return e
		end
	end
	return nil
end

test("editing a file puts it in the working set, with the lines worked on", function(t)
	project(t)
	t:keys("j i x esc")
	local a = assert(entry("a.txt"), "a.txt is in")
	assert(a.edits == 1 and a.agent_edits == 0, `{a.edits} {a.agent_edits}`)
	assert(a.lines[1] == 1, tostring(a.lines[1]))
end)

test("typing counts as one edit, not one per key", function(t)
	project(t)
	t:keys("i a b c esc")
	local a = assert(entry("a.txt"))
	assert(a.edits == 1, tostring(a.edits))
end)

test("what you did longer ago counts for less", function(t)
	local dir = project(t)
	t:keys("i x esc")
	t:wait(30 * MINUTE)
	greed.open(`{dir}/b.txt`)
	t:keys("i y esc")
	local list = agent.working.list()
	assert(list[1].path == "b.txt" and list[2].path == "a.txt", list[1].path)
	-- Two half lives: a quarter of an edit, plus what looking at it added.
	assert(list[2].score < 0.5, tostring(list[2].score))
end)

test("an agent's edits count, for less than yours", function(t)
	local dir = project(t)
	greed.command({
		name = "test-propose",
		run = function()
			agent.propose(`{dir}/a.txt`, { { old_text = "two\n", new_text = "TWO\n" } }, nil)
		end,
	})
	t:run("test-propose")
	t:keys("space o A")
	local a = assert(entry("a.txt"), "a.txt is in")
	assert(a.agent_edits == 1 and a.edits == 0, `{a.agent_edits} {a.edits}`)
	assert(a.score < 1, tostring(a.score))
end)

test("the file in front of you counts a little, once until you move", function(t)
	project(t)
	agent.working.look()
	local a = assert(entry("a.txt"))
	assert(a.edits == 0 and a.score > 0 and a.score < 1, tostring(a.score))
	agent.working.look()
	assert(math.abs(assert(entry("a.txt")).score - a.score) < 0.01, "not again without moving")
	t:keys("j")
	agent.working.look()
	assert(assert(entry("a.txt")).score > a.score, "again after moving")
end)

test("the working_set tool lists the files with their lines, 1-based", function(t)
	project(t)
	t:keys("j j i x esc")
	local result
	for _, tool in agent.tools() do
		if tool.name == "working_set" then
			result = tool.run({}, nil)
		end
	end
	assert(result[1].path == "a.txt", result[1].path)
	assert(result[1].lines[1] == 3, tostring(result[1].lines[1]))
	assert(result[1].last == "0s ago", result[1].last)
end)

test("the repo map ranks toward the working set", function(t)
	project(t)
	t:keys("i x esc")
	local focus = agent.map.focus({ "b.txt" })
	assert(focus["a.txt"] > 1, tostring(focus["a.txt"]))
	assert(focus["b.txt"] >= focus["a.txt"] - 0.1, tostring(focus["b.txt"]))
end)
