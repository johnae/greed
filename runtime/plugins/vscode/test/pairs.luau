-- Brackets in pairs where typing replaces the selection.

local test = require("@greed/test")
local greed = require("@greed")

local function check(t: test.TestContext, before: string, keys: string, after: string)
	t:buffer(before)
	greed.mode.set("vscode")
	t:keys(keys)
	t:expect(after)
end

test("an opener pairs, and typed over a selection goes around it", function(t)
	greed.option.set("editing-style", "vscode")
	check(t, "|", "(", "(|)")
	check(t, "^ab|", "(", "(^ab|)")
	check(t, "^ab|", '"', '"^ab|"')
	check(t, "|", "( backspace", "|")
	greed.option.set("editing-style", "helix")
end)
