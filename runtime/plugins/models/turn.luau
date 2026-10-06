-- One turn of a conversation with tools: the model answers in text and
-- may ask for tools to be called, and the next turn gives it their
-- results. The conversation is kept the same way for every provider and
-- put the way each API wants it when sent: Anthropic's messages API, or
-- OpenAI's chat completions (which most other servers speak too).

local greed = require("@greed")
local sse = require("./sse")

local M = {}

--- A tool the model may call: its name, what it does, and a JSON schema
--- for what it takes.
export type ToolSpec = { name: string, description: string, input: { [string]: any }? }

--- A call the model asked for, with the arguments it gave.
export type Call = { id: string, name: string, input: { [string]: any } }

--- What was said: by you (`text`), by the model (`text` and the `calls` it
--- asked for), or a tool's result for the call `call`.
export type Said = {
	role: "user" | "assistant" | "tool",
	text: string?,
	calls: { Call }?,
	call: string?,
	error: boolean?,
}

--- How a turn ended: "done" (the model has finished), "tools" (it wants
--- its calls run first), "length" (it ran out of room), or what the
--- provider said.
export type Turn = { text: string, calls: { Call }, stop: string }

-- A tool's schema, with an empty object for one that takes nothing.
local function schema(tool: ToolSpec): { [string]: any }
	return tool.input or { type = "object", properties = {} }
end

