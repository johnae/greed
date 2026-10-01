-- The tools offered to agents, and the MCP methods that list and run them.

local kern = require("@kern")

export type Tool = {
	--- Letters, digits, `_` and `-`, which every MCP client accepts.
	name: string,
	--- What it does, for the agent deciding whether to use it.
	description: string,
	--- A JSON Schema for the arguments: `{ type = "object", properties = {...} }`.
	input: { [string]: any }?,
	--- Does the work. It can wait, e.g. for the user. A string result goes
	--- to the agent as is; anything else as JSON. Errors go back as errors.
	run: (args: { [string]: any }) -> any,
}

local tools: { [string]: Tool } = {}

local M = {}

--- Offers `spec` to agents and `kern ctl`. A tool with the same name is
--- replaced.
function M.tool(spec: Tool)
	assert(string.match(spec.name, "^[%w_%-]+$"), "tool names are letters, digits, _ and -")
	tools[spec.name] = spec
end

--- The tools offered, sorted by name.
function M.tools(): { Tool }
	local list = {}
	for _, tool in tools do
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
local function call(params: { name: string, arguments: { [string]: any }? })
	local tool = tools[params.name]
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
	return text_result(kern.json.encode(result), false)
end

local methods: { [string]: (params: any) -> any } = {
	initialize = function(params)
		return {
			protocolVersion = params and params.protocolVersion or "2025-06-18",
			capabilities = { tools = {} },
			serverInfo = { name = "kern", version = "0.1" },
		}
	end,
	ping = function()
		return {}
	end,
	["tools/list"] = function()
		local list = {}
		for _, tool in M.tools() do
			table.insert(list, {
				name = tool.name,
				description = tool.description,
				inputSchema = tool.input or { type = "object", properties = {} },
			})
		end
		return { tools = kern.json.array(list) }
	end,
	["tools/call"] = call,
}

kern.on("control.request", function(request: kern.ControlRequest)
	local method = methods[request.method]
	-- Notifications, like notifications/initialized, need no answer, but the
	-- socket waits for one.
	if method == nil and string.sub(request.method, 1, 14) == "notifications/" then
		kern.control.reply(request.id, nil)
	elseif method == nil then
		kern.control.reply(request.id, nil, `unknown method {request.method}`)
	else
		local ok, result = pcall(method, request.params)
		if ok then
			kern.control.reply(request.id, result)
		else
			kern.control.reply(request.id, nil, tostring(result))
		end
	end
end)

return M
