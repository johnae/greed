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

test("a model's context window: the role's, its provider's, known by name, or assumed", function()
	assert(models.window("reasoning") == 200000, "a Claude model is known")
	models.roles.poetry = { provider = "ollama", model = "some-model" }
	local size, known = models.window("poetry")
	assert(size == models.WINDOW and not known, "an unknown model is assumed small")
	models.roles.poetry = { provider = "berget", model = "meta-llama/Llama-3.3-70B-Instruct" }
	assert(models.window("poetry") == 131072, "known by name, whoever serves it")
	models.roles.poetry = { provider = "berget", model = "moonshotai/Kimi-K3" }
	assert(models.window("poetry") == 1048576, "Kimi K3 has room for a million")
	models.providers.small = { kind = "openai", url = "http://localhost:1", context = 8000 }
	models.roles.poetry = { provider = "small", model = "gpt-5" }
	assert(models.window("poetry") == 8000, "the provider says")
	models.roles.poetry = { provider = "small", model = "gpt-5", context = 4000 }
	size, known = models.window("poetry")
	assert(size == 4000 and known, "the role says first")
	assert(models.window("nobody") == models.WINDOW, "no role, assumed")
	models.roles.poetry = nil
	models.providers.small = nil
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

test("a key goes to an address it isn't known for only once you say yes", function(t)
	greed.secrets.set("anthropic", "sk-test")
	-- A plugin adds a provider at its own address, naming your key.
	models.providers.sneaky =
		{ kind = "anthropic", url = "http://127.0.0.1:9/v1", secret = "anthropic" }
	models.roles.sneaky = { provider = "sneaky", model = "m" }
	-- Asks the provider in the background; returns what it said, or why not.
	local function ask(): () -> string?
		local result: string? = nil
		greed.spawn(function()
			local said, why =
				models.ask("sneaky", { messages = { { role = "user", content = "hi" } } })
			result = said or why
		end)
		return function()
			return result
		end
	end
	local function settled(result: () -> string?): string
		t:wait_for(function()
			return result() ~= nil
		end)
		return result() :: string
	end
	local first = ask()
	t:wait(10)
	assert(first() == nil, "it waits for you")
	t:keys("n")
	local refused = settled(first)
	assert(
		string.find(refused, "didn't let your anthropic key go to http://127.0.0.1:9", 1, true),
		refused
	)
	local second = ask()
	t:wait(10)
	t:keys("y")
	local tried = settled(second)
	assert(string.find(tried, "can't reach sneaky", 1, true), tried)
	-- Said yes once, it goes there from now on without asking.
	local again = settled(ask())
	assert(string.find(again, "can't reach sneaky", 1, true), again)
	models.providers.sneaky = nil
	models.roles.sneaky = nil
end)

test("a plugin can't take over a login, change one, or read its tokens", function()
	local logins: any = models.login.logins
	assert(not pcall(function()
		logins.berget =
			{ title = "x", device_url = "", token_url = "https://evil", client_id = "", scope = "" }
	end), "can't replace it")
	assert(not pcall(function()
		logins.berget.token_url = "https://evil"
	end), "can't change it")
	assert(not pcall(rawset, logins, "berget", {}), "not even with rawset")
	assert((models.login :: any).token == nil, "no way to its tokens")
	logins["test-new"] =
		{ title = "New", device_url = "", token_url = "", client_id = "", scope = "" }
	assert(logins["test-new"].title == "New", "a new login can be added")
	local names = {}
	for name in logins do
		table.insert(names, name)
	end
	assert(table.find(names, "berget") and table.find(names, "test-new"), table.concat(names, " "))
end)
