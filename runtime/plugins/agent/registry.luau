-- The tools offered to agents, and the MCP methods that list and run them.
--
-- Every tool an agent is offered costs tokens on each request, so tools
-- come in groups: those without one are always offered, and an agent
-- switches a group on with the `tools` tool when it needs it (or the
-- `agent-tool-groups` option gives it from the start). MCP clients hear
-- that their list changed and fetch it again.

local greed = require("@greed")
local registry = require("@core").registry

--- Who's calling a tool. `kind` says how they reach Greed: "shell" for
--- `greed ctl`, "socket" for MCP clients like `greed mcp`, "ide" for
--- Claude Code's IDE connection and "agent" for an agent running in the
--- editor. `groups` are the tool groups they switched on, which the
--- `tools` tool adds to, and `connection` is an MCP client's connection,
--- to tell when their list changes. `kind` is for telling callers apart,
--- not for trust: `from_shell(caller)` says whether a call really came
--- from a shell.
export type Caller = {
	kind: "shell" | "socket" | "ide" | "agent",
	groups: { [string]: boolean },
	connection: number?,
}

--- What a tool does beyond reading, named as ACP names tool kinds.
export type Kind = "read" | "edit" | "execute" | "fetch"

export type Tool = {
	--- Letters, digits, `_` and `-`, which every MCP client accepts.
	name: string,
	--- What it does, for the agent deciding whether to use it.
	description: string,
	--- A JSON Schema for the arguments, e.g. `schema.object({ path = ... }, { "path" })`.
	input: { [string]: any }?,
	--- Who sees it: "socket" (`greed ctl`, `greed mcp` and agents in the
	--- editor; the default) or "ide" (Claude Code's IDE connection, which
	--- expects its own set of tools).
	client: ("socket" | "ide")?,
	--- The group it's offered with (see `group`); without one it's always
	--- offered.
	group: string?,
	--- What it does beyond reading: "edit" changes files or notes,
	--- "execute" runs code or programs, "fetch" reaches the network. The
	--- default is "read". Agents in Greed ask you before a tool that does
	--- more than read runs.
	kind: Kind?,
	--- It puts what it does in front of the user itself (a proposal, a
	--- question, an approval page), so agents don't ask before it runs.
	reviews: boolean?,
	--- Does the work for `caller`. It can wait, e.g. for the user. A string
	--- result goes to the agent as is, one made with `result` as that MCP
	--- result, anything else as JSON. Errors go back as errors.
	run: (args: { [string]: any }, caller: Caller) -> any,
}

--- A piece of an MCP tool result, like `{ type = "text", text = "..." }`.
export type Content = { [string]: any }

-- The tools offered, by client and name.
local tools: { [string]: { [string]: Tool } } = {}

-- What each group is for, by name.
local groups: { [string]: string } = {}

-- The groups each MCP connection switched on, by connection.
local switched: { [number]: Caller } = {}

greed.option.define({
	name = "agent-tool-groups",
	doc = 'The tool groups agents get from the start, besides those they switch on: names with spaces between, or "all"',
	default = "plan",
})

local M = {}

--- Helpers for the JSON Schemas of tools' arguments.
M.schema = {
	--- An object with `properties`, of which those named in `required`
	--- must be given.
	object = function(properties: { [string]: any }, required: { string }?): { [string]: any }
		return { type = "object", properties = properties, required = required }
	end,
}

--- Offers `spec` to agents and `greed ctl`. A tool with the same name is
--- replaced. It goes when the plugin that offered it does.
function M.tool(spec: Tool)
	assert(string.match(spec.name, "^[%w_%-]+$"), "tool names are letters, digits, _ and -")
	local client = spec.client or "socket"
	local named = tools[client] or {}
	tools[client] = named
	greed.plugin.tie(registry.set(named, spec.name, spec))
end

--- Whether an agent should ask you before `tool` runs: it does more than
--- read, and puts nothing in front of you itself.
function M.asks(tool: Tool): boolean
	return (tool.kind or "read") ~= "read" and not tool.reviews
end

-- The callers made for calls from a shell (`greed ctl`). Only the registry
-- makes them, so a plugin can't pass one off as its own.
local shells: { [Caller]: boolean } = setmetatable({}, { __mode = "k" }) :: any

