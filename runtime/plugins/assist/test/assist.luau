local test = require("@greed/test")
local greed = require("@greed")

local function last(t: test.TestContext): string
	local messages = t:messages()
	return messages[#messages]
end

test("fix says when there's no problem on the line", function(t)
	t:buffer("|fine")
	t:run("fix")
	assert(last(t) == "no problem on this line", last(t))
end)

test("a description needs a repository", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a\n" })
	greed.open(dir .. "/a.txt")
	t:run("commit-message")
	t:wait(100)
	assert(last(t) == "not in a repository", last(t))
end)

test("without a model for its role, explain says how to set one, in its panel too", function(t)
	-- A role nothing plays, so no test ever reaches a real server.
	greed.option.set("assist-role", "nobody")
	t:buffer("|x = 1")
	t:run("explain")
	t:wait(50)
	assert(string.find(last(t), "models.roles.nobody", 1, true), last(t))
	local panel = ""
	for _, buffer in greed.buffers() do
		if buffer:kind() == "answer" then
			panel = buffer:text()
		end
	end
	assert(string.find(panel, "No answer: ", 1, true), panel)
	assert(string.find(panel, "models.roles.nobody", 1, true), panel)
	greed.option.set("assist-role", "fast")
end)
