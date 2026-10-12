local test = require("@greed/test")
local greed = require("@greed")
local models = require("@models")
local turn = models.tools
local sse = require("../sse")

local TOOLS: { models.ToolSpec } = {
	{
		name = "read",
		description = "Read a file",
		input = { type = "object", properties = { path = { type = "string" } } },
	},
	{ name = "now", description = "The time" },
}

-- A conversation where the model read a file and is told what it holds.
local SAID: { any } = {
	{ role = "user", text = "what's in a.txt?" },
	{
		role = "assistant",
		text = "Let me look.",
		calls = { { id = "c1", name = "read", input = { path = "a.txt" } } },
	},
	{ role = "tool", call = "c1", text = "hello" },
	{ role = "user", text = "and now?" },
}

test("Anthropic gets tool uses, results in the next user message, and turns joined", function(t)
	local body =
		turn.body("anthropic", "m", { system = "be brief", said = SAID, tools = TOOLS }, 100)
	assert(body.system[1].text == "be brief" and body.max_tokens == 100, "system and length")
	assert(body.tools[1].input_schema.properties.path, "the schema")
	assert(body.tools[2].input_schema.type == "object", "an empty one for no input")
	local messages = body.messages
	assert(#messages == 3, tostring(#messages))
	assert(
		messages[2].content[2].type == "tool_use" and messages[2].content[2].id == "c1",
		"the call"
	)
	local results = messages[3].content
	assert(results[1].type == "tool_result" and results[1].tool_use_id == "c1", "its result")
	assert(results[2].type == "text" and results[2].text == "and now?", "joined with what followed")
end)

test(
	"OpenAI gets a system message, tool calls with their arguments as JSON, and tool messages",
	function(t)
		local body =
			turn.body("openai", "m", { system = "be brief", said = SAID, tools = TOOLS }, 100)
		local messages = body.messages
		assert(messages[1].role == "system", "system first")
		local call = messages[3].tool_calls[1]
		assert(call.id == "c1" and call["function"].name == "read", "the call")
		assert(greed.json.decode(call["function"].arguments).path == "a.txt", "arguments as JSON")
		assert(messages[4].role == "tool" and messages[4].tool_call_id == "c1", "the result")
		assert(body.tools[1].type == "function" and body.tools[1]["function"].parameters, "tools")
	end
)

local function events(kind: string, list: { any }): models.Turn
	local reader = turn.reader(kind)
	local text = {}
	for _, event in list do
		local data = if type(event) == "string" then event else greed.json.encode(event)
		local piece = reader.feed({ data = data })
		if piece then
			table.insert(text, piece)
		end
	end
	local result = reader.turn()
	assert(result.text == table.concat(text), "the text as it came")
	return result
end

test("Anthropic's stream gives text and tool calls put together from their pieces", function(t)
	local result = events("anthropic", {
		{ type = "content_block_start", index = 0, content_block = { type = "text" } },
		{
			type = "content_block_delta",
			index = 0,
			delta = { type = "text_delta", text = "Looking" },
		},
		{
			type = "content_block_start",
			index = 1,
			content_block = { type = "tool_use", id = "t1", name = "read" },
		},
		{
			type = "content_block_delta",
			index = 1,
			delta = { type = "input_json_delta", partial_json = '{"pa' },
		},
		{
			type = "content_block_delta",
			index = 1,
			delta = { type = "input_json_delta", partial_json = 'th":"a.txt"}' },
		},
		{ type = "message_delta", delta = { stop_reason = "tool_use" } },
		{ type = "message_stop" },
	})
	assert(result.text == "Looking" and result.stop == "tools", result.stop)
	assert(result.calls[1].id == "t1" and result.calls[1].input.path == "a.txt", "the call")
end)

test("a reader says once a tool call has started, for either kind of stream", function()
	for kind, call in
		{
			anthropic = {
				type = "content_block_start",
				index = 1,
				content_block = { type = "tool_use", id = "t1", name = "read" },
			},
			openai = {
				choices = {
					{
						delta = { tool_calls = { { index = 0, ["function"] = { name = "read" } } } },
					},
				},
			},
		} :: { [string]: any }
	do
		local reader = turn.reader(kind)
		local text = if kind == "anthropic"
			then {
				type = "content_block_delta",
				index = 0,
				delta = { type = "text_delta", text = "Hi" },
			}
			else { choices = { { delta = { content = "Hi" } } } }
		reader.feed({ data = greed.json.encode(text) })
		assert(not reader.calling(), `{kind}: only text so far`)
		reader.feed({ data = greed.json.encode(call) })
		assert(reader.calling(), `{kind}: a call started`)
	end
end)

test("OpenAI's stream gives tool calls from their pieces, and a stop says so", function(t)
	local result = events("openai", {
		{ choices = { { delta = { content = "Sure" } } } },
		{
			choices = {
				{
					delta = {
						tool_calls = {
							{
								index = 0,
								id = "x",
								["function"] = { name = "read", arguments = "" },
							},
						},
					},
				},
			},
		},
		{
			choices = {
				{
					delta = {
						tool_calls = { { index = 0, ["function"] = { arguments = '{"path":' } } },
					},
				},
			},
		},
		{
			choices = {
				{
					delta = {
						tool_calls = { { index = 0, ["function"] = { arguments = '"b"}' } } },
					},
				},
			},
		},
		{ choices = { { delta = {}, finish_reason = "tool_calls" } } },
		"[DONE]",
	})
	assert(result.text == "Sure" and result.stop == "tools", result.stop)
	assert(result.calls[1].name == "read" and result.calls[1].input.path == "b", "the call")
	local done = events(
		"openai",
		{ { choices = { { delta = { content = "hi" }, finish_reason = "stop" } } } }
	)
	assert(done.stop == "done" and #done.calls == 0, done.stop)
end)

test(
	"a call with no arguments has an empty input, and a server that says stop still gets its calls run",
	function(t)
		local result = events("openai", {
			{
				choices = {
					{
						delta = {
							tool_calls = {
								{ index = 0, id = "n", ["function"] = { name = "now" } },
							},
						},
					},
				},
			},
			{ choices = { { delta = {}, finish_reason = "stop" } } },
		})
		assert(result.stop == "tools" and next(result.calls[1].input) == nil, result.stop)
	end
)

test("the tokens the conversation takes come from what the provider reports", function(t)
	local anthropic = events("anthropic", {
		{
			type = "message_start",
			message = { usage = { input_tokens = 10, cache_read_input_tokens = 1000 } },
		},
		{ type = "content_block_delta", index = 0, delta = { type = "text_delta", text = "hi" } },
		{
			type = "message_delta",
			delta = { stop_reason = "end_turn" },
			usage = { output_tokens = 5 },
		},
		{ type = "message_stop" },
	})
	assert(anthropic.tokens == 1015, tostring(anthropic.tokens))
	assert(anthropic.input == 1010 and anthropic.output == 5, "read and written apart")
	assert(anthropic.cached == 1000, "read from the cache")
	local openai = events("openai", {
		{ choices = { { delta = { content = "hi" }, finish_reason = "stop" } } },
		{
			choices = {},
			usage = {
				prompt_tokens = 200,
				completion_tokens = 7,
				prompt_tokens_details = { cached_tokens = 150 },
			},
		},
		"[DONE]",
	})
	assert(openai.tokens == 207, tostring(openai.tokens))
	assert(openai.input == 200 and openai.output == 7, "read and written apart")
	assert(openai.cached == 150, "read from the cache")
	local moonshot = events("openai", {
		{ choices = { { delta = { content = "hi" }, finish_reason = "stop" } } },
		{
			choices = {},
			usage = { prompt_tokens = 200, completion_tokens = 7, cached_tokens = 120 },
		},
		"[DONE]",
	})
	assert(moonshot.cached == 120, "said at the top, as Moonshot does")
	local quiet = events("openai", { { choices = { { delta = { content = "hi" } } } } })
	assert(quiet.tokens == nil, "nothing reported")
end)

test(
	"Anthropic requests mark the tools, the system prompt and the newest message for caching",
	function(t)
		local body =
			turn.body("anthropic", "m", { system = "be brief", said = SAID, tools = TOOLS }, 100)
		local marked = 0
		local function count(block: any)
			if block.cache_control then
				assert(block.cache_control.type == "ephemeral", "the kind Anthropic caches")
				marked += 1
			end
		end
		for _, tool in body.tools do
			count(tool)
		end
		assert(body.tools[#body.tools].cache_control, "the last tool")
		count(body.system[1])
		assert(body.system[1].cache_control, "the system prompt")
		for _, message in body.messages do
			for _, block in message.content do
				count(block)
			end
		end
		local last = body.messages[#body.messages].content
		assert(last[#last].cache_control, "the newest message")
		assert(marked == 3, `three of the four markers allowed: {marked}`)
		local openai =
			turn.body("openai", "m", { system = "be brief", said = SAID, tools = TOOLS }, 100)
		assert(openai.tools[#openai.tools].cache_control == nil, "OpenAI caches by itself")
	end
)

test("images you said go as image blocks to Anthropic and as data URLs to the rest", function(t)
	local dir = t:tempdir()
	local png = "\x89PNG\r\n\x1a\nfake"
	assert(greed.fs.write(`{dir}/a.png`, png))
	local said: { any } = {
		{ role = "user", text = "what's this?", images = { `{dir}/a.png`, `{dir}/gone.png` } },
	}
	local encoded = greed.base64.encode(png)
	local anthropic = turn.body("anthropic", "m", { said = said }, 100)
	local blocks = anthropic.messages[1].content
	assert(blocks[1].type == "image" and blocks[1].source.data == encoded, "the image first")
	assert(blocks[1].source.media_type == "image/png")
	assert(
		blocks[2].type == "text"
			and string.find(blocks[2].text, "gone.png, is no longer kept", 1, true)
	)
	local openai = turn.body("openai", "m", { said = said }, 100)
	local parts = openai.messages[1].content
	assert(parts[1].type == "text" and string.find(parts[1].text, "^what's this%?"))
	assert(
		parts[2].type == "image_url" and parts[2].image_url.url == `data:image/png;base64,{encoded}`
	)
	-- Without images, what you said stays plain text.
	local plain = turn.body("openai", "m", { said = { { role = "user", text = "hi" } } }, 100)
	assert(plain.messages[1].content == "hi")
end)

test("a message after a turn that stopped at tool results follows a word from the model", function()
	local said: { any } = {
		{ role = "user", text = "look" },
		{ role = "assistant", text = "", calls = { { id = "c1", name = "now", input = {} } } },
		{ role = "tool", call = "c1", text = "noon" },
		{ role = "user", text = "go on" },
	}
	local messages = turn.body("openai", "m", { said = said }, 100).messages
	assert(#messages == 5, `{#messages} messages`)
	assert(messages[3].role == "tool" and messages[4].role == "assistant", messages[4].role)
	assert(messages[4].content ~= "", "it says something")
	assert(messages[5].role == "user" and messages[5].content == "go on")
end)

test("a cache key goes with the request as prompt_cache_key, and only when given", function()
	local said: { any } = { { role = "user", text = "hi" } }
	local keyed = turn.body("openai", "m", { said = said, cache_key = "session-1" }, 100)
	assert(keyed.prompt_cache_key == "session-1", tostring(keyed.prompt_cache_key))
	local plain = turn.body("openai", "m", { said = said }, 100)
	assert(plain.prompt_cache_key == nil, "none without one")
end)

test("Mistral is sent a cache key by default, since it only caches with one", function()
	local mistral = models.providers.mistral
	assert(mistral and mistral.cache_key == true, "on for Mistral")
	local openai = models.providers.openai
	assert(openai and not openai.cache_key, "off where it isn't asked for")
end)

-- A conversation where the model thought before it called a tool.
local THOUGHT: { any } = {
	{ role = "user", text = "what's in a.txt?" },
	{
		role = "assistant",
		text = "Let me look.",
		thinking = "They want a.txt.",
		calls = { { id = "c1", name = "read", input = { path = "a.txt" } } },
	},
	{ role = "tool", call = "c1", text = "hello" },
	{ role = "assistant", text = "", thinking = "It says hello." },
	{ role = "user", text = "and now?" },
}

test("with thinking_back, the model's thinking goes back as Mistral's thinking parts", function()
	local messages =
		turn.body("openai", "m", { said = THOUGHT, thinking_back = true }, 100).messages
	local first = messages[2]
	assert(first.role == "assistant" and type(first.content) == "table", "parts")
	local thought = first.content[1]
	assert(thought.type == "thinking" and thought.closed == true, "a closed thinking part")
	assert(#thought.thinking == 1 and thought.thinking[1].type == "text", "its text parts")
	assert(thought.thinking[1].text == "They want a.txt.", thought.thinking[1].text)
	assert(first.content[2].type == "text" and first.content[2].text == "Let me look.", "text")
	assert(first.tool_calls[1].id == "c1", "the calls as usual")
	local second = messages[4]
	assert(#second.content == 1 and second.content[1].type == "thinking", "no empty text part")
	assert(type(messages[1].content) == "string", "your messages stay plain")
end)

test("without thinking_back, assistant messages stay plain strings", function()
	local messages = turn.body("openai", "m", { said = THOUGHT }, 100).messages
	assert(messages[2].content == "Let me look.", tostring(messages[2].content))
	assert(messages[4].content == "", tostring(messages[4].content))
	local mistral = models.providers.mistral
	assert(mistral and mistral.thinking_back == true, "on for Mistral")
	local openai = models.providers.openai
	assert(openai and not openai.thinking_back, "off for others")
end)

test("Mistral's stream: thinking parts left out, the first word kept from its part list", function()
	local result = events("openai", {
		{ choices = { { index = 0, delta = { role = "assistant", content = "" } } } },
		{
			choices = {
				{
					index = 0,
					delta = {
						content = {
							{
								type = "thinking",
								thinking = { { type = "text", text = "The user" } },
							},
						},
					},
				},
			},
		},
		{
			choices = {
				{
					index = 0,
					delta = {
						content = {
							{
								type = "thinking",
								thinking = { { type = "text", text = " says hi." } },
								closed = true,
							},
							{ type = "text", text = "Let" },
						} :: { any },
					},
				},
			},
		},
		{ choices = { { index = 0, delta = { content = " me check" } } } },
		{ choices = { { index = 0, delta = { content = {} }, finish_reason = "stop" } } },
		"[DONE]",
	})
	assert(result.text == "Let me check", result.text)
	assert(result.stop == "done", result.stop)
end)

test("Mistral's tool calls come whole in one chunk, several at once", function()
	local result = events("openai", {
		{ choices = { { index = 0, delta = { role = "assistant", content = "" } } } },
		{
			choices = {
				{
					index = 0,
					delta = {
						content = "",
						tool_calls = {
							{
								id = "D681PevKs",
								type = "function",
								index = 0,
								["function"] = { name = "read", arguments = '{"path": "a.txt"}' },
							},
							{
								id = "Zq3mK9xTb",
								type = "function",
								index = 1,
								["function"] = { name = "now", arguments = "{}" },
							},
						},
					},
					finish_reason = "tool_calls",
				},
			},
		},
		"[DONE]",
	})
	assert(result.stop == "tools" and #result.calls == 2, `{#result.calls} calls`)
	assert(result.calls[1].id == "D681PevKs" and result.calls[1].input.path == "a.txt")
	assert(result.calls[2].id == "Zq3mK9xTb" and result.calls[2].name == "now")
end)

test("whole tool calls without an index, or all at index 0, stay apart", function()
	local function whole(id: string, name: string, index: number?): any
		return { id = id, index = index, ["function"] = { name = name, arguments = "{}" } }
	end
	for _, index in { nil, 0 } :: { number? } do
		local result = events("openai", {
			{
				choices = {
					{
						delta = {
							tool_calls = {
								whole("aaaaaaaaa", "read", index),
								whole("bbbbbbbbb", "now", index),
							},
						},
						finish_reason = "tool_calls",
					},
				},
			},
		})
		assert(#result.calls == 2, `{#result.calls} calls`)
		assert(result.calls[1].name == "read" and result.calls[2].id == "bbbbbbbbb")
	end
end)

test("server-sent events survive any split between reads", function()
	local stream = 'data: {"a":1}\r\n\r\n: ping\r\n\r\ndata: {"b":2}\r\n\r\ndata: [DONE]\r\n\r\n'
	for size = 1, 7 do
		local got: { string } = {}
		local buffered = ""
		for at = 1, #stream, size do
			local found
			found, buffered = sse.parse(buffered .. string.sub(stream, at, at + size - 1))
			for _, event in found do
				table.insert(got, event.data)
			end
		end
		assert(
			table.concat(got, "|") == '{"a":1}|{"b":2}|[DONE]',
			`{size}: {table.concat(got, "|")}`
		)
		assert(buffered == "", buffered)
	end
end)

test("content_text takes a string, or the text parts of a list, leaving thinking out", function()
	assert(turn.content_text("hi") == "hi")
	assert(turn.content_text(nil) == nil)
	local parts: { any } = {
		{ type = "thinking", thinking = { { type = "text", text = "hmm" } }, closed = true },
		{ type = "text", text = "Let" },
	}
	assert(turn.content_text(parts) == "Let", tostring(turn.content_text(parts)))
end)

test("an effort goes to OpenAI-like servers as reasoning_effort, and only when set", function()
	local said: { any } = { { role = "user", text = "hi" } }
	local high = turn.body("openai", "m", { said = said, effort = "high" }, 100)
	assert(high.reasoning_effort == "high", tostring(high.reasoning_effort))
	local plain = turn.body("openai", "m", { said = said }, 100)
	assert(plain.reasoning_effort == nil, "nothing when unset")
end)

test("Anthropic's current models take an effort and summarised thinking", function()
	local said: { any } = { { role = "user", text = "hi" } }
	local high = turn.body("anthropic", "claude-opus-5-5", { said = said, effort = "high" }, 100)
	assert(high.output_config.effort == "high", "the effort")
	assert(high.thinking.type == "adaptive" and high.thinking.display == "summarized", "thinking")
	assert(high.max_tokens == 100 and high.temperature == nil, "the length as asked")
	local none = turn.body("anthropic", "claude-sonnet-5", { said = said, effort = "none" }, 100)
	assert(none.output_config.effort == "low" and none.thinking == nil, "none is the least")
	local plain = turn.body("anthropic", "claude-opus-5-5", { said = said }, 100)
	assert(plain.output_config == nil and plain.thinking == nil, "nothing when unset")
end)

test("older Claude models think within a budget, above which the answer has room", function()
	local said: { any } = { { role = "user", text = "hi" } }
	local model = "claude-haiku-4-5-20251001"
	local low = turn.body("anthropic", model, { said = said, effort = "low" }, 4000)
	local medium = turn.body("anthropic", model, { said = said, effort = "medium" }, 4000)
	local high = turn.body("anthropic", model, { said = said, effort = "high" }, 4000)
	assert(low.thinking.type == "enabled" and low.thinking.budget_tokens == 2048, "low")
	assert(medium.thinking.budget_tokens == 8192 and high.thinking.budget_tokens == 24576)
	assert(high.max_tokens == 4000 + 24576, tostring(high.max_tokens))
	assert(high.output_config == nil, "no effort for them")
	local none = turn.body("anthropic", model, { said = said, effort = "none" }, 4000)
	assert(none.thinking == nil and none.max_tokens == 4000, "none doesn't think")
	-- The plain path's temperature doesn't go with thinking.
	local body: { [string]: any } = { model = model, max_tokens = 100, temperature = 0.2 }
	turn.reasoning("anthropic", model, "low", body)
	assert(body.temperature == nil and body.max_tokens == 2148, "without a temperature")
end)

-- A tool loop where the model thought, signed, before its call.
local SIGNED: { any } = {
	{ role = "user", text = "earlier" },
	{
		role = "assistant",
		text = "Old.",
		signed = { { type = "thinking", thinking = "before", signature = "s0" } },
	},
	{ role = "user", text = "read a.txt" },
	{
		role = "assistant",
		text = "",
		calls = { { id = "c1", name = "read", input = { path = "a.txt" } } },
		signed = {
			{ type = "thinking", thinking = "I'll read it", signature = "s1" },
			{ type = "redacted_thinking", data = "xyz" },
		} :: { any },
	},
	{ role = "tool", call = "c1", text = "hello" },
}

test("older Claude models get their signed thinking back within the tool loop", function()
	local body = turn.body(
		"anthropic",
		"claude-haiku-4-5-20251001",
		{ said = SIGNED, effort = "low", tools = TOOLS },
		4000
	)
	local old = body.messages[2].content
	assert(#old == 1 and old[1].type == "text", "an earlier prompt's thinking isn't sent")
	local now = body.messages[4].content
	assert(now[1].type == "thinking" and now[1].signature == "s1", "thinking first, signed")
	assert(now[2].type == "redacted_thinking" and now[2].data == "xyz", "redacted kept")
	assert(now[3].type == "tool_use", "then the call")
	local current =
		turn.body("anthropic", "claude-opus-5-5", { said = SIGNED, effort = "low" }, 100)
	for _, message in current.messages do
		for _, block in message.content do
			assert(block.type ~= "thinking" and block.type ~= "redacted_thinking", block.type)
		end
	end
	local openai = turn.body("openai", "m", { said = SIGNED, effort = "low" }, 100)
	for _, message in openai.messages do
		assert(message.signed == nil and message.thinking == nil, "never to OpenAI-like servers")
	end
end)

-- Feeds `list` to a reader of `kind`, keeping the thinking it gives as it
-- comes.
local function thought(kind: string, list: { any }): (models.Turn, string)
	local reader = turn.reader(kind)
	local pieces = {}
	for _, event in list do
		local data = if type(event) == "string" then event else greed.json.encode(event)
		local _, _, _, thinking = reader.feed({ data = data })
		if thinking then
			table.insert(pieces, thinking)
		end
	end
	return reader.turn(), table.concat(pieces)
end

test("Mistral's thinking parts are kept as the turn's thinking, as they come", function()
	local result, streamed = thought("openai", {
		{
			choices = {
				{
					delta = {
						content = {
							{
								type = "thinking",
								thinking = { { type = "text", text = "The user" } },
							},
						},
					},
				},
			},
		},
		{
			choices = {
				{
					delta = {
						content = {
							{
								type = "thinking",
								thinking = { { type = "text", text = " says hi." } },
							},
							{ type = "text", text = "Hi" },
						} :: { any },
					},
				},
			},
		},
		{ choices = { { delta = { content = "!" }, finish_reason = "stop" } } },
	})
	assert(result.text == "Hi!", result.text)
	assert(result.thinking == "The user says hi.", tostring(result.thinking))
	assert(streamed == "The user says hi.", streamed)
	assert(result.signed == nil, "nothing signed")
end)

test("reasoning_content from other OpenAI-like servers is thinking too", function()
	local result = thought("openai", {
		{ choices = { { delta = { reasoning_content = "Hmm." } } } },
		{ choices = { { delta = { reasoning = " Yes." } } } },
		{ choices = { { delta = { content = "Yes" }, finish_reason = "stop" } } },
	})
	assert(result.thinking == "Hmm. Yes." and result.text == "Yes", tostring(result.thinking))
	local plain = thought("openai", { { choices = { { delta = { content = "x" } } } } })
	assert(plain.thinking == nil, "none when it didn't think")
end)

test("Anthropic's thinking blocks are kept, signed, and their text as thinking", function()
	local result, streamed = thought("anthropic", {
		{
			type = "content_block_start",
			index = 0,
			content_block = { type = "thinking", thinking = "" },
		},
		{
			type = "content_block_delta",
			index = 0,
			delta = { type = "thinking_delta", thinking = "Let me" },
		},
		{
			type = "content_block_delta",
			index = 0,
			delta = { type = "thinking_delta", thinking = " see." },
		},
		{
			type = "content_block_delta",
			index = 0,
			delta = { type = "signature_delta", signature = "sig" },
		},
		{ type = "content_block_stop", index = 0 },
		{
			type = "content_block_start",
			index = 1,
			content_block = { type = "redacted_thinking", data = "xyz" },
		},
		{ type = "content_block_start", index = 2, content_block = { type = "text", text = "" } },
		{ type = "content_block_delta", index = 2, delta = { type = "text_delta", text = "Done" } },
		{ type = "message_stop" },
	})
	assert(result.text == "Done", result.text)
	assert(
		result.thinking == "Let me see." and streamed == "Let me see.",
		tostring(result.thinking)
	)
	local signed = result.signed or {}
	assert(#signed == 2, `{#signed} blocks`)
	assert(signed[1].type == "thinking" and signed[1].thinking == "Let me see.")
	assert(signed[1].signature == "sig", tostring(signed[1].signature))
	assert(signed[2].type == "redacted_thinking" and signed[2].data == "xyz")
end)

test("equal tables encode the same, whatever order they were built in", function()
	local built: any = { type = "object", required = { "path" } }
	built.properties = { path = { type = "string" }, from_line = { type = "number" } }
	local backwards: any = {}
	backwards.properties = {}
	backwards.properties.from_line = { type = "number" }
	backwards.properties.path = { type = "string" }
	backwards.required = { "path" }
	backwards.type = "object"
	local again = greed.json.decode(greed.json.encode(backwards))
	assert(greed.json.encode(built) == greed.json.encode(backwards), greed.json.encode(backwards))
	assert(greed.json.encode(again) == greed.json.encode(built), "and read back in")
end)

test("compare says what a request changed of the last one in its conversation", function()
	local function body(kind: string, said: { any }, tools: { any }?, effort: string?): any
		return turn.body(
			kind,
			"m",
			{ system = "be brief", said = said, tools = tools or TOOLS, effort = effort },
			100
		)
	end
	local first = { SAID[1] }
	local second = { SAID[1], SAID[2], SAID[3] }
	for _, kind in { "openai", "anthropic" } do
		local said, last = turn.compare(body(kind, first))
		assert(string.find(said, "the first request", 1, true), said)
		local prefix = string.match(said, "prefix (%x+)")
		said = turn.compare(body(kind, second), last)
		assert(string.find(said, "of the last request first", 1, true), `{kind}: {said}`)
		-- Its prefix takes in what the first request sent.
		local whole = string.match(said, "prefix (%x+)")
		assert(whole ~= prefix, "the prefix grew")
		local changed = table.clone(second)
		changed[1] = { role = "user", text = "what's in b.txt?" }
		said = turn.compare(body(kind, changed), last)
		local at = if kind == "openai" then 2 else 1
		assert(string.find(said, `message {at} of the last request's`, 1, true), `{kind}: {said}`)
		local more = table.clone(TOOLS)
		table.insert(more, { name = "write", description = "Write a file" })
		said = turn.compare(body(kind, second, more), last)
		assert(string.find(said, "and tools added after its own", 1, true), `{kind}: {said}`)
		said = turn.compare(body(kind, second, { TOOLS[2], TOOLS[1] }), last)
		assert(string.find(said, "other tools", 1, true), `{kind}: {said}`)
		said = turn.compare(body(kind, second, nil, "high"), last)
		assert(string.find(said, "other settings", 1, true), `{kind}: {said}`)
	end
	local _, last = turn.compare(body("openai", first))
	local other =
		turn.body("openai", "m", { system = "be long", said = second, tools = TOOLS }, 100)
	local said = turn.compare(other, last)
	assert(string.find(said, "another system prompt", 1, true), said)
end)

test("a request's timing says the wait for its first bytes, the whole, and the pace", function()
	assert(
		turn.timing(1000, 4500, 9500, 500) == "first bytes after 3.50s, done in 8.50s, 100 tokens/s",
		turn.timing(1000, 4500, 9500, 500)
	)
	assert(
		turn.timing(1000, nil, 2000, nil) == "nothing back, done in 1.00s",
		turn.timing(1000, nil, 2000, nil)
	)
	assert(
		turn.timing(1000, 1200, 1200, 40) == "first bytes after 0.20s, done in 0.20s",
		"no pace over no time"
	)
end)
