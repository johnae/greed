local test = require("@greed/test")
local greed = require("@greed")
local cli = require("@cli")

test("new makes a plugin with a test, and type checking above it", function(t)
	local dir = t:tempdir({})
	local done = cli.new(dir, "hello")
	assert(done[1] == "created hello/: plugin.toml, init.luau, test/greet.luau", done[1])
	assert(greed.fs.read(dir .. "/hello/plugin.toml") ~= nil)
	local init = greed.fs.read(dir .. "/hello/init.luau") :: string
	assert(string.find(init, 'name = "hello-greet"', 1, true), init)
	assert(
		string.find(greed.fs.read(dir .. "/.luaurc") :: string, ".greed-types/greed", 1, true) ~= nil
	)
	assert(done[#done] == "run `greed test hello` to try it", done[#done])
end)

test("new leaves a .luaurc alone and says what to add", function(t)
	local dir = t:tempdir({ [".luaurc"] = "{}\n" })
	local done = cli.new(dir, "hello")
	assert(greed.fs.read(dir .. "/.luaurc") == "{}\n")
	assert(string.find(table.concat(done, "\n"), 'add "greed"', 1, true) ~= nil)
end)

test("new refuses a bad name or one that's taken", function(t)
	local dir = t:tempdir({ ["taken/plugin.toml"] = "" })
	local ok, err = pcall(cli.new, dir, "no spaces")
	assert(not ok and string.find(tostring(err), "letters, digits", 1, true), tostring(err))
	ok, err = pcall(cli.new, dir, "taken")
	assert(not ok and tostring(err) == "taken already exists", tostring(err))
end)
