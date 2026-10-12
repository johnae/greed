-- An agent session over the Agent Client Protocol: the agent program, its
-- ACP session, what it has said and done (the entries a transcript shows),
-- and the client side of the protocol: reading and writing files, running
-- programs and asking you for permission.
local greed = require("@greed")
local core = require("@core")
local agent = require("@agent")

local M = {}

export type Status = "starting" | "idle" | "working" | "waiting" | "exited"

--- A tool call, as the agent reports it.
export type Tool = {
	id: string,
	title: string,
	kind: string?,
	status: string?,
	--- The files it says it touches.
	locations: { string }?,
	--- A line or two about what it did: a diff's size, a bit of output.
	detail: { string },
	--- All of its output, shown when it's unfolded.
	output: { string },
	open: boolean,
	--- The `session_id` of the helper agent this call handed a task to
	--- (subagent.luau), whose transcript enter on its row shows.
	helper: string?,
}

--- A question the agent waits on you for.
export type Permission = {
	title: string,
	--- The kind of tool call it's for: "edit", "execute", ...
	kind: string?,
	--- The files the call touches, as absolute paths, when it says.
	locations: { string }?,
	options: { { id: string, name: string, kind: string } },
	answer: greed.Signal,
	--- Only you answer it, never a policy: for writes that let a plugin do
	--- more.
	firm: boolean?,
	--- What you wrote with a rejection: what to do instead.
	note: string?,
}

--- A mode the agent works in, like "plan" or "accept edits".
export type Mode = { id: string, name: string, description: string? }

--- What a transcript shows, in order. `kind` says which fields it has:
--- "user", "agent", "thought" and "note" have `text`, "tool" a `tool`,
--- "plan" its `items`, and "permission" a `permission` and, once
--- answered, what was `chosen`. A thought shows all of its text while
--- `open`, else only its first line. What was said started `since`, on
--- `greed.now()`'s clock.
export type Entry = {
	kind: string,
	text: string?,
	open: boolean?,
	since: number?,
	tool: Tool?,
	items: { { text: string, status: string } }?,
	permission: Permission?,
	chosen: string?,
}

--- Where an agent works when it has a workspace of its own.
export type Workspace = { kind: "jj" | "git", name: string, path: string, base: string? }

export type Session = {
	id: number,
	name: string,
	--- The registered agent it runs.
	agent: string,
	--- The project it's for, and where it works: the project, or its
	--- workspace.
	root: string,
	cwd: string,
	workspace: Workspace?,
	status: Status,
	--- The tool call running now, if any.
	tool: string?,
	--- What it's doing while it works and no tool runs: waiting for its
	--- model ("waiting for mistral"), "thinking" or "writing".
	doing: string?,
	--- The file it works in now, and the line (from 1) when it says.
	where: { path: string, line: number? }?,
	entries: { Entry },
	tools: { [string]: Tool },
	conn: greed.RpcConnection?,
	session_id: string?,
	--- The modes the agent offers, and the one it's in.
	modes: { Mode },
	mode: string?,
	--- The models the agent offers, and the one it uses. `model_option` is
	--- the id of the config option that picks it, for agents that offer
	--- models that way rather than with `session/set_model`.
	models: { Mode },
	model: string?,
	model_option: string?,
	--- Answers a question without asking you, with an option's id, when
	--- it returns one.
	decide: ((permission: Permission) -> string?)?,
	--- While set, updates from the agent are left out.
	quiet: boolean?,
	--- Called whenever there's something new to show.
	changed: () -> (),
	--- What runs an agent that isn't a program speaking ACP, like Greed's
	--- own: prompts, stops and model changes go to it instead.
	driver: Driver?,
	--- The editor context the last prompt took, so the same isn't sent again.
	context_sent: string?,
	--- What the user has pinned (agent.context.pinned_text), set as a
	--- prompt is sent, and what the last prompt took: each part of the
	--- context goes only when it changed, so a pinned file doesn't go
	--- again with every move of the cursor.
	pinned: string?,
	pinned_sent: string?,
	--- When the turn going on now started, on `greed.now()`'s clock.
	since: number?,
	--- How many tokens of the model's context the conversation takes, and
	--- how many it has room for, when the agent says.
	tokens: number?,
	window: number?,
	--- What keeps it from working before it's asked anything, like its
	--- model's provider having no key: the transcript says it in place of
	--- "ready".
	problem: string?,
	--- Images pasted for the next prompt, in order, and whether the agent
	--- takes images in a prompt, as it said when it started.
	attached: { Attachment }?,
	sees_images: boolean?,
	--- Why its last turn failed or it couldn't start, until a turn starts.
	failed: string?,
	--- Messages you sent while it worked, oldest first, waiting to go:
	--- Greed's own agent hears them at its next step, any agent as the
	--- next prompt once its turn ends.
	queued: { string }?,
	--- You stopped its turn (ctrl-c), until the next prompt.
	cancelled: boolean?,
	--- The helpers (subagent.luau) working on tasks it handed them now:
	--- its box counts them, and stopping its turn stops theirs.
	helpers: { Session }?,
	--- The slash commands the agent offers (ACP's
	--- `available_commands_update`), which the box completes.
	commands: { Command }?,
	--- How hard Greed's own agent's model thinks in this session, when
	--- not as its role says (`/effort`).
	effort: string?,
}

