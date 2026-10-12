-- One turn of a conversation with tools: the model answers in text and
-- may ask for tools to be called, and the next turn gives it their
-- results. The conversation is kept the same way for every provider and
-- put the way each API wants it when sent: Anthropic's messages API, or
-- OpenAI's chat completions (which most other servers speak too).

local greed = require("@greed")
local core = require("@core")
local sse = require("./sse")

local M = {}

--- A tool the model may call: its name, what it does, and a JSON schema
--- for what it takes.
export type ToolSpec = { name: string, description: string, input: { [string]: any }? }

--- A call the model asked for, with the arguments it gave.
export type Call = { id: string, name: string, input: { [string]: any } }

--- What was said: by you (`text`), by the model (`text` and the `calls` it
--- asked for), or a tool's result for the call `call`. What you said can
--- have `images` with it, PNG files by their paths, read when the request
--- is made. `thinking` is what the model thought before it answered, sent
--- back to providers with `thinking_back` (see `Request`), and `signed`
--- Anthropic's thinking blocks as they came, with their signatures, for
--- the models that want them back (see `body`).
export type Said = {
	role: "user" | "assistant" | "tool",
	text: string?,
	calls: { Call }?,
	call: string?,
	error: boolean?,
	images: { string }?,
	thinking: string?,
	signed: { any }?,
}

--- How a turn ended: "done" (the model has finished), "tools" (it wants
--- its calls run first), "length" (it ran out of room), or what the
--- provider said. `tokens` is how much of the model's context the
--- conversation takes after the turn, when the provider says; `input`
--- and `output` are the tokens this request read and wrote, `cached` how
--- many of those read came from the provider's cache. `thinking` is what
--- the model thought before answering, when the provider shows it, and
--- `signed` Anthropic's thinking blocks, to keep with what it said.
export type Turn = {
	text: string,
	calls: { Call },
	stop: string,
	tokens: number?,
	input: number?,
	output: number?,
	cached: number?,
	thinking: string?,
	signed: { any }?,
}

--- How hard a model may think before it answers, least first.
M.EFFORTS = { "none", "low", "medium", "high" }

-- Claude models that think within a budget of tokens rather than by an
-- effort, by a pattern in their name: those before the 4.6 family.
local BUDGETED = { "claude%-3", "%-4%-5", "%-4%-1", "%-4%-0", "%-4%-%d%d%d%d%d%d%d%d", "%-4$" }

-- The thinking budget of each effort, for those.
local BUDGETS: { [string]: number } = { low = 2048, medium = 8192, high = 24576 }

-- Whether the Claude model `model` thinks within a budget.
local function budgeted(model: string): boolean
	local name = string.lower(model)
	for _, pattern in BUDGETED do
		if string.find(name, pattern) then
			return true
		end
	end
	return false
end

--- Puts `effort` (one of `EFFORTS`) in `body`, a request to a provider of
--- `kind` for `model`, as its API wants it: `reasoning_effort` for
--- OpenAI-like servers; for Claude, an effort and summarised thinking, or
--- a thinking budget for models before the 4.6 family, with room for the
--- answer above it. Claude gets no temperature with either. Nil changes
--- nothing.
function M.reasoning(kind: string, model: string, effort: string?, body: { [string]: any })
	if effort == nil then
		return
	elseif kind ~= "anthropic" then
		body.reasoning_effort = effort
		return
	end
	body.temperature = nil
	if budgeted(model) then
		local budget = BUDGETS[effort]
		if budget then
			body.thinking = { type = "enabled", budget_tokens = budget }
			body.max_tokens = (body.max_tokens or 0) + budget
		end
		return
	end
	-- Current models always think some; none is as little as they go.
	body.output_config = { effort = if effort == "none" then "low" else effort }
	if effort ~= "none" then
		body.thinking = { type = "adaptive", display = "summarized" }
	end
end

-- A tool's schema, with an empty object for one that takes nothing.
local function schema(tool: ToolSpec): { [string]: any }
	return tool.input or { type = "object", properties = {} }
end

-- The images that go with `s`, each as its PNG in base64, and a note for
-- each that's no longer kept (its file was removed), to say instead.
local function images_of(s: Said): ({ string }, { string })
	local data: { string } = {}
	local gone: { string } = {}
	local paths: { string } = s.images or {}
	for _, path in paths do
		local png = greed.fs.read_bytes(path)
		if png then
			table.insert(data, greed.base64.encode(png))
		else
			table.insert(gone, `[an image that was here, {path}, is no longer kept]`)
		end
	end
	return data, gone
