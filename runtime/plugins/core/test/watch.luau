local test = require("@greed/test")
local greed = require("@greed")
local core = require("@core")

-- Lets a watch interval pass and checks what was said holds `text`.
local function heard(t: test.TestContext, text: string)
	t:wait(1100)
	local said = table.concat(t:messages(), "|")
	assert(string.find(said, text, 1, true), said)
end

test("watch says how a thing changed, says when it's gone, and again stops", function(t)
	local states: { [string]: { [string]: any }? } =
		{ ["T-1"] = { status = "open", row = { OWNER = "ann" } } }
	core.objects.kind({
		name = "test-ticket",
		get = function(key)
			return { kind = "test-ticket", id = `test-ticket:{key}`, label = key, value = key }
		end,
		fresh = function(key)
			return states[key]
		end,
	})
	greed.option.set("watch-interval", 1)
	local ticket = assert(core.objects.get("test-ticket:T-1"))
	assert(core.watch.toggle(ticket), "watched")
	assert(#core.watch.list() == 1)
	states["T-1"] = { status = "closed", row = { OWNER = "bob" } }
	heard(t, "T-1: OWNER ann → bob; status open → closed")
	states["T-1"] = nil
	heard(t, "T-1: gone")
	assert(#core.watch.list() == 0, "gone stops it")
	-- Again stops a watch.
	states["T-1"] = { status = "open" }
	assert(core.watch.toggle(ticket))
	assert(not core.watch.toggle(ticket) and #core.watch.list() == 0, "stopped")
	greed.option.set("watch-interval", 10)
end)