--- A slash command an agent offers: `/name`, what it does, and a hint for
--- what it takes, if anything.
export type Command = { name: string, description: string, hint: string? }

--- An image pasted for a prompt: where it's kept, its PNG bytes and its
--- size in pixels.
export type Attachment = { path: string, png: string, width: number, height: number }

--- An agent run in the editor rather than as an ACP program. `shown` is what
--- the transcript shows of a prompt, like its images' chips, when it isn't
--- what the agent is told.
export type Driver = {
	prompt: (
		session: Session,
		text: string,
		context: string?,
		shown: string?,
		images: { Attachment }?
	) -> (boolean, string?),
	cancel: (session: Session) -> (),
	set_model: (session: Session, id: string) -> (boolean, string?),
	--- Whether its model sees images now, so a prompt's images go to it
	--- (`images`) rather than only their files' paths.
	sees_images: ((session: Session) -> boolean)?,
	--- What keeps it from working now, like a missing key, if anything.
	check: ((session: Session) -> string?)?,
	--- Its session is over: it's stopped or closed.
	stop: ((session: Session) -> ())?,
}

-- A terminal the agent asked for: a program and what it printed.
type Term = {
	child: greed.Child,
	output: string,
	limit: number?,
	truncated: boolean,
	code: number?,
	done: boolean,
	-- Whoever waits for it to finish.
	waiters: { greed.Signal },
}

--- Adds `text` to the last entry if it's of `kind` ("agent", "thought",
--- "user"), or to a new one.
function M.append(session: Session, kind: string, text: string)
	local entry = session.entries[#session.entries]
	if entry and entry.kind == kind then
		entry.text = (entry.text or "") .. text
	else
		table.insert(session.entries, { kind = kind, text = text, since = greed.now() })
	end
end

local function text_of(content: any): string
	if type(content) ~= "table" then
		return ""
	elseif content.type == "text" then
		return content.text or ""
	elseif content.type == "resource_link" then
		return content.uri or ""
	end
	return `[{content.type}]`
end

-- The most of a tool's output kept to show when it's unfolded.
local OUTPUT_KEPT = 200

-- `path` from `cwd` when it's a full path inside it; anything else (a
-- name, a URI) as it is.
local function relative(path: string, cwd: string): string
	return if string.sub(path, 1, 1) == "/" then core.project.relative(path, cwd) else path
end

-- How many lines a diff from `old` to `new` adds and removes.
local function diff_size(old: string, new: string): (number, number)
	local added, removed = 0, 0
	for _, hunk in greed.diff(old, new) do
		local _, gone = string.gsub(string.sub(old, hunk.from + 1, hunk.to), "\n", "")
		local _, came = string.gsub(hunk.text, "\n", "")
		added += came
		removed += gone
	end
	return added, removed
end

-- The most of a line a tool's summary shows, in characters.
local SUMMARY_WIDTH = 60

local clip = core.text.clip

--- A tool call's title as an agent sends it, readable: an MCP tool's
--- `mcp__server__tool` is Greed's own `tool`, or `server: tool`.
function M.tool_title(title: string?): string?
	if title == nil then
		return nil
	end
	local server, rest = string.match(title, "^mcp__([^_]+)__(.+)$")
	if server == nil or rest == nil then
		return title
	end
	return if server == "greed" then rest else `{server}: {rest}`
end

--- The first line of `text`, like a command a tool runs, with "…" when
--- there's more, for places with room for one line.
function M.first_line(text: string): string
	local first = string.match(text, "^([^\n]*)\n")
	return if first then first .. " …" else text
end

--- A tool's output (`lines`, without trailing empty ones) in a few words
--- for its row in the transcript: a short line as it is, JSON as what it
--- holds, and anything longer as how many lines it has. Paths are shown
--- from `cwd`. Nil for no output.
function M.summary(lines: { string }, cwd: string?): string?
	if #lines == 0 then
		return nil
	end
	local text = table.concat(lines, "\n")
	local opening = string.match(text, "^%s*([%[{])")
	if opening then
		local ok, value = pcall(greed.json.decode, text)
		if ok and type(value) == "table" then
			if opening == "[" then
				local count = #value
				return if count == 0
					then "nothing"
					else `{count} {if count == 1 then "item" else "items"}`
			end
			local parts = {}
			local place = value.path or value.file or value.uri or value.name or value.title
			if type(place) == "string" then
				table.insert(parts, if cwd then relative(place, cwd) else place)
			end
			if type(value.text) == "string" then
				local _, breaks = string.gsub(value.text, "\n", "")
				table.insert(parts, `{breaks + 1} lines`)
			end
			if #parts == 0 then
				local count = 0
				for _ in value do
					count += 1
				end
				table.insert(parts, `{count} fields`)
			end
			return clip(table.concat(parts, ", "), SUMMARY_WIDTH)
		end
	end
	if #lines == 1 then
		return clip(lines[1], SUMMARY_WIDTH)
	end
	return `{#lines} lines`
