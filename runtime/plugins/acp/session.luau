-- An agent session over the Agent Client Protocol: the agent program, its
-- ACP session, what it has said and done (the entries a transcript shows),
-- and the client side of the protocol: reading and writing files, running
-- programs and asking you for permission.
local greed = require("@greed")
local rpc = require("./rpc")

local M = {}

export type Status = "starting" | "idle" | "working" | "waiting" | "exited"

--- A tool call, as the agent reports it.
export type Tool = {
	id: string,
	title: string,
	kind: string?,
	status: string?,
	--- A line or two about what it did: a diff's size, a bit of output.
	detail: { string },
	--- All of its output, shown when it's unfolded.
	output: { string },
	open: boolean,
}

--- A question the agent waits on you for.
export type Permission = {
	title: string,
	--- The kind of tool call it's for: "edit", "execute", ...
	kind: string?,
	options: { { id: string, name: string, kind: string } },
	answer: greed.Signal,
}

--- A mode the agent works in, like "plan" or "accept edits".
export type Mode = { id: string, name: string, description: string? }

--- What a transcript shows, in order. `kind` says which fields it has:
--- "user", "agent", "thought" and "note" have `text`, "tool" a `tool`,
--- "plan" its `items`, and "permission" a `permission` and, once
--- answered, what was `chosen`.
export type Entry = {
	kind: string,
	text: string?,
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
	--- The file it works in now, and the line (from 1) when it says.
	where: { path: string, line: number? }?,
	entries: { Entry },
	tools: { [string]: Tool },
	conn: rpc.Conn?,
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
	--- When the turn going on now started, on `greed.now()`'s clock.
	since: number?,
	--- How many tokens of the model's context the conversation takes, and
	--- how many it has room for, when the agent says.
	tokens: number?,
	window: number?,
}