--- Whether `caller` is a call from a shell (`greed ctl`), whose user can
--- run anything already.
function M.from_shell(caller: Caller?): boolean
	return caller ~= nil and shells[caller] == true
end

-- The results made with `result`, so data a tool returns that happens to
-- have a `content` field still goes to the agent as data.
local results: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

--- An MCP tool result, for a tool to return as it is: `content` is text,
--- or pieces like `{ type = "text", text = "..." }`.
function M.result(content: string | { Content }, is_error: boolean?): { [string]: any }
	local pieces: { Content } = if type(content) == "string"
		then { { type = "text", text = content } }
		else content
	local made = { content = pieces, isError = is_error == true }
	results[made] = true
	return made
end

--- What a tool returned, as text for an agent to read: a string as it is,
--- a `result`'s text pieces, anything else as JSON.
function M.as_text(value: any): string
	if type(value) == "string" then
		return value
	elseif results[value] then
		local parts = {}
		for _, piece in value.content do
			if type(piece.text) == "string" then
				table.insert(parts, piece.text)
			end
		end
		return table.concat(parts, "\n")
	end
	return greed.json.encode(value)
end

-- Says in the `tools` tool which groups there are; set once it's made.
local describe_groups = function() end

--- Names a group of tools and says what it's for, in a line the agent
--- reads when deciding whether to switch it on. It goes when the plugin
--- that named it does.
function M.group(name: string, description: string)
	local remove = registry.set(groups, name, description)
	describe_groups()
	greed.plugin.tie(function()
		remove()
		describe_groups()
	end)
end

local function sorted(list: { Tool }): { Tool }
	table.sort(list, function(a: Tool, b: Tool)
		return a.name < b.name
	end)
	return list
end

--- Every tool offered to `client` (default "socket"), in every group,
--- sorted by name.
function M.tools(client: ("socket" | "ide")?): { Tool }
	local list = {}
	local named: { [string]: Tool } = tools[client or "socket"] or {}
	for _, tool in named do
		table.insert(list, tool)
	end
	return sorted(list)
end

-- The set of tools `caller` gets: Claude Code's IDE connection its own,
-- everyone else the socket's.
local function client_of(caller: Caller): "socket" | "ide"
	return if caller.kind == "ide" then "ide" else "socket"
end

--- Whether `caller` gets the tools of `group`: it switched it on, or the
--- option gives it.
local function has(caller: Caller, group: string): boolean
	if caller.groups[group] then
		return true
	end
	local option = tostring(greed.option.get("agent-tool-groups") or "")
	for name in string.gmatch(option, "[%w_%-]+") do
		if name == group or name == "all" then
			return true
		end
	end
	return false
end

--- The tools `caller` is offered now: those in no group, and those in the
--- groups it has, sorted by name. A shell (`greed ctl`) gets every one.
function M.offered(caller: Caller): { Tool }
	local all = M.tools(client_of(caller))
	if caller.kind == "shell" then
		return all
	end
	local list = {}
	for _, tool in all do
		if tool.group == nil or has(caller, tool.group) then
			table.insert(list, tool)
		end
	end
	return list
end

--- A caller for an agent running in the editor, with no groups switched
--- on yet.
function M.caller(): Caller
	return { kind = "agent", groups = {} }
end

-- The caller for a request. An MCP client's is its connection's, kept
-- while the connection is open.
local function caller_of(request: greed.ControlRequest): Caller
	if request.client == "shell" then
		local shell: Caller = { kind = "shell", groups = {} }
		shells[shell] = true
		return shell
	end
	local connection = request.connection
	if connection == nil or request.client ~= "socket" then
		return { kind = "ide", groups = {} }
	end
	local known = switched[connection]
	if known == nil then
		known = { kind = "socket", groups = {}, connection = connection } :: Caller
		switched[connection] = known
	end
	return known
end

-- The connection each tool call from an MCP client runs for, by the
-- thread it runs in.
local running: { [thread]: number? } = setmetatable({}, { __mode = "k" }) :: any

--- The MCP connection whose tool call runs in this thread, if any, e.g.
--- to take back what the call leaves waiting once that connection closes.
function M.connection(): number?
	return running[coroutine.running()]
end

