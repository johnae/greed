local test = require("@kern/test")
local kern = require("@kern")

test("shows the mode, the tab, the file and the position", function(t)
	t:buffer("ab\nçd|e")
	local left, right = t:status()
	assert(
		left
			and string.find(left, " NORMAL ", 1, true)
			and string.find(left, " [scratch] ", 1, true),
		left
	)
	assert(right and string.find(right, " 2:3 ", 1, true), right)
end)

test("marks changed buffers and follows the mode", function(t)
	t:buffer("|abc")
	t:keys("i x")
	local left = t:status()
	assert(
		left
			and string.find(left, " INSERT ", 1, true)
			and string.find(left, "[scratch] [+]", 1, true),
		left
	)
end)

test("files in the project show from its root", function(t)
	local dir = t:tempdir({ [".git/HEAD"] = "", ["src/main.rs"] = "fn main() {}" })
	kern.project.open(dir)
	kern.open(dir .. "/src/main.rs")
	local left = t:status()
	assert(left and string.find(left, " src/main.rs ", 1, true), left)
end)

test("shows when keys are being recorded into a macro", function(t)
	t:buffer("|abc")
	t:keys("Q")
	local left = t:status()
	assert(left and string.find(left, "recording @@", 1, true), tostring(left))
	t:keys("Q")
	left = t:status()
	assert(left and not string.find(left, "recording", 1, true), tostring(left))
end)

test("pills get rounded ends in the theme's colors", function(t)
	kern.theme.set({
		["ui.statusline"] = { bg = "#101010" },
		["ui.statusline.mode"] = { bg = "#00ff00" },
	})
	t:buffer("|abc")
	local left = t:status()
	assert(left and string.find(left, "\u{e0b6} NORMAL \u{e0b4}", 1, true), left)
	kern.option.set("statusline-caps", "none")
	left = t:status()
	assert(left and not string.find(left, "\u{e0b6}", 1, true), left)
	kern.option.set("statusline-caps", "round")
end)

test("pieces can be added and taken away", function(t)
	local statusline = require("@statusline")
	statusline.add("right", "greeting", function()
		return "hi"
	end, "position")
	statusline.remove("tab")
	t:buffer("|abc")
	local left, right = t:status()
	assert(right and string.find(right, "hi%s+1:1"), right)
	assert(left and not string.find(left, " 1 ", 1, true), left)
	statusline.remove("greeting")
end)
