local test = require("@greed/test")
local core = require("@core")
local terminal = require("@terminal")

-- Opens a terminal running a program that waits, and gathers the nudges
-- said about it.
local function open(): (terminal.Term, { string })
	local term = terminal.open({ "sh", "-c", "sleep 30" })
	local id = `terminal:{term.buffer:id()}`
	local nudged: { string } = {}
	core.objects.on_changed(function(changed)
		if changed == id then
			table.insert(nudged, changed)
		end
	end)
	return term, nudged
end

test("a trusted report wins over one a program could have printed", function(t)
	t:buffer("|")
	local term, nudged = open()
	terminal.agent_report(
		term.buffer,
		{ source = "bell", trusted = false, name = "codex", state = "waiting" }
	)
	local agent = term.agent :: terminal.Agent
	assert(agent.state == "waiting" and not agent.trusted and agent.source == "bell")
	assert(#nudged == 1, "nudged once")
	terminal.agent_report(
		term.buffer,
		{ source = "hook", trusted = true, name = "claude", state = "working" }
	)
	local hooked = term.agent :: terminal.Agent
	assert(hooked.state == "working" and hooked.trusted and hooked.name == "claude", hooked.state)
	assert(core.attention.of(term.buffer) == nil, "working needs nothing")
	-- A newer untrusted report doesn't overrule the hook.
	terminal.agent_report(
		term.buffer,
		{ source = "bell", trusted = false, name = "claude", state = "waiting" }
	)
	assert((term.agent :: terminal.Agent).state == "working")
	-- The same again changes nothing, so nobody is nudged.
	local count = #nudged
	terminal.agent_report(
		term.buffer,
		{ source = "hook", trusted = true, name = "claude", state = "working" }
	)
	assert(#nudged == count, "no change, no nudge")
	-- With the hook gone, what the bell says is all there is.
	terminal.agent_report(term.buffer, { source = "hook", trusted = true, name = "claude" })
	assert((term.agent :: terminal.Agent).source == "bell")
	terminal.close(term)
end)

test("when its program ends, a terminal has no agent, whatever was said last", function(t)
	t:buffer("|")
	local term = terminal.open({ "sh", "-c", "sleep 0.2; exit 3" })
	terminal.agent_report(
		term.buffer,
		{ source = "hook", trusted = true, name = "claude", state = "waiting" }
	)
	assert(core.attention.of(term.buffer), "waiting needs you")
	t:wait_for(function()
		return term.agent == nil
	end)
	local need = core.attention.of(term.buffer)
	assert(need == nil or need.reason ~= "claude waits for your answer", "no longer waiting")
	terminal.close(term)
end)