end

-- What you said in `s`, with notes for images no longer kept.
local function user_text(s: Said, gone: { string }): string
	local text = s.text or ""
	return if #gone > 0 then `{text}\n{table.concat(gone, "\n")}` else text
end

-- The conversation as Anthropic's messages: tool results go in the next
-- user message, and messages by the same side are joined, since its API
-- wants them to take turns. With `signed`, the model's thinking blocks go
-- back from your last message on, in the tool loop going on, as models
-- that think within a budget want. Current models get none back: they
-- turn down thinking once anything before it changed, as compacting or a
-- tool group switched on does.
local function anthropic_messages(said: { Said }, signed: boolean): { any }
	local messages: { { role: string, content: { any } } } = {}
	local function add(role: string, block: any)
		local last = messages[#messages]
		if last and last.role == role then
			table.insert(last.content, block)
		else
			table.insert(messages, { role = role, content = { block } })
		end
	end
	local last_user = 0
	for i, s in said do
		if s.role == "user" then
			last_user = i
		end
	end
	for i, s in said do
		if s.role == "tool" then
			add("user", {
				type = "tool_result",
				tool_use_id = s.call,
				content = s.text or "",
				is_error = s.error or nil,
			})
		elseif s.role == "assistant" then
			local blocks: { any } = if signed and i > last_user then s.signed or {} else {}
			for _, block in blocks do
				add("assistant", block)
			end
			if s.text and s.text ~= "" then
				add("assistant", { type = "text", text = s.text })
			end
			local calls: { Call } = s.calls or {}
			for _, call in calls do
				add(
					"assistant",
					{ type = "tool_use", id = call.id, name = call.name, input = call.input }
				)
			end
		else
			local data, gone = images_of(s)
			for _, png in data do
				add("user", {
					type = "image",
					source = { type = "base64", media_type = "image/png", data = png },
				})
			end
			add("user", { type = "text", text = user_text(s, gone) })
		end
	end
	return messages
end

-- What the model said in `s` as an assistant message's content: its text,
-- or with `thinking_back` and thinking, Mistral's parts, the thinking (a
-- list of text parts) and then the text.
local function assistant_content(s: Said, thinking_back: boolean): any
	local text = s.text or ""
	if not thinking_back or s.thinking == nil or s.thinking == "" then
		return text
	end
	local parts: { any } = {
		{ type = "thinking", thinking = { { type = "text", text = s.thinking } }, closed = true },
	}
	if text ~= "" then
		table.insert(parts, { type = "text", text = text })
	end
	return parts
end

