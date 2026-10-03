local test = require("@greed/test")
local greed = require("@greed")

-- A plugin called `name` that declares `capabilities` and has a command
-- `<name>-go` running `body`, which leaves what happened in `_G.result`.
local function plugin(t: test.TestContext, name: string, capabilities: string, body: string): string
	return t:tempdir({
		["plugin.toml"] = `name = "{name}"\ncapabilities = [{capabilities}]\n`,
		["init.luau"] = `local greed = require("@greed")\n`
			.. `greed.command(\{ name = "{name}-go", run = function(ctx)\n`
			.. `  local ok, err = pcall(function() {body} end)\n`
			.. `  greed.echo(if ok then "ok" else tostring(err))\n`
			.. `end \})\n`,
	})
end

local function last(t: test.TestContext): string
	local messages = t:messages()
	return messages[#messages]
end

test("a plugin can't run programs or read files it didn't declare", function(t)
	t:buffer("|x")
	greed.plugin.load(plugin(t, "plain", "", 'greed.process.run({ "true" })'))
	t:run("plain-go")
	assert(
		string.find(
			last(t),
			'plain can\'t run programs, which can do anything you can: add "proc" to capabilities in its plugin.toml',
			1,
			true
		),
		last(t)
	)
	greed.plugin.load(plugin(t, "reader", "", 'greed.fs.read("/etc/hostname")'))
	t:run("reader-go")
	assert(string.find(last(t), 'add "fs.read"', 1, true), last(t))
end)

test("declaring a capability opens what it covers", function(t)
	t:buffer("|x")
	greed.plugin.load(plugin(t, "runner", '"proc"', 'assert(greed.process.run({ "true" }))'))
	t:run("runner-go")
	t:wait(100)
	assert(last(t) == "ok", last(t))
end)

test("saving a buffer to another path needs fs.write, its own file doesn't", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a\n" })
	greed.open(dir .. "/a.txt")
	greed.plugin.load(plugin(t, "saver", "", `ctx.buffer:save()\nctx.buffer:save("{dir}/b.txt")`))
	t:run("saver-go")
	assert(string.find(last(t), 'add "fs.write"', 1, true), last(t))
	assert(greed.fs.read(dir .. "/b.txt") == nil, "nothing was written")
end)

test("an unknown capability stops the plugin loading", function(t)
	local ok, err = pcall(greed.plugin.load, plugin(t, "odd", '"teleport"', ""), nil)
	assert(
		not ok and string.find(tostring(err), 'no capability "teleport"', 1, true),
		tostring(err)
	)
end)
