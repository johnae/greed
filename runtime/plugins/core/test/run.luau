local test = require("@kern/test")
local kern = require("@kern")

test("kern.run returns when the command waits; with wait, once it has finished", function(t)
	t:buffer("|")
	local seen: { string } = {}
	kern.command({
		name = "test-ask",
		run = function()
			table.insert(seen, "key " .. kern.next_key())
		end,
	})
	kern.command({
		name = "test-run",
		run = function()
			kern.run("test-ask")
			table.insert(seen, "after run")
		end,
	})
	kern.command({
		name = "test-run-wait",
		run = function()
			kern.run("test-ask", { wait = true })
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
	kern.command({
		name = "test-wait-quick",
		run = function()
			kern.run("goto-start", { wait = true })
			table.insert(seen, "done")
		end,
	})
	t:run("test-wait-quick")
	assert(seen[1] == "done", "carried straight on")
end)
