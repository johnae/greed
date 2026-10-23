local test = require("@greed/test")
local greed = require("@greed")

test("shows the mode, the tab, the file and the position", function(t)
	t:buffer("ab\nçd|e")
	local left, right = t:status()
	assert(
		left and string.find(left, " NORMAL ", 1, true) and string.find(left, " untitled ", 1, true),
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
			and string.find(left, "untitled [+]", 1, true),
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
	assert(file_segments() == #"untitled", "one segment per letter mid-wave: " .. file_segments())
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

-- The letters lit in the status line's left side now.
local function lit_letters(): string
	local statusline = require("@statusline")
	local ctx =
		{ view = greed.view(), buffer = greed.view():buffer(), mode = greed.mode.get(), width = 80 }
	local lit = {}
	local left: { greed.StatusSegment } = statusline.build(ctx :: any).left or {}
	for _, segment in left do
		if type(segment) == "table" and string.sub(segment.style or "", 1, 4) == "=fg:" then
			table.insert(lit, segment.text)
		end
	end
	return table.concat(lit)
end

-- How many of the status line's left segments are lit letters now.
local function lit_now(): number
	return #lit_letters()
end

test("the command line coming and going doesn't send light through the file", function(t)
	greed.theme.set({ ["ui.statusline"] = { fg = "#808080", bg = "#101010" } })
	greed.option.set("effects", true)
	local dir = t:tempdir({ ["notes.txt"] = "hi" })
	greed.open(dir .. "/notes.txt")
	t:wait(700)
	t:keys(": esc")
	t:wait(200)
	-- The mode, back from COMMAND, may glow; the file's name doesn't.
	local lit = lit_letters()
	assert(not string.find(lit, "%l"), "the file isn't lit: " .. lit)
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
		right and not string.find(right, "run %d"),
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
	-- The language; a language server still starting may name itself.
	assert(
		right and not string.find(right, " rust ", 1, true),
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

test("each client's status line shows its own mode", function(t)
	t:buffer("|abc")
	local second = t:client()
	second:keys("i")
	local mine = t:status()
	local theirs = second:status()
	assert(mine and string.find(mine, " NORMAL ", 1, true), mine)
	assert(theirs and string.find(theirs, " INSERT ", 1, true), theirs)
	local rows = second:draw(40, 4)
	assert(string.find(rows[#rows], " INSERT ", 1, true), rows[#rows])
	rows = t:draw(40, 4)
	assert(string.find(rows[#rows], " NORMAL ", 1, true), rows[#rows])
end)

test("names the focused panel rather than the pane beside it", function(t)
	t:buffer("|hello")
	local notes = greed.create_buffer("notes", "")
	notes:set_name("my notes")
	local panel = greed.panel(notes, { side = "right", width = 20 })
	assert(greed.view() == panel)
	local left = t:status()
	assert(left and string.find(left, "notes: my notes", 1, true), left)
	-- A picker over it doesn't count.
	greed.float(greed.create_buffer("picker", ""), { focus = true })
	left = t:status()
	assert(left and string.find(left, " untitled ", 1, true), left)
end)

test("a name that starts with its kind says the kind once", function(t)
	local board = greed.create_buffer("board", "")
	board:set_name("board System-Stats")
	greed.view():show(board)
	local left = t:status()
	assert(left and string.find(left, " board: System-Stats ", 1, true), left)
end)

test("the position is where the cursor is drawn, after a selecting motion too", function(t)
	t:buffer("|hello world")
	t:keys("w")
	local _, right = t:status()
	assert(right and string.find(right, " 1:6 ", 1, true), "on the space: " .. tostring(right))
	t:keys(";")
	_, right = t:status()
	assert(right and string.find(right, " 1:6 ", 1, true), "collapsed: " .. tostring(right))
	-- A bar sits between characters, at the head.
	t:keys("a")
	_, right = t:status()
	assert(right and string.find(right, " 1:7 ", 1, true), "typing: " .. tostring(right))
end)

test("typing a command says COMMAND, not the typing mode", function(t)
	t:buffer("|abc")
	t:keys(":")
	local left = t:status()
	assert(left and string.find(left, " COMMAND ", 1, true), tostring(left))
	t:keys("esc")
	left = t:status()
	assert(left and string.find(left, " NORMAL ", 1, true), tostring(left))
	t:keys("/")
	left = t:status()
	assert(left and string.find(left, " PROMPT ", 1, true), tostring(left))
	t:keys("esc")
end)

test("recording shows once while the message saying so is up", function(t)
	local statusline = require("@statusline")
	t:buffer("|abc")
	t:keys("Q")
	local function left(message: string?): string
		local parts = statusline.build({
			view = greed.view(),
			buffer = greed.view():buffer(),
			mode = greed.mode.get(),
			message = message,
			width = 100,
		})
		local texts = {}
		local segments: { greed.StatusSegment } = parts.left or {}
		for _, segment in segments do
			table.insert(texts, if type(segment) == "string" then segment else segment.text)
		end
		return table.concat(texts, " ")
	end
	for _, message in { "recording @@", "something else" } do
		local line = left(message)
		local _, count = string.gsub(line, "recording @@", "")
		assert(count == 1, line)
	end
	t:keys("Q")
end)

test(":messages shows the last messages whole, stack traces too", function(t)
	t:buffer("|x")
	greed.echo("saved")
	greed.echo("it failed\nstack traceback:\n\tsomewhere")
	local listed = greed.messages()
	assert(listed[#listed] == "it failed\nstack traceback:\n\tsomewhere", listed[#listed])
	t:run("messages")
	local text = greed.view():buffer():text()
	assert(string.find(text, "saved\n\nit failed\nstack traceback:\n\tsomewhere", 1, true), text)
end)

test("a long path gives way, keeping its end, [+] and the right side", function(t)
	local dir = t:tempdir({
		["src/components/forms/inputs/validation/rules/required_field_validator.rs"] = "x\n",
	})
	greed.open(`{dir}/src/components/forms/inputs/validation/rules/required_field_validator.rs`)
	greed.view():buffer():edit(function(e)
		e:insert(0, "y")
	end)
	local screen = t:screen(80, 10)
	local status = screen[#screen]
	-- How much of the path fits depends on the rest, like the host's name.
	assert(string.find(status, "…%S*%.rs %[%+%]"), status)
	assert(string.find(status, "1:%d"), status)
end)

test("a piece slow to draw is drawn in the background from then on", function(t)
	local statusline = require("@statusline")
	local calls = 0
	statusline.add("right", "test-slow", function()
		calls += 1
		if calls == 1 then
			local from = os.clock()
			while os.clock() - from < 0.03 do
			end
			return "first"
		end
		return `later {calls}`
	end)
	t:buffer("|abc")
	local _, right = t:status()
	assert(right and string.find(right, "first", 1, true), right)
	-- Found slow, it isn't drawn with the status line any more: frames show
	-- what it last made until it's drawn again, at most once a second.
	_, right = t:status()
	assert(right and string.find(right, "first", 1, true) and calls == 1, `{right} {calls}`)
	t:wait(1100)
	_, right = t:status()
	t:wait(10)
	_, right = t:status()
	assert(right and string.find(right, "later", 1, true), right)
	statusline.remove("test-slow")
end)

test("shows the function and type the cursor is in, outermost first", function(t)
	-- As the languages plugin has it, which these tests may run without.
	greed.syntax.set_query(
		"rust",
		"textobjects",
		[[
(function_item body: (_) @function.inside) @function.around
(impl_item body: (_) @type.inside) @type.around
]]
	)
	t:buffer("impl Server {\n    fn listen() {\n        x|\n    }\n}\n\nfn other() {}\n")
	greed.view():buffer():set_language("rust")
	local left = t:status()
	assert(left and string.find(left, "Server › listen", 1, true), left)
	-- On the blank line out of both, set directly rather than with keys.
	local at = string.find(greed.view():buffer():text(), "\n\nfn", 1, true) :: number
	greed.view():set_selection({ ranges = { { anchor = at, head = at } }, primary = 1 })
	left = t:status()
	assert(
		left and not string.find(left, "›", 1, true) and not string.find(left, "listen", 1, true),
		left
	)
end)
