local test = require("@greed/test")
local greed = require("@greed")
local models = require("@models")
local sse = require("../sse")

test("events come whole, however the stream cuts them", function()
	local events, rest = sse.parse("event: a\ndata: one\n\ndata: tw")
	assert(#events == 1 and events[1].event == "a" and events[1].data == "one")
	assert(rest == "data: tw", rest)
	local more, left = sse.parse(rest .. "o\r\n\r\n")
	assert(#more == 1 and more[1].event == nil and more[1].data == "two")
	assert(left == "")
end)

test("roles name a provider and model, and a missing one says how to set it", function()
	local role, provider = models.resolve("fast")
	assert(role and provider and provider.kind == "anthropic", "fast is a Claude model")
	local _, _, missing = models.resolve("poetry")
	assert(missing and string.find(missing, "models.roles.poetry", 1, true), missing)
	models.roles.poetry = { provider = "nowhere", model = "x" }
	local _, _, unknown = models.resolve("poetry")
	assert(unknown and string.find(unknown, "isn't set up", 1, true), unknown)
	models.roles.poetry = nil
end)

test(":models lists each role and whether its key is found", function(t)
	t:buffer("|x")
	t:run("models")
	t:wait(50)
	local text = greed.view():buffer():text()
	assert(string.find(text, "fast: claude-haiku", 1, true), text)
	assert(
		string.find(text, "local: llama3.2 at ollama", 1, true)
			and string.find(text, "no key needed", 1, true),
		text
	)
	t:keys("q")
end)
