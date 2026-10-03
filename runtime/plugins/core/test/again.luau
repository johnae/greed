local test = require("@kern/test")

local function check(t: test.TestContext, before: string, keys: string, after: string)
	t:buffer(before)
	t:keys(keys)
	t:expect(after)
end

test(". repeats the last change, typed text and all", function(t)
	check(t, "^one| two three", "c O N E esc w e .", "ONE ONE| three")
	check(t, "a|b\ncd", "i x esc j .", "axb\ncdx|")
end)

test(". leaves out motions, copies and undo", function(t)
	check(t, "|abc", "d l y .", "b|")
	check(t, "|abc", "d u .", "|bc")
end)

test("a count before . replaces the change's own", function(t)
	check(t, "|ab", "2 > 3 .", "|                    ab")
end)
