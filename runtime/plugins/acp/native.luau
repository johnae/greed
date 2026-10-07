-- Greed's own agent: a loop in the editor with a model from the models
-- plugin, rather than a program speaking ACP. It talks to any provider
-- the models plugin knows (Anthropic, or anything with OpenAI's API, like
-- berget or a local Ollama), uses the tools Greed offers every agent plus
-- editing files and running commands, and asks before it edits or runs
-- anything, the same way ACP agents ask. Its session is like theirs, so
-- the transcript, the session list and subagents work the same. Each
-- session is written down as it goes, to take up again (saved.luau), and
-- compacted as it nears the model's limit (compact.luau).

local greed = require("@greed")
local core = require("@core")
local agent = require("@agent")
local models = require("@models")
local vcs = require("@vcs")
local session = require("./session")
local saved = require("./saved")
local compact = require("./compact")

type Session = session.Session

local M = {}

--- The role played by the model it uses, unless it's started with
--- another; without a model in that role it uses `reasoning`.
M.ROLE = "agent"
models.fallback(M.ROLE, "reasoning", "Greed's own agent")
models.fallback(compact.ROLE, M.ROLE, "compacting long conversations with Greed's agent")

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
	--- Kinds of tool calls you allowed for the rest of the session. They
	--- aren't kept with it: a session taken up again asks again.
	allowed: { [string]: boolean },
	--- The tool groups it switched on.
	caller: agent.Caller,
	--- Where it works, for its prompt: worked out at its first prompt.
	env: string?,
	--- The tokens the provider last said the conversation takes, and how
	--- many messages of `said` that counted.
	reported: { tokens: number, at: number }?,
}

local states: { [number]: State } = {}

-- What a tool says after changing `buffer`, with what its language server
-- reports about it then.
local function changed(said: string, buffer: greed.Buffer?): string
	local found = if buffer then agent.problems_after({ buffer }) else nil
	return if found then `{said}\n{found}` else said
end

-- A tool of the agent's own: what the model is told, the kind of call it
-- is (for asking you), and what it does.
type Own = {
	spec: models.ToolSpec,
	kind: string,
	title: (args: any) -> string,
	run: (s: Session, args: any) -> string,
}

local object = agent.schema.object

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
			local text = core.file.text(args.path, s.cwd)
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
			agent.memory.guard(args.path, s.cwd)
			-- Through its buffer, opened if need be, so undo takes it back and
			-- its language server sees it.
			local buffer = core.file.write(
				args.path,
				args.new_text,
				{ root = s.cwd, from = from - 1, to = to, load = true }
			)
			return changed(`edited {args.path}`, buffer)
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
			agent.memory.guard(args.path, s.cwd)
			return changed(
				`wrote {args.path}`,
				core.file.write(args.path, args.text, { root = s.cwd, load = true })
			)
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

-- What `command` (a shell command line) prints in `cwd`, trimmed, or nil
-- when it fails.
local function output(command: string, cwd: string): string?
	local done = greed.process.run({ "sh", "-c", command }, { cwd = cwd })
	if done == nil or done.code ~= 0 then
		return nil
	end
	local text = string.match(done.stdout, "^%s*(.-)%s*$")
	return if text and text ~= "" then text else nil
end

-- How many lines `args` print in `repo`, or "?" when they fail.
local function count(repo: vcs.Repo, args: { string }): string
	local text = vcs.repo.run(repo, args)
	return if text then tostring(select(2, string.gsub(text, "\n", ""))) else "?"
end

-- Where the agent works, as lines for its prompt: the system and shell,
-- and the project's version control. Worked out once a session.
local function environment(root: string): string
	local lines = {}
	local system_name = output("uname -sr", root)
	local shell_name = output('basename "${SHELL:-sh}"', root)
	if system_name then
		table.insert(lines, `The system is {system_name}; the shell is {shell_name or "sh"}.`)
	end
	local repo = vcs.repo.repo_of(root .. "/.")
	if repo and repo.kind == "jj" then
		local described = vcs.repo.trimmed(
			repo,
			{ "log", "-r", "@", "--no-graph", "-T", "description.first_line()" }
		)
		table.insert(
			lines,
			`The project is a jj repository (use jj, not git). The working copy's change `
				.. (if described then `is "{described}"` else "has no description yet")
				.. `, with {count(repo, { "diff", "--name-only" })} files changed when the session started.`
		)
	elseif repo then
		local branch = vcs.repo.trimmed(repo, { "rev-parse", "--abbrev-ref", "HEAD" })
		local changed = count(repo, { "status", "--porcelain" })
		table.insert(
			lines,
			`The project is a git repository on branch {branch or "?"}, with {changed} `
				.. "files changed when the session started."
		)
	end
	return table.concat(lines, " ")
