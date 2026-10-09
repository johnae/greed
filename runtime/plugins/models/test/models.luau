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

test("asking without a key names the variable that sets it", function(t)
	models.providers.keyless =
		{ kind = "anthropic", url = "https://api.anthropic.com", secret = "greed-test-nokey" }
	models.roles.keyless = { provider = "keyless", model = "m" }
	local why: string? = nil
	greed.spawn(function()
		local _, err = models.ask("keyless", { messages = { { role = "user", content = "hi" } } })
		why = err
	end)
	t:wait_for(function()
		return why ~= nil
	end)
	assert(
		string.find(
			why or "",
			"no API key for keyless: set GREED_SECRET_GREED_TEST_NOKEY, or add one in :models",
			1,
			true
		),
		why
	)
	models.roles.keyless = nil
	models.providers.keyless = nil
end)

-- A provider whose key no test machine has, and a role it plays.
local function keyless(role: string)
	models.providers.keyless =
		{ kind = "anthropic", url = "https://api.anthropic.com", secret = "greed-test-nokey" }
	models.roles[role] = { provider = "keyless", model = "m" }
end

test("a role that falls back to another uses its model, and :models says so", function(t)
	models.fallback("poetry", "fast", "writing poems")
	assert(models.playing("poetry") == "fast", models.playing("poetry"))
	t:buffer("|x")
	t:run("models")
	local text = greed.view():buffer():text()
	assert(
		string.find(
			text,
			"poetry: for writing poems; none set, so it uses fast: claude-haiku",
			1,
			true
		),
		text
	)
	models.roles.poetry = { provider = "ollama", model = "m" }
	assert(models.playing("poetry") == "poetry", "once set, it plays itself")
	models.roles.poetry = nil
	models.fallbacks.poetry = nil
	t:keys("q")
end)

test("Greed's own agent falls back to reasoning, as :models shows", function(t)
	t:buffer("|x")
	t:run("models")
	local text = greed.view():buffer():text()
	assert(
		string.find(text, "agent: for Greed's own agent; none set, so it uses reasoning", 1, true),
		text
	)
	t:keys("q")
end)

test("check says what's missing before anything is asked", function()
	keyless("poetry")
	local why = models.check("poetry")
	assert(why and string.find(why, "no API key for keyless", 1, true), tostring(why))
	assert(string.find(models.check("nobody") or "", "models.roles.nobody", 1, true) ~= nil)
	assert(models.check("local") == nil, "Ollama needs no key")
	models.roles.poetry = nil
	models.providers.keyless = nil
end)

test("a role chosen in :models is kept for next time, and your config's are marked", function(t)
	assert(models.is_own("fast"), "built in")
	assert(models.choose("fast", "openai", "gpt-test") == nil)
	local fast = models.roles.fast :: models.Role
	assert(fast.model == "gpt-test" and models.is_own("fast"))
	local kept = greed.json.decode(greed.fs.read(`{greed.fs.dirs().data}/models.json`) :: string)
	assert(kept.roles.fast.provider == "openai" and kept.roles.fast.model == "gpt-test")
	models.roles.fast = { provider = "ollama", model = "mine" }
	assert(not models.is_own("fast"), "set by config")
	t:buffer("|x")
	t:run("models")
	local text = greed.view():buffer():text()
	assert(string.find(text, "fast: mine at ollama", 1, true), text)
	assert(string.find(text, "(set in your config)", 1, true), text)
	t:keys("q")
end)

