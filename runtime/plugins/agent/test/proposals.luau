local test = require("@kern/test")
local kern = require("@kern")
local agent = require("@agent")

-- Proposes `edits` to `path` from a command, as a tool call would, and
-- returns a function that gives the agent's answer once there is one.
local function propose(t: any, path: string, edits: { agent.Edit }): () -> string?
	local answer: string? = nil
	kern.command({
		name = "test-propose",
		run = function()
			answer = agent.propose(path, edits, "numbers")
		end,
	})
	t:run("test-propose")
	return function()
		return answer
	end
end

test("proposed changes wait for review, and the agent hears what went in", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one two three\n" })
	local path = dir .. "/a.txt"
	kern.open(path)
	local answer = propose(t, path, {
		{ old_text = "one", new_text = "1" },
		{ old_text = "three", new_text = "3" },
	})
	local buffer = kern.view():buffer()
	assert(buffer:text() == "one two three\n", "nothing changes before review")
	assert(agent.pending() == 2)
	t:keys("space o a")
	assert(buffer:text() == "1 two three\n", buffer:text())
	assert(answer() == nil, "still waiting on the second change")
	t:keys("] o")
	t:expect("1 two ^three|\n")
	t:keys("space o r")
	assert(buffer:text() == "1 two three\n")
	assert(answer() == `accepted 1 of 2 changes to {path}; the user rejected change 2`, answer())
	assert(agent.pending() == 0)
end)

test("changes follow edits made while they wait", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one two three\n" })
	local path = dir .. "/a.txt"
	kern.open(path)
	local answer = propose(t, path, { { old_text = "three", new_text = "3" } })
	t:keys("i X X esc")
	t:keys("space o A")
	assert(kern.view():buffer():text() == "XXone two 3\n", kern.view():buffer():text())
	assert(answer() == `accepted 1 of 1 changes to {path}`, answer())
end)

test("old text has to be there exactly once, and changes can't overlap", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one one two\n" })
	local path = dir .. "/a.txt"
	local function fails(edits: { agent.Edit }): string
		local ok, err = pcall(agent.propose, path, edits, nil)
		assert(not ok, "it fails")
		return tostring(err)
	end
	assert(string.find(fails({ { old_text = "zzz", new_text = "" } }), "isn't in", 1, true) ~= nil)
	assert(
		string.find(fails({ { old_text = "one", new_text = "1" } }), "more than once", 1, true)
			~= nil
	)
	local overlap = fails({
		{ old_text = "one two", new_text = "x" },
		{ old_text = "two", new_text = "y" },
	})
	assert(string.find(overlap, "overlaps", 1, true), overlap)
	assert(agent.pending() == 0, "nothing is left proposed")
end)

test("new whole lines show as lines under the ones they replace", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one\ntwo\nthree\n" })
	local path = dir .. "/a.txt"
	kern.open(path)
	kern.view():buffer():set_line_numbers(false)
	propose(t, path, { { old_text = "two\n", new_text = "2\nzwei\n" } })
	local rows = t:draw(20, 8)
	assert(rows[1] == "one", rows[1])
	assert(rows[2] == "two", "the old line stays, marked: " .. rows[2])
	assert(rows[3] == "2" and rows[4] == "zwei", `then the new ones: {rows[3]} / {rows[4]}`)
	assert(rows[5] == "three", rows[5])

	-- Inside a line, the new text shows after the old.
	t:keys("space o R")
	propose(t, path, { { old_text = "thr", new_text = "3" } })
	rows = t:draw(20, 8)
	assert(rows[3] == "thr3ee", rows[3])
end)
