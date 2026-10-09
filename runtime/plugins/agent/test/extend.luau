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

test("a try keeps the files left out from the last one, and drops those given empty", function(t)
	local dir = sandbox(t)
	in_command(t, function()
		return (agent.try("shout", PLUGIN))
	end)
	local report = in_command(t, function()
		return (
			agent.try("shout", {
				["test/shout.luau"] = 'local test = require("@greed/test")\ntest("fails", function() error("no", 0) end)\n',
			})
		)
	end)()
	-- init.luau came along, so its command still checks; the new test ran.
	assert(report and string.find(report, "0 passed, 1 failed", 1, true), report)
	assert(string.find(report, "files: init.luau, plugin.toml, test/shout.luau", 1, true), report)
	local dropped = in_command(t, function()
		return (agent.try("shout", { ["test/shout.luau"] = "" }))
	end)()
	assert(dropped and string.find(dropped, "files: init.luau, plugin.toml\n", 1, true), dropped)
	local without = 0
	local tries: { greed.DirEntry } = greed.fs.list(dir .. "/staging") or {}
	for _, try in tries do
		if greed.fs.stat(`{dir}/staging/{try.name}/test/shout.luau`) == nil then
			without += 1
		end
	end
	assert(without == 1, "the last try has no test file")
end)

test("an installed plugin edited after its try is what the next try starts from", function(t)
	local dir = sandbox(t)
	in_command(t, function()
		return (agent.try("shout", PLUGIN))
	end)
	local answer = in_command(t, function()
		return agent.install("shout")
	end)
	t:keys("a")
	assert(answer() and string.find(answer() :: string, "installed", 1, true), answer())
	-- Edited in place, as an agent's edit_file would.
	local edited = PLUGIN["init.luau"] .. "-- edited in place\n"
	greed.fs.write(dir .. "/plugins/shout/init.luau", edited)
	local refused = in_command(t, function()
		local ok, err = pcall(agent.install, "shout")
		return if ok then "installed" else tostring(err)
	end)()
	assert(refused and string.find(refused, "changed after your last plugin_try", 1, true), refused)
	in_command(t, function()
		return (
			agent.try(
				"shout",
				{ ["test/more.luau"] = 'require("@greed/test")("more", function() end)\n' }
			)
		)
	end)
	local again = in_command(t, function()
		return agent.install("shout")
	end)
	t:keys("a")
	assert(again() and string.find(again() :: string, "installed", 1, true), again())
	assert(greed.fs.read(dir .. "/plugins/shout/init.luau") == edited, "the edit is kept")
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
	local said, may = agent.describe_check(report({ waiting }), { "proc" })
	assert(may, said)
	assert(string.find(said, "plugin_install may go ahead", 1, true), said)
	assert(string.find(said, "tests: 1 passed, 0 failed, 1 waiting for approval", 1, true), said)
	local shown = agent.describe_check(report({ waiting }), { "proc" }, true)
	assert(string.find(shown, "they run again once you install it", 1, true), shown)
	assert(not string.find(shown, "runs gh", 1, true), "a test that only waits isn't listed")
	assert(not string.find(shown, "plugin_install", 1, true), "the review speaks to you")
	local broken = { file = "a.luau", name = "adds", message = "expected 2, got 3" }
	local _, may_not = agent.describe_check(report({ waiting, broken }), { "proc" })
	assert(not may_not, "a real failure still stops it")
	local typed: any = report({})
	typed.types = { ok = false, output = "./plugin/init.luau(1,1): TypeError" }
	local _, typed_may = agent.describe_check(typed)
	assert(not typed_may, "so do type errors")
	-- Needing what the plugin doesn't ask for is a failure: installing won't grant it.
	local undeclared = {
		file = "a.luau",
		name = "writes",
		message = 'needs approval: it would write any file, by path, and you haven\'t approved "fs.write" for gh',
	}
	local _, may_write = agent.describe_check(report({ undeclared }), { "proc" })
	assert(not may_write, "fs.write isn't declared")
end)

test("a try never lands in a folder left from before", function(t)
	local dir = sandbox(t)
	-- As if an earlier session had tried "shout" and left a test behind.
	greed.fs.write(`{dir}/staging/shout-1/test/old.luau`, 'error("an old try")\n')
	greed.fs.write(`{dir}/staging/shout-2/plugin.toml`, 'name = "shout"\n')
	local report = in_command(t, function()
		return (agent.try("shout", PLUGIN))
	end)()
	assert(report and string.find(report, "tests: 1 passed, 0 failed", 1, true), report)
end)

test("the plugin guide carries the API's signatures, not its doc comments", function()
	local guide: any
	for _, tool in agent.tools() do
		if tool.name == "plugin_guide" then
			guide = tool
		end
	end
	local text = guide.run({}, agent.caller())
	assert(string.find(text, "export type ThemeEntry", 1, true), "the types are there")
	assert(
		string.find(text, "describe a function or type for its doc", 1, true),
		"and how to get docs"
	)
	assert(not string.find(text, "\n%s*%-%-%- "), "without doc comments")
	assert(#text < 50000, `small enough to carry: {#text}`)
end)

test("two pages asked for at once show one after the other", function(t)
	local dir = sandbox(t)
	in_command(t, function()
		return (agent.try("shout", PLUGIN))
	end)
	local loud = table.clone(PLUGIN)
	loud["init.luau"] = string.gsub(PLUGIN["init.luau"], '"shout"', '"loud"')
	loud["test/shout.luau"] = string.gsub(PLUGIN["test/shout.luau"], '"shout"', '"loud"')
	in_command(t, function()
		return (agent.try("loud", loud))
	end)
	local first = in_command(t, function()
		return agent.install("shout")
	end)
	greed.command({
		name = "test-extend-second",
		run = function()
			agent.install("loud")
		end,
	})
	t:run("test-extend-second")
	local reviews = 0
	for _, buffer in greed.buffers() do
		if buffer:kind() == "plugin-review" then
			reviews += 1
		end
	end
	assert(reviews == 1, `one review up at a time: {reviews}`)
	assert(
		string.find(greed.view():buffer():text(), '"shout"', 1, true),
		"the first asked shows first"
	)
	t:keys("a")
	assert(first() and string.find(first() or "", "installed shout", 1, true), first())
	t:wait(10)
	assert(string.find(greed.view():buffer():text(), '"loud"', 1, true), "then the second")
	t:keys("r")
	assert(greed.fs.stat(dir .. "/plugins/loud") == nil, "rejected")
end)