end

-- A tool call's content as a short summary, and as all its lines to show
-- when it's unfolded. Code fences around output are left out.
local function detail_of(content: any, cwd: string): ({ string }, { string })
	local summary, output = {}, {}
	local items = if type(content) == "table" then content else {}
	for _, item in items do
		if item.type == "diff" then
			local added, removed = diff_size(item.oldText or "", item.newText or "")
			-- The tool's title names the file when it changes only one.
			local size = `+{added} -{removed}`
			table.insert(
				summary,
				if #items == 1 then size else `{relative(item.path or "", cwd)} {size}`
			)
		elseif item.type == "content" then
			local lines = {}
			for _, line in string.split(text_of(item.content), "\n") do
				if not string.match(line, "^```") then
					table.insert(lines, line)
				end
			end
			while lines[#lines] == "" do
				table.remove(lines)
			end
			local said = M.summary(lines, cwd)
			if said then
				table.insert(summary, said)
			end
			for i = 1, math.min(#lines, OUTPUT_KEPT) do
				table.insert(output, lines[i])
			end
		elseif item.type == "terminal" then
			table.insert(summary, "(in a terminal)")
		end
	end
	return summary, output
end

-- Takes in the models `from` offers: a session's start or an update. Agents
-- say them as `models` (with `session/set_model` to pick one), or as a
-- config option in the "model" category (`session/set_config_option`).
local function take_models(session: Session, from: any)
	local models = type(from.models) == "table" and from.models
	if models then
		session.models = {}
		for _, model in models.availableModels or {} do
			table.insert(session.models, {
				id = model.modelId,
				name = model.name or model.modelId,
				description = model.description,
			})
		end
		session.model = models.currentModelId
		session.model_option = nil
	end
	for _, option in (type(from.configOptions) == "table" and from.configOptions) or {} do
		if option.category == "model" and type(option.options) == "table" then
			session.models = {}
			for _, choice in option.options do
				table.insert(session.models, {
					id = choice.value,
					name = choice.name or choice.value,
					description = choice.description,
				})
			end
			session.model = option.currentValue
			session.model_option = option.id
		end
	end
end

-- The files a tool call (or an update of one) says it touches: its
-- locations and the files its diffs change, made absolute from `cwd`. Nil
-- when it names none.
local function paths_of(call: any, cwd: string): { string }?
	local found: { string } = {}
	local function add(path: any)
		if type(path) == "string" and path ~= "" then
			table.insert(found, core.project.resolve(path, cwd))
		end
	end
	for _, place in (if type(call.locations) == "table" then call.locations else {}) :: { any } do
		add(type(place) == "table" and place.path)
	end
	for _, item in (if type(call.content) == "table" then call.content else {}) :: { any } do
		if type(item) == "table" and item.type == "diff" then
			add(item.path)
		end
	end
	return if #found > 0 then found else nil
end

--- Whether `path` is in the folder `session` works in.
function M.within(session: Session, path: string): boolean
	return core.project.inside(core.project.resolve(path, session.cwd), session.cwd)
end

--- The first of `paths` outside the folder `session` works in, if any.
function M.outside(session: Session, paths: { string }): string?
	for _, path in paths do
		if not M.within(session, path) then
			return path
		end
	end
	return nil
end

-- Applies one session/update notification.
local function update(session: Session, u: any)
	local kind = u.sessionUpdate
	-- Tool calls say which files they touch.
	local place = type(u.locations) == "table" and u.locations[1]
	if place and type(place.path) == "string" then
		session.where = { path = place.path, line = place.line }
	end
	if kind == "agent_message_chunk" then
		M.append(session, "agent", text_of(u.content))
		session.doing = "writing"
	elseif kind == "agent_thought_chunk" then
		M.append(session, "thought", text_of(u.content))
		session.doing = "thinking"
	elseif kind == "user_message_chunk" then
		M.append(session, "user", text_of(u.content))
	elseif kind == "available_commands_update" then
		local commands: { Command } = {}
		for _, c in
			(if type(u.availableCommands) == "table" then u.availableCommands else {}) :: { any }
		do
			if type(c) == "table" and type(c.name) == "string" then
				local input = type(c.input) == "table" and c.input
				table.insert(commands, {
					name = (string.gsub(c.name, "^/", "")),
					description = if type(c.description) == "string" then c.description else "",
					hint = if input and type(input.hint) == "string" then input.hint else nil,
				})
			end
		end
		session.commands = commands
	elseif kind == "tool_call" then
		local detail, output = detail_of(u.content, session.cwd)
		local tool: Tool = {
			id = u.toolCallId,
			title = M.tool_title(u.title) or "a tool",
			kind = u.kind,
			status = u.status or "pending",
			locations = paths_of(u, session.cwd),
			detail = detail,
			output = output,
			open = false,
		}
		session.tools[tool.id] = tool
		table.insert(session.entries, { kind = "tool", tool = tool })
		session.tool = tool.title
	elseif kind == "tool_call_update" then
		local tool = session.tools[u.toolCallId]
		if tool == nil then
			return
		end
		tool.title = M.tool_title(u.title) or tool.title
		tool.kind = u.kind or tool.kind
		tool.status = u.status or tool.status
		tool.locations = paths_of(u, session.cwd) or tool.locations
		if u.content then
			tool.detail, tool.output = detail_of(u.content, session.cwd)
		end
		if tool.status == "completed" or tool.status == "failed" then
			if session.tool == tool.title then
				session.tool = nil
			end
			session.doing = `waiting for {session.name}`
		else
			session.tool = tool.title
		end
	elseif kind == "usage_update" then
		session.tokens = tonumber(u.used) or session.tokens
		session.window = tonumber(u.size) or session.window
	elseif kind == "config_option_update" or kind == "config_options_update" then
		take_models(session, u)
	elseif kind == "current_mode_update" then
		session.mode = u.currentModeId
	elseif kind == "plan" then
		local items = {}
		for _, entry in u.entries or {} do
			table.insert(items, { text = entry.content or "", status = entry.status or "pending" })
		end
		-- One plan a turn, updated in place.
		for i = #session.entries, 1, -1 do
			local entry = session.entries[i] :: any
			if entry.kind == "user" then
				break
			elseif entry.kind == "plan" then
				entry.items = items
				return
			end
		end
		table.insert(session.entries, { kind = "plan", items = items })
	end
end

-- What answers the agent's requests and notifications, by method. A
-- request's handler returns the result, or nil and an error message.
type Handlers = { [string]: (params: any) -> (any, string?) }

-- What the agent asks of the editor, by method.
local function handlers(session: Session): Handlers
	local terms: { [string]: Term } = {}
	local next_term = 0
	local h: Handlers = {}

	h["session/update"] = function(params: any): (any, string?)
		if not session.quiet then
			update(session, params.update)
		end
		session.changed()
		return nil
	end

	h["session/request_permission"] = function(params: any): (any, string?)
		local options = {}
		for _, option in params.options or {} do
			table.insert(options, { id = option.optionId, name = option.name, kind = option.kind })
		end
		local call: any = params.toolCall or {}
		local tool = session.tools[call.toolCallId or ""]
		local chosen = M.ask(
			session,
			M.tool_title(call.title) or (tool and tool.title) or "a tool call",
			call.kind or (tool and tool.kind),
			options,
			paths_of(call, session.cwd) or (tool and tool.locations)
		)
		if chosen == nil then
			return { outcome = { outcome = "cancelled" } }
		end
		return { outcome = { outcome = "selected", optionId = chosen } }
	end

	h["fs/read_text_file"] = function(params: any): (any, string?)
		session.where = { path = params.path, line = params.line }
		local text = core.file.text(params.path, session.cwd)
		if text == nil then
			return nil, `can't read {params.path}`
		end
		if params.line or params.limit then
			local lines = string.split(text, "\n")
			local first = params.line or 1
			local last = if params.limit then first + params.limit - 1 else #lines
			text = table.concat(lines, "\n", first, math.min(last, #lines))
		end
		return { content = text }
	end

	h["fs/write_text_file"] = function(params: any): (any, string?)
		if type(params.path) ~= "string" or string.sub(params.path, 1, 1) ~= "/" then
			return nil, "the path must be absolute"
		end
		local refused = M.may_write(session, `Write {params.path}`, "edit", { params.path })
		if refused then
			return nil, refused
		end
		-- Whatever the agent was allowed before, a write letting a plugin do
		-- more asks you, and only you.
		local widens = agent.widens(params.path, core.file.text(params.path), params.content)
		if widens then
			local chosen = M.ask(
				session,
				`Write {params.path}, which {widens}`,
				"edit",
				M.ONCE,
				{ params.path },
				true
			)
			if chosen ~= "once" then
				return nil, M.refused(M.NOT_WIDENED)
			end
		end
		local guarded: boolean, why: unknown = pcall(agent.memory.guard, params.path, session.root)
		if not guarded then
			return nil, tostring(why)
		end
		session.where = { path = params.path }
		-- An open file is edited as you would, so undo takes it back.
		local ok, err = pcall(core.file.write, params.path, params.content)
		if not ok then
			return nil, tostring(err)
		end
		return nil
	end

	h["terminal/create"] = function(params: any): (any, string?)
		local command: { string } = { params.command }
		for _, arg in params.args or {} do
			table.insert(command, tostring(arg))
		end
		local env: { [string]: string | false } = {}
		for _, var in params.env or {} do
			env[tostring(var.name)] = tostring(var.value)
		end
		local child, err =
			greed.process.spawn(command, { cwd = params.cwd or session.cwd, env = env })
		if child == nil then
			return nil, err
		end
		next_term += 1
		local id = `term-{next_term}`
		local term: Term = {
			child = child,
			output = "",
			limit = params.outputByteLimit,
			truncated = false,
			done = false,
			waiters = {},
		}
		terms[id] = term
		greed.spawn(function()
			while true do
				local piece = child:read()
				if piece == nil then
					break
				end
				term.output ..= piece
				local limit = term.limit
				if limit and #term.output > limit then
					term.output = string.sub(term.output, -limit)
					term.truncated = true
				end
			end
			term.code = child:wait()
			term.done = true
			for _, waiter in term.waiters do
				waiter:send(true)
			end
		end)
		return { terminalId = id }
	end

	local function term_of(params: any): Term
		local term = terms[params.terminalId]
		if term == nil then
			error(`no terminal {params.terminalId}`, 0)
		end
		return term
	end

	local function exit_status(term: Term): any
		return { exitCode = term.code, signal = if term.code == nil then "killed" else nil }
	end

	h["terminal/output"] = function(params: any): (any, string?)
		local term = term_of(params)
		local result: any = { output = term.output, truncated = term.truncated }
		if term.done then
			result.exitStatus = exit_status(term)
		end
		return result
	end

	h["terminal/wait_for_exit"] = function(params: any): (any, string?)
		local term = term_of(params)
		-- Done once everything it printed is in, which comes after its exit.
		if not term.done then
			local finished = greed.signal()
			table.insert(term.waiters, finished)
			finished:wait()
		end
		return exit_status(term)
	end

	h["terminal/kill"] = function(params: any): (any, string?)
		term_of(params).child:kill()
		return nil
	end

	h["terminal/release"] = function(params: any): (any, string?)
		local term = term_of(params)
		term.child:kill()
		terms[params.terminalId] = nil
		return nil
	end

	return h
end

--- Answers for a question that can't be allowed for good.
M.ONCE = {
	{ id = "once", name = "Allow once", kind = "allow_once" },
	{ id = "no", name = "Reject", kind = "reject_once" },
}

--- What an agent hears when you don't let it widen what a plugin may do.
M.NOT_WIDENED = "the user didn't allow letting a plugin do more; tell them what you needed it for"

--- Asks you whether the agent may do `title` (a tool call of `kind`,
--- touching the files at `locations` when it says), with `options` to
--- answer by, unless a policy answers first; a `firm` question only you
--- answer. Returns the option chosen, or nil if the question was cancelled,
--- and what you wrote with a rejection. That shows as your message: an
--- agent in the editor tells its model with the rejection, and an ACP agent
--- gets it as the next prompt.
function M.ask(
	session: Session,
	title: string,
	kind: string?,
	options: { { id: string, name: string, kind: string } },
	locations: { string }?,
	firm: boolean?
): (string?, string?)
	local permission: Permission = {
		title = title,
		kind = kind,
		locations = locations,
		options = options,
		answer = greed.signal(),
		firm = firm,
	}
	local entry: Entry = { kind = "permission", permission = permission }
	table.insert(session.entries, entry)
	local function chose(id: string, how: string)
		for _, option in options do
			if option.id == id then
				entry.chosen = option.name .. how
			end
		end
	end
	local decided = if firm then nil else session.decide and session.decide(permission)
	if decided then
		chose(decided, " (by policy)")
		session.changed()
		return decided, nil
	end
	local before: Status = session.status
	session.status = "waiting"
	session.changed()
	local chosen = permission.answer:wait()
	if session.status == "waiting" then
		session.status = before
	end
	if chosen == nil then
		entry.chosen = "cancelled"
	else
		chose(chosen, "")
	end
	local note = permission.note
	if note and session.driver then
		table.insert(session.entries, { kind = "user", text = note })
	elseif note then
		M.queue(session, note)
	end
	session.changed()
	return chosen, note
end

--- Why the agent may not do something, `why`, with what you wrote with
--- the rejection (`note`), for an agent's tool result. It says not to get
--- there another way: models told only "not allowed" go round it.
function M.refused(why: string, note: string?): string
	if note then
		return `{why}; the user rejected it and says: {note}\n\nDo what they say. Don't do what `
			.. "they rejected another way (another tool, a command or eval); if it's unclear "
			.. "what they want, ask them."
	end
	return `{why}. Don't try to do it another way (another tool, a command or eval): stop and `
		.. "ask the user what they want."
end

--- Whether the agent of `session` may change the files at `paths` (full
--- paths), doing `title` (a call of `kind`). Inside where it works it may.
--- An agent in a workspace of its own changes nothing outside it; one in
--- the project asks first, Allow once or Reject, whatever you allowed it
--- before. Nil when it may, else why not.
function M.may_write(session: Session, title: string, kind: string, paths: { string }): string?
	local outside = M.outside(session, paths)
	if outside == nil then
		return nil
	elseif session.workspace then
		return `{outside} is outside the workspace ({session.cwd})`
	end
	local chosen, note = M.ask(session, `{title}, outside the project`, kind, M.ONCE, paths)
	if chosen == "once" then
		return nil
	end
	-- An ACP agent gets your note as the next prompt instead.
	return M.refused(
		"the user didn't allow writing outside the project",
		if session.driver then note else nil
	)
end

local next_id = 0

-- Who waits for each session that's starting, by session id, until it's
-- ready or can't start.
local starting: { [number]: { greed.Signal } } = {}

-- Wakes whoever waits for `session` to start.
local function settle(session: Session)
	local waiters = starting[session.id]
	starting[session.id] = nil
	if waiters then
		for _, waiter in waiters do
			waiter:send(nil)
		end
	end
end

--- Waits until `session` is ready for prompts or can't start, and returns
--- whether it's running.
function M.ready(session: Session): boolean
	local waiters = starting[session.id]
	if waiters then
		local signal = greed.signal()
		table.insert(waiters, signal)
		signal:wait()
	end
	return session.status ~= "starting" and session.status ~= "exited"
end

--- A session of the agent `command` (registered as `agent`) working in
--- `cwd` for the project at `root`, starting now. `changed` is called
--- whenever there's something new to show.
function M.start(
	opts: {
		name: string,
		agent: string,
		command: { string },
		root: string,
		cwd: string,
		workspace: Workspace?,
		--- MCP servers the agent should use, as ACP describes them.
		servers: { any }?,
		decide: ((permission: Permission) -> string?)?,
		--- An earlier ACP session to take up instead of starting one, or
		--- one to fork.
		load: string?,
		fork: string?,
		--- What the transcript starts with, for a fork.
		entries: { Entry }?,
		changed: () -> (),
	}
): Session
	next_id += 1
	local session: Session = {
		id = next_id,
		name = opts.name,
		agent = opts.agent,
		root = opts.root,
		cwd = opts.cwd,
		workspace = opts.workspace,
		status = "starting",
		entries = opts.entries or {},
		tools = {},
		modes = {},
		models = {},
		decide = opts.decide,
		changed = opts.changed,
	}
	starting[session.id] = {}
	for _, entry in session.entries do
		if entry.tool then
			session.tools[entry.tool.id] = entry.tool
		end
	end
	local function note(text: string)
		table.insert(session.entries, { kind = "note", text = text })
		session.changed()
	end
	-- Says why it can't start, to the transcript and whoever waits for it.
	local function failed(text: string)
		-- Its exit said why already; the requests it left unanswered fail too.
		if session.status == "exited" and session.failed then
			return
		end
		session.failed = text
		note(text)
		settle(session)
	end
	local answers = handlers(session)
	local conn, err = greed.rpc.start(opts.command, {
		cwd = opts.cwd,
		framing = "lines",
		on_request = function(method: string, params: any): (any, string?)
			local handler = answers[method]
			if handler == nil then
				return nil, `{method} isn't supported`
			end
			local result, problem = handler(params)
			if problem then
				return nil, problem
			end
			-- `null` can't be a Luau value, so no result answers with an
			-- empty object.
			return if result == nil then {} else result, nil
		end,
		on_notify = function(method: string, params: any)
			local handler = answers[method]
			if handler then
				handler(params)
			end
		end,
		on_exit = function(stderr: string)
			local what = if session.status == "starting"
				then "the agent didn't start"
				else "the agent exited"
			session.status = "exited"
			session.tool = nil
			local said = string.match(stderr, "([^\n]+)\n?$")
			failed(if said then `{what}: {said}` else what)
		end,
	})
	if conn == nil then
		session.status = "exited"
		failed(`couldn't start {table.concat(opts.command, " ")}: {err}`)
		return session
	end
	session.conn = conn
	greed.spawn(function()
		local init, problem = conn:request("initialize", {
			protocolVersion = 1,
			clientCapabilities = {
				fs = { readTextFile = true, writeTextFile = true },
				terminal = true,
			},
			clientInfo = { name = "greed", title = "Greed", version = "0" },
		})
		if init == nil then
			failed(`the agent didn't start: {problem}`)
			return
		end
		local can = init.agentCapabilities or {}
		session.sees_images = can.promptCapabilities ~= nil and can.promptCapabilities.image == true
		local params: any = { cwd = opts.cwd, mcpServers = greed.json.array(opts.servers) }
		local method = "session/new"
		if opts.load then
			if not can.loadSession then
				failed("the agent can't take up an earlier session")
				return
			end
			-- The agent tells the conversation so far again, as updates.
			method, params.sessionId = "session/load", opts.load
		elseif opts.fork then
			if not (can.sessionCapabilities and can.sessionCapabilities.fork) then
				failed("the agent can't fork a session")
				return
			end
			method, params.sessionId = "session/fork", opts.fork
		end
		local new, refused = conn:request(method, params)
		if new == nil then
			failed(`the agent couldn't start a session: {refused}`)
			return
		end
		session.session_id = new.sessionId or opts.load
		-- A fork is a new session the agent hasn't opened yet: it's taken up,
		-- without telling the conversation again where the agent can.
		if opts.fork and new.sessionId then
			local open: any = table.clone(params)
			open.sessionId = new.sessionId
			if can.sessionCapabilities and can.sessionCapabilities.resume then
				conn:request("session/resume", open)
			elseif can.loadSession then
				session.quiet = true
				conn:request("session/load", open)
				session.quiet = false
			end
		end
		if type(new.modes) == "table" then
			for _, mode in new.modes.availableModes or {} do
				table.insert(
					session.modes,
					{ id = mode.id, name = mode.name or mode.id, description = mode.description }
				)
			end
			session.mode = new.modes.currentModeId
		end
		take_models(session, new)
		if session.status == "starting" then
			session.status = "idle"
		end
		session.changed()
		settle(session)
	end)
	return session
end

--- A session of an agent `driver` runs in the editor, ready at once.
function M.start_driven(opts: {
	name: string,
	agent: string,
	root: string,
	cwd: string,
	workspace: Workspace?,
	decide: ((permission: Permission) -> string?)?,
	changed: () -> (),
	driver: Driver,
}): Session
	next_id += 1
	return {
		id = next_id,
		name = opts.name,
		agent = opts.agent,
		root = opts.root,
		cwd = opts.cwd,
		workspace = opts.workspace,
		status = "idle",
		entries = {},
		tools = {},
		modes = {},
		models = {},
		decide = opts.decide,
		changed = opts.changed,
		driver = opts.driver,
	}
end

--- What to send with a prompt now: `context` (what you have on screen) and
--- what's pinned (`session.pinned`), each only when it isn't what the last
--- prompt took; nil for neither. Call it once the prompt is going.
function M.fresh_context(session: Session, context: string?): string?
	local parts: { string } = {}
	if context and context ~= session.context_sent then
		session.context_sent = context
		table.insert(parts, context)
	end
	if session.pinned ~= session.pinned_sent then
		session.pinned_sent = session.pinned
		table.insert(parts, agent.context.pinned_block(session.pinned))
	end
	return if #parts > 0 then table.concat(parts, "\n\n") else nil
end

--- Works out again what keeps `session` from working now, like its model
--- having no key, and keeps it as its `problem`. It can wait.
function M.check(session: Session): string?
	local driver = session.driver
	session.problem = if driver and driver.check then driver.check(session) else nil
	return session.problem
end

--- Attaches the image `png` to `session`'s next prompt. It's kept in the
--- cache folder too, so an agent that can't see images can still use the
--- file. False and why when it isn't an image.
function M.attach(session: Session, png: string): (boolean, string?)
	local id, why = greed.image.decode(png)
	if id == nil then
		return false, why or "that isn't an image"
	end
	local width, height = greed.image.size(id)
	greed.image.forget(id)
	local attached = session.attached or {}
	local dirs = greed.fs.dirs()
	local cache = dirs.cache or dirs.data or "."
	local path =
		`{cache}/agent-images/{session.id}-{os.time()}-{math.floor(greed.now() % 1000000)}-{#attached + 1}.png`
	local ok, err = greed.fs.write(path, png)
	if not ok then
		return false, `couldn't keep the image: {err}`
	end
	table.insert(attached, { path = path, png = png, width = width or 0, height = height or 0 })
	session.attached = attached
	session.changed()
	return true, nil
end

--- Drops the images attached to `session`'s next prompt, and their files,
--- which no agent has been told of.
function M.drop_images(session: Session)
	local attached = session.attached
	if attached == nil then
		return
	end
	for _, image in attached do
		greed.fs.remove(image.path)
	end
	session.attached = nil
	session.changed()
end

--- What the chips for `attached` images say, in the box and in your
--- message: "🖼 image 1 · 1280×720".
function M.chips(attached: { Attachment }): string
	local chips: { string } = {}
	for i, image in attached do
		table.insert(chips, `🖼 image {i} · {image.width}×{image.height}`)
	end
	return table.concat(chips, "  ")
end

-- What a prompt with `attached` images says of them to the agent: where
-- each is kept, and for an agent that can't see them (`seen` false), that
-- it can't and what it can do instead.
local function about_images(attached: { Attachment }, seen: boolean): string
	local lines: { string } = {}
	for i, image in attached do
		table.insert(
			lines,
			if seen
				then `[Image {i}, {image.width}×{image.height} pixels, is also saved at {image.path}]`
				else `[The user pasted image {i}, {image.width}×{image.height} pixels, saved at {image.path}. You can't see images: work with the file as you can, and ask the user what it shows if you need to know.]`
		)
	end
	return table.concat(lines, "\n")
end

-- One prompt, as M.prompt sends it.
local function prompt_once(session: Session, text: string, context: string?): (boolean, string?)
	session.cancelled = nil
	local attached = session.attached
	local driver = session.driver
	local seen = if driver
		then driver.sees_images ~= nil and driver.sees_images(session)
		else session.sees_images == true
	local said, shown = text, text
	if attached then
		said = `{text}\n\n{about_images(attached, seen)}`
		shown = `{text}\n{M.chips(attached)}`
	end
	if driver then
		session.attached = nil
		local ok, err = driver.prompt(session, said, context, shown, if seen then attached else nil)
		if not ok then
			session.attached = attached
		end
		return ok, err
	end
	local conn = session.conn
	if conn == nil or session.session_id == nil then
		return false,
			if session.status == "starting"
				then "the agent is still starting"
				else "the agent isn't running"
	elseif session.status == "working" or session.status == "waiting" then
		return false, "the agent is still working; stop it first"
	end
	session.attached = nil
	session.failed = nil
	table.insert(session.entries, { kind = "user", text = shown })
	session.status = "working"
	session.since = greed.now()
	session.doing = `waiting for {session.name}`
	session.changed()
	local blocks: { any } = { { type = "text", text = said } }
	if attached and seen then
		for _, image in attached do
			table.insert(
				blocks,
				{ type = "image", mimeType = "image/png", data = greed.base64.encode(image.png) }
			)
		end
	end
	local fresh = M.fresh_context(session, context)
	if fresh then
		table.insert(blocks, 1, { type = "text", text = fresh })
	end
	local result, err = conn:request("session/prompt", {
		sessionId = session.session_id,
		prompt = blocks,
	})
	if session.status ~= "exited" then
		session.status = "idle"
	end
	session.tool = nil
	if result == nil then
		session.failed = `the turn failed: {err}`
		table.insert(session.entries, { kind = "note", text = session.failed })
	elseif result.stopReason and result.stopReason ~= "end_turn" then
		table.insert(
			session.entries,
			{ kind = "note", text = `stopped: {string.gsub(result.stopReason, "_", " ")}` }
		)
	end
	session.changed()
	return true, nil
end

--- Keeps `text`, a message you sent while the agent works, to send once it
--- can take it (see `Session.queued`).
function M.queue(session: Session, text: string)
	local queued = session.queued or {}
	table.insert(queued, text)
	session.queued = queued
	session.changed()
end

--- The messages queued for the agent, as one, taken out of the queue; nil
--- when there are none.
function M.take_queued(session: Session): string?
	local queued = session.queued
	session.queued = nil
	return if queued and #queued > 0 then table.concat(queued, "\n\n") else nil
end

--- Sends `text` to the agent and waits for its turn to end; what it says
--- and does meanwhile arrives as entries. `context` goes along before it,
--- unless the last prompt took the same, and the images attached to the
--- session go with it: as images to an agent that sees them, and as their
--- files' paths to one that doesn't. Messages queued meanwhile go next,
--- together, unless you stopped the turn. False and why when it can't.
function M.prompt(session: Session, text: string, context: string?): (boolean, string?)
	-- Those still queued when you stopped the last turn go first.
	local left = if session.status == "idle" then M.take_queued(session) else nil
	if left then
		text = if text == "" then left else `{left}\n\n{text}`
	end
	local ok, err = prompt_once(session, text, context)
	while ok and not session.cancelled and session.status == "idle" do
		local queued = M.take_queued(session)
		if queued == nil then
			break
		end
		ok, err = prompt_once(session, queued, nil)
	end
	return ok, err
end

--- Puts the agent in the mode `id`. False and why when it won't.
function M.set_mode(session: Session, id: string): (boolean, string?)
	local conn = session.conn
	if conn == nil or session.session_id == nil then
		return false, "the agent isn't running"
	end
	local _, err = conn:request("session/set_mode", { sessionId = session.session_id, modeId = id })
	if err then
		return false, err
	end
	session.mode = id
	session.changed()
	return true, nil
end

--- Has the agent use the model `id`. False and why when it won't.
function M.set_model(session: Session, id: string): (boolean, string?)
	if session.driver then
		return session.driver.set_model(session, id)
	end
	local conn = session.conn
	if conn == nil or session.session_id == nil then
		return false, "the agent isn't running"
	end
	local result, err
	if session.model_option then
		result, err = conn:request("session/set_config_option", {
			sessionId = session.session_id,
			configId = session.model_option,
			value = id,
		})
		if result then
			take_models(session, result)
		end
	else
		result, err =
			conn:request("session/set_model", { sessionId = session.session_id, modelId = id })
	end
	if err then
		return false, err
	end
	session.model = id
	session.changed()
	return true, nil
end

--- Asks the agent to stop its turn, answering any question it waits on.
--- Messages queued for it stay queued, for your next one. Its helpers stop
--- too.
function M.cancel(session: Session)
	session.cancelled = true
	for _, permission in M.pending(session) do
		permission.answer:send(nil)
	end
	if session.driver then
		session.driver.cancel(session)
	end
	local conn = session.conn
	if conn and session.session_id then
		conn:notify("session/cancel", { sessionId = session.session_id })
	end
	-- After its own turn stopped, so what they report is left out.
	local helpers: { Session } = session.helpers or {}
	for _, helper in table.clone(helpers) do
		M.cancel(helper)
	end
end

--- The questions the agent waits on you for, oldest first.
function M.pending(session: Session): { Permission }
	local out = {}
	for _, entry in session.entries do
		if entry.kind == "permission" and entry.chosen == nil and entry.permission then
			table.insert(out, entry.permission)
		end
	end
	return out
end

--- Stops the agent program.
function M.stop(session: Session)
	M.cancel(session)
	local driver = session.driver
	if driver and driver.stop then
		driver.stop(session)
	end
	if session.conn then
		session.conn:close()
	end
	session.status = "exited"
	settle(session)
end

return M
