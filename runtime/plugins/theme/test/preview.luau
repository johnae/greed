local test = require("@greed/test")
local greed = require("@greed")

-- The text's background now.
local function background(): string?
	local text = greed.theme.get("ui.text")
	return text and text.bg
end

test(":theme shows each theme as you move to it, and esc goes back", function(t)
	t:buffer("|x")
	local before = background()
	t:run("theme")
	t:keys("down")
	local moved = background()
	assert(moved ~= before, `moving changes the theme ({tostring(before)} -> {tostring(moved)})`)
	t:keys("down")
	assert(background() ~= moved, "and again")
	t:keys("esc")
	assert(background() == before, "esc puts the old theme back")
end)

test("tab on :theme tries each theme, and esc goes back", function(t)
	t:buffer("|x")
	local before = background()
	t:keys(": t h e m e space tab")
	local tried = background()
	assert(tried ~= before, "tab shows the theme")
	t:keys("esc")
	assert(background() == before, "closing without running puts it back")
	t:keys(": t h e m e space tab tab enter")
	local chosen = background()
	assert(chosen ~= before, "enter keeps the one tabbed to")
end)