end

-- What the model is told about where it is and how to work.
local function system(s: Session, env: string?): string
	local lines = {
		"You are Greed's coding agent, working in the Greed editor with the user. You can read and "
			.. "search the project, edit files and run commands with the tools you have.",
		`The project is at {s.root}; paths are relative to it. It's {os.date(
			"%A %Y-%m-%d %H:%M %Z"
		)}.` .. (if env and env ~= "" then " " .. env else ""),
		"A user's message may start with an <editor-context> block: what they had on screen as "
			.. "they wrote it. It's left out when nothing changed since their last message.",
		"Find your way with focus (what the user is looking at), symbols, grep and files before "
			.. "reading whole files. Files are read as the user has them, unsaved changes included. "
			.. "Edit with edit_file, giving enough of the old text to match once.",
		"More tools come in groups you switch on with the tools tool when you need them: the "
			.. "repo map and the user's working set, renaming and the language server's fixes, "
			.. "history, notes, plugins and more.",
		"When the user asks for something new in Greed itself (a command, keys, a panel, an "
			.. "integration like a GitHub client), build it as a plugin with the plugins group: "
			.. "plugin_guide, then plugin_try until it passes, then plugin_install, which installs "
			.. "it in their own config after they review it. Don't write it into the project, even "
			.. "when the project is Greed's own code, unless they ask you to change the project.",
		"Keep your plan for bigger tasks with plan_read and plan_write, where the user sees and "
			.. "changes it. Follow the decisions the decisions tool lists as accepted.",
		"Be brief: say what you did and what's left, not every step.",
		agent.memory.prompt(s.root),
	}
	local found = instructions(s.root)
	if found then
		table.insert(lines, "The project's instructions for agents follow.\n\n" .. found)
	end
	return table.concat(lines, "\n\n")
end

-- The tools the model is told about now (Greed's tools for agents in the
-- groups it has, and its own), and every tool it may call, by name, with
-- what to do for each.
local function tools(state: State): ({ models.ToolSpec }, { [string]: Own | agent.Tool })
	local specs: { models.ToolSpec } = {}
	local by_name: { [string]: Own | agent.Tool } = {}
	for _, tool in agent.offered(state.caller) do
		table.insert(
			specs,
			{ name = tool.name, description = tool.description, input = tool.input }
		)
	end
	for _, tool in agent.tools() do
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

-- The arguments that best say what a call of one of Greed's tools is about,
-- in the order they're looked for.
local TELLING = { "path", "file", "query", "pattern", "name", "symbol", "group", "url", "command" }

-- A call of one of Greed's tools as its row in the transcript names it:
-- the tool and what it's about, like "read src/main.rs".
local function title_of(s: Session, c: models.Call): string
	for _, key in TELLING do
		local value = c.input[key]
		if type(value) == "string" and value ~= "" then
			if key == "path" or key == "file" then
				value = core.project.relative(value, s.root)
			end
			local line = string.match(value, "^[^\n]*") or value
			return `{c.name} {core.text.clip(line, 50)}`
		end
	end
	return c.name
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
	local registered = if own then nil else found :: agent.Tool
	local kind = if own then own.kind else (registered and registered.kind) or "read"
	local tool: session.Tool = {
		id = c.id,
		title = if own then own.title(c.input) else title_of(s, c),
		kind = kind,
		status = "pending",
		detail = {},
		output = {},
		open = false,
	}
	s.tools[c.id] = tool
	table.insert(s.entries, { kind = "tool", tool = tool })
	s.tool = tool.title
	if type(c.input.path) == "string" then
		s.where = { path = core.project.resolve(c.input.path, s.cwd) }
	end
	s.changed()
	-- Its own tools all change something; Greed's ask unless they only
	-- read or put what they do in front of you themselves.
	local asks = own ~= nil or (registered ~= nil and agent.asks(registered))
	if asks and not allowed(s, state, tool.title, kind) then
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
		local tool = registered :: agent.Tool
		local wrong = agent.check(tool, c.input)
		if wrong then
			error(wrong, 0)
		end
		return agent.as_text(tool.run(c.input, state.caller))
	end)
	local text = if ok then result else agent.error_text(result)
	tool.status = if ok then "completed" else "failed"
	local lines = string.split(text, "\n")
	while #lines > 0 and lines[#lines] == "" do
		table.remove(lines)
	end
	-- A failure's first line says why; the rest is there unfolded.
	local summary = session.summary(if ok then lines else { lines[1] }, s.root)
	tool.detail = if summary then { summary } else {}
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

