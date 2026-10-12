local test = require("@greed/test")
local greed = require("@greed")
local models = require("@models")
local turn = models.tools

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
