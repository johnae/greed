local test = require("@kern/test")
local kern = require("@kern")

local function lines(n: number): string
	local all = {}
	for i = 1, n do
		table.insert(all, `line {i}`)
	end
	return table.concat(all, "\n")
end

-- A buffer without line numbers, drawn, so screen cells are text cells.
local function drawn(t: test.TestContext, text: string)
	t:buffer("|" .. text)
	kern.view():buffer():set_line_numbers(false)
	t:draw(40, 10)
end

local function head(): number
	local selection = kern.view():selection()
	return selection.ranges[selection.primary].head
end

test("a click puts the cursor where it is", function(t)
	drawn(t, "hello world\nsecond")
	t:mouse("press", 6, 0)
	t:mouse("release", 6, 0)
	assert(head() == 6, tostring(head()))
	-- Past the end of a line, the cursor goes to its end.
	t:mouse("press", 30, 1)
	assert(head() == #"hello world\n" + #"second", tostring(head()))
end)

test("dragging selects from where the button went down", function(t)
	drawn(t, "hello world")
	t:mouse("press", 0, 0)
	t:mouse("drag", 4, 0)
	t:mouse("release", 4, 0)
	t:expect("^hell|o world")
end)

test("the wheel scrolls the view and brings the cursor along", function(t)
	drawn(t, lines(50))
	t:mouse("scroll", 5, 5, "down")
	t:mouse("scroll", 5, 5, "down")
	assert(kern.view():scroll() == 6, tostring(kern.view():scroll()))
	local buffer = kern.view():buffer()
	assert(buffer:line_of(head()) == 6, "the cursor is on screen")
	t:draw(40, 10)
	assert(kern.view():scroll() == 6, "drawing doesn't scroll back")
	t:mouse("scroll", 5, 5, "up")
	assert(kern.view():scroll() == 3)
end)
