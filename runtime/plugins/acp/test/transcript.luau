local test = require("@greed/test")
local greed = require("@greed")
local acp = require("@acp")
local models: any = require("@models")

local FAKE: acp.Agent = {
	name = "fake",
	title = "Fake",
	commands = { { "sh", `{greed.plugin.dirs().acp}/test/fake-agent.sh` } },
}

-- A session of the fake agent with its transcript in the main view, where
-- `t:draw` shows it, ready.
local function start(t: test.TestContext): any
	local s = assert(acp.start(FAKE, t:tempdir({ ["a.txt"] = "one\ntwo\n" })))
	acp.show(s)
	local panel = greed.view()
	local buffer = panel:buffer()
	panel:close()
	greed.view():show(buffer)
	t:wait_for(function()
		return s.status == "idle"
	end)
	t:wait(30)
	return s
end

-- Types `keys` at the end of the box.
local function type_in(t: test.TestContext, keys: string)
	local view = greed.view()
	local pos = view:buffer():len()
	view:set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
	t:keys(`i {keys} esc`)
end

-- Sends `text` and waits until the agent is no longer working.
local function send(t: test.TestContext, s: any, text: string)
	local keys = {}
	for char in string.gmatch(text, ".") do
		table.insert(keys, if char == " " then "space" else char)
	end
	type_in(t, table.concat(keys, " "))
	t:keys("alt-enter")
	t:wait_for(function()
		return s.status ~= "working"
	end)
	t:wait(30)
end

-- The screen's rows, without the status line, as one string.
local function screen(t: test.TestContext, width: number?): string
	local rows = t:draw(width or 70, 16)
	table.remove(rows)
	return table.concat(rows, "\n")
end

-- What the box's bottom line says.
local function bottom(): string
	local text = ""
	for _, mark in greed.view():buffer():decorations("acp-live") do
		for _, piece in (mark.lines or {})[1] or {} do
			text ..= piece.text
		end
	end
	return text
end

-- The choice highlighted in the box.
local function highlighted(): string?
	for _, mark in greed.view():buffer():decorations("acp-choices") do
		if mark.style == "ui.menu.selected" then
			return mark.text
		end
	end
	return nil
end

-- `drawn` with runs of rule and of spaces as one, to compare the shape.
local function squeeze(drawn: string): string
	local out = string.gsub(drawn, " +", " ")
	while string.find(out, "──", 1, true) do
		out = string.gsub(out, "──", "─")
	end
	return out
end

test("you write in a box that shows the agent, its mode and model, and the keys", function(t)
	start(t)
	local drawn = screen(t)
	local box =
		"╭─ Fake · Manual · Small ─ alt-enter sends · ctrl-c stops ─╮\n│ │\n╰─ ready ─╯"
	assert(string.find(squeeze(drawn), box, 1, true), drawn)
end)

test("the box grows with what you write and keeps its sides", function(t)
	start(t)
	type_in(t, "h i enter t h e r e")
	local drawn = screen(t)
	assert(
		string.find(squeeze(drawn), "\n│ hi │\n│ there │\n╰─ ready ─╯", 1, true),
		drawn
	)
	-- Each row of the box is as wide as its top.
	local top = string.match(drawn, "(╭[^\n]*)") :: string
	local side = string.match(drawn, "(│ there[^\n]*)") :: string
	assert(utf8.len(top) == utf8.len(side), `{top}\n{side}`)
end)

test("in a narrow view the keys give way to the agent's name", function(t)
	start(t)
	local drawn = screen(t, 40)
	assert(string.find(squeeze(drawn), "╭─ Fake · Manual · Small ─╮", 1, true), drawn)
	assert(not string.find(drawn, "alt-enter sends", 1, true), drawn)
end)

test("your messages and the agent's have bars beside them, yours a background", function(t)
	local s = start(t)
	send(t, s, "hello")
	local drawn = screen(t)
	assert(string.find(drawn, "▍ You\n▍ hello\n\n▍ Fake\n▍ Hello there\n", 1, true), drawn)
	local buffer = greed.view():buffer()
	local yours, theirs = 0, 0
	for _, mark in buffer:decorations("acp") do
		if mark.style == "agent.you" and mark.line then
			yours += 1
		elseif mark.style == "agent.bar" then
			theirs += 1
		end
	end
	assert(yours == 2, `your heading and message have a background: {yours}`)
	assert(theirs == 2, `the agent's heading and words have its bar: {theirs}`)
end)

test("the status says what the agent does and for how long, then that it's ready", function(t)
	local s = start(t)
	type_in(t, "b u s y")
	t:keys("alt-enter")
	t:wait_for(function()
		return s.tool ~= nil
	end)
	t:wait(2100)
	local drawn = screen(t)
	assert(string.find(drawn, "▍ ◐ Run tests\n", 1, true), "a running tool: " .. drawn)
	assert(string.find(drawn, "╰─ ● Run tests · 2s ─", 1, true), drawn)
	t:keys("ctrl-c")
	t:wait_for(function()
		return s.status == "idle"
	end)
	t:wait(30)
	assert(string.find(screen(t), "╰─ ready ─", 1, true), screen(t))
end)

