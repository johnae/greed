local test = require("@greed/test")
local greed = require("@greed")
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

-- Claude Code's permission hook for the terminal `term`, as `greed ctl
-- agent_permission` runs it: in the background, since it waits for you,
-- giving back what it prints once it's done.
local function permission(term: terminal.Term, input: { [string]: any }): { printed: string? }
	local tool: agent.Tool? = nil
	for _, found in agent.tools() do
		if found.name == "agent_permission" then
			tool = found
		end
	end
	local out: { printed: string? } = {}
	greed.spawn(function()
		out.printed = (tool :: agent.Tool).run(
			{ terminal = term.buffer:id(), hook = input },
			agent.caller()
		)
	end)
	return out
end

local ASKS = {
	hook_event_name = "PermissionRequest",
	tool_name = "Bash",
	tool_input = { command = "npm test" },
	permission_suggestions = { { type = "addRules", rules = { { toolName = "Bash" } } } },
}

test(
	"Claude Code's question waits in Greed while you're elsewhere, answered from anywhere",
	function(t)
		t:buffer("|")
		local term = terminal.open({ "sh", "-c", "sleep 5" })
		greed.view():split("right", greed.create_buffer("text", "elsewhere")):focus()
		local asked = permission(term, ASKS)
		t:wait(10)
		assert(asked.printed == nil, "held")
		local found = assert(core.objects.get(`terminal:{term.buffer:id()}`))
		local names = {}
		for _, action in core.objects.actions(found) do
			table.insert(names, action.name)
		end
		local offered = table.concat(names, " ")
		assert(
			string.find(offered, "allow-always", 1, true)
				and string.find(offered, "reject", 1, true),
			offered
		)
		-- The status says what it asks, for the hub and the notification.
		local said = nil
		for _, one in agent.status().agents do
			if one.id == found.id then
				said = one.question
			end
		end
		assert(said == "Bash: npm test", tostring(said))
		-- Only you answer it.
		local ok = pcall(agent.call, "act", { id = found.id, action = "allow" }, agent.caller())
		assert(asked.printed == nil and ok ~= nil, "an agent can't")
		assert(core.objects.act(found, "allow-always"))
		t:wait_for(function()
			return asked.printed ~= nil
		end)
		local decision = greed.json.decode(tostring(asked.printed)).hookSpecificOutput.decision
		assert(decision.behavior == "allow" and decision.updatedPermissions[1].type == "addRules")
		terminal.close(term)
	end
)

test("looking at Claude Code's terminal leaves the question to its own screen", function(t)
	t:buffer("|")
	local term = terminal.open({ "sh", "-c", "sleep 5" })
	-- Asked while you look at it: it asks there at once.
	local now = permission(term, ASKS)
	t:wait_for(function()
		return now.printed ~= nil
	end)
	assert(now.printed == "", tostring(now.printed))
	-- Asked while you're elsewhere, held until you look.
	greed.view():split("right", greed.create_buffer("text", "elsewhere")):focus()
	local later = permission(term, ASKS)
	t:wait(10)
	assert(later.printed == nil, "held")
	term.buffer:views()[1]:focus()
	t:wait_for(function()
		return later.printed ~= nil
	end)
	assert(later.printed == "", "let go for its own screen")
	terminal.close(term)
end)
