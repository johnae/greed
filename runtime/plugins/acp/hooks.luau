-- Agents in terminals saying how they're doing, through their hooks:
-- `greed ctl agent_hook terminal=$GREED_TERMINAL_ID hook=@-` from a Claude
-- Code hook passes on what the hook was given (on stdin), and this works
-- out whether the agent is working, waiting for you or idle. Hooks are
-- told what happened rather than guessed from the screen, which any
-- program could print.

local core = require("@core")
local agent = require("@agent")
local terminal = require("@terminal")

local M = {}

--- What a Claude Code hook's input says about the agent: its state, "gone"
--- when the session ended, or nil when it says nothing about that.
function M.state_of(hook: { [string]: any }): (terminal.AgentState | "gone")?
	local event = hook.hook_event_name
	if event == "UserPromptSubmit" or event == "PreToolUse" or event == "PostToolUse" then
		return "working"
	elseif event == "Stop" or event == "SessionStart" then
		return "idle"
	elseif event == "SessionEnd" then
		return "gone"
	elseif event == "Notification" then
		local kind = hook.notification_type
		if kind == "permission_prompt" or kind == "elicitation_dialog" then
			return "waiting"
		elseif kind == "idle_prompt" then
			return "idle"
		end
		-- Older versions say it only in the message.
		local message = string.lower(tostring(hook.message or ""))
		if string.find(message, "permission", 1, true) then
			return "waiting"
		elseif string.find(message, "waiting for your input", 1, true) then
			return "idle"
		end
	end
	return nil
end

agent.tool({
	name = "agent_hook",
	shell_only = true,
	description = "For an agent's hooks in one of Greed's terminals: says what happened (the "
		.. "hook's input as JSON) so Greed knows whether the agent works, waits for you or "
		.. "is idle. Claude Code: `greed ctl agent_hook terminal=$GREED_TERMINAL_ID "
		.. "hook=@-` (the input on stdin)",
	input = agent.schema.object({
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
