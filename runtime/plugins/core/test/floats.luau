local test = require("@greed/test")
local greed = require("@greed")

local function float(t: test.TestContext): greed.View
	t:buffer("|x")
	local view = greed.float(
		greed.create_buffer("scratch", "hello"),
		{ title = "f", x = 2, y = 2, width = 20, height = 6 }
	)
	t:draw(60, 20)
	return view
end

test("dragging a float's top border moves it", function(t)
	local view = float(t)
	local before = view:area() :: { x: number, y: number, width: number, height: number }
	t:mouse("press", before.x + 3, before.y - 1)
	t:mouse("drag", before.x + 8, before.y + 1)
	t:mouse("release", before.x + 8, before.y + 1)
	t:draw(60, 20)
	local after = view:area() :: { x: number, y: number, width: number, height: number }
	assert(after.x == before.x + 5 and after.y == before.y + 2, `moved to {after.x},{after.y}`)
	assert(after.width == before.width and after.height == before.height, "same size")
end)

test("dragging a float's corner resizes it, and a press brings it to the front", function(t)
	local view = float(t)
	local other = greed.float(
		greed.create_buffer("scratch", "other"),
		{ x = 30, y = 2, width = 20, height = 6, focus = false }
	)
	t:draw(60, 20)
	local before = view:area() :: { x: number, y: number, width: number, height: number }
	local right, bottom = before.x + before.width, before.y + before.height
	t:mouse("press", right, bottom)
	assert(greed.view():id() == view:id(), "pressing the border focuses it")
	t:mouse("drag", right + 4, bottom + 2)
	t:mouse("release", right + 4, bottom + 2)
	t:draw(60, 20)
	local after = view:area() :: { x: number, y: number, width: number, height: number }
	assert(after.x == before.x and after.width == before.width + 4, `width {after.width}`)
	assert(after.height == before.height + 2, `height {after.height}`)
	other:close()
end)

test("a float doesn't shrink below its smallest size", function()
	local floats = require("@core").floats
	local box = floats.dragged({ x = 5, y = 5, width = 20, height = 6 }, "left", 30, 0)
	assert(box.width == floats.min_width and box.x == 15, `{box.x} {box.width}`)
end)
