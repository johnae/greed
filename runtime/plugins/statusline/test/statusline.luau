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

test("with the pills option, pills get rounded ends in the theme's colors", function(t)
	kern.theme.set({
		["ui.statusline"] = { bg = "#101010" },
		["ui.statusline.mode"] = { bg = "#00ff00" },
	})
	t:buffer("|abc")
	local left = t:status()
	assert(
		left and not string.find(left, "\u{e0b6}", 1, true),
		"no pills by default: " .. tostring(left)
	)
	kern.option.set("statusline-pills", true)
	left = t:status()
	assert(left and string.find(left, "\u{e0b6} NORMAL \u{e0b4}", 1, true), left)
	kern.option.set("statusline-caps", "none")
	left = t:status()
	assert(left and not string.find(left, "\u{e0b6}", 1, true), left)
	kern.option.set("statusline-caps", "round")
	kern.option.set("statusline-pills", false)
end)

test("with effects on, a wave of light goes through the file's letters when it changes", function(t)
	local statusline = require("@statusline")
	kern.theme.set({
		["ui.statusline"] = { fg = "#808080", bg = "#101010" },
		["ui.glow"] = { fg = "#ffffff" },
	})
	t:buffer("|abc")
	local function file_segments(): number
		local ctx =
			{ view = kern.view(), buffer = kern.view():buffer(), mode = "normal", width = 80 }
		local lit = 0
		for _, segment in statusline.build(ctx :: any).left or {} do
			if type(segment) == "table" and string.sub(segment.style or "", 1, 4) == "=fg:" then
				lit += 1
			end
		end
		return lit
	end
	kern.command({
		name = "wave-test",
		run = function()
			statusline.wave("file")
		end,
	})
	t:run("wave-test")
	assert(file_segments() == 0, "effects are off by default")
	kern.option.set("effects", true)
	t:run("wave-test")
	t:wait(300)
	assert(file_segments() == #"[scratch]", "one segment per letter mid-wave: " .. file_segments())
	t:wait(400)
	assert(file_segments() == 0, "gone once it's through")
	kern.option.set("effects", false)
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

test("opening another file sends the wave by itself", function(t)
	local statusline = require("@statusline")
	kern.theme.set({
		["ui.statusline"] = { fg = "#808080", bg = "#101010" },
		["ui.glow"] = { fg = "#ffffff" },
	})
	kern.option.set("effects", true)
	local dir = t:tempdir({ ["notes.txt"] = "hi" })
	t:buffer("|abc")
	t:run("open", { dir .. "/notes.txt" })
	t:wait(300)
	local ctx = { view = kern.view(), buffer = kern.view():buffer(), mode = "normal", width = 80 }
	local lit = 0
	for _, segment in statusline.build(ctx :: any).left or {} do
		if type(segment) == "table" and string.sub(segment.style or "", 1, 4) == "=fg:" then
			lit += 1
		end
	end
	assert(lit > 0, "the file's letters are lit")
	t:wait(400)
	kern.option.set("effects", false)
end)
