local test = require("@greed/test")
local greed = require("@greed")

local function said(t: test.TestContext, text: string): boolean
	return string.find(table.concat(t:messages(), "\n"), text, 1, true) ~= nil
end

-- A plugin declaring nothing whose command `feed-go` feeds `keys`.
local function feeder(t: test.TestContext, keys: string)
	greed.plugin.load(t:tempdir({
		["plugin.toml"] = 'name = "feeder"\n',
		["init.luau"] = `local greed = require("@greed")\n`
			.. `greed.command(\{ name = "feed-go", run = function()\n`
			.. `  local ok, err = pcall(greed.keys.feed, "{keys}")\n`
			.. `  if not ok then greed.echo(tostring(err)) end\n`
			.. `end \})\n`,
	}))
end

test("keys a plugin feeds to the command line run within what it may", function(t)
	t:buffer("|x")
	greed.plugin.load(t:tempdir({
		["plugin.toml"] = 'name = "runner"\ncapabilities = ["proc"]\n',
		["init.luau"] = [[
local greed = require("@greed")
greed.command({ name = "run-true", run = function()
	local ok, err = pcall(greed.process.run, { "true" })
	greed.echo(if ok then "ran" else tostring(err))
end })
]],
	}))
	feeder(t, ": r u n - t r u e enter")
	t:run("feed-go")
	t:wait(100)
	assert(said(t, 'feeder started it, and doesn\'t have "proc"'), table.concat(t:messages(), "\n"))
	-- Typed by you, the same keys run.
	t:keys(": r u n - t r u e enter")
	t:wait(100)
	assert(said(t, "ran"), "it ran")
end)

test("Luau a plugin feeds to the command line needs eval", function(t)
	t:buffer("|x")
	feeder(t, ": l u a space 4 0 + 2 enter")
	t:run("feed-go")
	local messages = table.concat(t:messages(), "\n")
	assert(string.find(messages, 'feeder started it, and doesn\'t have "eval"', 1, true), messages)
	assert(not string.find(messages, "42", 1, true), messages)
	t:keys("esc : l u a space 4 0 + 2 enter")
	assert(said(t, "42"), "typed by you, it runs")
end)
