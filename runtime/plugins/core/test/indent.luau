-- New lines' indent without a language: the line's own, one level more
-- after an opening bracket.

local test = require("@kern/test")
local kern = require("@kern")

local function check(t: test.TestContext, before: string, keys: string, after: string)
	t:buffer(before)
	t:keys(keys)
	t:expect(after)
end

test("enter keeps the line's indent", function(t)
	kern.option.set("indent", "  ")
	check(t, "  a|b", "i enter", "  a\n  |b")
	check(t, "\tx|", "a enter", "\tx\n\t|")
end)

test("after an opening bracket a new line goes a level in", function(t)
	kern.option.set("indent", "  ")
	check(t, "f(|", "a enter", "f(\n  |")
	check(t, "  a = [|", "a enter", "  a = [\n    |")
end)

test("between brackets the closing one gets a line of its own", function(t)
	kern.option.set("indent", "  ")
	check(t, "  f(|)", "i enter", "  f(\n    |\n  )")
	-- Before a closing bracket that isn't paired on the line, it lines up.
	check(t, "  a|]", "i enter", "  a\n  |]")
end)

test("a line left blank loses its indent, and spaces after the cursor go", function(t)
	kern.option.set("indent", "  ")
	check(t, "  a(|", "a enter enter", "  a(\n\n    |")
	check(t, "a|   b", "i enter", "a\n|b")
end)

test("o and O open lines at the indent the code calls for", function(t)
	kern.option.set("indent", "  ")
	check(t, "  a|b\nc", "o", "  ab\n  |\nc")
	check(t, "x {\n  a|b", "O", "x {\n  |\n  ab")
	check(t, "  a|b", "O", "|\n  ab")
	check(t, "x|", "O", "|\nx")
end)

test("several cursors each get their line's indent", function(t)
	kern.option.set("indent", "  ")
	check(t, "a|\n  b|", "i enter", "a\n|\n  b\n  |")
end)
