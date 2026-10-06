local test = require("@greed/test")
local greed = require("@greed")

test("the profile counts commands and handlers by plugin and what they did", function(t)
	t:buffer("|abc")
	greed.on("buffer.changed", function() end)
	greed.profile.start()
	assert(greed.profile.running(), "taking one")
	t:keys("i x esc")
	local rows = greed.profile.stop()
	assert(not greed.profile.running(), "stopped")
	local seen: { [string]: greed.ProfileRow } = {}
	for _, row in rows do
		seen[`{row.plugin or "greed"}: {row.what}`] = row
	end
	assert(seen["core: insert-char"], "a command")
	assert(seen["core: insert-char"].runs == 1, tostring(seen["core: insert-char"].runs))
	local handler = false
	for name in seen do
		if string.find(name, "on buffer.changed", 1, true) then
			handler = true
		end
	end
	assert(handler, "a handler, by its event")
	assert(#greed.profile.stop() == 0, "nothing after it stopped")
end)

test(":profile starts, then shows what it counted", function(t)
	t:buffer("|abc")
	t:run("profile")
	t:keys("w")
	t:run("profile")
	local shown = greed.view():buffer():text()
	assert(string.find(shown, "Time spent per plugin", 1, true), shown)
	assert(string.find(shown, "core: next-word", 1, true), shown)
end)
