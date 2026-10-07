local test = require("@greed/test")
local greed = require("@greed")

test(
	"an error nothing caught names its plugin and what it ran, and keeps where it failed",
	function(t)
		t:buffer("|x")
		greed.plugin.load(t:tempdir({
			["plugin.toml"] = 'name = "faulty"\n',
			["init.luau"] = [[
local greed = require("@greed")
local function fail()
	error("broken on purpose")
end
greed.on("buffer.opened", function()
	fail()
end)
]],
		}))
		local dir = t:tempdir({ ["a.txt"] = "a\n" })
		pcall(greed.open, `{dir}/a.txt`)
		local failure = greed.errors()[1]
		assert(failure, "kept")
		assert(failure.plugin == "faulty" and failure.what == "on buffer.opened", failure.what)
		assert(string.find(failure.message, "broken on purpose", 1, true), failure.message)
		assert(string.find(failure.traceback, "faulty/init.luau:3", 1, true), failure.traceback)
		t:run("errors")
		assert(
			string.find(greed.view():buffer():text(), "faulty (on buffer.opened)", 1, true) ~= nil
		)
	end
)
