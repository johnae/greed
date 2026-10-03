local test = require("@kern/test")
local kern = require("@kern")

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
	kern.open(dir .. "/a.txt")
	t:run("commit-message")
	t:wait(100)
	assert(last(t) == "not in a repository", last(t))
end)

test("without a model for its role, explain says how to set one", function(t)
	-- A role nothing plays, so no test ever reaches a real server.
	kern.option.set("assist-role", "nobody")
	t:buffer("|x = 1")
	t:run("explain")
	t:wait(50)
	assert(string.find(last(t), "models.roles.nobody", 1, true), last(t))
	kern.option.set("assist-role", "fast")
end)
