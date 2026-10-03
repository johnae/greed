local test = require("@greed/test")
local greed = require("@greed")

test("greed.run returns when the command waits; with wait, once it has finished", function(t)
	t:buffer("|")
	local seen: { string } = {}
	greed.command({
		name = "test-ask",
		run = function()
			table.insert(seen, "key " .. greed.next_key())
		end,
	})
	greed.command({
		name = "test-run",
		run = function()
			greed.run("test-ask")
			table.insert(seen, "after run")
		end,
	})
	greed.command({
		name = "test-run-wait",
		run = function()
			greed.run("test-ask", { wait = true })
			table.insert(seen, "after waiting")
		end,
	})
	t:run("test-run")
	t:keys("x")
	assert(table.concat(seen, ", ") == "after run, key x", table.concat(seen, ", "))
	table.clear(seen)
	t:run("test-run-wait")
	t:keys("y")
	assert(table.concat(seen, ", ") == "key y, after waiting", table.concat(seen, ", "))
	table.clear(seen)
	-- A command that doesn't wait has finished already.
	greed.command({
		name = "test-wait-quick",
		run = function()
			greed.run("goto-start", { wait = true })
			table.insert(seen, "done")
		end,
	})
	t:run("test-wait-quick")
	assert(seen[1] == "done", "carried straight on")
end)
