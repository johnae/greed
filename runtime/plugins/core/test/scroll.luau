local test = require("@greed/test")
local greed = require("@greed")

-- A hundred numbered lines, drawn on a screen ten lines high.
local function long(t: any, cursor_line: number)
	local lines = {}
	for i = 0, 99 do
		table.insert(lines, (if i == cursor_line then "|" else "") .. `line {i}`)
	end
	t:buffer(table.concat(lines, "\n"))
	t:draw(40, 11)
end

local function cursor_line(): number
	local view = greed.view()
	local selection = view:selection()
	return view:buffer():line_of(selection.ranges[selection.primary].head)
end

test("ctrl-f and ctrl-b move a screen down and up, cursor and all", function(t)
	long(t, 3)
	t:keys("ctrl-f")
	assert(
		greed.view():scroll() == 10 and cursor_line() == 13,
		`{greed.view():scroll()} {cursor_line()}`
	)
	t:draw(40, 11)
	t:keys("ctrl-b")
	assert(
		greed.view():scroll() == 0 and cursor_line() == 3,
		`{greed.view():scroll()} {cursor_line()}`
	)
	t:keys("ctrl-b")
	assert(greed.view():scroll() == 0 and cursor_line() == 0, "stops at the top")
end)

test("ctrl-d and ctrl-u move half a screen", function(t)
	long(t, 2)
	t:keys("ctrl-d")
	assert(
		greed.view():scroll() == 5 and cursor_line() == 7,
		`{greed.view():scroll()} {cursor_line()}`
	)
	t:draw(40, 11)
	t:keys("ctrl-u")
	assert(
		greed.view():scroll() == 0 and cursor_line() == 2,
		`{greed.view():scroll()} {cursor_line()}`
	)
end)

test("paging stops at the end, and the screen shows where the cursor went", function(t)
	long(t, 95)
	t:keys("ctrl-f")
	assert(cursor_line() == 99, tostring(cursor_line()))
	local rows = t:draw(40, 11)
	assert(string.find(table.concat(rows, "\n"), "line 99", 1, true), "the last line is on screen")
end)

test("z z puts the cursor's line in the middle of the screen", function(t)
	long(t, 50)
	t:keys("z z")
	assert(greed.view():scroll() == 45, tostring(greed.view():scroll()))
	local rows = t:draw(40, 11)
	assert(string.find(rows[6], "line 50", 1, true), rows[6])
end)

test("page down and page up work in insert mode too", function(t)
	long(t, 0)
	t:keys("i pagedown")
	assert(cursor_line() == 10, tostring(cursor_line()))
	t:keys("pageup esc")
	assert(cursor_line() == 0, tostring(cursor_line()))
end)

test("view.scrolled lets one view scroll another, in the same frame", function(t)
	long(t, 0)
	local left = greed.view()
	local right = left:split("right")
	local heard: { number } = {}
	greed.on("view.scrolled", function(event: greed.ViewScrolled)
		table.insert(heard, event.line)
		if event.view:id() == left:id() then
			-- Drawing keeps the cursor on screen, so it goes along too.
			local at = right:buffer():line_start(event.line)
			right:set_selection({ ranges = { { anchor = at, head = at } }, primary = 1 })
			right:set_scroll(event.line)
		end
	end)
	t:draw(40, 11)
	left:focus()
	t:keys("5 0 j")
	local rows = t:draw(40, 11)
	assert(#heard > 0, "it was heard")
	assert(right:scroll() == left:scroll(), `{right:scroll()} vs {left:scroll()}`)
	-- The right half of the first row already shows the line the left does.
	local first = rows[1]
	local shown = string.match(first, "line (%d+)%s*$")
	assert(tonumber(shown) == left:scroll(), first)
end)
