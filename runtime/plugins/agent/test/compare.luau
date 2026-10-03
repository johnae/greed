local test = require("@greed/test")
local greed = require("@greed")
local agent = require("@agent")

-- Proposes `edits` to `path` from a command, as a tool call would.
local function propose(t: any, path: string, edits: { agent.Edit })
	greed.command({
		name = "test-propose",
		run = function()
			agent.propose(path, edits, nil)
		end,
	})
	t:run("test-propose")
end

local function numbered(n: number): string
	local lines = {}
	for i = 1, n do
		table.insert(lines, `line {i}`)
	end
	return table.concat(lines, "\n") .. "\n"
end

local function side(): greed.Buffer?
	for _, buffer in greed.buffers() do
		if buffer:kind() == "proposal" then
			return buffer
		end
	end
	return nil
end

test("space o d shows the file with its changes in, beside it, scrolling along", function(t)
	local dir = t:tempdir({ ["a.txt"] = numbered(60) })
	local path = dir .. "/a.txt"
	greed.open(path)
	local file = greed.view()
	-- Three lines in for one near the top, so the two sides are off by two.
	propose(t, path, { { old_text = "line 3\n", new_text = "three\nand\nmore\n" } })
	t:draw(80, 12)
	t:keys("space o d")
	local shown = assert(side(), "a side view")
	assert(greed.view():id() == file:id(), "the file keeps focus")
	local text = shown:text()
	assert(string.find(text, "line 2\nthree\nand\nmore\nline 4\n", 1, true), text)
	local marks = shown:decorations("compare")
	assert(#marks == 1 and shown:slice(marks[1].from, marks[1].to) == "three\nand\nmore\n")

	t:draw(80, 12)
	t:keys("4 0 j")
	t:draw(80, 12)
	local other = shown:views()[1]
	assert(other:scroll() == file:scroll() + 2, `{other:scroll()} vs {file:scroll()}`)

	-- Deciding on the last change closes it.
	t:keys("space o A")
	assert(side() == nil, "it closes with the proposal")
end)

test("without proposed changes it says so", function(t)
	t:buffer("|text")
	t:keys("space o d")
	local messages = t:messages()
	assert(messages[#messages] == "no proposed changes here", messages[#messages])
end)

test("the side view keeps up with edits to the file", function(t)
	local dir = t:tempdir({ ["a.txt"] = numbered(5) })
	local path = dir .. "/a.txt"
	greed.open(path)
	propose(t, path, { { old_text = "line 5\n", new_text = "five\n" } })
	t:keys("space o d")
	t:keys("g g i X esc")
	local shown = assert(side())
	assert(string.sub(shown:text(), 1, 7) == "Xline 1", shown:text())
	assert(string.find(shown:text(), "five\n", 1, true), shown:text())
end)
