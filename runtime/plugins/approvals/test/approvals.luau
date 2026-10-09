local test = require("@greed/test")
local greed = require("@greed")
local approvals = require("@approvals")

test("a plugin's capabilities read as what it may do", function(t)
	local dir = t:tempdir({
		["plugin.toml"] = 'name = "runner"\ncapabilities = ["proc", "fs.read"]\n',
		["init.luau"] = "return {}\n",
	})
	local about = greed.plugin.describe(dir)
	assert(about.name == "runner" and #about.missing == 0, about.name)
	local lines = approvals.lines(about)
	assert(lines[1] == "It asks to:", lines[1])
	assert(lines[2] == "  proc: run programs, which can do anything you can", lines[2])
	assert(lines[3] == "  fs.read: read any file, by path", lines[3])
end)

test("a plugin using nothing beyond the editor says so", function(t)
	local dir = t:tempdir({ ["plugin.toml"] = 'name = "plain"\n', ["init.luau"] = "return {}\n" })
	assert(approvals.lines(greed.plugin.describe(dir))[1] == "It uses nothing beyond the editor.")
end)

test(":plugins-approve says when nothing waits", function(t)
	t:buffer("|x")
	t:run("plugins-approve")
	local messages = t:messages()
	assert(messages[#messages] == "no plugins wait for approval", messages[#messages])
end)

test("each plugin says where it comes from", function(t)
	local approvals = require("@approvals")
	local dirs = greed.fs.dirs()
	assert(approvals.origin(greed.plugin.dirs().core :: string) == "Greed's own")
	assert(approvals.origin((dirs.config :: string) .. "/plugins/x") == "your config")
	assert(
		approvals.origin((dirs.data :: string) .. "/plugins/x")
			== "made in the editor (data folder)"
	)
	t:buffer("|x")
	t:run("plugins")
	t:wait(50)
	local listed = greed.view():buffer():text()
	assert(string.find(listed, "core  Greed's own", 1, true), listed)
	t:keys("esc")
end)

-- A plugin called `name` whose command `name` says `said`.
local function plugin(dir: string, name: string, said: string)
	greed.fs.write(`{dir}/{name}/plugin.toml`, `name = "{name}"\n`)
	greed.fs.write(
		`{dir}/{name}/init.luau`,
		`require("@greed").command(\{ name = "{name}", run = function() require("@greed").echo("{said}") end \})\nreturn \{\}\n`
	)
end

local function said(t: test.TestContext, command: string): string?
	t:run(command)
	local listed = greed.messages()
	return listed[#listed]
end

test("a plugin put in the plugins folder loads, and reloads when it changes", function(t)
	local dir = t:tempdir()
	approvals.watched = function()
		return { dir }
	end
	approvals.rescan(false)
	plugin(dir, "hello-watch", "one")
	t:wait(10)
	t:wait(500)
	assert(
		table.find(greed.plugin.list(), "hello-watch"),
		"it loaded: " .. table.concat(greed.messages(), " | ")
	)
	assert(said(t, "hello-watch") == "one", tostring(said(t, "hello-watch")))
	plugin(dir, "hello-watch", "two")
	t:wait(10)
	t:wait(500)
	assert(said(t, "hello-watch") == "two", "it reloaded")
	greed.plugin.unload("hello-watch")
end)

test(":plugin-reload loads a plugin again from its folder, and says so", function(t)
	t:buffer("|")
	local dir = t:tempdir({
		["plugin.toml"] = 'name = "greeter"\n',
		["init.luau"] = 'require("@greed").command({ name = "greet", run = function() require("@greed").echo("hi") end })\nreturn {}\n',
	})
	greed.plugin.load(dir)
	greed.fs.write(
		dir .. "/init.luau",
		'require("@greed").command({ name = "greet", run = function() require("@greed").echo("hello again") end })\nreturn {}\n'
	)
	t:run("plugin-reload", { "greeter" })
	local said = t:messages()
	assert(said[#said] == "reloaded greeter", said[#said])
	t:run("greet")
	said = t:messages()
	assert(said[#said] == "hello again", said[#said])
	t:run("plugin-reload", { "nobody" })
	said = t:messages()
	assert(string.find(said[#said], "no plugin called nobody", 1, true), said[#said])
end)
