local test = require("@greed/test")
local greed = require("@greed")
local attention = require("@core").attention

test("what needs you is listed oldest first, with why, until its owner takes it off", function(t)
	local a = greed.create_buffer("scratch", "a")
	local changes = 0
	attention.on_change(function()
		changes += 1
	end)
	attention.set("test:a", { label = "a", reason = "waits for your answer", buffer = a })
	attention.set("test:b", { label = "b", reason = "a command finished" })
	local list = attention.list()
	assert(#list == 2 and list[1].key == "test:a" and list[2].key == "test:b", tostring(#list))
	assert(list[1].reason == "waits for your answer" and list[1].since > 0)
	assert((attention.of(a) :: any).key == "test:a")
	-- Said again with the same reason, nothing changes.
	attention.set("test:a", { label = "a", reason = "waits for your answer", buffer = a })
	assert(changes == 2, `{changes} changes`)
	attention.set("test:b", nil)
	assert(#attention.list() == 1 and changes == 3)
	attention.set("test:b", nil)
	assert(changes == 3, "taking off what isn't there changes nothing")
	a:close()
	assert(#attention.list() == 0 and attention.of(a) == nil, "a closed buffer's need goes")
	assert(changes == 4)
end)
