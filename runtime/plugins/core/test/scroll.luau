local test = require("@kern/test")
local kern = require("@kern")

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
	local view = kern.view()
	local selection = view:selection()
	return view:buffer():line_of(selection.ranges[selection.primary].head)
end

test("ctrl-f and ctrl-b move a screen down and up, cursor and all", function(t)
	long(t, 3)
	t:keys("ctrl-f")
	assert(
		kern.view():scroll() == 10 and cursor_line() == 13,
		`{kern.view():scroll()} {cursor_line()}`
	)
	t:draw(40, 11)
	t:keys("ctrl-b")
	assert(
		kern.view():scroll() == 0 and cursor_line() == 3,
		`{kern.view():scroll()} {cursor_line()}`
	)
	t:keys("ctrl-b")
	assert(kern.view():scroll() == 0 and cursor_line() == 0, "stops at the top")
end)

test("ctrl-d and ctrl-u move half a screen", function(t)
	long(t, 2)
	t:keys("ctrl-d")
	assert(
		kern.view():scroll() == 5 and cursor_line() == 7,
		`{kern.view():scroll()} {cursor_line()}`
	)
	t:draw(40, 11)
	t:keys("ctrl-u")
	assert(
		kern.view():scroll() == 0 and cursor_line() == 2,
		`{kern.view():scroll()} {cursor_line()}`
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
	assert(kern.view():scroll() == 45, tostring(kern.view():scroll()))
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
