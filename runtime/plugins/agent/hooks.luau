-- Agents in terminals saying how they're doing, through their hooks:
-- `greed ctl agent_hook terminal=$GREED_TERMINAL_ID hook=@-` from a Claude
-- Code hook passes on what the hook was given (on stdin), and this works
-- out whether the agent is working, waiting for you or idle. Hooks are
-- told what happened rather than guessed from the screen, which any
-- program could print.

local core = require("@core")
local registry = require("./registry")
local terminal = require("@terminal")

local M = {}

-- The hook events that say how the agent is doing, by what they say. A
-- permission request or a question (an elicitation) comes as the prompt
-- shows; its notification only some time after.
local STATES: { [string]: terminal.AgentState | "gone" } = {
	UserPromptSubmit = "working",
	PreToolUse = "working",
	PostToolUse = "working",
	PostToolUseFailure = "working",
	PermissionDenied = "working",
	PermissionRequest = "waiting",
	Elicitation = "waiting",
	Stop = "idle",
	SessionStart = "idle",
	SessionEnd = "gone",
}

--- The hook events that say something here, by name, for asking Claude
--- Code for those hooks (claude.luau).
M.EVENTS = {} :: { string }
for event in STATES do
	table.insert(M.EVENTS, event)
end
table.sort(M.EVENTS)

--- What a Claude Code hook's input says about the agent: its state, "gone"
--- when the session ended, or nil when it says nothing about that. Its
--- notifications say nothing here: one can come after you answered the
--- prompt it was about, and the events above already said it.
function M.state_of(hook: { [string]: any }): (terminal.AgentState | "gone")?
	return STATES[tostring(hook.hook_event_name)]
end

registry.tool({
	name = "agent_hook",
	shell_only = true,
	description = "For an agent's hooks in one of Greed's terminals: says what happened (the "
		.. "hook's input as JSON) so Greed knows whether the agent works, waits for you or "
		.. "is idle. Claude Code: `greed ctl agent_hook terminal=$GREED_TERMINAL_ID "
		.. "hook=@-` (the input on stdin)",
	input = registry.schema.object({
		terminal = { type = "number", description = "The terminal, $GREED_TERMINAL_ID" },
		hook = { type = "object", description = "What the hook was given, as JSON" },
		agent = { type = "string", description = 'Which agent (default "claude")' },
	}, { "terminal", "hook" }),
	run = function(args)
		local found = core.objects.get(`terminal:{args.terminal}`)
		if found == nil then
			error(`there's no terminal {args.terminal}`, 0)
		end
		local hook: { [string]: any } = if type(args.hook) == "table" then args.hook :: any else {}
		local state = M.state_of(hook)
		if state == nil then
			return "nothing to say"
		end
		local term: terminal.Term = found.value
		-- The agent's own hooks: only `greed ctl` reaches this tool, and
		-- nothing a program prints can stand in for them.
		terminal.agent_report(term.buffer, {
			source = "hook",
			trusted = true,
			name = tostring(args.agent or "claude"),
			state = if state == "gone" then nil else state :: terminal.AgentState,
		})
		return state
	end,
})

return M
