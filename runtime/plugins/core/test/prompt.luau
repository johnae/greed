local test = require("@kern/test")
local core = require("@core")

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
