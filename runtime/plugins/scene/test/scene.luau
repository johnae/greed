local test = require("@greed/test")
local scene = require("@scene")

local function draw(items: { scene.Item }, cols: number, rows: number): string
	return scene.text(scene.cells({ alt = "test", items = items }, cols, rows))
end

test("a line is braille dots, two across and four down a cell", function()
	-- Flat along the top row of dots, then down the left column of a cell.
	assert(draw({ { kind = "line", points = { { 0, 0 }, { 1.9, 0 } } } }, 3, 1) == "⠉⠉", "flat")
	assert(draw({ { kind = "line", points = { { 0, 0 }, { 0, 0.99 } } } }, 1, 1) == "⡇", "down")
	-- Its last point is drawn too.
	assert(draw({ { kind = "line", points = { { 0, 0 }, { 2, 0 } } } }, 3, 1) == "⠉⠉⠁")
end)

test("filled boxes end between cells in eighth blocks", function()
	-- A bar standing on the bottom, two and a half cells tall.
	local bar = draw({ { kind = "rect", at = { 0, 0.5 }, size = { 1, 2.5 }, fill = "x" } }, 1, 3)
	assert(bar == "▄\n█\n█", bar)
	-- A bar from the left, two and a quarter cells long.
	local across = draw({ { kind = "rect", at = { 0, 0 }, size = { 2.25, 1 }, fill = "x" } }, 4, 1)
	assert(across == "██▎", across)
	-- An area down to the bottom, under a line from low to high, as high
	-- as the line is at the middle of each cell.
	local area =
		draw({ { kind = "area", points = { { 0, 2 }, { 4, 0 } }, base = 2, fill = "x" } }, 4, 2)
	assert(area == "  ▂▆\n▂▆██", "\n" .. area)
end)

test("text is placed by its start, middle or end, and later items go over earlier", function()
	assert(draw({ { kind = "text", at = { 1, 0 }, text = "ab" } }, 5, 1) == " ab")
	assert(draw({ { kind = "text", at = { 5, 0 }, text = "ab", align = "end" } }, 5, 1) == "   ab")
	assert(
		draw({ { kind = "text", at = { 2.5, 0 }, text = "abc", align = "middle" } }, 5, 1) == " abc"
	)
	local over = draw({
		{ kind = "rect", at = { 0, 0 }, size = { 3, 1 }, fill = "x" },
		{ kind = "text", at = { 1, 0 }, text = "a" },
	}, 3, 1)
	assert(over == "█a█", over)
end)

test("a group is clipped, and kinds it doesn't know are left out", function()
	local clipped = draw({
		{
			kind = "group",
			clip = { 1, 0, 3, 1 },
			items = { { kind = "rect", at = { 0, 0 }, size = { 5, 1 }, fill = "x" } },
		},
		{ kind = "sparkle", at = { 0, 0 } },
	}, 5, 1)
	assert(clipped == " ██", clipped)
end)

test("each cell takes the style of what was drawn in it last, in runs", function()
	local lines = scene.cells({
		alt = "styles",
		items = {
			{ kind = "rect", at = { 0, 0 }, size = { 4, 1 }, fill = "a" },
			{ kind = "text", at = { 2, 0 }, text = "xy", style = "b" },
		},
	}, 4, 1)
	local marks = lines[1].marks
	assert(#marks == 2, tostring(#marks))
	assert(
		marks[1].style == "a" and marks[1].from == 0 and marks[1].to == 6,
		"two blocks of three bytes"
	)
	assert(marks[2].style == "b" and marks[2].from == 6 and marks[2].to == 8)
end)
