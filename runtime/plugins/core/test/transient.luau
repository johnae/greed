local test = require("@greed/test")
local greed = require("@greed")
local transient = require("@core").transient

test("a menu lists its keys, flips switches, and runs the action chosen", function(t)
	t:buffer("|x")
	local got: { [string]: boolean }? = nil
	greed.command({
		name = "test-menu",
		run = function()
			transient.show({
				title = "Push",
				groups = {
					{
						title = "Switches",
						items = { { key = "f", doc = "force", switch = "force" } },
					},
					{
						title = "Push",
						items = {
							{
								key = "p",
								doc = "to origin",
								run = function(on)
									got = on
								end,
							},
						},
					},
				},
			})
		end,
	})
	t:run("test-menu")
	local shown = t:floats()[1]
	assert(string.find(shown, "-f    force", 1, true), shown)
	assert(string.find(shown, "p     to origin", 1, true), shown)
	t:keys("- f")
	assert(string.find(t:floats()[1], "force  (on)", 1, true), "the switch shows it's on")
	t:keys("p")
	assert(#t:floats() == 0, "it closes")
	assert(got and got.force == true, "the action got the switch")
end)

test("any other key closes a menu without running anything", function(t)
	t:buffer("|x")
	local ran = false
	greed.command({
		name = "test-menu",
		run = function()
			transient.show({
				title = "M",
				groups = {
					{
						title = "G",
						items = {
							{
								key = "a",
								doc = "act",
								run = function()
									ran = true
								end,
							},
						},
					},
				},
			})
		end,
	})
	t:run("test-menu")
	t:keys("esc")
	assert(#t:floats() == 0 and not ran)
end)
