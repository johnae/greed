-- Agents in terminals saying how they're doing, through their hooks:
-- `greed ctl agent_hook terminal=$GREED_TERMINAL_ID hook=@-` from a Claude
-- Code hook passes on what the hook was given (on stdin), and this works
-- out whether the agent is working, waiting for you or idle. Hooks are
-- told what happened rather than guessed from the screen, which any
-- program could print.

local greed = require("@greed")
local core = require("@core")
local registry = require("./registry")
local terminal = require("@terminal")
local ask = require("./ask")

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
	-- Its multiple-choice questions come as a tool it uses: waiting for you.
	if hook.hook_event_name == "PreToolUse" and hook.tool_name == "AskUserQuestion" then
		return "waiting"
	end
	return STATES[tostring(hook.hook_event_name)]
end

local HOOK_INPUT = registry.schema.object({
	terminal = { type = "number", description = "The terminal, $GREED_TERMINAL_ID" },
	hook = { type = "object", description = "What the hook was given, as JSON" },
	agent = { type = "string", description = 'Which agent (default "claude")' },
}, { "terminal", "hook" })

-- Tells the terminal `args.terminal` what its agent's hook said: its state,
-- or nil when the hook says nothing about that. Gives back the terminal and
-- the hook's input.
local function report(args: { [string]: any }): (terminal.Term, { [string]: any }, any)
	local found = core.objects.get(`terminal:{args.terminal}`)
	if found == nil then
		error(`there's no terminal {args.terminal}`, 0)
	end
	local hook: { [string]: any } = if type(args.hook) == "table" then args.hook :: any else {}
	local state = M.state_of(hook)
	local term: terminal.Term = found.value
	if state then
		-- The agent's own hooks: only `greed ctl` reaches this tool, and
		-- nothing a program prints can stand in for them.
		terminal.agent_report(term.buffer, {
			source = "hook",
			trusted = true,
			name = tostring(args.agent or "claude"),
			state = if state == "gone" then nil else state :: terminal.AgentState,
		})
	end
	return term, hook, state
end

registry.tool({
	name = "agent_hook",
	shell_only = true,
	description = "For an agent's hooks in one of Greed's terminals: says what happened (the "
		.. "hook's input as JSON) so Greed knows whether the agent works, waits for you or "
		.. "is idle. Claude Code: `greed ctl agent_hook terminal=$GREED_TERMINAL_ID "
		.. "hook=@-` (the input on stdin)",
	input = HOOK_INPUT,
	run = function(args)
		local _, _, state = report(args)
		return state or "nothing to say"
	end,
})

-- Asking you from anywhere ----------------------------------------------------
--
-- Claude Code waits for its permission hook before it shows its own
-- question, so Greed can hold the question while you aren't looking at
-- that terminal: the agent offers allow, allow-always and reject as its
-- actions there, and you answer from another session, another machine or
-- later your phone. Looking at the terminal again lets it go, and Claude
-- Code asks in its own screen as it always does; so does a question held
-- for `M.HOLD`, and one that comes while you're looking at it.

--- How long a question is held for you before Claude Code asks it in its
--- own screen, in milliseconds.
M.HOLD = 30 * 60 * 1000

--- A question held for you: what it asks, where the answer goes, and the
--- rules Claude Code offers for not asking again.
export type Held = { title: string, answer: greed.Signal, suggestions: any }

-- The questions held, by the terminal's buffer id.
local held: { [number]: Held } = {}

-- The buffer each client has its focus in, by client id.
local focused: { [number]: number } = {}

greed.on("view.focused", function(event: greed.ViewFocused)
	focused[event.client] = event.view:buffer():id()
end)

greed.on("client.detached", function(event: greed.ClientDetached)
	focused[event.client] = nil
end)

-- Whether a client attached is looking at the terminal in `buffer`: the
-- one acting now, as its focus is, or another as it last moved its focus.
local function looked_at(buffer: number): boolean
	if greed.view():buffer():id() == buffer then
		return true
	end
	for _, client in greed.client.list() do
		if client.kind ~= "headless" and focused[client.id] == buffer then
			return true
		end
	end
	return false
end

--- The question held for the terminal in `buffer`, if one is.
function M.held(buffer: number): Held?
	return held[buffer]
end

-- What a permission request asks, in a line: the tool and what it's given
-- that says the most (the command, the file).
local function asking(hook: { [string]: any }): string
	local input: { [string]: any } = if type(hook.tool_input) == "table"
		then hook.tool_input :: any
		else {}
	local what = input.command or input.file_path or input.path or input.url or input.pattern
	local tool = tostring(hook.tool_name or "a tool")
	return if what then `{tool}: {what}` else tool
end

