local test = require("@kern/test")
local kern = require("@kern")
local models = require("@models")
local sse = require("../sse")

test("events come whole, however the stream cuts them", function()
	local events, rest = sse.parse("event: a\ndata: one\n\ndata: tw")
	assert(#events == 1 and events[1].event == "a" and events[1].data == "one")
	assert(rest == "data: tw", rest)
	events, rest = sse.parse(rest .. "o\r\n\r\n")
	assert(#events == 1 and events[1].event == nil and events[1].data == "two")
	assert(rest == "")
end)

test("roles name a provider and model, and a missing one says how to set it", function()
	local role, provider = models.resolve("fast")
	assert(role and provider and provider.kind == "anthropic", "fast is a Claude model")
	local _, _, why = models.resolve("poetry")
	assert(why and string.find(why, "models.roles.poetry", 1, true), why)
	models.roles.poetry = { provider = "nowhere", model = "x" }
	_, _, why = models.resolve("poetry")
	assert(why and string.find(why, "isn't set up", 1, true), why)
	models.roles.poetry = nil
end)

test(":models lists each role and whether its key is found", function(t)
	t:buffer("|x")
	t:run("models")
	t:wait(50)
	local text = kern.view():buffer():text()
	assert(string.find(text, "fast: claude-haiku", 1, true), text)
	assert(
		string.find(text, "local: llama3.2 at ollama", 1, true)
			and string.find(text, "no key needed", 1, true),
		text
	)
	t:keys("q")
end)
