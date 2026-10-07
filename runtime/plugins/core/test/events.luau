local test = require("@greed/test")
local greed = require("@greed")

-- Counts "selection.changed" for the focused view.
local function count_selections(): { n: number }
	local count = { n = 0 }
	greed.on("selection.changed", function(event: greed.SelectionChanged)
		if event.view == greed.view() then
			count.n += 1
		end
	end)
	return count
end

test("selection.changed comes once for many moves, and not when nothing moved", function(t)
	t:buffer("|hello world")
	t:wait(0)
	local count = count_selections()
	t:keys("l l l w")
	assert(count.n == 1, `once for four keys: {count.n}`)
	t:wait(0)
	assert(count.n == 1, "nothing moved since")
	t:keys("esc")
	assert(count.n == 1, `a key that moves nothing: {count.n}`)
end)

test("selection.changed comes for a plugin's set_selection, undo and a click", function(t)
	t:buffer("|hello world\nsecond")
	greed.view():buffer():set_line_numbers(false)
	t:draw(40, 10)
	local count = count_selections()
	greed.view():set_selection({ ranges = { { anchor = 0, head = 4 } }, primary = 1 })
	t:wait(0)
	assert(count.n == 1, `set_selection: {count.n}`)
	t:keys("d")
	assert(count.n == 2, `deleting: {count.n}`)
	t:keys("u")
	assert(count.n == 3, `undo: {count.n}`)
	t:draw(40, 10)
	t:mouse("press", 3, 1)
	t:mouse("release", 3, 1)
	assert(count.n == 4, `a click: {count.n}`)
end)

test("view.focused comes when a pane or a float takes focus", function(t)
	t:buffer("|text")
	t:wait(0)
	local heard: { string } = {}
	greed.on("view.focused", function(event: greed.ViewFocused)
		local from = if event.from then event.from:buffer():text() else "nil"
		table.insert(heard, `{from}>{event.view:buffer():text()}`)
	end)
	local main = greed.view()
	local pane = main:split("right", greed.create_buffer("scratch", "pane"))
	pane:focus()
	t:wait(0)
	main:focus()
	t:wait(0)
	assert(table.concat(heard, " ") == "text>pane pane>text", table.concat(heard, " "))
	table.clear(heard)
	local float = greed.float(greed.create_buffer("scratch", "float"))
	t:wait(0)
	float:close()
	t:wait(0)
	assert(table.concat(heard, " ") == "text>float nil>text", table.concat(heard, " "))
	t:wait(0)
	assert(#heard == 2, "nothing more")
end)
