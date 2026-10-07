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

local floats = require("@core").floats

-- A typing float over the buffer, and what it heard.
local function typing(t: test.TestContext, spec: greed.FloatSpec?, mode: string?)
	t:buffer("|x")
	local heard = { changes = 0, closes = 0 }
	local float =
		floats.typing(greed.create_buffer("scratch", ""), spec or { width = 20, height = 3 }, {
			mode = mode,
			on_change = function()
				heard.changes += 1
			end,
			on_close = function()
				heard.closes += 1
			end,
		})
	return float, heard
end

test("a typing float types in insert mode and comes back when closed", function(t)
	local main = greed.view()
	local float, heard = typing(t)
	t:expect_mode("helix-insert")
	assert(greed.view() == float.view, "focused")
	t:keys("a b")
	assert(float.buffer:text() == "ab" and heard.changes == 2, `{heard.changes} changes`)
	float.close()
	float.close()
	t:expect_mode("helix")
	assert(greed.view() == main, "focus is back")
	assert(heard.closes == 1 and not float.is_open(), "closed once")
end)

test("a typing float closed some other way still comes back and says so", function(t)
	local float, heard = typing(t)
	float.view:close()
	t:wait(0)
	t:expect_mode("helix")
	assert(heard.closes == 1 and not float.is_open())
	float.close()
	assert(heard.closes == 1, "closing again does nothing")
end)

test("a typing float whose view is gone hears no more changes, even before it's told", function(t)
	-- A handler that runs before the float hears its view closed edits its
	-- buffer, as code running in between can.
	local edited: greed.Buffer? = nil
	greed.on("view.closed", function()
		if edited then
			edited:edit(function(e)
				e:insert(0, "a")
			end)
		end
	end)
	local float, heard = typing(t)
	float.buffer:set_kept(true)
	edited = float.buffer
	float.view:close()
	assert(heard.changes == 0, `{heard.changes} changes`)
	assert(heard.closes == 1 and not float.is_open())
end)

test("a typing float comes back to the mode for wherever focus ends up", function(t)
	t:buffer("|x")
	greed.mode.set("helix-select")
	local float = floats.typing(greed.create_buffer("scratch", ""), { width = 20, height = 3 })
	local other = greed.float(greed.create_buffer("scratch", ""), { width = 20, height = 3 })
	float.close()
	assert(greed.view() == other)
	t:expect_mode("helix")
end)

test("a typing float without focus comes back only from its own mode", function(t)
	t:buffer("|x")
	t:keys("i")
	local float = floats.typing(
		greed.create_buffer("scratch", ""),
		{ width = 20, height = 3, focus = false },
		{
			mode = "test-menu",
		}
	)
	t:expect_mode("test-menu")
	float.close()
	t:expect_mode("helix-insert")
	local again = floats.typing(
		greed.create_buffer("scratch", ""),
		{ width = 20, height = 3, focus = false },
		{
			mode = "test-menu",
		}
	)
	greed.mode.set("helix")
	again.close()
	t:expect_mode("helix")
end)

test("text to read shows in a float that esc or q closes, one per kind", function(t)
	t:buffer("|x")
	local first = floats.show_text("One", "first", { kind = "test-info" })
	assert(greed.view() == first and first:buffer():text() == "first")
	local second = floats.show_text("Two", "second", { kind = "test-info" })
	assert(not first:valid(), "the one before of its kind closed")
	assert(second:buffer():readonly(), "it can't be changed")
	t:keys("esc")
	assert(not second:valid(), "esc closes it")
	greed.option.set("editing-style", "vim")
	local third = floats.show_text("Three", "third")
	t:keys("q")
	assert(not third:valid(), "q closes it in another style")
end)