-- The conversation as Anthropic's messages: tool results go in the next
-- user message, and messages by the same side are joined, since its API
-- wants them to take turns.
local function anthropic_messages(said: { Said }): { any }
	local messages: { { role: string, content: { any } } } = {}
	local function add(role: string, block: any)
		local last = messages[#messages]
		if last and last.role == role then
			table.insert(last.content, block)
		else
			table.insert(messages, { role = role, content = { block } })
		end
	end
	for _, s in said do
		if s.role == "tool" then
			add("user", {
				type = "tool_result",
				tool_use_id = s.call,
				content = s.text or "",
				is_error = s.error or nil,
			})
		elseif s.role == "assistant" then
			if s.text and s.text ~= "" then
				add("assistant", { type = "text", text = s.text })
			end
			for _, call in s.calls or {} do
				add(
					"assistant",
					{ type = "tool_use", id = call.id, name = call.name, input = call.input }
				)
			end
		else
			add("user", { type = "text", text = s.text or "" })
		end
	end
	return messages
end

-- The conversation as OpenAI's chat messages.
local function openai_messages(system: string?, said: { Said }): { any }
	local messages: { any } = {}
	if system then
		table.insert(messages, { role = "system", content = system })
	end
	for _, s in said do
		if s.role == "tool" then
			table.insert(messages, { role = "tool", tool_call_id = s.call, content = s.text or "" })
		elseif s.role == "assistant" then
			local message: { [string]: any } = { role = "assistant", content = s.text or "" }
			if s.calls and #s.calls > 0 then
				local calls = {}
				for _, call in s.calls do
					table.insert(calls, {
						id = call.id,
						type = "function",
						["function"] = {
							name = call.name,
							arguments = greed.json.encode(call.input),
						},
					})
				end
				message.tool_calls = calls
			end
			table.insert(messages, message)
		else
			table.insert(messages, { role = "user", content = s.text or "" })
		end
	end
	return messages
end

export type Request = {
	system: string?,
	said: { Said },
	tools: { ToolSpec }?,
	max_tokens: number?,
}

--- The body to send to a provider of `kind` for `model`, as a table.
function M.body(
	kind: string,
	model: string,
	request: Request,
	max_tokens: number
): { [string]: any }
	local tools: { any } = {}
	for _, tool in request.tools or {} do
		if kind == "anthropic" then
			table.insert(
				tools,
				{ name = tool.name, description = tool.description, input_schema = schema(tool) }
			)
		else
			table.insert(tools, {
				type = "function",
				["function"] = {
					name = tool.name,
					description = tool.description,
					parameters = schema(tool),
				},
			})
		end
	end
	local body: { [string]: any } = {
		model = model,
		max_tokens = request.max_tokens or max_tokens,
		stream = true,
		tools = if #tools > 0 then tools else nil,
	}
	if kind == "anthropic" then
		body.system = request.system
		body.messages = anthropic_messages(request.said)
	else
		body.messages = openai_messages(request.system, request.said)
	end
	return body
end

-- What each provider says when it stops, as a Turn's `stop`.
local STOPS = {
	end_turn = "done",
	stop = "done",
	stop_sequence = "done",
	tool_use = "tools",
	tool_calls = "tools",
	max_tokens = "length",
	length = "length",
}

export type Reader = {
	--- Takes one event of the stream; returns text that arrived, whether
	--- the turn is over, and an error if the provider sent one.
	feed: (event: sse.Event) -> (string?, boolean, string?),
	--- The turn as read so far.
	turn: () -> Turn,
}

--- Reads a streamed answer from a provider of `kind`, as events arrive.
function M.reader(kind: string): Reader
	local text: { string } = {}
	-- Calls being put together, in order, with their arguments as the JSON
	-- text that has come so far.
	local building: { { id: string, name: string, json: { string } } } = {}
	local by_index: { [number]: number } = {}
	local stop: string = "done"
	local function call_at(index: number, id: string?, name: string?)
		local at = by_index[index]
		if at == nil then
			table.insert(
				building,
				{ id = id or `call_{index}`, name = name or "", json = {} :: { string } }
			)
			at = #building
			by_index[index] = at
		end
		local call = building[at]
		if id and id ~= "" then
			call.id = id
		end
		if name and name ~= "" then
			call.name = name
		end
		return call
	end
	local reader: Reader
	reader = {
		feed = function(event: sse.Event): (string?, boolean, string?)
			if event.data == "[DONE]" then
				return nil, true, nil
			end
			local decoded = greed.json.decode(event.data)
			if type(decoded) ~= "table" then
				return nil, false, nil
			end
			if decoded.error then
				local err = decoded.error
				return nil,
					true,
					if type(err) == "table"
						then err.message or greed.json.encode(err)
						else tostring(err)
			end
			if kind == "anthropic" then
				local t = decoded.type
				if t == "content_block_start" and decoded.content_block then
					local block = decoded.content_block
					if block.type == "tool_use" then
						call_at(decoded.index, block.id, block.name)
					end
				elseif t == "content_block_delta" and decoded.delta then
					local delta = decoded.delta
					if delta.type == "input_json_delta" then
						table.insert(call_at(decoded.index).json, delta.partial_json or "")
					elseif type(delta.text) == "string" then
						table.insert(text, delta.text)
						return delta.text, false, nil
					end
				elseif t == "message_delta" and decoded.delta and decoded.delta.stop_reason then
					stop = STOPS[decoded.delta.stop_reason] or decoded.delta.stop_reason
				elseif t == "message_stop" then
					return nil, true, nil
				end
				return nil, false, nil
			end
			local choice = decoded.choices and decoded.choices[1]
			if choice == nil then
				return nil, false, nil
			end
			local delta = choice.delta or {}
			for _, piece in delta.tool_calls or {} do
				local fn = piece["function"] or {}
				local call = call_at(piece.index or 0, piece.id, fn.name)
				if type(fn.arguments) == "string" then
					table.insert(call.json, fn.arguments)
				end
			end
			if choice.finish_reason then
				stop = STOPS[choice.finish_reason] or choice.finish_reason
			end
			if type(delta.content) == "string" and delta.content ~= "" then
				table.insert(text, delta.content)
				return delta.content, false, nil
			end
			return nil, false, nil
		end,
		turn = function()
			local calls: { Call } = {}
			for _, call in building do
				local json = table.concat(call.json)
				local input = if json == "" then {} else greed.json.decode(json)
				table.insert(calls, {
					id = call.id,
					name = call.name,
					input = if type(input) == "table" then input else {},
				})
			end
			-- Some servers say "stop" though they asked for tools.
			local ended = if #calls > 0 and stop == "done" then "tools" else stop
			return { text = table.concat(text), calls = calls, stop = ended }
		end,
	}
	return reader
end

return M