-- Writes `s` down to take up again, once it has been asked something.
local function keep(s: Session, state: State)
	if saved.first_asked(s) == nil then
		return
	end
	local groups = {}
	for group, on in state.caller.groups do
		if on then
			table.insert(groups, group)
		end
	end
	table.sort(groups)
	saved.store(s, { role = state.role, groups = groups, said = state.said })
end

-- About how many tokens the next request takes, with `extra` characters
-- (its system prompt and tools) when the provider hasn't said yet.
local function estimate(state: State, extra: number): number
	local reported = state.reported
	if reported then
		return reported.tokens + compact.tokens(state.said, reported.at + 1)
	end
	return compact.tokens(state.said, 1, extra)
end

-- Replaces all but the last few turns of what `s` said with the model's
-- summary of them, shown in the transcript as a folded row with the
-- summary in it. False and why when it can't.
local function compact_now(s: Session, state: State): (boolean, string?)
	local upto = compact.cut(state.said)
	if upto == nil then
		return false, "there's too little to compact yet"
	end
	local before = s.tool
	s.tool = "compacting the conversation"
	s.changed()
	local role = if models.roles[compact.ROLE] then compact.ROLE else state.role
	local summary, err = compact.summarise(role, state.said, upto)
	s.tool = before
	if summary == nil then
		table.insert(
			s.entries,
			{ kind = "note", text = `couldn't compact the conversation: {err}` }
		)
		s.changed()
		return false, err
	end
	state.said = compact.replace(state.said, upto, summary)
	state.reported = nil
	s.tokens = compact.tokens(state.said)
	local tool: session.Tool = {
		id = `compact-{greed.now()}-{#s.entries}`,
		title = `conversation compacted ({upto - 1} messages → summary)`,
		kind = "other",
		status = "completed",
		detail = {},
		output = string.split(summary, "\n"),
		open = false,
	}
	s.tools[tool.id] = tool
	table.insert(s.entries, { kind = "tool", tool = tool })
	keep(s, state)
	s.changed()
	return true, nil
end

-- Turns a prompt into an answer: the model's turns, and the tools it asks
-- for between them, until it's done.
local function prompt(s: Session, text: string, context: string?): (boolean, string?)
	local state = states[s.id]
	if s.status == "working" or s.status == "waiting" then
		return false, "the agent is still working; stop it first"
	end
	state.cancelled = false
	s.failed = nil
	table.insert(s.entries, { kind = "user", text = text })
	local fresh = session.fresh_context(s, context)
	local said = if fresh then `{fresh}\n\n{text}` else text
	table.insert(state.said, { role = "user", text = said } :: models.Said)
	s.status = "working"
	s.since = greed.now()
	s.changed()
	state.env = state.env or environment(s.root)
	-- The same for every turn of this prompt, so providers can cache it,
	-- until the hour changes and the time in it with it.
	local said_system, said_hour = system(s, state.env), os.date("%Y-%m-%d %H")
	-- Once a summary fails, it isn't asked for again until the next prompt.
	local may_compact = true
	for _ = 1, MAX_TURNS do
		if os.date("%Y-%m-%d %H") ~= said_hour then
			said_system, said_hour = system(s, state.env), os.date("%Y-%m-%d %H")
		end
		-- Again each turn, for the groups it switched on in the last.
		local specs, by_name = tools(state)
		local room = models.window(state.role) * compact.THRESHOLD
		local extra = #said_system + #greed.json.encode(specs)
		if may_compact and estimate(state, extra) > room and compact.cut(state.said) then
			may_compact = compact_now(s, state)
		end
		local turn, err = models.turn(state.role, {
			system = said_system,
			said = state.said,
			tools = specs,
		}, function(piece)
			say(s, piece)
		end)
		if turn == nil then
			s.failed = `the model failed: {err}`
			table.insert(s.entries, { kind = "note", text = s.failed })
			break
		end
		-- It answered, so nothing keeps it from working.
		s.problem = nil
		table.insert(
			state.said,
			{ role = "assistant", text = turn.text, calls = turn.calls } :: models.Said
		)
		if turn.tokens then
			state.reported = { tokens = turn.tokens, at = #state.said }
		end
		s.tokens = turn.tokens or s.tokens
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
		keep(s, state)
		if state.cancelled then
			table.insert(s.entries, { kind = "note", text = "stopped: cancelled" })
			break
		end
	end
	s.status = "idle"
	keep(s, state)
	s.changed()
	return true, nil
end

-- The roles the models plugin knows, as the models to pick from.
local function roles(): { session.Mode }
	local list = {}
	for name, role in models.roles do
		if role then
			table.insert(
				list,
				{ id = name, name = name, description = `{role.model} at {role.provider}` }
			)
		end
	end
	table.sort(list, function(a: session.Mode, b: session.Mode)
		return a.id < b.id
	end)
	return list
end

-- Has `s` use the model playing `role`.
local function use(s: Session, state: State, role: string)
	state.role = role
	s.model = role
	s.window = models.window(role)
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
		use(s, states[s.id], id)
		session.check(s)
		s.changed()
		return true, nil
	end,
	check = function(s)
		return models.check(states[s.id].role)
	end,
}