test("on the :models page, k sets the key of the role's provider", function(t)
	keyless("poetry")
	t:buffer("|x")
	t:run("models")
	local page = greed.view():buffer()
	local line = 0
	for n = 0, page:line_count() - 1 do
		if string.find(page:line_text(n), "^poetry:") then
			line = n
		end
	end
	assert(
		string.find(page:line_text(line), "no API key: k adds one", 1, true),
		page:line_text(line)
	)
	greed.view():set_cursor(page:line_start(line))
	t:keys("k")
	t:keys("s e c r e t enter")
	t:wait(100)
	local messages = t:messages()
	assert(
		string.find(messages[#messages], "kept the keyless key in", 1, true),
		messages[#messages]
	)
	assert(string.find(page:line_text(line), "key found", 1, true), page:line_text(line))
	t:keys("q")
	models.roles.poetry = nil
	models.providers.keyless = nil
end)

test("using a provider sets the fast and reasoning roles to its models", function()
	assert(models.use_provider("openai") == nil)
	local fast = models.roles.fast :: models.Role
	local reasoning = models.roles.reasoning :: models.Role
	assert(fast.provider == "openai" and fast.model == "gpt-5-mini")
	assert(reasoning.model == "gpt-5")
	assert(models.use_provider("nowhere") ~= nil, "no preset")
end)

test("an Ollama that isn't running says how to start it", function(t)
	models.providers.ollama = { kind = "openai", url = "http://127.0.0.1:9/v1" }
	local found, why = models.ollama_models()
	assert(found == nil and string.find(why or "", "ollama serve", 1, true), tostring(why))
	local said: string? = nil
	greed.spawn(function()
		local _, err = models.ask("local", { messages = { { role = "user", content = "hi" } } })
		said = err
	end)
	t:wait_for(function()
		return said ~= nil
	end)
	assert(string.find(said or "", "`ollama serve` starts it", 1, true), tostring(said))
end)

test("how long an answer may be: the role's, its provider's, or sized from the window", function()
	models.roles.poetry = { provider = "berget", model = "moonshotai/Kimi-K3" }
	assert(models.output("poetry") == 32000, tostring(models.output("poetry")))
	models.roles.poetry = { provider = "ollama", model = "some-model" }
	-- An unknown model is assumed small, so its answers leave room for the rest.
	assert(models.output("poetry") == models.WINDOW // 4, tostring(models.output("poetry")))
	models.providers.small = { kind = "openai", url = "http://localhost:1", output = 2000 }
	models.roles.poetry = { provider = "small", model = "gpt-5" }
	assert(models.output("poetry") == 2000, "the provider says")
	models.roles.poetry = { provider = "small", model = "gpt-5", output = 1000 }
	assert(models.output("poetry") == 1000, "the role says first")
	models.roles.poetry = nil
	models.providers.small = nil
end)

test("how the agent edits is the role's, the provider's, or replace", function()
	models.roles.poetry = { provider = "ollama", model = "some-model" }
	assert(models.edits("poetry") == "replace", models.edits("poetry"))
	models.providers.small = { kind = "openai", url = "http://localhost:1", edits = "hashline" }
	models.roles.poetry = { provider = "small", model = "m" }
	assert(models.edits("poetry") == "hashline", "the provider says")
	models.roles.poetry = { provider = "small", model = "m", edits = "replace" }
	assert(models.edits("poetry") == "replace", "the role says first")
	models.roles.poetry = { provider = "small", model = "m", edits = "nonsense" }
	assert(models.edits("poetry") == "hashline", "a way it doesn't know is passed over")
	models.roles.poetry = nil
	models.providers.small = nil
end)

test("edits are counted by model and how they were made, and :usage says how they went", function()
	models.count_edit("anthropic", "claude-sonnet-5", "replace", true)
	models.count_edit("anthropic", "claude-sonnet-5", "replace", false)
	models.count_edit("anthropic", "claude-sonnet-5", "hashline", true)
	local today = models.usage(os.date("%Y-%m-%d"))
	local used = today[`{os.date("%H")} anthropic/claude-sonnet-5`]
	assert(used and used.edits, "kept")
	local edits: any = used.edits
	assert(
		edits.replace.ok == 1 and edits.replace.failed == 1 and edits.hashline.ok == 1,
		"by format"
	)
	local report = table.concat(models.usage_report(), "\n")
	assert(string.find(report, "edits: hashline 1 of 1, replace 1 of 2", 1, true), report)
end)

test("tokens used are counted a day at a time, and :usage says how many", function(t)
	models.count("berget", "moonshotai/Kimi-K3", 1000, 50)
	models.count("berget", "moonshotai/Kimi-K3", 3000, 20, 2500)
	models.count("anthropic", "claude-haiku-4-5-20251001", 200, 10)
	local today = models.usage(os.date("%Y-%m-%d"))
	local key = `{os.date("%H")} berget/moonshotai/Kimi-K3`
	local kimi = today[key]
	assert(
		kimi
			and kimi.requests == 2
			and kimi.input == 4000
			and kimi.output == 70
			and kimi.cached == 2500,
		key
	)
	local report = table.concat(models.usage_report(), "\n")
	assert(
		string.find(
			report,
			"berget/moonshotai/Kimi-K3: 2 requests, 4000 in (2500 cached), 70 out",
			1,
			true
		),
		report
	)
	assert(string.find(report, "3 requests, 4200 in (2500 cached), 80 out", 1, true), report)
	assert(
		string.find(report, "claude-haiku-4-5-20251001: 1 requests, 200 in, 10 out", 1, true),
		report
	)
	t:buffer("|")
	t:run("usage")
	assert(string.find(greed.view():buffer():text(), "Today", 1, true), "shown in a float")
end)

test("which models see images is known by name, and a role can say otherwise", function()
	local function sees(model: string, images: boolean?): boolean
		models.roles.eyes = { provider = "berget", model = model, images = images }
		local seen = models.sees_images("eyes")
		models.roles.eyes = nil
		return seen
	end
	assert(sees("moonshotai/Kimi-K3") and sees("moonshotai/Kimi-K2.5"), "Kimi from K2.5 on")
	assert(not sees("moonshotai/Kimi-K2-Instruct"), "K2 itself doesn't")
	assert(sees("claude-sonnet-5") and sees("Qwen/Qwen2.5-VL-72B-Instruct") and sees("gpt-4o"))
	assert(not sees("meta-llama/Llama-3.3-70B-Instruct") and not sees("openai/gpt-oss-120b"))
	assert(sees("some-model", true) and not sees("claude-x", false), "the role says")
	assert(not models.sees_images("nobody-plays-this"))
end)
