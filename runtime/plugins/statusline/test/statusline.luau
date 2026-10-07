local test = require("@greed/test")
local greed = require("@greed")

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
	greed.project.open(dir)
	greed.open(dir .. "/src/main.rs")
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
	greed.theme.set({
		["ui.statusline"] = { bg = "#101010" },
		["ui.statusline.mode"] = { bg = "#00ff00" },
	})
	t:buffer("|abc")
	local left = t:status()
	assert(
		left and not string.find(left, "\u{e0b6}", 1, true),
		"no pills by default: " .. tostring(left)
	)
	greed.option.set("statusline-pills", true)
	left = t:status()
	assert(left and string.find(left, "\u{e0b6} NORMAL \u{e0b4}", 1, true), left)
	greed.option.set("statusline-caps", "none")
	left = t:status()
	assert(left and not string.find(left, "\u{e0b6}", 1, true), left)
	greed.option.set("statusline-caps", "round")
	greed.option.set("statusline-pills", false)
end)

test("with effects on, a wave of light goes through the file's letters when it changes", function(t)
	local statusline = require("@statusline")
	greed.theme.set({
		["ui.statusline"] = { fg = "#808080", bg = "#101010" },
		["ui.glow"] = { fg = "#ffffff" },
	})
	t:buffer("|abc")
	local function file_segments(): number
		local ctx =
			{ view = greed.view(), buffer = greed.view():buffer(), mode = "helix", width = 80 }
		local lit = 0
		local left: { greed.StatusSegment } = statusline.build(ctx :: any).left or {}
		for _, segment in left do
			if type(segment) == "table" and string.sub(segment.style or "", 1, 4) == "=fg:" then
				lit += 1
			end
		end
		return lit
	end
	greed.command({
		name = "wave-test",
		run = function()
			statusline.glow("file")
		end,
	})
	t:run("wave-test")
	assert(file_segments() == 0, "effects are off by default")
	greed.option.set("effects", true)
	t:run("wave-test")
	t:wait(300)
	assert(file_segments() == #"[scratch]", "one segment per letter mid-wave: " .. file_segments())
	t:wait(400)
	assert(file_segments() == 0, "gone once it's through")
	greed.option.set("effects", false)
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
	greed.theme.set({
		["ui.statusline"] = { fg = "#808080", bg = "#101010" },
		["ui.glow"] = { fg = "#ffffff" },
	})
	greed.option.set("effects", true)
	local dir = t:tempdir({ ["notes.txt"] = "hi" })
	t:buffer("|abc")
	t:run("open", { dir .. "/notes.txt" })
	t:wait(300)
	local ctx = { view = greed.view(), buffer = greed.view():buffer(), mode = "helix", width = 80 }
	local lit = 0
	local left: { greed.StatusSegment } = statusline.build(ctx :: any).left or {}
	for _, segment in left do
		if type(segment) == "table" and string.sub(segment.style or "", 1, 4) == "=fg:" then
			lit += 1
		end
	end
	assert(lit > 0, "the file's letters are lit")
	t:wait(400)
	greed.option.set("effects", false)
end)

-- How many of the status line's left segments are lit letters now.
local function lit_now(): number
	local statusline = require("@statusline")
	local ctx =
		{ view = greed.view(), buffer = greed.view():buffer(), mode = greed.mode.get(), width = 80 }
	local lit = 0
	local left: { greed.StatusSegment } = statusline.build(ctx :: any).left or {}
	for _, segment in left do
		if type(segment) == "table" and string.sub(segment.style or "", 1, 4) == "=fg:" then
			lit += 1
		end
	end
	return lit
end

test("the command line coming and going doesn't send light through the file", function(t)
	greed.theme.set({ ["ui.statusline"] = { fg = "#808080", bg = "#101010" } })
	greed.option.set("effects", true)
	local dir = t:tempdir({ ["notes.txt"] = "hi" })
	greed.open(dir .. "/notes.txt")
	t:wait(700)
	t:keys(": esc")
	t:wait(200)
	assert(lit_now() == 0, "nothing lit: " .. lit_now())
	greed.option.set("effects", false)
end)

test("a new mode glows from the middle of its name", function(t)
	greed.theme.set({
		["ui.statusline"] = { fg = "#808080", bg = "#101010" },
		["ui.statusline.mode"] = { fg = "#000000", bg = "#00aa00" },
	})
	greed.option.set("effects", true)
	t:buffer("|abc")
	t:keys("i")
	t:wait(100)
	assert(lit_now() == #"INSERT", "the mode's letters are lit: " .. lit_now())
	t:wait(500)
	assert(lit_now() == 0, "and back to normal")
	t:keys("esc")
	t:wait(500)
	greed.option.set("effects", false)
end)

test("dark letters on a light pill light up too", function(t)
	-- Nord's mode pill: dark letters on light green, with a near white glow.
	greed.theme.set({
		["ui.statusline"] = { fg = "#e5e9f0", bg = "#3b4252" },
		["ui.statusline.mode"] = { fg = "#2e3440", bg = "#a3be8c" },
		["ui.glow"] = { fg = "#f3f5f8" },
	})
	greed.option.set("effects", true)
	t:buffer("|abc")
	t:keys("i")
	t:wait(60)
	local statusline = require("@statusline")
	local ctx =
		{ view = greed.view(), buffer = greed.view():buffer(), mode = "helix-insert", width = 80 }
	local brightest = 0
	local left: { greed.StatusSegment } = statusline.build(ctx :: any).left or {}
	for _, segment in left do
		local r, g, b = string.match(
			type(segment) == "table" and segment.style or "",
			"^=fg:#(%x%x)(%x%x)(%x%x)"
		)
		if r then
			brightest = math.max(
				brightest,
				(tonumber(r, 16) :: number)
					+ (tonumber(g, 16) :: number)
					+ tonumber(b, 16) :: number
			)
		end
	end
	-- #2e3440 adds up to 162; lit letters move well past it, towards the glow.
	assert(brightest > 400, "the letters got brighter: " .. brightest)
	t:keys("esc")
	t:wait(500)
	greed.option.set("effects", false)
end)

test("an async piece shows what its last refresh found, without the line waiting", function(t)
	local statusline = require("@statusline")
	local runs = 0
	statusline.add_async("right", "slow", {
		refresh = function()
			-- Stands in for a slow program, like a status in a big repository.
			greed.sleep(200)
			runs += 1
			return `run {runs}`
		end,
		every = 1000,
	}, "position")
	t:buffer("|abc")
	local _, right = t:status()
	assert(
		right and not string.find(right, "run", 1, true),
		"nothing yet, and no waiting: " .. tostring(right)
	)
	t:wait(250)
	_, right = t:status()
	assert(right and string.find(right, "run 1", 1, true), right)
	t:wait(1250)
	_, right = t:status()
	assert(
		right and string.find(right, "run 2", 1, true),
		"it refreshes every second: " .. tostring(right)
	)
	statusline.remove("slow")
	t:wait(2000)
	assert(runs == 2, "taken away, it stops refreshing")
end)

test("shows the language, and the features on for the buffer", function(t)
	local dir = t:tempdir({ ["main.rs"] = "fn main() {}" })
	greed.open(dir .. "/main.rs")
	local _, right = t:status()
	assert(right and string.find(right, " rust ", 1, true), right)
	local remove = require("@core").features.add("demo", function(buffer)
		return buffer:language() == "rust"
	end)
	_, right = t:status()
	assert(right and string.find(right, " rust · demo ", 1, true), right)
	remove()
	t:buffer("plain|")
	_, right = t:status()
	assert(
		right and not string.find(right, "rust", 1, true),
		"none for plain text: " .. tostring(right)
	)
end)

test("shows how many selections there are, once there's more than one", function(t)
	t:buffer("|one two three")
	local _, right = t:status()
	assert(right and not string.find(right, "selections", 1, true), right)
	t:keys("%")
	t:keys("s o enter")
	_, right = t:status()
	assert(right and string.find(right, " 2 selections ", 1, true), right)
end)

test(
	"says when a file is read-only, has Windows line breaks or indents unlike its language",
	function(t)
		t:buffer("|a\r\nb\r\n")
		local _, right = t:status()
		assert(right and string.find(right, " CRLF ", 1, true), right)
		greed.view():buffer():set_readonly(true)
		_, right = t:status()
		assert(right and string.find(right, " CRLF · read-only ", 1, true), right)
		-- Tabs where the indent is spaces.
		t:buffer("|fn\n\tx\n\ty\n")
		_, right = t:status()
		assert(right and string.find(right, " tabs ", 1, true), right)
		t:buffer("|fn\n    x\n")
		_, right = t:status()
		assert(
			right
				and not string.find(right, "tabs", 1, true)
				and not string.find(right, "CRLF", 1, true),
			right
		)
	end
)

test("clicking a piece with an action runs it, in either style", function(t)
	local statusline = require("@statusline")
	local clicked = 0
	greed.command({
		name = "test-status-click",
		doc = "Counts clicks",
		run = function()
			clicked += 1
		end,
	})
	statusline.add("left", "clicky", function()
		return { text = "CLICK", style = "ui.statusline.warning", action = "test-status-click" }
	end)
	t:buffer("|abc")
	for _, pills in { false, true } do
		greed.option.set("statusline-pills", pills)
		local rows = t:draw(80, 4)
		local at = string.find(rows[4], "CLICK", 1, true)
		assert(at, rows[4])
		-- The cell it's in: pills' rounded ends take more than a byte.
		local col = utf8.len(string.sub(rows[4], 1, at - 1)) or 0
		t:mouse("press", col, 3)
		t:mouse("release", col, 3)
		t:mouse("press", 0, 3)
	end
	assert(clicked == 2, `clicked {clicked} times`)
	statusline.remove("clicky")
	greed.option.set("statusline-pills", false)
end)

test("the mode shows as its style calls it, and the style's name picks another", function(t)
	t:buffer("|abc")
	local left, right = t:status()
	assert(left and string.find(left, "NORMAL", 1, true), left)
	assert(right and string.find(right, "helix", 1, true), right)
	t:keys("i")
	left = t:status()
	assert(left and string.find(left, "INSERT", 1, true), left)
	t:keys("esc v")
	left = t:status()
	assert(left and string.find(left, "SELECT", 1, true), left)
	t:keys("esc")
	local rows = t:draw(80, 4)
	local at = string.find(rows[4], "helix", 1, true)
	assert(at, rows[4])
	local col = utf8.len(string.sub(rows[4], 1, at - 1)) or 0
	t:mouse("press", col, 3)
	t:mouse("release", col, 3)
	local picker = t:floats()[1]
	assert(picker and string.find(picker, "Select text, then say", 1, true), tostring(picker))
	t:keys("esc")
end)
