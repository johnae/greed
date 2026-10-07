local test = require("@greed/test")
local greed = require("@greed")

test("removing or moving the home folder is refused", function()
	local home = greed.fs.dirs().home :: string
	assert(greed.fs.mkdir(home .. "/kept"))
	local tries: { () -> (boolean?, string?) } = {
		function()
			return greed.fs.remove(home, { recursive = true })
		end,
		function()
			return greed.fs.remove(home .. "/", { recursive = true })
		end,
		function()
			return greed.fs.rename(home, home .. "-moved")
		end,
	}
	for _, try in tries do
		local ok, err = pcall(try :: any)
		assert(not ok and string.find(tostring(err), "the home folder", 1, true), tostring(err))
	end
	assert(greed.fs.stat(home .. "/kept"), "still there")
	assert(greed.fs.remove(home .. "/kept"), "what's in it can go")
end)

test("making, removing and moving files needs fs.write, and hashing a file fs.read", function(t)
	local dir = t:tempdir({ ["a.txt"] = "abc" })
	greed.plugin.load(t:tempdir({
		["plugin.toml"] = 'name = "reader"\ncapabilities = ["net"]\n',
		["init.luau"] = `local greed = require("@greed")\n`
			.. `local DIR = "{dir}"\n`
			.. [[
greed.command({ name = "reader-go", run = function()
	local said = {}
	for _, call in {
		function() return greed.fs.mkdir(DIR .. "/new") end,
		function() return greed.fs.remove(DIR .. "/a.txt") end,
		function() return greed.fs.rename(DIR .. "/a.txt", DIR .. "/b.txt") end,
		function() return greed.fs.copy(DIR .. "/a.txt", DIR .. "/b.txt") end,
		function() return greed.hash.sha256_file(DIR .. "/a.txt") end,
		function() return greed.http.request({ url = "http://127.0.0.1:1/", save = DIR .. "/got" }) end,
	} do
		local ok, err = pcall(call)
		table.insert(said, if ok then "allowed" else string.match(tostring(err), 'add "([%w.]+)"') or tostring(err))
	end
	table.insert(said, string.sub(greed.hash.sha256("abc"), 1, 8))
	greed.echo(table.concat(said, " "))
end })
]],
	}))
	t:run("reader-go")
	local messages = table.concat(t:messages(), "\n")
	assert(
		string.find(
			messages,
			"fs.write fs.write fs.write fs.write fs.read fs.write ba7816bf",
			1,
			true
		),
		messages
	)
	assert(greed.fs.stat(dir .. "/a.txt") and not greed.fs.stat(dir .. "/new"), "nothing changed")
end)
