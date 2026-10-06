local test = require("@greed/test")
local greed = require("@greed")

test("with auto-save on, a file is saved once its edits stop", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one\n" })
	local path = dir .. "/a.txt"
	greed.open(path)
	greed.option.set("auto-save", true)
	t:keys("i x esc")
	t:wait(500)
	t:keys("i y esc")
	t:wait(500)
	assert(greed.fs.read(path) == "one\n", "not while the edits keep coming")
	t:wait(600)
	assert(greed.fs.read(path) == "xyone\n", tostring((greed.fs.read(path))))
	assert(not greed.view():buffer():modified())
end)

test("auto-save is off unless asked for", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one\n" })
	local path = dir .. "/a.txt"
	greed.open(path)
	t:keys("i x esc")
	t:wait(2000)
	assert(greed.fs.read(path) == "one\n")
	assert(greed.view():buffer():modified())
end)

test(
	"auto-save waits as long as auto-save-delay says, and leaves buffers without files",
	function(t)
		local dir = t:tempdir({ ["a.txt"] = "one\n" })
		local path = dir .. "/a.txt"
		greed.option.set("auto-save", true)
		greed.option.set("auto-save-delay", 3000)
		t:buffer("|scratch")
		t:keys("i x esc")
		t:wait(3500)
		greed.open(path)
		t:keys("i x esc")
		t:wait(2000)
		assert(greed.fs.read(path) == "one\n", "not yet")
		t:wait(1500)
		assert(greed.fs.read(path) == "xone\n", tostring((greed.fs.read(path))))
	end
)
