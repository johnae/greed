local test = require("@greed/test")
local greed = require("@greed")

-- `text` open as a Markdown file with the cursor at its end (on a line of
-- its own), drawn without line numbers. Returns the rows.
local function shown(t: test.TestContext, text: string): { string }
	local dir = t:tempdir({ ["doc.md"] = text .. "\n" })
	greed.open(`{dir}/doc.md`)
	local view = greed.view()
	view:buffer():set_line_numbers(false)
	local last = view:buffer():len()
	view:set_selection({ ranges = { { anchor = last, head = last } }, primary = 1 })
	return t:draw(60, 12)
end

local function styled(style: string): { string }
	local buffer = greed.view():buffer()
	local out = {}
	for _, mark in buffer:decorations("markdown") do
		if mark.style == style then
			table.insert(out, buffer:slice(mark.from, mark.to))
		end
	end
	return out
end

test("headings lose their hashes, the top level twice the size", function(t)
	local rows = shown(t, "# Title\n## Part\ntext")
	assert(rows[1] == "Title", rows[1])
	assert(rows[2] == "", "the big heading takes the row below too")
	assert(rows[3] == "Part", rows[3])
	for _, mark in greed.view():buffer():decorations("markdown") do
		if mark.style == "markdown.heading.1" then
			assert(mark.scale == 2, "twice the size")
		end
	end
	assert(styled("markdown.heading.2")[1] == "Part")
end)

test("emphasis, code and links show without their markup", function(t)
	local rows = shown(t, "a **bold** and *slanted* ~~gone~~ `x = 1` [site](http://e.x) snake_case")
	assert(rows[1] == "a bold and slanted gone x = 1 site snake_case", rows[1])
	assert(styled("markdown.bold")[1] == "bold")
	assert(styled("markdown.italic")[1] == "slanted")
	assert(styled("markdown.strike")[1] == "gone")
	assert(styled("markdown.code")[1] == "x = 1")
	assert(styled("markdown.link")[1] == "site")
end)

test("markup inside code stays as written", function(t)
	local rows = shown(t, "`**not bold**` and *yes*")
	assert(rows[1] == "**not bold** and yes", rows[1])
end)

test("code blocks, quotes, rules and bullets", function(t)
	local rows = shown(t, "```lua\nlocal x = **1**\n```\n> wise words\n---\n- item")
	assert(rows[2] == "local x = **1**", `code keeps its markup: {rows[2]}`)
	assert(#styled("markdown.code.block") == 3, "the fences and the code between")
	assert(rows[4] == "▎ wise words", rows[4])
	assert(rows[5] ~= "" and (string.gsub(rows[5], "─", "")) == "", rows[5])
	assert(rows[6] == "• item", rows[6])
end)

test("a code block's result looks a little apart from code", function(t)
	shown(t, "```sh\nls\n```\n\n```result\na\n```")
	assert(#styled("markdown.code.block") == 3, "the code block")
	assert(#styled("markdown.code.block.result") == 3, "its result")
end)

test("typing on a line shows it as written", function(t)
	shown(t, "# Title\n**bold**")
	greed.view():set_selection({ ranges = { { anchor = 10, head = 10 } }, primary = 1 })
	t:keys("i")
	local rows = t:draw(60, 12)
	assert(rows[3] == "**bold**", `the line being typed on: {rows[3]}`)
	assert(rows[1] == "Title", "the others stay drawn")
	t:keys("esc")
	assert(t:draw(60, 12)[3] == "bold")
end)

test("markdown-look off shows the file as written", function(t)
	shown(t, "# Title")
	greed.option.set("markdown-look", false)
	assert(t:draw(60, 12)[1] == "# Title")
end)

test("a plugin can draw headings its own way", function(t)
	local undo = require("@markdown").claim(function()
		return { headings = true }
	end)
	local rows = shown(t, "# Title")
	assert(rows[1] == "# Title", rows[1])
	undo()
	assert(t:draw(60, 12)[1] == "Title")
end)

-- The hidden line ranges in the main view, e.g. "2-3".
local function hidden(): string
	local out = {}
	for _, lines in greed.view():hidden_lines() do
		table.insert(out, `{lines.from}-{lines.to}`)
	end
	return table.concat(out, " ")
end

test("tab folds the code block, list item or section around the cursor", function(t)
	local function at(line: number)
		local start = greed.view():buffer():line_start(line)
		greed.view():set_selection({ ranges = { { anchor = start, head = start } }, primary = 1 })
	end
	shown(
		t,
		"# Plan\n\n```sh\necho a\necho b\n```\n\n- [ ] ship it\n  - [ ] tests\n  - [ ] docs\n- [ ] rest\n\n# Later"
	)
	-- In the code: the block folds under its opening fence.
	at(3)
	t:keys("tab")
	assert(hidden() == "3-5", "the code block: " .. hidden())
	t:keys("tab")
	assert(hidden() == "", hidden())
	-- On a todo with subtasks: the subtasks fold under it.
	at(7)
	t:keys("tab")
	assert(hidden() == "8-9", "the subtasks: " .. hidden())
	t:keys("tab")
	-- On a line that's in neither: the section under the heading.
	at(1)
	t:keys("tab")
	assert(hidden() == "1-10", "the section, up to the blank line before the next: " .. hidden())
	-- shift-tab unfolds everything, and folds everything when nothing is.
	t:keys("shift-tab")
	assert(hidden() == "", hidden())
	t:keys("shift-tab")
	assert(hidden() ~= "", "folded again")
end)
