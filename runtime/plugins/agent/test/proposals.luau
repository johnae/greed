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
	assert(rows[2] == "two accept reject", "the old line stays, marked: " .. rows[2])
	assert(rows[3] == "2" and rows[4] == "zwei", `then the new ones: {rows[3]} / {rows[4]}`)
	assert(rows[5] == "three", rows[5])

	-- Inside a line, the new text shows after the old.
	t:keys("space o R")
	propose(t, path, { { old_text = "thr", new_text = "3" } })
	rows = t:draw(20, 8)
	assert(string.sub(rows[3], 1, 7) == "thr3ee ", rows[3])
end)

-- The marks of the proposal's changes beyond the old text itself.
local function change_marks(buffer: kern.Buffer): { kern.Mark }
	-- Proposals number their changes from 1 up, across tests.
	for id = 1, 100 do
		local marks = buffer:decorations(`proposal-{id}-text`)
		if #marks > 0 then
			return marks
		end
	end
	return {}
end

test("in a changed line, the words that changed stand out on both sides", function(t)
	local dir = t:tempdir({ ["a.txt"] = "let total = count + 1\n" })
	local path = dir .. "/a.txt"
	kern.open(path)
	propose(
		t,
		path,
		{ { old_text = "let total = count + 1\n", new_text = "let total = amount + 1\n" } }
	)
	local buffer = kern.view():buffer()
	local old, new
	for _, mark in change_marks(buffer) do
		if mark.style == "diff.minus.change" then
			old = buffer:slice(mark.from, mark.to)
		elseif mark.lines then
			new = mark.lines[1]
		end
	end
	assert(old == "count", old)
	assert(type(new) == "table", "pieces")
	assert(new[2].text == "amount" and new[2].style == "diff.plus.change", new[2].text)
	assert(new[1].text == "let total = " and new[3].text == " + 1", new[1].text)
end)

test("each change has accept and reject buttons to click", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one\ntwo\nthree\n" })
	local path = dir .. "/a.txt"
	kern.open(path)
	kern.view():buffer():set_line_numbers(false)
	local answer = propose(t, path, {
		{ old_text = "one\n", new_text = "1\n" },
		{ old_text = "three\n", new_text = "3\n" },
	})
	local rows = t:draw(30, 8)
	assert(rows[1] == "one accept reject", rows[1])
	-- "accept" after "one ".
	t:mouse("press", 5, 0)
	local buffer = kern.view():buffer()
	assert(buffer:text() == "1\ntwo\nthree\n", buffer:text())
	rows = t:draw(30, 8)
	local line = table.find(rows, "three accept reject")
	assert(line, table.concat(rows, " / "))
	-- "reject" after "three accept ".
	t:mouse("press", 14, line - 1)
	assert(buffer:text() == "1\ntwo\nthree\n")
	assert(answer() == `accepted 1 of 2 changes to {path}; the user rejected change 2`, answer())
end)

test("changes to several files are one operation, undone in one step", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one\n", ["b.txt"] = "two\n" })
	local answer: string? = nil
	kern.command({
		name = "test-propose-files",
		run = function()
			answer = agent.propose_files({
				{ path = dir .. "/a.txt", edits = { { old_text = "one", new_text = "1" } } },
				{ path = dir .. "/b.txt", edits = { { old_text = "two", new_text = "2" } } },
			}, "numbers")
		end,
	})
	t:run("test-propose-files")
	assert(agent.pending() == 2)
	local messages = t:messages()
	assert(string.find(messages[#messages], "2 changes to 2 files", 1, true), messages[#messages])
	kern.open(dir .. "/a.txt")
	t:keys("space o A")
	kern.open(dir .. "/b.txt")
	t:keys("space o A")
	local a, b = kern.load(dir .. "/a.txt"), kern.load(dir .. "/b.txt")
	assert(a:text() == "1\n" and b:text() == "2\n", a:text() .. b:text())
	assert(
		answer and string.find(answer, "accepted 1 of 1 changes to " .. dir .. "/b.txt", 1, true),
		answer
	)
	t:keys("space u u")
	assert(a:text() == "one\n" and b:text() == "two\n", a:text() .. b:text())
end)

test("one file's bad edit stops the whole proposal before anything shows", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one\n", ["b.txt"] = "two\n" })
	local ok, err = pcall(agent.propose_files, {
		{ path = dir .. "/a.txt", edits = { { old_text = "one", new_text = "1" } } },
		{ path = dir .. "/b.txt", edits = { { old_text = "missing", new_text = "2" } } },
	}, nil)
	assert(not ok and string.find(tostring(err), "isn't in", 1, true), tostring(err))
	assert(agent.pending() == 0)
end)
