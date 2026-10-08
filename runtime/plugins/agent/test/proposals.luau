local test = require("@greed/test")
local greed = require("@greed")
local agent = require("@agent")

-- Proposes `edits` to `path` from a command, as a tool call would, and
-- returns a function that gives the agent's answer once there is one.
local function propose(t: any, path: string, edits: { agent.Edit }): () -> string?
	local answer: string? = nil
	greed.command({
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
	greed.open(path)
	local answer = propose(t, path, {
		{ old_text = "one", new_text = "1" },
		{ old_text = "three", new_text = "3" },
	})
	local buffer = greed.view():buffer()
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
	greed.open(path)
	local answer = propose(t, path, { { old_text = "three", new_text = "3" } })
	t:keys("i X X esc")
	t:keys("space o A")
	assert(greed.view():buffer():text() == "XXone two 3\n", greed.view():buffer():text())
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
	greed.open(path)
	greed.view():buffer():set_line_numbers(false)
	propose(t, path, { { old_text = "two\n", new_text = "2\nzwei\n" } })
	local rows = t:draw(30, 8)
	assert(rows[1] == "one", rows[1])
	assert(rows[2] == "two accept reject note", "the old line stays, marked: " .. rows[2])
	assert(rows[3] == "2" and rows[4] == "zwei", `then the new ones: {rows[3]} / {rows[4]}`)
	assert(rows[5] == "three", rows[5])

	-- Inside a line, the new text shows after the old.
	t:keys("space o R")
	propose(t, path, { { old_text = "thr", new_text = "3" } })
	rows = t:draw(20, 8)
	assert(string.sub(rows[3], 1, 7) == "thr3ee ", rows[3])
end)

-- The marks of the proposal's changes beyond the old text itself.
local function change_marks(buffer: greed.Buffer): { greed.Mark }
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
	greed.open(path)
	propose(
		t,
		path,
		{ { old_text = "let total = count + 1\n", new_text = "let total = amount + 1\n" } }
	)
	local buffer = greed.view():buffer()
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

test("each change has accept, reject and note buttons to click", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one\ntwo\nthree\n" })
	local path = dir .. "/a.txt"
	greed.open(path)
	greed.view():buffer():set_line_numbers(false)
	local answer = propose(t, path, {
		{ old_text = "one\n", new_text = "1\n" },
		{ old_text = "three\n", new_text = "3\n" },
	})
	local rows = t:draw(30, 8)
	assert(rows[1] == "one accept reject note", rows[1])
	-- "accept" after "one ".
	t:mouse("press", 5, 0)
	local buffer = greed.view():buffer()
	assert(buffer:text() == "1\ntwo\nthree\n", buffer:text())
	rows = t:draw(30, 8)
	local line = table.find(rows, "three accept reject note")
	assert(line, table.concat(rows, " / "))
	-- "reject" after "three accept ".
	t:mouse("press", 14, line - 1)
	assert(buffer:text() == "1\ntwo\nthree\n")
	assert(answer() == `accepted 1 of 2 changes to {path}; the user rejected change 2`, answer())
end)

test("changes to several files are one operation, undone in one step", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one\n", ["b.txt"] = "two\n" })
	local answer: string? = nil
	greed.command({
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
	assert(
		string.find(
			messages[#messages],
			"2 changes in 2 files (numbers): space o o lists them",
			1,
			true
		),
		messages[#messages]
	)
	greed.open(dir .. "/a.txt")
	t:keys("space o A")
	greed.open(dir .. "/b.txt")
	t:keys("space o A")
	local a, b = greed.load(dir .. "/a.txt"), greed.load(dir .. "/b.txt")
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

test("rejecting with a note tells the agent what to do instead", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one two\n" })
	local path = dir .. "/a.txt"
	greed.open(path)
	local answer = propose(t, path, {
		{ old_text = "one", new_text = "1" },
		{ old_text = "two", new_text = "2" },
	})
	t:keys("] o space o n")
	t:keys("w o r d s space p l e a s e enter")
	local buffer = greed.view():buffer()
	assert(buffer:text() == "one two\n", "rejected")
	assert(answer() == nil, "the other change still waits")
	t:keys("space o A")
	assert(buffer:text() == "1 two\n", buffer:text())
	assert(
		answer()
			== `accepted 1 of 2 changes to {path}; the user rejected change 2\nabout change 2, the user said: words please`,
		answer()
	)
end)

test("a note with nothing written leaves the change waiting", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one\n" })
	local path = dir .. "/a.txt"
	greed.open(path)
	local answer = propose(t, path, { { old_text = "one", new_text = "1" } })
	t:keys("] o space o n esc")
	assert(agent.pending() == 1 and answer() == nil)
end)

-- The new text a proposal shows in `buffer`: the lines under the old
-- ones, and what shows inline after it.
local function shown_new(buffer: greed.Buffer): ({ string }, { string })
	local lines: { string } = {}
	local inline: { string } = {}
	local seen: { [string]: boolean } = {}
	for pos = 0, buffer:len() do
		for _, mark in buffer:marks_at(pos) do
			local key = `{mark.ns} {mark.from} {mark.to} {mark.style}`
			if mark.style == "diff.plus" and not seen[key] then
				seen[key] = true
				local under: { any } = mark.lines or {}
				for _, line in under do
					local text = line
					if type(line) ~= "string" then
						text = ""
						for _, piece in line do
							text ..= piece.text
						end
					end
					table.insert(lines, text)
				end
				if mark.text then
					table.insert(inline, mark.text)
				end
			end
		end
	end
	return lines, inline
end

test("whole lines without their newline show as lines under the old ones", function(t)
	local dir = t:tempdir({ ["a.txt"] = "keep\nold one\nold two\nlast\n" })
	local path = dir .. "/a.txt"
	greed.open(path)
	-- As Claude Code sends them: whole lines, the last without its newline.
	propose(
		t,
		path,
		{ { old_text = "old one\nold two", new_text = "new one\nnew two\nnew three" } }
	)
	local buffer = greed.view():buffer()
	local lines, inline = shown_new(buffer)
	assert(#inline == 0, "nothing inline: " .. table.concat(inline, " | "))
	assert(table.concat(lines, "|") == "new one|new two|new three", table.concat(lines, "|"))
	t:keys("space o A")
	assert(buffer:text() == "keep\nnew one\nnew two\nnew three\nlast\n", buffer:text())
end)

test("the message says how many, where in the project, and the keys", function(t)
	local dir = t:tempdir({ ["src/a.txt"] = "one two\n" })
	greed.project.open(dir)
	local path = dir .. "/src/a.txt"
	greed.open(path)
	propose(t, path, { { old_text = "one", new_text = "1" } })
	local messages = t:messages()
	assert(
		messages[#messages]
			== "an agent proposes 1 change in src/a.txt (numbers): ] o goes to each, space o a accepts, space o r rejects",
		messages[#messages]
	)
end)

test("space o o lists a change that adds text by the text it adds", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one\n" })
	local path = dir .. "/a.txt"
	local buffer = greed.load(path)
	greed.command({
		name = "test-propose-insert",
		run = function()
			agent.propose_changes(
				buffer,
				path,
				{ { from = 4, to = 4, text = "- added\n" } },
				"memory"
			)
		end,
	})
	t:buffer("|x")
	t:run("test-propose-insert")
	local messages = t:messages()
	assert(string.find(messages[#messages], "space o o lists them", 1, true), messages[#messages])
	t:keys("space o o")
	local list = t:floats()
	assert(
		string.find(table.concat(list, "\n"), "a.txt:2: + - added", 1, true),
		table.concat(list, "\n")
	)
	t:keys("esc")
end)
