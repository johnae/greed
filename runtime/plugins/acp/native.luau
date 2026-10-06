-- Greed's own agent: a loop in the editor with a model from the models
-- plugin, rather than a program speaking ACP. It talks to any provider
-- the models plugin knows (Anthropic, or anything with OpenAI's API, like
-- berget or a local Ollama), uses the tools Greed offers every agent plus
-- editing files and running commands, and asks before it edits or runs
-- anything, the same way ACP agents ask. Its session is like theirs, so
-- the transcript, the agents overview and subagents work the same.

local greed = require("@greed")
local agent = require("@agent")
local models = require("@models")
local session = require("./session")

type Session = session.Session

local M = {}

--- The role played by the model it uses, unless it's started with
--- another; without a model in that role it uses `reasoning`.
M.ROLE = "agent"

-- Turns one prompt may take, so a model that keeps calling tools stops.
local MAX_TURNS = 50

-- The most of a tool's result the model gets back, in characters.
local MAX_RESULT = 30000

-- The most of a project's instructions (AGENTS.md, CLAUDE.md) it reads.
local MAX_INSTRUCTIONS = 20000

local ALLOW = {
	{ id = "once", name = "Allow once", kind = "allow_once" },
	{ id = "always", name = "Allow always", kind = "allow_always" },
	{ id = "no", name = "Reject", kind = "reject_once" },
}

-- What each session keeps between prompts.
type State = {
	said: { models.Said },
	role: string,
	cancelled: boolean,
	--- Kinds of tool calls you allowed for the rest of the session.
	allowed: { [string]: boolean },
}

local states: { [number]: State } = {}

-- `path` in the session's folder.
local function absolute(s: Session, path: string): string
	return if string.sub(path, 1, 1) == "/" then path else `{s.cwd}/{path}`
end

-- The open buffer for `path`, if there is one.
local function open_buffer(path: string): greed.Buffer?
	for _, buffer in greed.buffers() do
		if buffer:path() == path then
			return buffer
		end
	end
	return nil
end

-- `path`'s text as you have it, unsaved changes included.
local function read(path: string): string?
	local buffer = open_buffer(path)
	if buffer then
		return buffer:text()
	end
	return (greed.fs.read(path))
end

-- Writes `text` to `path` through its buffer when it's open, so undo takes
-- it back, and saves it.
local function write(path: string, text: string)
	local buffer = open_buffer(path)
	if buffer then
		buffer:edit(function(e)
			e:replace(0, buffer:len(), text)
		end)
		buffer:save()
		return
	end
	local ok, err = greed.fs.write(path, text)
	if not ok then
		error(err, 0)
	end
end

-- A tool of the agent's own: what the model is told, the kind of call it
-- is (for asking you), and what it does.
type Own = {
	spec: models.ToolSpec,
	kind: string,
	title: (args: any) -> string,
	run: (s: Session, args: any) -> string,
}

local function object(properties: { [string]: any }, required: { string }): { [string]: any }
	return { type = "object", properties = properties, required = required }
end

local OWN: { Own } = {
	{
		spec = {
			name = "edit_file",
			description = "Replace text in a file: `old_text` must appear in it exactly once (give enough "
				.. "lines around it to be sure), and becomes `new_text`. An open file is edited as the "
				.. "user has it, and saved",
			input = object({
				path = { type = "string" },
				old_text = { type = "string" },
				new_text = { type = "string" },
			}, { "path", "old_text", "new_text" }),
		},
		kind = "edit",
		title = function(args)
			return `Edit {args.path}`
		end,
		run = function(s, args)
			local path = absolute(s, args.path)
			local text = read(path)
			if text == nil then
				error(`there's no file {args.path}`, 0)
			end
			local from, to = string.find(text, args.old_text, 1, true)
			if from == nil or to == nil then
				error(`old_text isn't in {args.path}`, 0)
			end
			if string.find(text, args.old_text, to + 1, true) then
				error(`old_text is in {args.path} more than once; give more of it`, 0)
			end
			write(path, string.sub(text, 1, from - 1) .. args.new_text .. string.sub(text, to + 1))
			return `edited {args.path}`
		end,
	},
	{
		spec = {
			name = "write_file",
			description = "Write a file's whole text, making it (and its folders) if it's new",
			input = object(
				{ path = { type = "string" }, text = { type = "string" } },
				{ "path", "text" }
			),
		},
		kind = "edit",
		title = function(args)
			return `Write {args.path}`
		end,
		run = function(s, args)
			write(absolute(s, args.path), args.text)
			return `wrote {args.path}`
		end,
	},
	{
		spec = {
			name = "run",
			description = "Run a shell command in the project's folder and get what it printed and how "
				.. "it exited: for tests, builds, version control. Don't use it to read or search files; "
				.. "read, grep and files see unsaved changes",
			input = object({ command = { type = "string" } }, { "command" }),
		},
		kind = "execute",
		title = function(args)
			return `Run {args.command}`
		end,
		run = function(s, args)
			local done, err = greed.process.run({ "sh", "-c", args.command }, { cwd = s.cwd })
			if done == nil then
				error(err or "it didn't start", 0)
			end
			local out = done.stdout .. (if done.stderr ~= "" then "\n" .. done.stderr else "")
			return `{out}\n(exit {done.code or "killed"})`
		end,
	},
}

