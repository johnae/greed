local test = require("@greed/test")
local greed = require("@greed")

-- Records where the cursor was each time "test-button" ran.
local function recorder(): { number }
	local ran: { number } = {}
	greed.command({
		name = "test-button",
		run = function(ctx)
			local selection = ctx.view:selection()
			table.insert(ran, selection.ranges[selection.primary].head)
		end,
	})
	return ran
end

test("enter runs the button under the cursor, the cursor at its mark", function(t)
	local ran = recorder()
	t:buffer("- [ ] t|odo\nplain")
	greed.view():buffer():decorate("buttons", {
		{ from = 2, to = 9, style = "ui.button", action = "test-button" },
		{
			from = 10,
			to = 10,
			style = "ui.button",
			text = "[go]",
			eol = true,
			action = "test-button",
		},
	})
	t:keys("enter")
	assert(ran[1] == 2, tostring(ran[1]))
	-- An empty mark's text is over where it starts.
	greed.view():set_selection({ ranges = { { anchor = 10, head = 10 } }, primary = 1 })
	t:keys("enter")
	assert(ran[2] == 10, tostring(ran[2]))
end)

test("enter off a button does nothing", function(t)
	local ran = recorder()
	t:buffer("|plain text")
	greed.view():buffer():decorate("buttons", {
		{ from = 6, to = 10, style = "ui.button", action = "test-button" },
	})
	t:keys("enter")
	assert(#ran == 0, `{#ran} ran`)
	t:expect("|plain text")
end)

test("marks_at finds marks in every namespace, with their namespace", function(t)
	t:buffer("|abcdef")
	local buffer = greed.view():buffer()
	buffer:decorate("one", { { from = 0, to = 3, style = "x" } })
	buffer:decorate("two", { { from = 2, to = 2, style = "y" }, { from = 4, to = 6, style = "z" } })
	local function at(pos: number): string
		local found = {}
		for _, mark in buffer:marks_at(pos) do
			table.insert(found, `{mark.ns}:{mark.style}`)
		end
		table.sort(found)
		return table.concat(found, " ")
	end
	assert(at(2) == "one:x two:y", at(2))
	assert(at(3) == "", "a range's end is outside it: " .. at(3))
	assert(at(5) == "two:z", at(5))
end)

test("two panes have independent buttons without changing buffer lookup", function(t)
	t:buffer("|plain")
	local buttons = require("../buttons")
	local left = greed.view()
	local buffer = left:buffer()
	local right = left:split("right", buffer)
	buffer:decorate("shared", {
		{ from = 0, to = 5, style = "ui.button", action = "shared" },
	})
	left:decorate("local", {
		{ from = 0, to = 5, style = "ui.button", text = "LEFT", action = "left" },
	})
	right:decorate("local", {
		{ from = 0, to = 5, style = "ui.button", text = "RIGHT", action = "right" },
	})
	assert(#buttons.at(buffer, 0) == 1)
	assert(buttons.at(buffer, 0, left)[2].action == "left")
	assert(buttons.at(buffer, 0, right)[2].action == "right")
	left:decorate("local", {})
	assert(#buttons.at(buffer, 0, left) == 1)
	assert(#buttons.at(buffer, 0, right) == 2)
	assert(right:close())
	assert(not right:valid())
end)
