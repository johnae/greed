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
	options: { { id: string, name: string, kind: string } },
	answer: greed.Signal,
}

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
	entries: { Entry },
	tools: { [string]: Tool },
	conn: rpc.Conn?,
	session_id: string?,
	--- Called whenever there's something new to show.
	changed: () -> (),
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

-- A tool call's content as a short summary, and as all its lines to show
-- when it's unfolded. Code fences around output are left out.
local function detail_of(content: any, cwd: string): ({ string }, { string })
	local summary, output = {}, {}
	for _, item in (if type(content) == "table" then content else {}) do
		if item.type == "diff" then
			local added, removed = diff_size(item.oldText or "", item.newText or "")
			table.insert(summary, `{relative(item.path or "", cwd)}  +{added} -{removed}`)
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
			if #lines > 0 then
				local more = if #lines > 1 then `  (+{#lines - 1} lines, tab shows them)` else ""
				table.insert(summary, lines[1] .. more)
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

-- Applies one session/update notification.
local function update(session: Session, u: any)
	local kind = u.sessionUpdate
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
		update(session, params.update)
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
		local permission: Permission = {
			title = call.title or (tool and tool.title) or "a tool call",
			options = options,
			answer = greed.signal(),
		}
		local entry: Entry = { kind = "permission", permission = permission }
		table.insert(session.entries, entry)
		local before = session.status
		session.status = "waiting"
		session.changed()
		local chosen = permission.answer.wait()
		if session.status == "waiting" then
			session.status = before
		end
		if chosen == nil then
			entry.chosen = "cancelled"
			session.changed()
			return { outcome = { outcome = "cancelled" } }
		end
		for _, option in options do
			if option.id == chosen then
				entry.chosen = option.name
			end
		end
		session.changed()
		return { outcome = { outcome = "selected", optionId = chosen } }
	end

	h["fs/read_text_file"] = function(params: any): (any, string?)
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

local next_id = 0

--- A session of the agent `command` (registered as `agent`) working in
--- `cwd` for the project at `root`, starting now. `changed` is called
--- whenever there's something new to show.
function M.start(opts: {
	name: string,
	agent: string,
	command: { string },
	root: string,
	cwd: string,
	workspace: Workspace?,
	changed: () -> (),
}): Session
	next_id += 1
	local session: Session = {
		id = next_id,
		name = opts.name,
		agent = opts.agent,
		root = opts.root,
		cwd = opts.cwd,
		workspace = opts.workspace,
		status = "starting",
		entries = {},
		tools = {},
		changed = opts.changed,
	}
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
		local new, failed =
			conn.request("session/new", { cwd = opts.cwd, mcpServers = greed.json.array() })
		if new == nil then
			note(`the agent couldn't start a session: {failed}`)
			return
		end
		session.session_id = new.sessionId
		if session.status == "starting" then
			session.status = "idle"
		end
		session.changed()
	end)
	return session
end

--- Sends `text` to the agent and waits for its turn to end; what it says
--- and does meanwhile arrives as entries. False and why when it can't.
function M.prompt(session: Session, text: string): (boolean, string?)
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
	session.changed()
	local result, err = conn.request("session/prompt", {
		sessionId = session.session_id,
		prompt = { { type = "text", text = text } },
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

--- Asks the agent to stop its turn, answering any question it waits on.
function M.cancel(session: Session)
	for _, permission in M.pending(session) do
		permission.answer.send(nil)
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