-- The project's own instructions for agents, if it has them.
local function instructions(root: string): string?
	for _, name in { "AGENTS.md", "CLAUDE.md", ".github/copilot-instructions.md" } do
		local text = greed.fs.read(`{root}/{name}`)
		if text then
			return `{name}:\n\n{string.sub(text, 1, MAX_INSTRUCTIONS)}`
		end
	end
	return nil
end

-- What the model is told about where it is and how to work.
local function system(s: Session): string
	local lines = {
		"You are Greed's coding agent, working in the Greed editor with the user. You can read and "
			.. "search the project, edit files and run commands with the tools you have.",
		`The project is at {s.root}; paths are relative to it.`,
		"Find your way with working_set (what the user works on), repo_map, symbols, grep and "
			.. "files before reading whole files. Files are read as the user has them, unsaved "
			.. "changes included. Edit with edit_file, giving enough of the old text to match once.",
		"Keep your plan for bigger tasks with plan_read and plan_write, where the user sees and "
			.. "changes it. Follow the decisions the decisions tool lists as accepted.",
		"Be brief: say what you did and what's left, not every step.",
	}
	local found = instructions(s.root)
	if found then
		table.insert(lines, "The project's instructions for agents follow.\n\n" .. found)
	end
	return table.concat(lines, "\n\n")
end

-- A registered tool's result as text for the model.
local function as_text(result: any): string
	if type(result) == "string" then
		return result
	elseif type(result) == "table" and type(result.content) == "table" then
		local parts = {}
		for _, item in result.content do
			if type(item) == "table" and type(item.text) == "string" then
				table.insert(parts, item.text)
			end
		end
		return table.concat(parts, "\n")
	end
	return greed.json.encode(result)
end

-- Every tool the model may call: Greed's tools for agents and its own,
-- by name, with what to do for each.
local function tools(): ({ models.ToolSpec }, { [string]: Own | agent.Tool })
	local specs: { models.ToolSpec } = {}
	local by_name: { [string]: Own | agent.Tool } = {}
	for _, tool in agent.tools() do
		table.insert(
			specs,
			{ name = tool.name, description = tool.description, input = tool.input }
		)
		by_name[tool.name] = tool
	end
	for _, own in OWN do
		table.insert(specs, own.spec)
		by_name[own.spec.name] = own
	end
	return specs, by_name
end

-- Whether you let `kind` of call happen, asking unless you allowed it for
-- the session (or a policy answers).
local function allowed(s: Session, state: State, title: string, kind: string): boolean
	if state.allowed[kind] then
		return true
	end
	local chosen = session.ask(s, title, kind, ALLOW)
	if chosen == "always" then
		state.allowed[kind] = true
	end
	return chosen == "once" or chosen == "always"
end

