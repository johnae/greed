local test = require("@greed/test")
local greed = require("@greed")

local GOOD = {
	["plugin.toml"] = 'name = "hello"\n',
	["init.luau"] = [[
local greed = require("@greed")
greed.command({ name = "hello", run = function() greed.echo("hello there") end })
return {}
]],
	["test/hello.luau"] = [[
local test = require("@greed/test")
test("says hello", function(t)
	t:run("hello")
	assert(t:messages()[1] == "hello there")
end)
test("fails on purpose", function(t)
	error("nope", 0)
end)
]],
}

-- Checks `dir` from a command, since checking waits, and returns the report.
local function check(t: any, dir: string): greed.PluginCheck
	local report: greed.PluginCheck? = nil
	greed.command({
		name = "test-check",
		run = function()
			report = greed.plugin.check(dir)
		end,
	})
	t:run("test-check")
	assert(report, "the check finished")
	return report
end

test("checking a plugin runs its tests and type checks it", function(t)
	local report = check(t, t:tempdir(GOOD))
	assert(report.types.ok or report.types.skipped, report.types.output)
	assert(report.tests.passed == 1, tostring(report.tests.error))
	local failed = (report.tests.failed :: any)[1]
	-- The line the error came from follows it when the error doesn't say.
	assert(failed.name == "fails on purpose", failed.name)
	assert(
		failed.message == "nope\nat test/test/hello.luau:7: in function <test/test/hello.luau:6>",
		failed.message
	)
end)

test("type errors are reported", function(t)
	local dir = t:tempdir({
		["plugin.toml"] = 'name = "typo"\n',
		["init.luau"] = 'local greed = require("@greed")\ngreed.ech("x")\nreturn {}\n',
	})
	local report = check(t, dir)
	if report.types.skipped then
		return
	end
	assert(report.types.ok == false, "greed.ech isn't in the API")
	assert(string.find(report.types.output or "", "ech", 1, true) ~= nil, report.types.output)
end)

test("plugins load while the editor runs", function(t)
	local dir = t:tempdir(GOOD)
	assert(greed.plugin.load(dir) == "hello")
	assert(table.find(greed.plugin.list(), "hello"))
	assert(greed.plugin.dirs().hello == dir)
	t:run("hello")
	assert(t:messages()[1] == "hello there")
end)
