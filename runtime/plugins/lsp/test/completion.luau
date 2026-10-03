local test = require("@greed/test")
local greed = require("@greed")

-- What a command line or prompt does: a float typed into, closed by enter
-- before the typing pause runs out.
test("a float typed into and closed before the pause doesn't break completion", function(t)
	t:buffer("|x")
	local dir = t:tempdir({ ["a.txt"] = "" })
	local list = greed.create_buffer("scratch", "")
	list:save(dir .. "/a.txt")
	local float = greed.float(list, { width = 20, height = 1 })
	t:keys("i a b")
	float:close()
	t:wait(greed.option.get("completion-delay") :: number + 100)
	for _, message in t:messages() do
		assert(not string.find(message, "closed", 1, true), message)
	end
end)
