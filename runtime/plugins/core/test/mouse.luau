local test = require("@greed/test")
local greed = require("@greed")

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
	greed.view():buffer():set_line_numbers(false)
	t:draw(40, 10)
end

local function head(): number
	local selection = greed.view():selection()
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
	assert(greed.view():scroll() == 6, tostring(greed.view():scroll()))
	local buffer = greed.view():buffer()
	assert(buffer:line_of(head()) == 6, "the cursor is on screen")
	t:draw(40, 10)
	assert(greed.view():scroll() == 6, "drawing doesn't scroll back")
	t:mouse("scroll", 5, 5, "up")
	assert(greed.view():scroll() == 3)
end)

test("clicking a mark's text with an action runs it, the cursor at the mark", function(t)
	t:buffer("|hello\nworld")
	local buffer = greed.view():buffer()
	local ran: { number } = {}
	greed.command({
		name = "test-button",
		run = function(ctx)
			local selection = ctx.view:selection()
			table.insert(ran, selection.ranges[selection.primary].head)
		end,
	})
	buffer:decorate("buttons", {
		{
			from = 6,
			to = 6,
			style = "ui.button",
			text = "[go]",
			eol = true,
			action = "test-button",
		},
		{ from = 8, to = 8, style = "ui.button", text = "<>", action = "test-button" },
	})
	local rows = t:draw(30, 4)
	assert(rows[1] == "1 hello", rows[1])
	assert(rows[2] == "2 wo<>rld [go]", rows[2])
	-- "[go]" after the second line.
	t:mouse("press", 11, 1)
	assert(ran[1] == 6, tostring(ran[1]))
	-- "<>" inside it.
	t:mouse("press", 5, 1)
	assert(ran[2] == 8, tostring(ran[2]))
	-- Next to them it's an ordinary click.
	t:mouse("press", 3, 1)
	assert(#ran == 2)
end)

test("double and triple clicks select the word and the line; shift extends, alt adds", function(t)
	drawn(t, "hello world\nsecond")
	t:mouse("press", 7, 0)
	t:mouse("release", 7, 0)
	t:mouse("press", 7, 0)
	t:expect("hello ^world|\nsecond")
	t:mouse("release", 7, 0)
	t:mouse("press", 7, 0)
	t:expect("^hello world\n|second")
	t:mouse("release", 7, 0)
	t:mouse("press", 1, 0)
	t:mouse("release", 1, 0)
	t:mouse("press", 3, 1, "left", { shift = true })
	t:expect("h^ello world\nsec|ond")
	t:mouse("release", 3, 1)
	t:mouse("press", 0, 0, "left", { alt = true })
	assert(#greed.view():selection().ranges == 2, "a second cursor")
end)

test("the wheel scrolls up through lines that wrap, all the way to the top", function(t)
	-- Lines three or four rows long in a view 40 cells wide.
	local long: { string } = {}
	for i = 1, 30 do
		table.insert(long, `{i} ` .. string.rep("word ", 25))
	end
	t:buffer(table.concat(long, "\n") .. "|")
	greed.view():buffer():set_line_numbers(false)
	t:draw(40, 10)
	local start = greed.view():scroll()
	assert(start > 20, `at the end: {start}`)
	for _ = 1, 20 do
		t:mouse("scroll", 5, 5, "up")
		t:draw(40, 10)
	end
	assert(greed.view():scroll() == 0, `at the top: {greed.view():scroll()}`)
	local rows = t:draw(40, 10)
	assert(string.find(rows[1], "^1 word"), rows[1])
end)

test("the wheel sideways scrolls lines that don't wrap, the cursor coming along", function(t)
	t:buffer("|" .. string.rep("abcdefghij", 20) .. "\nshort")
	local buffer = greed.view():buffer()
	buffer:decorate("test", { { from = 0, to = 200, style = "", nowrap = true } })
	t:draw(40, 10)
	t:mouse("scroll", 5, 1, "right")
	t:draw(40, 10)
	local scrolled = greed.view():side_scroll()
	assert(scrolled > 0, "scrolled")
	assert(buffer:display_column(greed.view():cursor()) >= scrolled, "the cursor came along")
	t:mouse("scroll", 5, 1, "left")
	t:draw(40, 10)
	assert(greed.view():side_scroll() < scrolled, "back")
end)
