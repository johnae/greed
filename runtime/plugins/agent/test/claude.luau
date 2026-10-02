local test = require("@kern/test")
local kern = require("@kern")

local function terminals(): { kern.Buffer }
	local found = {}
	for _, buffer in kern.buffers() do
		if buffer:kind() == "terminal" then
			table.insert(found, buffer)
		end
	end
	return found
end

test("space o c opens Claude Code in a pane, then goes back to it", function(t)
	kern.option.set("claude-command", "cat")
	local dir = t:tempdir({ ["a.txt"] = "text" })
	kern.open(dir .. "/a.txt")
	local files = kern.view()
	t:keys("space o c")
	local claude = kern.view()
	assert(claude:id() ~= files:id(), "a pane of its own")
	assert(claude:buffer():kind() == "terminal")
	assert(files:buffer():path() == dir .. "/a.txt", "the file stays where it was")
	assert(kern.mode.get() == "terminal")

	t:keys("ctrl-\\")
	files:focus()
	t:keys("space o c")
	assert(kern.view():id() == claude:id(), "it goes to the pane that's there")
	assert(#terminals() == 1)

	-- Closed but still running, it comes back.
	t:keys("ctrl-\\")
	files:focus()
	claude:close()
	t:keys("space o c")
	assert(kern.view():buffer():kind() == "terminal")
	assert(#terminals() == 1, "the same Claude Code")
	t:keys("ctrl-d")
end)

test("without Claude Code installed, it says so and leaves the panes alone", function(t)
	kern.option.set("claude-command", "kern-test-no-such-program")
	local dir = t:tempdir({ ["a.txt"] = "text" })
	kern.open(dir .. "/a.txt")
	t:keys("space o c")
	local messages = t:messages()
	assert(
		string.find(messages[#messages] or "", "can't start Claude Code", 1, true),
		table.concat(messages, " / ")
	)
	assert(kern.view():buffer():path() == dir .. "/a.txt")
	assert(#terminals() == 0)
end)
