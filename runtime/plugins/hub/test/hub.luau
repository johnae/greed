local test = require("@greed/test")
local hub = require("@hub")

test("the hub is the session hub-session names, else the first of this build by name", function()
	local sessions: any = {
		{ name = "world", build = "b1" },
		{ name = "greed", build = "old" },
		{ name = "cloud", build = "b1" },
	}
	assert(hub.elect(sessions, "b1", nil) == "cloud", "first by name, of this build")
	assert(hub.elect(sessions, "b1", "world") == "world", "the one named")
	assert(
		hub.elect(sessions, "b1", "gone") == "cloud",
		"one named that isn't running doesn't count"
	)
	local old: any = { { name = "greed", build = "old" } }
	assert(hub.elect(old, "b1", nil) == nil, "none of this build")
end)

test("what a watched session prints comes as whole lines, the rest kept for later", function()
	local lines, rest = hub.lines('{"a":1}\n{"b":')
	assert(#lines == 1 and lines[1] == '{"a":1}' and rest == '{"b":', rest)
	local more, left = hub.lines(rest .. "2}\n")
	assert(#more == 1 and more[1] == '{"b":2}' and left == "", tostring(#more))
end)