-- A new session's id: when it started, and a few letters to tell apart
-- sessions started in the same second.
local function new_id(): string
	local salt = greed.hash.sha256(`{greed.now()} {math.random()}`)
	return `{os.date("%Y%m%d-%H%M%S")}-{string.sub(salt, 1, 8)}`
end

--- A session of Greed's own agent for the project at `root`, using the
--- model in role `role` (by default `M.ROLE`, else `reasoning`). With
--- `resume`, the id of a session kept from before, it takes that up where
--- it left off: its transcript, what was said, its model and tool groups.
function M.start(opts: {
	name: string,
	agent: string,
	root: string,
	role: string?,
	resume: string?,
	decide: ((permission: session.Permission) -> string?)?,
	changed: () -> (),
}): (Session?, string?)
	local kept = if opts.resume then saved.load(opts.root, opts.resume) else nil
	if opts.resume and kept == nil then
		return nil, "its conversation isn't kept any more"
	end
	local s = session.start_driven({
		name = opts.name,
		agent = opts.agent,
		root = opts.root,
		cwd = opts.root,
		decide = opts.decide,
		changed = opts.changed,
		driver = DRIVER,
	})
	local role = opts.role or models.playing(M.ROLE)
	local state: State =
		{ said = {}, role = role, cancelled = false, allowed = {}, caller = agent.caller() }
	states[s.id] = state
	s.session_id = if kept then kept.id else new_id()
	if kept then
		s.entries = kept.entries
		for _, entry in s.entries do
			if entry.tool then
				s.tools[entry.tool.id] = entry.tool
			end
		end
		table.insert(s.entries, { kind = "note", text = "taken up again" })
		state.said = kept.said
		if models.roles[kept.role] then
			role = kept.role
		end
		for _, group in kept.groups do
			state.caller.groups[group] = true
		end
	end
	s.models = roles()
	use(s, state, role)
	session.check(s)
	return s, nil
end

--- Compacts the conversation of `s`, a session of Greed's own agent, now:
--- the model summarises all but its last few turns. False and why when it
--- can't.
function M.compact(s: Session): (boolean, string?)
	local state = states[s.id]
	if state == nil then
		return false, "only Greed's own agent can be compacted here"
	elseif s.status == "working" or s.status == "waiting" then
		return false, "the agent is working; wait for it or stop it first"
	end
	s.status = "working"
	s.since = greed.now()
	local ok, err = compact_now(s, state)
	s.status = "idle"
	s.changed()
	return ok, err
end

--- Switches tool group `group` on for the session `s`, as the agent would
--- with the tools tool, e.g. to start it with the tools a task needs.
function M.switch_on(s: Session, group: string)
	local state = states[s.id]
	if state then
		state.caller.groups[group] = true
	end
end

return M
