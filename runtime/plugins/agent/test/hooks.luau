local test = require("@greed/test")
local agent = require("@agent")
local core = require("@core")
local terminal = require("@terminal")
local hooks = require("../hooks")

test("Claude Code's hooks say whether it works, waits for you or is idle", function()
	local cases: { { any } } = {
		{ { hook_event_name = "UserPromptSubmit" }, "working" },
		{ { hook_event_name = "PreToolUse" }, "working" },
		{ { hook_event_name = "PermissionRequest" }, "waiting" },
		{ { hook_event_name = "Elicitation" }, "waiting" },
		{ { hook_event_name = "PermissionDenied" }, "working" },
		{ { hook_event_name = "Stop" }, "idle" },
		{ { hook_event_name = "SessionEnd" }, "gone" },
		-- A notification comes late, maybe after you answered: it says nothing.
		{ { hook_event_name = "Notification", notification_type = "permission_prompt" }, nil },
		{ { hook_event_name = "SubagentStop" }, nil },
	}
	for _, case in cases do
		local got = hooks.state_of(case[1])
		assert(got == case[2], `{case[1].hook_event_name}: {tostring(got)}`)
	end
	assert(
		table.find(hooks.EVENTS, "PermissionRequest")
			and not table.find(hooks.EVENTS, "Notification")
	)
end)

test("a terminal's agent waiting for you needs you, until its hooks say otherwise", function(t)
	t:buffer("|")
	local term = terminal.open({ "sh", "-c", "sleep 5" })
	local id = term.buffer:id()
	local tool: agent.Tool? = nil
	for _, found in agent.tools() do
		if found.name == "agent_hook" then
			tool = found
		end
	end
	local function hook(input: { [string]: any }): any
		return (tool :: agent.Tool).run({ terminal = id, hook = input }, agent.caller())
	end
	-- Only from a shell: an agent can't say another is waiting.
	local refused = agent.call("agent_hook", { terminal = id, hook = {} }, agent.caller())
	assert(refused.isError, "agents can't call it")
	hook({ hook_event_name = "PermissionRequest" })
	local need = core.attention.of(term.buffer)
	assert(need and need.reason == "claude waits for your answer", "waiting")
	assert(term.agent and term.agent.state == "waiting")
	hook({ hook_event_name = "PreToolUse" })
	assert(core.attention.of(term.buffer) == nil and (term.agent :: any).state == "working")
	hook({ hook_event_name = "SessionEnd" })
	assert(term.agent == nil, "gone")
	assert(hook({ hook_event_name = "SubagentStop" }) == "nothing to say")
	terminal.close(term)
end)
