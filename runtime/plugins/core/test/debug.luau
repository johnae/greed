local test = require("@greed/test")
local greed = require("@greed")

-- Debug topics are the editor's, shared with the tests running beside
-- these (this file too, in another run), so each test switches only a
-- plugin of a name of its own and looks for its own lines.

local SOURCE = [[
local greed = require("@greed")
greed.command({ name = "NAME-say", run = function(ctx)
	greed.debug.log(table.unpack(ctx.args))
end })
]]

-- Loads a plugin with a name no other test has, whose command `NAME-say`
-- keeps its arguments as a debug line. Returns the name.
local function chatty(t: test.TestContext): string
	-- Named after a folder of the test's own, which no other test has.
	local own = string.match(t:tempdir({}), "([^/]+)$") or ""
	local name = "chatty" .. string.lower((string.gsub(own, "[^%w]", "")))
	greed.plugin.load(t:tempdir({
		["plugin.toml"] = `name = "{name}"\n`,
		["init.luau"] = (string.gsub(SOURCE, "NAME", name)),
	}))
	return name
end

local function texts(
	opts: { after: number?, limit: number?, topic: string?, plugin: string? }
): string
	local out = {}
	for _, line in greed.debug.lines(opts) do
		table.insert(out, line.text)
	end
	return table.concat(out, "\n")
end

test(":debug turns topics on and off and says which are on", function(t)
	local name = chatty(t)
	t:run("debug", { `plugin:{name}` })
	assert(greed.debug.on(`plugin:{name}`), "on")
	local said = greed.messages()
	assert(string.find(said[#said] or "", name, 1, true), said[#said])
	t:run("debug", { `-plugin:{name}` })
	assert(not greed.debug.on(`plugin:{name}`), "off again")
	local ok, err = pcall(function()
		t:run("debug", { "keyz" })
	end)
	assert(not ok and string.find(tostring(err), "keys, runs", 1, true), tostring(err))
end)

test("a plugin's lines are kept only while its topic is on, with its name", function(t)
	local name = chatty(t)
	t:run(`{name}-say`, { "unheard" })
	assert(texts({ plugin = name }) == "", "off: nothing")
	greed.debug.set(`plugin:{name}`, true)
	t:run(`{name}-say`, { "says", "42" })
	greed.debug.set(`plugin:{name}`, false)
	local lines = greed.debug.lines({ plugin = name })
	assert(#lines == 1 and lines[1].text == "says 42", texts({ plugin = name }))
	assert(lines[1].topic == "plugins", lines[1].topic)
end)

test("with keys on, each key says what it ran", function(t)
	t:buffer("|one\ntwo")
	-- Left on: another run of this test may be pressing its key now.
	greed.debug.set("keys", true)
	t:keys("j")
	assert(string.find(texts({ topic = "keys" }), "j runs ", 1, true), texts({ topic = "keys" }))
end)

test(":debug-log shows the lines and follows new ones", function(t)
	local name = chatty(t)
	greed.debug.set(`plugin:{name}`, true)
	t:run(`{name}-say`, { "before", "the", "log" })
	t:run("debug-log")
	local buffer = greed.view():buffer()
	assert(string.find(buffer:text(), "before the log", 1, true), buffer:text())
	t:run(`{name}-say`, { "after", "it", "opened" })
	t:wait(600)
	greed.debug.set(`plugin:{name}`, false)
	assert(string.find(buffer:text(), "after it opened", 1, true), buffer:text())
end)
