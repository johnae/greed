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