--- Runs the tool `name` as `caller` would through MCP, and wraps what it
--- returns the way MCP wants. Tools `caller` isn't offered are there to
--- call too: an agent that remembers one needn't switch its group on
--- first.
local function call(name: string, arguments: { [string]: any }, caller: Caller)
	local tool = (tools[client_of(caller)] or {})[name]
	if tool == nil then
		return M.result(`there is no tool called {name}`, true)
	end
	local thread = coroutine.running()
	running[thread] = caller.connection
	local ok, result = pcall(tool.run, arguments, caller)
	running[thread] = nil
	if not ok then
		return M.result(tostring(result), true)
	elseif results[result] then
		return result
	end
	return M.result(M.as_text(result))
end

local methods: { [string]: (request: greed.ControlRequest) -> any } = {
	initialize = function(request)
		local params = request.params
		return {
			protocolVersion = params and params.protocolVersion or "2025-06-18",
			capabilities = { tools = { listChanged = true } },
			serverInfo = { name = "greed", version = "0.1" },
		}
	end,
	ping = function()
		return {}
	end,
	["tools/list"] = function(request)
		local list = {}
		for _, tool in M.offered(caller_of(request)) do
			table.insert(list, {
				name = tool.name,
				description = tool.description,
				inputSchema = tool.input or { type = "object", properties = {} },
				annotations = {
					readOnlyHint = (tool.kind or "read") == "read",
					openWorldHint = tool.kind == "fetch",
				},
			})
		end
		return { tools = greed.json.array(list) }
	end,
	["tools/call"] = function(request)
		local params = request.params
		return call(params.name, params.arguments or {}, caller_of(request))
	end,
}

greed.on("control.request", function(request: greed.ControlRequest)
	local method = methods[request.method]
	-- Notifications, like notifications/initialized, need no answer, but the
	-- socket waits for one.
	if method == nil and string.sub(request.method, 1, 14) == "notifications/" then
		greed.control.reply(request.id, nil)
	elseif method == nil then
		greed.control.reply(request.id, nil, `unknown method {request.method}`)
	else
		local ok, result = pcall(method, request)
		if ok then
			greed.control.reply(request.id, result)
		else
			greed.control.reply(request.id, nil, tostring(result))
		end
	end
end)

greed.on("control.closed", function(event: greed.ControlClosed)
	switched[event.connection] = nil
end)

-- The names of the tools in `group`, sorted, with commas between.
local function members(group: string): string
	local names = {}
	for _, tool in M.tools() do
		if tool.group == group then
			table.insert(names, tool.name)
		end
	end
	return table.concat(names, ", ")
end

-- The groups' names, sorted.
local function group_names(): { string }
	local names = {}
	for name in groups do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

-- The groups and what's in them, for the agent to pick from.
local function listing(caller: Caller): string
	local lines = {}
	for _, name in group_names() do
		local on = if has(caller, name) then " (on)" else ""
		table.insert(lines, `{name}{on}: {groups[name]}. Tools: {members(name)}`)
	end
	return table.concat(lines, "\n")
end

local TOOLS = "More of Greed's tools, in groups you switch on when you need them: without "
	.. "arguments, the groups and what's in each; with group, switches that group on so "
	.. "its tools are offered from now on."

local tools_tool: Tool = {
	name = "tools",
	description = TOOLS,
	input = M.schema.object({ group = { type = "string", description = "The group to switch on" } }),
	run = function(args, caller)
		local group = args.group
		if group == nil then
			return listing(caller)
		elseif groups[group] == nil then
			error(
				`there's no group called {group}; the groups are {table.concat(group_names(), ", ")}`,
				0
			)
		elseif caller.kind == "shell" then
			return "every tool is offered to you already"
		end
		caller.groups[group] = true
		if caller.connection then
			greed.control.send(caller.connection, "notifications/tools/list_changed", nil)
		end
		return `switched on {group}: {members(group)}`
	end,
}
M.tool(tools_tool)

-- The groups are named in the tool's description and allowed as its
-- argument, so an agent needn't guess at them or list them first.
describe_groups = function()
	local names = group_names()
	local said = {}
	for _, known in names do
		table.insert(said, `{known} ({groups[known]})`)
	end
	tools_tool.description = `{TOOLS} The groups: {table.concat(said, "; ")}.`
	tools_tool.input = M.schema.object({
		group = { type = "string", description = "The group to switch on", enum = names },
	})
end

return M
