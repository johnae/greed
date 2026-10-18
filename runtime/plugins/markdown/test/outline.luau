-- Markdown's outline: list items and sections move, indent and zoom with
-- what's under them.

local test = require("@greed/test")
local greed = require("@greed")

-- Opens `text` as a Markdown file with the cursor at the start of the line
-- holding `at`.
local function open(t: test.TestContext, text: string, at: string): greed.Buffer
	local dir = t:tempdir({ ["a.md"] = text })
	greed.open(`{dir}/a.md`)
	local buffer = greed.view():buffer()
	local found = string.find(text, at, 1, true) :: number
	greed.view():set_cursor(buffer:line_start(buffer:line_of(found - 1)))
	return buffer
end

local function cursor_line(buffer: greed.Buffer): string
	return buffer:line_text(buffer:line_of(greed.view():cursor()))
end

test("a list item moves past the one beside it, with the items under it", function(t)
	local buffer = open(t, "- a\n  - a1\n- b\n- c\n", "- a")
	t:run("move-lines-down")
	assert(buffer:text() == "- b\n- a\n  - a1\n- c\n", buffer:text())
	assert(cursor_line(buffer) == "- a", cursor_line(buffer))
	t:run("move-lines-down")
	t:run("move-lines-up")
	t:run("move-lines-up")
	assert(buffer:text() == "- a\n  - a1\n- b\n- c\n", buffer:text())
	t:run("move-lines-up")
	assert(buffer:text() == "- a\n  - a1\n- b\n- c\n", "nothing before the first")
	greed.view():set_cursor(buffer:line_start(1))
	t:run("move-lines-down")
	assert(buffer:text() == "- a\n  - a1\n- b\n- c\n", "nothing after the last under a")
end)

test("a section moves past the one beside it, the blank line between staying", function(t)
	local buffer = open(t, "# A\na\n\n## A1\n\n# B\nb\n", "# A")
	t:run("move-lines-down")
	assert(buffer:text() == "# B\nb\n\n# A\na\n\n## A1\n", buffer:text())
	assert(cursor_line(buffer) == "# A", cursor_line(buffer))
end)

test("tab on a list item indents it with the items under it, shift-tab takes it back", function(t)
	local buffer = open(t, "- a\n- b\n  - b1\n", "- b")
	t:keys("i tab")
	local lines = string.split(buffer:text(), "\n")
	local by = #(string.match(lines[2], "^%s*") :: string)
	assert(by > 0, buffer:text())
	assert(lines[3] == string.rep(" ", by) .. "  - b1", buffer:text())
	t:keys("shift-tab")
	assert(buffer:text() == "- a\n- b\n  - b1\n", buffer:text())
	-- The first item has nothing to go under.
	greed.view():set_cursor(0)
	t:keys("tab")
	assert(string.sub(buffer:text(), 1, 6) ~= "  - a\n", buffer:text())
end)

test("zooming in shows only the item or section, as it grows, until zooming out", function(t)
	local buffer = open(t, "# A\na\n# B\nb\n", "b")
	greed.view():set_cursor(buffer:line_start(3))
	t:run("zoom-in")
	local first, last = greed.view():narrowed()
	assert(first == 2 and last == 3, `{first} {last}`)
	t:keys("A enter c esc")
	first, last = greed.view():narrowed()
	assert(first == 2 and last == 4, `{first} {last}`)
	t:run("zoom-out")
	assert(greed.view():narrowed() == nil, "all of it again")
end)
