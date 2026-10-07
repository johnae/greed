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
	assert(string.find(drawn, "╰─  waiting for you  enter answers · 0s ─", 1, true), drawn)
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
	local bottom = ""
	for _, mark in greed.view():buffer():decorations("acp-live") do
		for _, piece in (mark.lines or {})[1] or {} do
			bottom ..= piece.text
		end
	end
	assert(string.find(bottom, " 1.5k / 200k tokens ─╯", 1, true), bottom)
end)
