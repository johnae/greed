local test = require("@greed/test")
local greed = require("@greed")

local function terminals(): { greed.Buffer }
	local found = {}
	for _, buffer in greed.buffers() do
		if buffer:kind() == "terminal" then
			table.insert(found, buffer)
		end
	end
	return found
end

test("space i C opens Claude Code in a pane, then goes back to it", function(t)
	greed.option.set("claude-command", "cat")
	local dir = t:tempdir({ ["a.txt"] = "text" })
	greed.open(dir .. "/a.txt")
	local files = greed.view()
	t:keys("space i C")
	local claude = greed.view()
	assert(claude:id() ~= files:id(), "a pane of its own")
	assert(claude:buffer():kind() == "terminal")
	assert(files:buffer():path() == dir .. "/a.txt", "the file stays where it was")
	assert(greed.mode.get() == "terminal")

	t:keys("ctrl-\\")
	files:focus()
	t:keys("space i C")
	assert(greed.view():id() == claude:id(), "it goes to the pane that's there")
	assert(#terminals() == 1)

	-- Closed but still running, it comes back.
	t:keys("ctrl-\\")
	files:focus()
	claude:close()
	t:keys("space i C")
	assert(greed.view():buffer():kind() == "terminal")
	assert(#terminals() == 1, "the same Claude Code")
	t:keys("ctrl-d")
end)

test("without Claude Code installed, it says so and leaves the panes alone", function(t)
	greed.option.set("claude-command", "greed-test-no-such-program")
	local dir = t:tempdir({ ["a.txt"] = "text" })
	greed.open(dir .. "/a.txt")
	t:keys("space i C")
	local messages = t:messages()
	assert(
		string.find(messages[#messages] or "", "can't start Claude Code", 1, true),
		table.concat(messages, " / ")
	)
	assert(greed.view():buffer():path() == dir .. "/a.txt")
	assert(#terminals() == 0)
end)
