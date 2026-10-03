local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")

local function commands(): { [string]: boolean }
	local names = {}
	for _, command in greed.commands() do
		names[command.name] = true
	end
	return names
end

test("a watched file that changes is heard about, wherever it changed", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one" })
	local heard: { string } = {}
	greed.on("file.changed", function(event: greed.FileChanged)
		table.insert(heard, event.path)
	end)
	greed.fs.watch(dir .. "/a.txt")
	greed.fs.watch(dir .. "/later.txt")
	t:wait(10)
	assert(#heard == 0, "nothing changed yet")
	greed.fs.write(dir .. "/a.txt", "two!")
	greed.fs.write(dir .. "/later.txt", "made")
	t:wait(10)
	table.sort(heard)
	assert(
		#heard == 2 and heard[1] == dir .. "/a.txt" and heard[2] == dir .. "/later.txt",
		table.concat(heard, ",")
	)
end)

test("the config runs again when it changes, taking away what it registered before", function(t)
	local dir = t:tempdir({
		["init.luau"] = "require('@greed').command({ name = 'from-before', run = function() end })\n",
	})
	greed.plugin.load(dir, "user/config")
	core.config.watch()
	assert(commands()["from-before"])
	greed.fs.write(
		dir .. "/init.luau",
		"require('@greed').command({ name = 'from-now', run = function() end })\n"
	)
	t:wait(10)
	local names = commands()
	assert(names["from-now"] and not names["from-before"], "the new config replaced the old")
	local messages = t:messages()
	assert(messages[#messages] == "config reloaded", messages[#messages])

	-- A config that fails says why.
	greed.fs.write(dir .. "/init.luau", "error('oops')\n")
	t:wait(10)
	messages = t:messages()
	assert(string.find(messages[#messages], "oops", 1, true), messages[#messages])
	greed.plugin.unload("user/config")
end)
