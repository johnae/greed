local test = require("@kern/test")
local core = require("@core")
local kern = require("@kern")

test("a prompt can start from some text, with the cursor after it", function(t)
	t:buffer("|text")
	local got
	core.prompt.open({
		title = "Name",
		text = "old",
		on_submit = function(text)
			got = text
		end,
	})
	t:keys("e r enter")
	assert(got == "older", got)
end)

test("ask waits for the text, and gives nil when cancelled", function(t)
	t:buffer("|x")
	local done, got = false, nil
	kern.command({
		name = "test-ask",
		run = function()
			got = core.prompt.ask("Name", "a")
			done = true
		end,
	})
	t:run("test-ask")
	assert(not done)
	t:keys("b enter")
	assert(done and got == "ab", tostring(got))
	done = false
	t:run("test-ask")
	t:keys("esc")
	assert(done and got == nil, tostring(got))
end)
