local test = require("@kern/test")
local kern = require("@kern")

-- The highlighted item in the open picker.
local function current(): string?
	local buffer = kern.view():buffer()
	for _, mark in buffer:decorations("picker") do
		if mark.line then
			return string.match(buffer:slice(mark.from, mark.to), "^ ([%w%-]+)")
		end
	end
	return nil
end

-- The text of every character marked as matching the query.
local function matched(): string
	local buffer = kern.view():buffer()
	local out = {}
	for _, mark in buffer:decorations("picker") do
		if mark.style == "ui.menu.match" then
			table.insert(out, buffer:slice(mark.from, mark.to))
		end
	end
	return table.concat(out)
end

test("the command palette runs the command you pick", function(t)
	t:buffer("|abc")
	t:keys("space ?")
	t:expect_mode("insert")
	assert(current() ~= nil, "the picker lists commands")

	t:keys("g o t o - e n d")
	assert(current() == "goto-end", "best match is goto-end, got " .. tostring(current()))

	t:keys("enter")
	t:expect_mode("normal")
	t:expect("abc|")
end)

test("the characters the query matched are marked", function(t)
	t:buffer("|abc")
	t:keys("space ? g o t o - e n d")
	assert(string.find(matched(), "goto-end", 1, true), matched())
end)

test("up and down move through the matches", function(t)
	t:buffer("|abc")
	t:keys("space ?")
	local first = current()
	t:keys("down")
	local second = current()
	assert(second ~= first, "down moves to another item")
	t:keys("up")
	assert(current() == first, "up moves back")
end)

test("esc closes the picker without choosing", function(t)
	t:buffer("a|bc")
	t:keys("space ?")
	t:keys("esc")
	t:expect_mode("normal")
	t:expect("a|bc")
end)

test("a preview shows the current item beside the list", function(t)
	local picker = require("@picker")
	t:buffer("|abc")
	local items = { { label = "one", value = "first" }, { label = "two", value = "second" } }
	picker.pick("Things", items, function() end, {
		preview = function(item)
			return { text = item.value .. " body" }
		end,
	})
	-- Bottom first: the preview, then the list on top of it.
	local floats = t:floats()
	assert(#floats == 2 and floats[1] == "first body", tostring(floats[1]))
	t:keys("down")
	assert(t:floats()[1] == "second body", t:floats()[1])
	t:keys("t w o")
	assert(t:floats()[1] == "second body", "the match stays previewed")
	t:keys("esc")
	assert(#t:floats() == 0, "both close")
end)
