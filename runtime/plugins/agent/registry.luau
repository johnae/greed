-- The tools offered to agents, and the MCP methods that list and run them.

local greed = require("@greed")

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
	--- Does the work. It can wait, e.g. for the user. A string result goes
	--- to the agent as is, a table with `content` as an MCP result, anything
	--- else as JSON. Errors go back as errors.
	run: (args: { [string]: any }) -> any,
}

-- The tools offered, by client and name.
local tools: { [string]: { [string]: Tool } } = {}

local M = {}

--- Offers `spec` to agents and `greed ctl`. A tool with the same name is
--- replaced.
function M.tool(spec: Tool)
	assert(string.match(spec.name, "^[%w_%-]+$"), "tool names are letters, digits, _ and -")
	local client = spec.client or "socket"
	tools[client] = tools[client] or {}
	tools[client][spec.name] = spec
end

--- The tools offered to `client` (default "socket"), sorted by name.
function M.tools(client: string?): { Tool }
	local list = {}
	for _, tool in tools[client or "socket"] or {} do
		table.insert(list, tool)
	end
	table.sort(list, function(a: Tool, b: Tool)
		return a.name < b.name
	end)
	return list
end

local function text_result(text: string, is_error: boolean)
	return { content = { { type = "text", text = text } }, isError = is_error }
end

-- Runs a tool for tools/call and wraps what it returns the way MCP wants.
local function call(params: { name: string, arguments: { [string]: any }? }, client: string)
	local tool = (tools[client] or {})[params.name]
	if tool == nil then
		return text_result(`there is no tool called {params.name}`, true)
	end
	local ok, result = pcall(tool.run, params.arguments or {})
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

local methods: { [string]: (params: any, client: string) -> any } = {
	initialize = function(params)
		return {
			protocolVersion = params and params.protocolVersion or "2025-06-18",
			capabilities = { tools = {} },
			serverInfo = { name = "greed", version = "0.1" },
		}
	end,
	ping = function()
		return {}
	end,
	["tools/list"] = function(_, client)
		local list = {}
		for _, tool in M.tools(client) do
			table.insert(list, {
				name = tool.name,
				description = tool.description,
				inputSchema = tool.input or { type = "object", properties = {} },
			})
		end
		return { tools = greed.json.array(list) }
	end,
	["tools/call"] = call,
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
		local ok, result = pcall(method, request.params, request.client)
		if ok then
			greed.control.reply(request.id, result)
		else
			greed.control.reply(request.id, nil, tostring(result))
		end
	end
end)

return M