-- Runs one call the model asked for and returns what it gets back, and
-- whether that's an error.
local function call(
	s: Session,
	state: State,
	by_name: { [string]: any },
	c: models.Call
): (string, boolean)
	local found = by_name[c.name]
	if found == nil then
		return `there's no tool called {c.name}`, true
	end
	local own = if found.spec then found :: Own else nil
	local tool: session.Tool = {
		id = c.id,
		title = if own then own.title(c.input) else c.name,
		kind = if own then own.kind else "read",
		status = "pending",
		detail = {},
		output = {},
		open = false,
	}
	s.tools[c.id] = tool
	table.insert(s.entries, { kind = "tool", tool = tool })
	s.tool = tool.title
	if type(c.input.path) == "string" then
		s.where = { path = absolute(s, c.input.path) }
	end
	s.changed()
	if own and not allowed(s, state, tool.title, own.kind) then
		tool.status = "failed"
		s.tool = nil
		return "the user didn't allow it", true
	end
	tool.status = "in_progress"
	s.changed()
	local ok, result = pcall(function(): string
		if own then
			return own.run(s, c.input)
		end
		return as_text((found :: agent.Tool).run(c.input, "agent"))
	end)
	local text = if ok then result else tostring(result)
	tool.status = if ok then "completed" else "failed"
	local lines = string.split(text, "\n")
	tool.detail =
		{ lines[1] .. (if #lines > 1 then `  (+{#lines - 1} lines, tab shows them)` else "") }
	tool.output = lines
	s.tool = nil
	if #text > MAX_RESULT then
		text = string.sub(text, 1, MAX_RESULT) .. "\n(cut short)"
	end
	return text, not ok
end

-- Adds `text` to the agent's last words in the transcript, or starts them.
local function say(s: Session, text: string)
	local last = s.entries[#s.entries]
	if last and last.kind == "agent" then
		last.text = (last.text or "") .. text
	else
		table.insert(s.entries, { kind = "agent", text = text })
	end
	s.changed()
end

-- Turns a prompt into an answer: the model's turns, and the tools it asks
-- for between them, until it's done.
local function prompt(s: Session, text: string): (boolean, string?)
	local state = states[s.id]
	if s.status == "working" or s.status == "waiting" then
		return false, "the agent is still working; stop it first"
	end
	state.cancelled = false
	table.insert(s.entries, { kind = "user", text = text })
	table.insert(state.said, { role = "user", text = text } :: models.Said)
	s.status = "working"
	s.changed()
	local specs, by_name = tools()
	for _ = 1, MAX_TURNS do
		local turn, err = models.turn(state.role, {
			system = system(s),
			said = state.said,
			tools = specs,
		}, function(piece)
			say(s, piece)
		end)
		if turn == nil then
			table.insert(s.entries, { kind = "note", text = `the model failed: {err}` })
			break
		end
		table.insert(
			state.said,
			{ role = "assistant", text = turn.text, calls = turn.calls } :: models.Said
		)
		if turn.stop ~= "tools" or #turn.calls == 0 then
			if turn.stop == "length" then
				table.insert(
					s.entries,
					{ kind = "note", text = "stopped: the answer ran out of room" }
				)
			end
			break
		end
		for _, c in turn.calls do
			local result, failed = call(s, state, by_name, c)
			table.insert(
				state.said,
				{ role = "tool", call = c.id, text = result, error = failed } :: models.Said
			)
			s.changed()
		end
		if state.cancelled then
			table.insert(s.entries, { kind = "note", text = "stopped: cancelled" })
			break
		end
	end
	s.status = "idle"
	s.changed()
	return true, nil
end

-- The roles the models plugin knows, as the models to pick from.
local function roles(): { session.Mode }
	local list = {}
	for name, role in models.roles do
		table.insert(
			list,
			{ id = name, name = name, description = `{role.model} at {role.provider}` }
		)
	end
	table.sort(list, function(a: session.Mode, b: session.Mode)
		return a.id < b.id
	end)
	return list
end

local DRIVER: session.Driver = {
	prompt = prompt,
	cancel = function(s)
		states[s.id].cancelled = true
	end,
	set_model = function(s, id)
		if models.roles[id] == nil then
			return false, `no model plays the role "{id}"`
		end
		states[s.id].role = id
		s.model = id
		s.changed()
		return true, nil
	end,
}

--- A session of Greed's own agent for the project at `root`, using the
--- model in role `role` (by default `M.ROLE`, else `reasoning`).
function M.start(opts: {
	name: string,
	agent: string,
	root: string,
	role: string?,
	decide: ((permission: session.Permission) -> string?)?,
	changed: () -> (),
}): Session
	local s = session.start_driven({
		name = opts.name,
		agent = opts.agent,
		root = opts.root,
		cwd = opts.root,
		decide = opts.decide,
		changed = opts.changed,
		driver = DRIVER,
	})
	local role = opts.role or (if models.roles[M.ROLE] then M.ROLE else "reasoning")
	states[s.id] = { said = {}, role = role, cancelled = false, allowed = {} }
	s.models = roles()
	s.model = role
	return s
end

return M