--- An agent run in the editor rather than as an ACP program.
export type Driver = {
	prompt: (session: Session, text: string, context: string?) -> (boolean, string?),
	cancel: (session: Session) -> (),
	set_model: (session: Session, id: string) -> (boolean, string?),
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

-- Adds `text` to the last entry if it's of `kind`, or to a new one.
local function append(session: Session, kind: string, text: string)
	local entry = session.entries[#session.entries]
	if entry and entry.kind == kind then
		entry.text = (entry.text or "") .. text
	else
		table.insert(session.entries, { kind = kind, text = text })
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

-- `path` from `cwd` when it's inside it.
local function relative(path: string, cwd: string): string
	return if string.sub(path, 1, #cwd + 1) == cwd .. "/" then string.sub(path, #cwd + 2) else path
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

-- `text` cut to `width` characters, with an ellipsis when it's longer.
local function clip(text: string, width: number): string
	if (utf8.len(text) or #text) <= width then
		return text
	end
	local at = utf8.offset(text, width) or width
	return string.sub(text, 1, at - 1) .. "…"
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

-- Applies one session/update notification.
local function update(session: Session, u: any)
	local kind = u.sessionUpdate
	-- Tool calls say which files they touch.
	local place = type(u.locations) == "table" and u.locations[1]
	if place and type(place.path) == "string" then
		session.where = { path = place.path, line = place.line }
	end
	if kind == "agent_message_chunk" then
		append(session, "agent", text_of(u.content))
	elseif kind == "agent_thought_chunk" then
		append(session, "thought", text_of(u.content))
	elseif kind == "user_message_chunk" then
		append(session, "user", text_of(u.content))
	elseif kind == "tool_call" then
		local detail, output = detail_of(u.content, session.cwd)
		local tool: Tool = {
			id = u.toolCallId,
			title = u.title or "a tool",
			kind = u.kind,
			status = u.status or "pending",
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
		tool.title = u.title or tool.title
		tool.kind = u.kind or tool.kind
		tool.status = u.status or tool.status
		if u.content then
			tool.detail, tool.output = detail_of(u.content, session.cwd)
		end
		if tool.status == "completed" or tool.status == "failed" then
			if session.tool == tool.title then
				session.tool = nil
			end
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

-- The open buffer for `path`, if any.
local function open_buffer(path: string): greed.Buffer?
	for _, buffer in greed.buffers() do
		if buffer:path() == path then
			return buffer
		end
	end
	return nil
end

-- What the agent asks of the editor, by method.
local function handlers(session: Session): rpc.Handlers
	local terms: { [string]: Term } = {}
	local next_term = 0
	local h: rpc.Handlers = {}

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
			call.title or (tool and tool.title) or "a tool call",
			call.kind or (tool and tool.kind),
			options
		)
		if chosen == nil then
			return { outcome = { outcome = "cancelled" } }
		end
		return { outcome = { outcome = "selected", optionId = chosen } }
	end

	h["fs/read_text_file"] = function(params: any): (any, string?)
		session.where = { path = params.path, line = params.line }
		local buffer = open_buffer(params.path)
		local text: string? = if buffer then buffer:text() else greed.fs.read(params.path)
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
		session.where = { path = params.path }
		-- An open file is edited as you would, so undo takes it back.
		local buffer = open_buffer(params.path)
		if buffer then
			local content = params.content
			buffer:edit(function(e)
				e:replace(0, buffer:len(), content)
			end)
			buffer:save()
		else
			local ok, err = greed.fs.write(params.path, params.content)
			if not ok then
				return nil, err
			end
		end
		return nil
	end

	h["terminal/create"] = function(params: any): (any, string?)
		local command: { string } = { params.command }
		for _, arg in params.args or {} do
			table.insert(command, tostring(arg))
		end
		local env = {}
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
				local piece = child.read()
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
			term.code = child.wait()
			term.done = true
			for _, waiter in term.waiters do
				waiter.send(true)
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
			finished.wait()
		end
		return exit_status(term)
	end

	h["terminal/kill"] = function(params: any): (any, string?)
		term_of(params).child.kill()
		return nil
	end

	h["terminal/release"] = function(params: any): (any, string?)
		local term = term_of(params)
		term.child.kill()
		terms[params.terminalId] = nil
		return nil
	end

	return h
end

--- Asks you whether the agent may do `title` (a tool call of `kind`),
--- with `options` to answer by, unless a policy answers first. Returns the
--- option chosen, or nil if the question was cancelled.
function M.ask(
	session: Session,
	title: string,
	kind: string?,
	options: { { id: string, name: string, kind: string } }
): string?
	local permission: Permission =
		{ title = title, kind = kind, options = options, answer = greed.signal() }
	local entry: Entry = { kind = "permission", permission = permission }
	table.insert(session.entries, entry)
	local function chose(id: string, how: string)
		for _, option in options do
			if option.id == id then
				entry.chosen = option.name .. how
			end
		end
	end
	local decided = session.decide and session.decide(permission)
	if decided then
		chose(decided, " (by policy)")
		session.changed()
		return decided
	end
	local before: Status = session.status
	session.status = "waiting"
	session.changed()
	local chosen = permission.answer.wait()
	if session.status == "waiting" then
		session.status = before
	end
	if chosen == nil then
		entry.chosen = "cancelled"
	else
		chose(chosen, "")
	end
	session.changed()
	return chosen
end

local next_id = 0

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
	for _, entry in session.entries do
		if entry.tool then
			session.tools[entry.tool.id] = entry.tool
		end
	end
	local function note(text: string)
		table.insert(session.entries, { kind = "note", text = text })
		session.changed()
	end
	local conn, err = rpc.start(opts.command, opts.cwd, handlers(session), function(stderr)
		session.status = "exited"
		session.tool = nil
		local said = string.match(stderr, "([^\n]+)\n?$")
		note(if said then `the agent exited: {said}` else "the agent exited")
	end)
	if conn == nil then
		session.status = "exited"
		note(`couldn't start {table.concat(opts.command, " ")}: {err}`)
		return session
	end
	session.conn = conn
	greed.spawn(function()
		local init, problem = conn.request("initialize", {
			protocolVersion = 1,
			clientCapabilities = {
				fs = { readTextFile = true, writeTextFile = true },
				terminal = true,
			},
			clientInfo = { name = "greed", title = "Greed", version = "0" },
		})
		if init == nil then
			note(`the agent didn't start: {problem}`)
			return
		end
		local can = init.agentCapabilities or {}
		local params: any = { cwd = opts.cwd, mcpServers = greed.json.array(opts.servers) }
		local method = "session/new"
		if opts.load then
			if not can.loadSession then
				note("the agent can't take up an earlier session")
				return
			end
			-- The agent tells the conversation so far again, as updates.
			method, params.sessionId = "session/load", opts.load
		elseif opts.fork then
			if not (can.sessionCapabilities and can.sessionCapabilities.fork) then
				note("the agent can't fork a session")
				return
			end
			method, params.sessionId = "session/fork", opts.fork
		end
		local new, failed = conn.request(method, params)
		if new == nil then
			note(`the agent couldn't start a session: {failed}`)
			return
		end
		session.session_id = new.sessionId or opts.load
		-- A fork is a new session the agent hasn't opened yet: it's taken up,
		-- without telling the conversation again where the agent can.
		if opts.fork and new.sessionId then
			local open: any = table.clone(params)
			open.sessionId = new.sessionId
			if can.sessionCapabilities and can.sessionCapabilities.resume then
				conn.request("session/resume", open)
			elseif can.loadSession then
				session.quiet = true
				conn.request("session/load", open)
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
	end)
	return session
end

--- A session of an agent `driver` runs in the editor, ready at once.
function M.start_driven(opts: {
	name: string,
	agent: string,
	root: string,
	cwd: string,
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

--- `context` (what you have on screen) to send with a prompt now, or nil
--- when it's what the last prompt took. Call it once the prompt is going.
function M.fresh_context(session: Session, context: string?): string?
	if context == nil or context == session.context_sent then
		return nil
	end
	session.context_sent = context
	return context
end

--- Sends `text` to the agent and waits for its turn to end; what it says
--- and does meanwhile arrives as entries. `context` goes along before it,
--- unless the last prompt took the same. False and why when it can't.
function M.prompt(session: Session, text: string, context: string?): (boolean, string?)
	if session.driver then
		return session.driver.prompt(session, text, context)
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
	table.insert(session.entries, { kind = "user", text = text })
	session.status = "working"
	session.since = greed.now()
	session.changed()
	local blocks = { { type = "text", text = text } }
	local fresh = M.fresh_context(session, context)
	if fresh then
		table.insert(blocks, 1, { type = "text", text = fresh })
	end
	local result, err = conn.request("session/prompt", {
		sessionId = session.session_id,
		prompt = blocks,
	})
	if session.status ~= "exited" then
		session.status = "idle"
	end
	session.tool = nil
	if result == nil then
		table.insert(session.entries, { kind = "note", text = `the turn failed: {err}` })
	elseif result.stopReason and result.stopReason ~= "end_turn" then
		table.insert(
			session.entries,
			{ kind = "note", text = `stopped: {string.gsub(result.stopReason, "_", " ")}` }
		)
	end
	session.changed()
	return true, nil
end

--- Puts the agent in the mode `id`. False and why when it won't.
function M.set_mode(session: Session, id: string): (boolean, string?)
	local conn = session.conn
	if conn == nil or session.session_id == nil then
		return false, "the agent isn't running"
	end
	local _, err = conn.request("session/set_mode", { sessionId = session.session_id, modeId = id })
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
		result, err = conn.request("session/set_config_option", {
			sessionId = session.session_id,
			configId = session.model_option,
			value = id,
		})
		if result then
			take_models(session, result)
		end
	else
		result, err =
			conn.request("session/set_model", { sessionId = session.session_id, modelId = id })
	end
	if err then
		return false, err
	end
	session.model = id
	session.changed()
	return true, nil
end

--- Asks the agent to stop its turn, answering any question it waits on.
function M.cancel(session: Session)
	for _, permission in M.pending(session) do
		permission.answer.send(nil)
	end
	if session.driver then
		session.driver.cancel(session)
	end
	local conn = session.conn
	if conn and session.session_id then
		conn.notify("session/cancel", { sessionId = session.session_id })
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
	if session.conn then
		session.conn.close()
	end
	session.status = "exited"
end

return M
