local test = require("@kern/test")
local kern = require("@kern")
local core = require("@core")

local function commands(): { [string]: boolean }
	local names = {}
	for _, command in kern.commands() do
		names[command.name] = true
	end
	return names
end

test("a watched file that changes is heard about, wherever it changed", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one" })
	local heard: { string } = {}
	kern.on("file.changed", function(event: kern.FileChanged)
		table.insert(heard, event.path)
	end)
	kern.fs.watch(dir .. "/a.txt")
	kern.fs.watch(dir .. "/later.txt")
	t:wait(10)
	assert(#heard == 0, "nothing changed yet")
	kern.fs.write(dir .. "/a.txt", "two!")
	kern.fs.write(dir .. "/later.txt", "made")
	t:wait(10)
	table.sort(heard)
	assert(
		#heard == 2 and heard[1] == dir .. "/a.txt" and heard[2] == dir .. "/later.txt",
		table.concat(heard, ",")
	)
end)

test("the config runs again when it changes, taking away what it registered before", function(t)
	local dir = t:tempdir({
		["init.luau"] = "require('@kern').command({ name = 'from-before', run = function() end })\n",
	})
	kern.plugin.load(dir, "user/config")
	core.config.watch()
	assert(commands()["from-before"])
	kern.fs.write(
		dir .. "/init.luau",
		"require('@kern').command({ name = 'from-now', run = function() end })\n"
	)
	t:wait(10)
	local names = commands()
	assert(names["from-now"] and not names["from-before"], "the new config replaced the old")
	local messages = t:messages()
	assert(messages[#messages] == "config reloaded", messages[#messages])

	-- A config that fails says why.
	kern.fs.write(dir .. "/init.luau", "error('oops')\n")
	t:wait(10)
	messages = t:messages()
	assert(string.find(messages[#messages], "oops", 1, true), messages[#messages])
	kern.plugin.unload("user/config")
end)