-- The conversation as OpenAI's chat messages, with the model's thinking
-- in its messages for `thinking_back`.
local function openai_messages(system: string?, said: { Said }, thinking_back: boolean): { any }
	local messages: { any } = {}
	if system then
		table.insert(messages, { role = "system", content = system })
	end
	for _, s in said do
		if s.role == "tool" then
			table.insert(messages, { role = "tool", tool_call_id = s.call, content = s.text or "" })
		elseif s.role == "assistant" then
			local message: { [string]: any } =
				{ role = "assistant", content = assistant_content(s, thinking_back) }
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
			-- A turn stopped at tool results, by you or the turn limit, ends
			-- with a word from the model: some providers, like Mistral, turn
			-- down a message that follows a tool's result.
			local last = messages[#messages]
			if last and last.role == "tool" then
				table.insert(messages, { role = "assistant", content = "(stopped here)" })
			end
			local data, gone = images_of(s)
			if #data == 0 then
				table.insert(messages, { role = "user", content = user_text(s, gone) })
			else
				-- With images, the content is parts: the text, then each image.
				local parts: { any } = { { type = "text", text = user_text(s, gone) } }
				for _, png in data do
					table.insert(
						parts,
						{ type = "image_url", image_url = { url = `data:image/png;base64,{png}` } }
					)
				end
				table.insert(messages, { role = "user", content = parts })
			end
		end
	end
	return messages
end

export type Request = {
	system: string?,
	said: { Said },
	tools: { ToolSpec }?,
	max_tokens: number?,
	--- Names the conversation for the provider's cache, as
	--- `prompt_cache_key`; set only for providers with `cache_key`.
	cache_key: string?,
	--- How hard the model may think (`EFFORTS`); nil sends nothing.
	effort: string?,
	--- Sends the model's thinking back in its messages, as Mistral's
	--- reasoning models want; set only for providers with `thinking_back`.
	--- OpenAI-like servers only: many turn down parts in the model's
	--- messages.
	thinking_back: boolean?,
}

--- The body to send to a provider of `kind` for `model`, as a table.
function M.body(
	kind: string,
	model: string,
	request: Request,
	max_tokens: number
): { [string]: any }
	local tools: { any } = {}
	local specs: { ToolSpec } = request.tools or {}
	for _, tool in specs do
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
		-- Cache markers on the tools, the system prompt and the newest
		-- message: the next request starts with all of it, and reads it back
		-- for a tenth of the price. Other providers cache matching starts
		-- by themselves.
		local cached = { type = "ephemeral" }
		if #tools > 0 then
			tools[#tools].cache_control = cached
		end
		if request.system then
			body.system = { { type = "text", text = request.system, cache_control = cached } }
		end
		local messages = anthropic_messages(request.said, request.effort ~= nil and budgeted(model))
		local last = messages[#messages]
		if last and #last.content > 0 then
			last.content[#last.content].cache_control = cached
		end
		body.messages = messages
	else
		body.messages = openai_messages(request.system, request.said, request.thinking_back == true)
		body.prompt_cache_key = request.cache_key
	end
	M.reasoning(kind, model, request.effort, body)
	return body
end

--- A request in short, to tell what the next one in the same conversation
--- changed: a hash of its tools, of its system prompt (Anthropic's; the
--- rest have it as the first message), of its other fields, and of each
--- message.
export type Fingerprint = {
	tools: string,
	system: string,
	settings: string,
	messages: { string },
}

-- The first 8 hex digits of `text`'s SHA-256.
local function short_hash(text: string): string
	return string.sub(greed.hash.sha256(text), 1, 8)
end

-- `value` (a tool, a block or a message) encoded without Anthropic's
-- cache markers, which move to the newest of each every request.
local function unmarked(value: any): string
	if type(value) ~= "table" then
		return greed.json.encode(value)
	end
	local copy = table.clone(value)
	copy.cache_control = nil
	if type(copy.content) == "table" then
		local blocks = {}
		for _, block in copy.content do
			if type(block) == "table" and block.cache_control then
				block = table.clone(block)
				block.cache_control = nil
			end
			table.insert(blocks, block)
		end
		copy.content = blocks
	end
	return greed.json.encode(copy)
end

-- The hash of each of `list` (nil for none), unmarked.
local function hashes(list: { any }?): { string }
	local out = {}
	local items: { any } = list or {}
	for _, item in items do
		table.insert(out, short_hash(unmarked(item)))
	end
	return out
end

--- What a debug line says of a request's timing, all in milliseconds from
--- greed.now(): sent at `sent`, its first bytes back at `first` (nil if
--- none came), ended at `done`, having written `output` tokens. The pace
--- is over the time it streamed, which tells a slow model from a long wait.
function M.timing(sent: number, first: number?, done: number, output: number?): string
	local duration = core.time.duration
	if first == nil then
		return `nothing back, done in {duration(done - sent)}`
	end
	local said = `first bytes after {duration(first - sent)}, done in {duration(done - sent)}`
	if output and done > first then
		said ..= `, {math.floor(output / ((done - first) / 1000) + 0.5)} tokens/s`
	end
	return said
end

--- What a debug line says of `body` (from `M.body`), a request after
--- `last`, the fingerprint of the one before it in the same conversation
--- (nil for the first): how many messages it has, a hash of everything
--- but its newest message, and what it changed of the last request, which
--- a provider's cache needs it to start with. Returns that and the
--- request's fingerprint, for the next one.
function M.compare(body: { [string]: any }, last: Fingerprint?): (string, Fingerprint)
	local rest = table.clone(body)
	rest.messages, rest.tools, rest.system = nil, nil, nil
	local now: Fingerprint = {
		tools = table.concat(hashes(body.tools), ""),
		system = table.concat(hashes(body.system), ""),
		settings = short_hash(greed.json.encode(rest)),
		messages = hashes(body.messages),
	}
	local messages = now.messages
	local older = table.concat(messages, "", 1, math.max(#messages - 1, 0))
	local prefix = short_hash(`{now.tools} {now.system} {now.settings} {older}`)
	local said
	if last == nil then
		said = "the first request"
	elseif now.settings ~= last.settings then
		said = "other settings than the last request (model, effort, length)"
	elseif now.system ~= last.system then
		said = "another system prompt than the last request"
	elseif string.sub(now.tools, 1, #last.tools) ~= last.tools then
		said = "other tools than the last request"
	else
		local same = 0
		while same < #last.messages and messages[same + 1] == last.messages[same + 1] do
			same += 1
		end
		local first = body.messages and body.messages[1]
		if same == #last.messages then
			said = `all {same} messages of the last request first`
		elseif same == 0 and type(first) == "table" and first.role == "system" then
			said = "another system prompt than the last request"
		else
			said = `message {same + 1} of the last request's {#last.messages} changed`
		end
		if #now.tools > #last.tools then
			said ..= ", and tools added after its own"
		end
	end
	return `{#messages} messages, prefix {prefix}: {said}`, now
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
	--- the turn is over, an error if the provider sent one, and thinking
	--- that arrived.
	feed: (event: sse.Event) -> (string?, boolean, string?, string?),
	--- The turn as read so far.
	turn: () -> Turn,
	--- Whether it has started on a tool call.
	calling: () -> boolean,
}

--- The answer's text in a streamed `delta.content` of OpenAI's API: a
--- string, or with Mistral's reasoning models a list of parts, the
--- thinking (left out, see `content_thinking`) and the text, whose first
--- word comes in the same list as the end of the thinking.
function M.content_text(content: any): string?
	if type(content) == "string" then
		return content
	elseif type(content) ~= "table" then
		return nil
	end
	local parts = {}
	for _, part in content do
		if type(part) == "table" and part.type == "text" and type(part.text) == "string" then
			table.insert(parts, part.text)
		end
	end
	return table.concat(parts)
end

--- The thinking in a streamed `delta` of OpenAI's API: Mistral's thinking
--- parts of `content`, each a list of text parts, or the
--- `reasoning_content` (or `reasoning`) other servers send. Nil when
--- there's none.
function M.content_thinking(delta: any): string?
	if type(delta) ~= "table" then
		return nil
	end
	local parts: { string } = {}
	for _, field in { "reasoning_content", "reasoning" } do
		if type(delta[field]) == "string" then
			table.insert(parts, delta[field])
		end
	end
	local content = delta.content
	if type(content) == "table" then
		for _, part in content do
			local thought = type(part) == "table" and part.type == "thinking" and part.thinking
			if type(thought) == "string" then
				table.insert(parts, thought)
			elseif type(thought) == "table" then
				for _, piece in thought do
					if type(piece) == "table" and type(piece.text) == "string" then
						table.insert(parts, piece.text)
					end
				end
			end
		end
	end
	local thinking = table.concat(parts)
	return if thinking ~= "" then thinking else nil
end

--- Reads a streamed answer from a provider of `kind`, as events arrive.
function M.reader(kind: string): Reader
	local text: { string } = {}
	-- Calls being put together, in order, with their arguments as the JSON
	-- text that has come so far. `given` says the server named its id.
	local building: { { id: string, name: string, json: { string }, given: boolean } } = {}
	local by_index: { [any]: number } = {}
	local stop: string = "done"
	-- Tokens read (the prompt, cached or not) and written, as reported.
	local read: number?, written: number?, cached: number? = nil, nil, nil
	-- The call at `index`, or a new one there when the server names
	-- another id for it, as Mistral may with several whole calls at 0.
	local function call_at(index: any, id: string?, name: string?)
		local at = by_index[index]
		local named = id ~= nil and id ~= ""
		if at == nil or (named and building[at].given and building[at].id ~= id) then
			table.insert(building, {
				id = `call_{#building}`,
				name = name or "",
				json = {} :: { string },
				given = false,
			})
			at = #building
			by_index[index] = at
		end
		local call = building[at]
		if named then
			call.id = id :: string
			call.given = true
		end
		if name and name ~= "" then
			call.name = name
		end
		return call
	end
	-- What it thought, and Anthropic's thinking blocks by their index.
	local thought: { string } = {}
	local signed: { any } = {}
	local signed_at: { [any]: any } = {}
	local reader: Reader
	reader = {
		feed = function(event: sse.Event): (string?, boolean, string?, string?)
			if event.data == "[DONE]" then
				return nil, true, nil, nil
			end
			local decoded = greed.json.decode(event.data)
			if type(decoded) ~= "table" then
				return nil, false, nil, nil
			end
			if decoded.error then
				local err = decoded.error
				return nil,
					true,
					if type(err) == "table"
						then err.message or greed.json.encode(err)
						else tostring(err),
					nil
			end
			if kind == "anthropic" then
				local t = decoded.type
				local usage = decoded.usage or (decoded.message and decoded.message.usage)
				if type(usage) == "table" then
					if usage.input_tokens then
						read = usage.input_tokens
							+ (usage.cache_creation_input_tokens or 0)
							+ (usage.cache_read_input_tokens or 0)
						cached = usage.cache_read_input_tokens
					end
					written = usage.output_tokens or written
				end
				if t == "content_block_start" and decoded.content_block then
					local block = decoded.content_block
					if block.type == "tool_use" then
						call_at(decoded.index, block.id, block.name)
					elseif block.type == "thinking" or block.type == "redacted_thinking" then
						local kept = table.clone(block)
						table.insert(signed, kept)
						signed_at[decoded.index] = kept
					end
				elseif t == "content_block_delta" and decoded.delta then
					local delta = decoded.delta
					local block = signed_at[decoded.index]
					if delta.type == "input_json_delta" then
						table.insert(call_at(decoded.index).json, delta.partial_json or "")
					elseif
						delta.type == "thinking_delta"
						and type(delta.thinking) == "string"
						and delta.thinking ~= ""
					then
						if block then
							block.thinking = (block.thinking or "") .. delta.thinking
						end
						table.insert(thought, delta.thinking)
						return nil, false, nil, delta.thinking
					elseif delta.type == "signature_delta" then
						if block then
							block.signature = (block.signature or "") .. (delta.signature or "")
						end
					elseif type(delta.text) == "string" then
						table.insert(text, delta.text)
						return delta.text, false, nil, nil
					end
				elseif t == "message_delta" and decoded.delta and decoded.delta.stop_reason then
					stop = STOPS[decoded.delta.stop_reason] or decoded.delta.stop_reason
				elseif t == "message_stop" then
					return nil, true, nil, nil
				end
				return nil, false, nil, nil
			end
			-- Servers asked for it, or that send it anyway, say it at the end.
			local usage = decoded.usage
			if type(usage) == "table" and usage.prompt_tokens then
				read, written = usage.prompt_tokens, usage.completion_tokens
				local details = usage.prompt_tokens_details
				cached = if type(details) == "table" and details.cached_tokens
					then details.cached_tokens
					else usage.cached_tokens
			end
			local choice = decoded.choices and decoded.choices[1]
			if choice == nil then
				return nil, false, nil, nil
			end
			local delta = choice.delta or {}
			local pieces: { any } = delta.tool_calls or {}
			for position, piece in pieces do
				local fn = piece["function"] or {}
				-- Without an index, each piece is a whole call of its own.
				local call = call_at(piece.index or `#{position}`, piece.id, fn.name)
				if type(fn.arguments) == "string" then
					table.insert(call.json, fn.arguments)
				end
			end
			if choice.finish_reason then
				stop = STOPS[choice.finish_reason] or choice.finish_reason
			end
			local thinking = M.content_thinking(delta)
			if thinking then
				table.insert(thought, thinking)
			end
			local said = M.content_text(delta.content)
			if said and said ~= "" then
				table.insert(text, said)
				return said, false, nil, thinking
			end
			return nil, false, nil, thinking
		end,
		calling = function()
			return #building > 0
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
			local tokens = if read then read + (written or 0) else nil
			return {
				thinking = if #thought > 0 then table.concat(thought) else nil,
				signed = if #signed > 0 then signed else nil,
				text = table.concat(text),
				calls = calls,
				stop = ended,
				tokens = tokens,
				input = read,
				output = written,
				cached = cached,
			}
		end,
	}
	return reader
end

return M
