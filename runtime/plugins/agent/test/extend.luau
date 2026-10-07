local test = require("@greed/test")
local greed = require("@greed")
local agent = require("@agent")

local PLUGIN = {
	["init.luau"] = [[
local greed = require("@greed")
greed.command({ name = "shout", doc = "Upper-case the buffer", run = function(ctx)
	ctx.buffer:edit(function(e) e:replace(0, ctx.buffer:len(), string.upper(ctx.buffer:text())) end)
end })
return {}
]],
	["test/shout.luau"] = [[
local test = require("@greed/test")
test("shouts", function(t)
	t:buffer("|hi")
	t:run("shout")
	assert(t:marked() == "HI|", t:marked())
end)
]],
}

-- Points staging and installing at `t`'s temporary folder.
local function sandbox(t: any): string
	local dir = t:tempdir()
	agent.dirs.staging = dir .. "/staging"
	agent.dirs.plugins = dir .. "/plugins"
	agent.dirs.fallback = dir .. "/data/plugins"
	return dir
end

-- Runs `f` as a command, since trying and installing wait, and returns
-- what it returned once it has.
local function in_command(t: any, f: () -> string): () -> string?
	local result: string? = nil
	greed.command({
		name = "test-extend",
		run = function()
			result = f()
		end,
	})
	t:run("test-extend")
	return function()
		return result
	end
end

test("a tried plugin is checked and the agent hears what failed", function(t)
	sandbox(t)
	local report = in_command(t, function()
		return (agent.try("shout", PLUGIN))
	end)()
	assert(report and string.find(report, "tests: 1 passed, 0 failed", 1, true), report)
	local broken = in_command(t, function()
		return (agent.try("shout", { ["init.luau"] = 'require("@greed").nope()\nreturn {}\n' }))
	end)()
	assert(
		broken
			and (
				string.find(broken, "types: errors", 1, true)
				or string.find(broken, "not checked", 1, true)
			),
		broken
	)
end)

test("installing waits for the user, then loads the plugin", function(t)
	local dir = sandbox(t)
	in_command(t, function()
		return (agent.try("shout", PLUGIN))
	end)
	local answer = in_command(t, function()
		return agent.install("shout")
	end)
	assert(answer() == nil, "waiting for the user")
	assert(greed.view():buffer():kind() == "plugin-review", "the review has focus")
	assert(string.find(greed.view():buffer():text(), "shout", 1, true) ~= nil)
	t:keys("a")
	assert(
		answer()
			== `the user installed shout in {dir}/plugins/shout; it's loaded and its commands are ready`,
		answer()
	)
	assert(greed.fs.read(dir .. "/plugins/shout/init.luau") == PLUGIN["init.luau"])
	t:buffer("|hey")
	t:run("shout")
	t:expect("HEY|")
end)

test("a rejected plugin isn't installed", function(t)
	local dir = sandbox(t)
	in_command(t, function()
		return (agent.try("shout", PLUGIN))
	end)
	local answer = in_command(t, function()
		return agent.install("shout")
	end)
	t:keys("r")
	assert(answer() == "the user rejected shout", answer())
	assert(greed.fs.stat(dir .. "/plugins/shout") == nil)
end)

test("closing the review some other way rejects the plugin", function(t)
	local dir = sandbox(t)
	in_command(t, function()
		return (agent.try("shout", PLUGIN))
	end)
	local answer = in_command(t, function()
		return agent.install("shout")
	end)
	greed.view():close()
	assert(answer() == "the user rejected shout", answer())
	assert(greed.fs.stat(dir .. "/plugins/shout") == nil)
	local again = in_command(t, function()
		return agent.install("shout")
	end)
	assert(again() == nil, "a new review can start")
	t:keys("r")
end)

test("bad names and paths are refused", function(t)
	sandbox(t)
	local ok, err = pcall(function()
		agent.try("Bad Name", PLUGIN)
	end)
	assert(not ok and string.find(tostring(err), "lowercase", 1, true), tostring(err))
	ok, err = pcall(function()
		agent.try("fine", { ["../escape.luau"] = "" })
	end)
	assert(not ok and string.find(tostring(err), "inside", 1, true), tostring(err))
end)

test("when the config can't be written, a plugin is installed in the data folder", function(t)
	local dir = sandbox(t)
	-- A file where the plugins folder would go, as good as a read-only config.
	greed.fs.write(dir .. "/blocked", "")
	agent.dirs.plugins = dir .. "/blocked/plugins"
	in_command(t, function()
		return (agent.try("shout", PLUGIN))
	end)
	local answer = in_command(t, function()
		return agent.install("shout")
	end)
	t:keys("a")
	assert(string.find(answer() or "", dir .. "/data/plugins/shout", 1, true), answer())
	assert(greed.fs.read(dir .. "/data/plugins/shout/init.luau") == PLUGIN["init.luau"])
end)

test("tests failing only for want of approval don't keep a plugin from install", function()
	local function report(failed: { any }): any
		return {
			types = { ok = true, output = "" },
			tests = { passed = 1, failed = failed },
			warnings = {},
		}
	end
	local waiting = {
		file = "a.luau",
		name = "runs gh",
		message = 'needs approval: it would run programs, and you haven\'t approved "proc" for gh',
	}
	local said, may = agent.describe_check(report({ waiting }))
	assert(may, said)
	assert(string.find(said, "plugin_install may go ahead", 1, true), said)
	local broken = { file = "a.luau", name = "adds", message = "expected 2, got 3" }
	local _, may_not = agent.describe_check(report({ waiting, broken }))
	assert(not may_not, "a real failure still stops it")
	local typed: any = report({})
	typed.types = { ok = false, output = "./plugin/init.luau(1,1): TypeError" }
	local _, typed_may = agent.describe_check(typed)
	assert(not typed_may, "so do type errors")
end)