-- What Claude Code is told for an answer, as its permission hook prints it;
-- nothing leaves the question to its own screen.
local function decision(answer: string, mine: Held): string
	local said: { [string]: any }
	if answer == "allow" then
		said = { behavior = "allow" }
	elseif answer == "allow-always" then
		said = { behavior = "allow", updatedPermissions = mine.suggestions }
	elseif answer == "reject" then
		said = { behavior = "deny", message = "The user rejected this." }
	else
		return ""
	end
	return greed.json.encode({
		hookSpecificOutput = { hookEventName = "PermissionRequest", decision = said },
	})
end

registry.tool({
	name = "agent_permission",
	shell_only = true,
	description = "For Claude Code's permission hook in one of Greed's terminals: holds the "
		.. "question for you while you aren't looking at that terminal, so you can answer it "
		.. "from anywhere, and prints the answer as the hook's decision; prints nothing for "
		.. "Claude Code to ask in its own screen. `greed ctl agent_permission "
		.. "terminal=$GREED_TERMINAL_ID hook=@-`",
	input = HOOK_INPUT,
	run = function(args)
		local term, hook = report(args)
		local id = term.buffer:id()
		if looked_at(id) or held[id] then
			return ""
		end
		local mine: Held = {
			title = asking(hook),
			answer = greed.signal(),
			suggestions = hook.permission_suggestions,
		}
		held[id] = mine
		core.objects.changed(`terminal:{id}`)
		-- Let go once you look at it, or after a while, for it to ask there.
		local since = greed.now()
		greed.spawn(function()
			while held[id] == mine do
				if looked_at(id) or greed.now() - since > M.HOLD or not term.terminal:valid() then
					mine.answer:send("there")
				end
				greed.sleep(500)
			end
		end)
		local answer = mine.answer:wait()
		held[id] = nil
		core.objects.changed(`terminal:{id}`)
		return decision(tostring(answer), mine)
	end,
})

-- Its multiple-choice questions (its AskUserQuestion tool) come before the
-- tool runs, so the same goes for them: while you aren't looking at its
-- terminal, Greed asks them as its own agent's questions are asked (a page,
-- answered from anywhere: ask.luau), and gives your answers back as the
-- tool's own, in its input.

--- What a terminal's agent asks on a page now, its first question, by the
--- terminal's buffer id.
local asking_in: { [number]: string } = {}

--- The first question the agent in the terminal in `buffer` asks on a page
--- now, if it does.
function M.asking(buffer: number): string?
	return asking_in[buffer]
end

registry.tool({
	name = "agent_ask",
	shell_only = true,
	description = "For Claude Code's PreToolUse hook on its AskUserQuestion tool, in one of "
		.. "Greed's terminals: asks its questions on a page while you aren't looking at that "
		.. "terminal, answered from anywhere, and prints them as the tool's answers; prints "
		.. "nothing for Claude Code to ask in its own screen. `greed ctl agent_ask "
		.. "terminal=$GREED_TERMINAL_ID hook=@-`",
	input = HOOK_INPUT,
	run = function(args)
		local term, hook = report(args)
		local id = term.buffer:id()
		local input: { [string]: any } = if type(hook.tool_input) == "table"
			then hook.tool_input :: any
			else {}
		local asked: { any } = if type(input.questions) == "table"
			then input.questions :: any
			else {}
		if #asked == 0 or looked_at(id) or asking_in[id] then
			return ""
		end
		-- Each question by its text, the key Claude Code answers it by.
		local questions: { ask.Question } = {}
		for _, q in asked do
			local choices: { string } = {}
			local options: { any } = if type(q.options) == "table" then q.options else {}
			for _, option in options do
				table.insert(choices, tostring(option.label))
			end
			local text = tostring(q.question)
			table.insert(questions, { id = text, question = text, choices = choices })
		end
		asking_in[id] = questions[1].question
		core.objects.changed(`terminal:{id}`)
		local answers, cancelled = ask.ask(
			`{term.agent and term.agent.name or "claude"} asks`,
			questions,
			function()
				return looked_at(id) or not term.terminal:valid()
			end
		)
		asking_in[id] = nil
		core.objects.changed(`terminal:{id}`)
		if cancelled then
			return ""
		end
		local given = table.clone(input)
		given.answers = answers
		return greed.json.encode({
			hookSpecificOutput = {
				hookEventName = "PreToolUse",
				permissionDecision = "allow",
				updatedInput = given,
			},
		})
	end,
})

-- The answers, as actions of the terminal while a question is held: the
-- same names Greed's own agent's have, and only you run them.
for _, name in { "allow", "allow-always", "reject" } do
	core.actions.action({
		kind = "terminal",
		name = name,
		doc = `{name} what the agent in it asks`,
		yours = true,
		offers = function(target)
			local term: terminal.Term = target.value
			local mine = held[term.buffer:id()]
			-- Allowing for good takes the rules Claude Code offered for it.
			return mine ~= nil and (name ~= "allow-always" or mine.suggestions ~= nil)
		end,
		run = function(target)
			local term: terminal.Term = target.value
			local mine = held[term.buffer:id()]
			if mine then
				mine.answer:send(name)
			end
		end,
	})
end

return M
