-- The tools offered to agents, and the MCP methods that list and run them.
--
-- Every tool an agent is offered costs tokens on each request, so tools
-- come in groups: those without one are always offered, and an agent
-- switches a group on with the `tools` tool when it needs it (or the
-- `agent-tool-groups` option gives it from the start). MCP clients hear
-- that their list changed and fetch it again.

local greed = require("@greed")

--- Who's calling a tool: the groups they have switched on, which the
--- `tools` tool adds to, and for MCP clients the connection to tell when
--- their list changes.
export type Caller = { groups: { [string]: boolean }, connection: number? }

export type Tool = {
	--- Letters, digits, `_` and `-`, which every MCP client accepts.
	name: string,
	--- What it does, for the agent deciding whether to use it.
	description: string,
	--- A JSON Schema for the arguments: `{ type = "object", properties = {...} }`.
	input: { [string]: any }?,
	--- Who sees it: "socket" (`greed ctl`, `greed mcp`; the default) or "ide"
	--- (Claude Code's IDE connection, which expects its own set of tools).
	client: string?,
	--- The group it's offered with (see `group`); without one it's always
	--- offered.
	group: string?,
	--- Does the work. It can wait, e.g. for the user. A string result goes
	--- to the agent as is, a table with `content` as an MCP result, anything
	--- else as JSON. Errors go back as errors.
	--- It gets who called as `client`: "shell" for `greed ctl`, whose caller
	--- can run anything already, or the set it was offered to.
	run: (args: { [string]: any }, client: string?, caller: Caller?) -> any,
}

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

--- Offers `spec` to agents and `greed ctl`. A tool with the same name is
--- replaced.
function M.tool(spec: Tool)
	assert(string.match(spec.name, "^[%w_%-]+$"), "tool names are letters, digits, _ and -")
	local client = spec.client or "socket"
	tools[client] = tools[client] or {}
	tools[client][spec.name] = spec
end

--- Names a group of tools and says what it's for, in a line the agent
--- reads when deciding whether to switch it on.
-- Says in the `tools` tool which groups there are; set once it's made.
local describe_groups = function() end

function M.group(name: string, description: string)
	groups[name] = description
	describe_groups()
end

-- The set of tools `client` gets: a shell (`greed ctl`) gets the socket's.
local function offered(client: string): string
	return if client == "shell" then "socket" else client
end

local function sorted(list: { Tool }): { Tool }
	table.sort(list, function(a: Tool, b: Tool)
		return a.name < b.name
	end)
	return list
end

--- Every tool offered to `client` (default "socket"), in every group,
--- sorted by name.
function M.tools(client: string?): { Tool }
	local list = {}
	for _, tool in tools[offered(client or "socket")] or {} do
		table.insert(list, tool)
	end
	return sorted(list)
end

--- Whether `caller` gets the tools of `group`: it switched it on, or the
--- option gives it.
local function has(caller: Caller?, group: string): boolean
	if caller and caller.groups[group] then
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
function M.offered(client: string?, caller: Caller?): { Tool }
	if client == "shell" then
		return M.tools(client)
	end
	local list = {}
	for _, tool in M.tools(client) do
		if tool.group == nil or has(caller, tool.group) then
			table.insert(list, tool)
		end
	end
	return list
end

--- A caller with no groups switched on yet, e.g. for an agent session.
function M.caller(): Caller
	return { groups = {} }
end

-- The caller for a request: its connection's. Connection ids aren't
-- reused, and a caller is a small table, so they're kept for the session.
local function caller_of(request: greed.ControlRequest): Caller?
	local connection = request.connection
	if connection == nil or request.client ~= "socket" then
		return nil
	end
	local known = switched[connection]
	if known == nil then
		known = { groups = {}, connection = connection } :: Caller
		switched[connection] = known
	end
	return known
end

local function text_result(text: string, is_error: boolean)
	return { content = { { type = "text", text = text } }, isError = is_error }
end

--- Runs the tool `name` for `client` as `caller` would through MCP, and
--- wraps what it returns the way MCP wants. Tools `caller` isn't offered
--- are there to call too: an agent that remembers one needn't switch its
--- group on first.
local function call(name: string, arguments: { [string]: any }, client: string, caller: Caller?)
	local tool = (tools[offered(client)] or {})[name]
	if tool == nil then
		return text_result(`there is no tool called {name}`, true)
	end
	local ok, result = pcall(tool.run, arguments, client, caller)
	if not ok then
		return text_result(tostring(result), true)
	end
	if type(result) == "string" then
		return text_result(result, false)
	end
	if type(result) == "table" and result.content then
		return result
	end
	return text_result(greed.json.encode(result), false)
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
		for _, tool in M.offered(request.client, caller_of(request)) do
			table.insert(list, {
				name = tool.name,
				description = tool.description,
				inputSchema = tool.input or { type = "object", properties = {} },
			})
		end
		return { tools = greed.json.array(list) }
	end,
	["tools/call"] = function(request)
		local params = request.params
		return call(params.name, params.arguments or {}, request.client, caller_of(request))
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

-- The groups and what's in them, for the agent to pick from.
local function listing(caller: Caller?): string
	local names = {}
	for name in groups do
		table.insert(names, name)
	end
	table.sort(names)
	local lines = {}
	for _, name in names do
		local on = if has(caller, name) then " (on)" else ""
		table.insert(lines, `{name}{on}: {groups[name]}. Tools: {members(name)}`)
	end
	return table.concat(lines, "\n")
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

local TOOLS = "More of Greed's tools, in groups you switch on when you need them: without "
	.. "arguments, the groups and what's in each; with group, switches that group on so "
	.. "its tools are offered from now on."

local tools_tool: Tool = {
	name = "tools",
	description = TOOLS,
	input = {
		type = "object",
		properties = { group = { type = "string", description = "The group to switch on" } },
	},
	run = function(args, _, caller)
		local group = args.group
		if group == nil then
			return listing(caller)
		elseif groups[group] == nil then
			error(
				`there's no group called {group}; the groups are {table.concat(group_names(), ", ")}`,
				0
			)
		elseif caller == nil then
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
	tools_tool.input = {
		type = "object",
		properties = {
			group = { type = "string", description = "The group to switch on", enum = names },
		},
	}
end

return M