test("waiting on you shows as a chip, and how much context is used on the right", function(t)
	local s = start(t)
	send(t, s, "usage")
	local strip = "╰─ ready ─ 14.2k / 200k tokens ─╯"
	assert(string.find(squeeze(screen(t)), strip, 1, true), screen(t))
	send(t, s, "edit a.txt")
	local drawn = screen(t)
	assert(
		string.find(
			drawn,
			"╰─  waiting for you  y/n or enter answers · esc hides · 0s ─",
			1,
			true
		),
		drawn
	)
	assert(string.find(drawn, "▍ ○ Edit a.txt\n", 1, true), "it waits to start: " .. drawn)
	acp.stop(s)
end)

test("with effects on, a running tool and the status spin; without, they stay still", function(t)
	local s = start(t)
	type_in(t, "b u s y")
	t:keys("alt-enter")
	t:wait_for(function()
		return s.tool ~= nil
	end)
	t:wait(30)
	local buffer = greed.view():buffer()
	local function spinners(): { string }
		local out = {}
		for _, mark in buffer:decorations("acp-live") do
			if mark.overlay then
				table.insert(out, mark.text :: string)
			end
		end
		return out
	end
	assert(#spinners() == 0, "still without effects")
	greed.option.set("effects", true)
	s.changed()
	t:wait(100)
	local first = spinners()[1]
	assert(first and string.find("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏", first, 1, true), tostring(first))
	assert(not string.find(screen(t), "╰─ ●", 1, true), "the status spins too")
	t:wait(170)
	assert(spinners()[1] ~= first, "it turns")
	t:keys("ctrl-c")
	t:wait_for(function()
		return s.status == "idle"
	end)
	t:wait(30)
	assert(#spinners() == 0, "nothing moves once it's done")
	greed.option.set("effects", false)
end)

test("tool rows say what came back in a few words, never as JSON", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one\ntwo\n" })
	greed.open(dir .. "/a.txt")
	local at = 0
	models.turn = function(_role, _request, on_text)
		at += 1
		if at == 1 then
			return {
				text = "",
				calls = {
					{ id = "c1", name = "focus", input = {} },
					{ id = "c2", name = "read", input = { path = dir .. "/a.txt" } },
					{ id = "c3", name = "buffers", input = {} },
				},
				stop = "tools",
				tokens = 1234,
			},
				nil
		end
		on_text("Done.")
		return { text = "Done.", calls = {}, stop = "done", tokens = 1500 }, nil
	end
	local s =
		assert(acp.start({ name = "greed", title = "Greed", commands = {}, native = true }, dir))
	greed.spawn(function()
		acp.prompt(s, "look")
	end)
	t:wait(30)
	local rows: { string } = {}
	for _, entry in s.entries do
		local tool = entry.tool
		if tool then
			table.insert(rows, `{tool.title} · {table.concat(tool.detail, " · ")}`)
		end
	end
	assert(rows[1] == "focus · a.txt", rows[1])
	assert(rows[2] == "read a.txt · 2 lines", rows[2])
	assert(rows[3] == "buffers · 1 item", rows[3])
	acp.show(s)
	assert(string.find(bottom(), " 1.5k / 200k tokens ─╯", 1, true), bottom())
end)

-- What's typed in the box once no question shows in it.
local function draft(): string
	return string.match(greed.view():buffer():text(), "ctrl%-c stops ─╮\n(.*)$") or "?"
end

-- Asks to edit a.txt and waits for the question.
local function ask(t: test.TestContext, s: any)
	send(t, s, "edit a.txt")
	local status = s.status
	assert(status == "waiting", status)
	local text = greed.view():buffer():text()
	assert(string.find(text, "[y] Allow once  [n] Reject", 1, true) ~= nil, text)
end

-- Waits for the agent to hear the answer, and returns what was chosen last.
local function answered(t: test.TestContext, s: any): string
	t:wait_for(function()
		return s.status == "idle"
	end)
	t:wait(30)
	local last = "?"
	for chosen in string.gmatch(greed.view():buffer():text(), "%? Edit a%.txt: ([^\n]*)") do
		last = chosen
	end
	return last
end

test("a question shows as choices in the box; letters answer outside typing", function(t)
	local s = start(t)
	ask(t, s)
	assert(string.find(bottom(), "y/n or enter answers · esc hides", 1, true), bottom())
	t:keys("n")
	assert(answered(t, s) == "Reject", greed.view():buffer():text())
	assert(not string.find(greed.view():buffer():text(), "[y]", 1, true), "the row is gone")
end)

test("while you type, enter answers and what you typed stays in the box", function(t)
	local s = start(t)
	ask(t, s)
	-- An empty box takes letters as answers, but h and i aren't any.
	t:keys("i h")
	t:keys("i")
	assert(string.find(bottom(), "enter answers · tab moves · esc hides", 1, true), bottom())
	-- With something typed, letters type.
	t:keys("y")
	local status = s.status
	assert(status == "waiting", "y typed rather than answered")
	assert(highlighted() == "[y] Allow once", tostring(highlighted()))
	t:keys("tab")
	assert(highlighted() == "[n] Reject", tostring(highlighted()))
	t:keys("enter")
	assert(answered(t, s) == "Reject", greed.view():buffer():text())
	assert(draft() == "hiy", draft())
	assert(greed.mode.get() == "helix-insert", greed.mode.get())
end)

test("esc hides the choices, leaving the question; alt-p brings them back", function(t)
	local s = start(t)
	ask(t, s)
	t:keys("esc")
	local text = greed.view():buffer():text()
	assert(not string.find(text, "[y]", 1, true), text)
	assert(string.find(text, "? Allow Edit a.txt?", 1, true), "still asked")
	assert(string.find(bottom(), "enter shows the question", 1, true), bottom())
	-- Keys do what they always do again: i starts typing.
	t:keys("i")
	assert(string.find(bottom(), "alt-p shows the question", 1, true), bottom())
	t:keys("alt-p")
	t:keys("right")
	t:keys("left")
	t:keys("enter")
	assert(answered(t, s) == "Allow once", greed.view():buffer():text())
end)

test("clicking a choice answers with it", function(t)
	local s = start(t)
	ask(t, s)
	local rows = t:draw(70, 16)
	for row, text in rows do
		local at = string.find(text, "[n] Reject", 1, true)
		if at then
			local col = utf8.len(string.sub(text, 1, at - 1)) :: number
			t:mouse("press", col + 1, row - 1)
			t:mouse("release", col + 1, row - 1)
			break
		end
	end
	assert(answered(t, s) == "Reject", greed.view():buffer():text())
end)

test("in Vim's style letters answer in normal mode, enter while typing", function(t)
	greed.option.set("editing-style", "vim")
	local s = start(t)
	ask(t, s)
	t:keys("y")
	assert(answered(t, s) == "Allow once", greed.view():buffer():text())
	-- Again, now typing with something in the box.
	ask(t, s)
	t:keys("i")
	t:keys("o")
	t:keys("k")
	t:keys("enter")
	assert(answered(t, s) == "Allow once", greed.view():buffer():text())
	assert(draft() == "ok", draft())
	greed.option.set("editing-style", "helix")
end)

test("in the vscode style letters answer only while the box is empty", function(t)
	local s = start(t)
	-- Asked from Helix's style, which `send` types in.
	ask(t, s)
	greed.option.set("editing-style", "vscode")
	local view = greed.view()
	view:set_cursor(view:buffer():len())
	t:keys("o")
	t:keys("n")
	local status = s.status
	assert(status == "waiting", "n typed rather than answered")
	t:keys("enter")
	assert(answered(t, s) == "Allow once", greed.view():buffer():text())
	assert(draft() == "on", draft())
	-- With the box empty again, a letter answers.
	t:keys("backspace")
	t:keys("backspace")
	greed.option.set("editing-style", "helix")
	ask(t, s)
	greed.option.set("editing-style", "vscode")
	t:keys("n")
	assert(answered(t, s) == "Reject", greed.view():buffer():text())
	greed.option.set("editing-style", "helix")
end)

test("undo in the box takes back only typing, never what the transcript drew", function(t)
	local s = start(t)
	send(t, s, "hello")
	local buffer = greed.view():buffer()
	local sent = buffer:text()
	t:run("undo")
	assert(buffer:text() == sent, "what was sent and the reply stay: " .. buffer:text())
	type_in(t, "n e x t")
	assert(buffer:text() == sent .. "next", buffer:text())
	t:run("undo")
	assert(buffer:text() == sent, buffer:text())
end)

test("the agent's Markdown shows as Markdown, its markup hidden", function(t)
	local s = start(t)
	send(t, s, "markdown")
	local drawn = screen(t, 70)
	assert(string.find(drawn, "Some bold and code, then:", 1, true), drawn)
	assert(not string.find(drawn, "**bold**", 1, true), "the stars are hidden: " .. drawn)
	assert(not string.find(drawn, "`code`", 1, true), "the backticks too: " .. drawn)
	-- While you type in the box, it shows as you typed it, as on the line you
	-- type on in a Markdown file.
	local view = greed.view()
	local pos = view:buffer():len()
	view:set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
	t:keys("i * * x * *")
	assert(string.find(screen(t, 70), "**x**", 1, true), screen(t, 70))
	t:keys("esc")
	acp.stop(s)
end)

test("a tool's output shows exactly as it is, its stars and backticks too", function(t)
	local s = start(t)
	send(t, s, "stars")
	local view = greed.view()
	local text = view:buffer():text()
	local at = (string.find(text, "Run python", 1, true) :: number) - 1
	view:set_selection({ ranges = { { anchor = at, head = at } }, primary = 1 })
	t:keys("tab")
	-- The cursor away from it, so nothing is shown as written for being on
	-- the cursor's line.
	view:set_cursor(0)
	local drawn = screen(t, 70)
	assert(string.find(drawn, "def f(**kwargs):", 1, true), drawn)
	assert(string.find(drawn, "return *ptr, `x`", 1, true), drawn)
	assert(string.find(drawn, "- not a list", 1, true), drawn)
	acp.stop(s)
end)
