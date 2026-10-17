-- Vim's style doesn't type brackets in pairs, as Vim doesn't; auto-pairs
-- says otherwise.

local test = require("@greed/test")
local greed = require("@greed")

local function check(t: test.TestContext, before: string, keys: string, after: string)
	t:buffer(before)
	greed.mode.set("vim")
	t:keys(keys)
	t:expect(after)
end

test("vim's style doesn't pair, and auto-pairs on does", function(t)
	greed.option.set("editing-style", "vim")
	check(t, "|", "i (", "(|")
	greed.option.set("auto-pairs", "on")
	check(t, "|", "i (", "(|)")
	greed.option.set("auto-pairs", "style")
	greed.option.set("editing-style", "helix")
end)
