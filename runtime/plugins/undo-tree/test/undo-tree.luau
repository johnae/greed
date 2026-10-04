local test = require("@greed/test")
local greed = require("@greed")

local main: greed.View? = nil

-- The file's text, from its view, whichever has focus.
local function text(): string
	return (main :: greed.View):buffer():text()
end

test("space u t shows the tree; moving goes to each state, esc goes back", function(t)
	t:buffer("|")
	main = greed.view()
	t:keys("i a esc i b esc u i c esc")
	assert(text() == "ac", text())
	t:keys("space u t")
	local shown = t:floats()[1]
	assert(string.find(shown, "○ 0  loaded", 1, true), shown)
	assert(
		string.find(shown, "│ ○ 2", 1, true),
		"the left-behind branch is indented: " .. shown
	)
	assert(string.find(shown, "● 3", 1, true), "the current state is marked: " .. shown)
	t:keys("k")
	assert(text() == "ab", "up a line is the other branch: " .. text())
	t:keys("esc")
	assert(#t:floats() == 0)
	assert(text() == "ac", "back where it was: " .. text())
end)

test("enter keeps the state moved to", function(t)
	t:buffer("|")
	main = greed.view()
	t:keys("i a esc i b esc")
	t:keys("space u t k enter")
	assert(#t:floats() == 0)
	assert(text() == "a", text())
end)
