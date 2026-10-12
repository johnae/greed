local test = require("@greed/test")
local greed = require("@greed")
local shell = require("@shell")

type Shell = typeof(shell.open())

-- A plugin listening to the shell in every way it can, each listener
-- failing.
local BROKEN = [[
local shell = require("@shell")
local function boom()
	error("boom", 0)
end
shell.log.on_update(boom)
shell.log.on_status(boom)
shell.log.on_placed(boom)
shell.runners.on_finish(boom)
]]

-- Runs `line` in `sh`, and how it ended once it did.
local function status(t: test.TestContext, sh: Shell, line: string): string
	local block = assert(shell.run(sh, line))
	t:wait_for(function()
		return block.status ~= "running"
	end)
	return block.status
end

test("listeners that fail don't keep a block running, and go with their plugin", function(t)
	greed.option.set("shell-fallback", "sh")
	t:run("shell")
	local sh = assert(shell.of(greed.view():buffer()))
	sh.cwd = t:tempdir({})
	greed.plugin.load(t:tempdir({ ["init.luau"] = BROKEN }), "test/broken")
	t:messages()

	local ended = status(t, sh, "echo hi")
	assert(ended == "done", ended)
	assert(table.find(t:messages(), "boom"), "a failing listener says so")

	greed.plugin.unload("test/broken")
	ended = status(t, sh, "echo again")
	assert(ended == "done", ended)
	assert(table.find(t:messages(), "boom") == nil, "gone with its plugin")
end)
