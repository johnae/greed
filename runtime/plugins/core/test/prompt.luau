local test = require("@greed/test")
local core = require("@core")
local greed = require("@greed")

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
	greed.command({
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

test("a prompt whose view closes some other way is cancelled", function(t)
	t:buffer("|x")
	local cancelled = 0
	core.prompt.open({
		title = "Name",
		on_submit = function() end,
		on_cancel = function()
			cancelled += 1
		end,
	})
	t:expect_mode("insert")
	greed.view():close()
	t:wait(0)
	t:expect_mode("normal")
	assert(cancelled == 1, `cancelled {cancelled} times`)
	t:run("prompt-cancel")
	assert(cancelled == 1, "nothing left to cancel")
end)
