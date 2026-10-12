local test = require("@greed/test")
local acp = require("@acp")
local terminal = require("@terminal")

test("the status line counts agents in terminals with the sessions", function(t)
	t:buffer("|")
	local term = terminal.open({ "sh", "-c", "sleep 30" })
	terminal.agent_report(
		term.buffer,
		{ source = "hook", trusted = true, name = "claude", state = "waiting" }
	)
	assert(acp.status() == "◆ 1 waiting for you", tostring(acp.status()))
	terminal.agent_report(
		term.buffer,
		{ source = "hook", trusted = true, name = "claude", state = "working" }
	)
	assert(acp.status() == "◆ 1 working", tostring(acp.status()))
	terminal.close(term)
	assert(acp.status() == nil, tostring(acp.status()))
end)

test("an agent in a terminal is in the session list, and enter goes to its terminal", function(t)
	local greed = require("@greed")
	local dir = t:tempdir({ [".git/HEAD"] = "", ["a.txt"] = "text" })
	greed.open(`{dir}/a.txt`)
	local files = greed.view()
	local term = terminal.open({ "sh", "-c", "sleep 30" }, { cwd = dir, split = "right" })
	terminal.agent_report(
		term.buffer,
		{ source = "hook", trusted = true, name = "claude", state = "waiting" }
	)
	t:keys("ctrl-\\")
	files:focus()
	acp.list(dir)
	local shown = greed.view():buffer():text()
	assert(
		string.find(shown, "claude", 1, true) and string.find(shown, "waiting for you", 1, true),
		shown
	)
	-- The cursor is on its row, the only one; a session's keys say what a
	-- terminal's row takes instead.
	t:keys("f")
	local said = t:messages()
	assert(string.find(said[#said] or "", "runs in a terminal", 1, true), table.concat(said, " / "))
	-- Its state changes in the list as it changes.
	terminal.agent_report(
		term.buffer,
		{ source = "hook", trusted = true, name = "claude", state = "working" }
	)
	assert(
		string.find(greed.view():buffer():text(), "working", 1, true),
		greed.view():buffer():text()
	)
	t:keys("enter")
	assert(greed.view():buffer() == term.buffer, "at its terminal")
	terminal.close(term)
end)
