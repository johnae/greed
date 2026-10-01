local test = require("@kern/test")
local kern = require("@kern")

local GOOD = {
	["plugin.toml"] = 'name = "hello"\n',
	["init.luau"] = [[
local kern = require("@kern")
kern.command({ name = "hello", run = function() kern.echo("hello there") end })
return {}
]],
	["test/hello.luau"] = [[
local test = require("@kern/test")
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
local function check(t: any, dir: string): kern.PluginCheck
	local report: kern.PluginCheck? = nil
	kern.command({
		name = "test-check",
		run = function()
			report = kern.plugin.check(dir)
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
	assert(failed.name == "fails on purpose" and failed.message == "nope", failed.message)
end)

test("type errors are reported", function(t)
	local dir = t:tempdir({
		["plugin.toml"] = 'name = "typo"\n',
		["init.luau"] = 'local kern = require("@kern")\nkern.ech("x")\nreturn {}\n',
	})
	local report = check(t, dir)
	if report.types.skipped then
		return
	end
	assert(report.types.ok == false, "kern.ech isn't in the API")
	assert(string.find(report.types.output or "", "ech", 1, true) ~= nil, report.types.output)
end)

test("plugins load while the editor runs", function(t)
	local dir = t:tempdir(GOOD)
	assert(kern.plugin.load(dir) == "hello")
	assert(table.find(kern.plugin.list(), "hello"))
	assert(kern.plugin.dirs().hello == dir)
	t:run("hello")
	assert(t:messages()[1] == "hello there")
end)
