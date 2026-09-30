-- Buffers are written with markers: `|` is a selection's head and `^` its
-- anchor (left out for cursors). "^hello |world" selects "hello ".

local test = require("@kern/test")

local function check(t: test.TestContext, before: string, keys: string, after: string)
	t:buffer(before)
	t:keys(keys)
	t:expect(after)
end

test("typing in insert mode", function(t)
	check(t, "ab|c", "i x y esc", "abxy|c")
	check(t, "a|bc", "a Z", "abZ|c")
	check(t, "ab|c", "i backspace", "a|c")
	check(t, "ab|c", "i enter", "ab\n|c")
	check(t, "^hello |world", "i >", ">|hello world")
end)

test("insert mode is left with esc", function(t)
	t:buffer("|")
	t:keys("i")
	t:expect_mode("insert")
	t:keys("esc")
	t:expect_mode("normal")
end)

test("typing at every cursor", function(t)
	check(t, "a|b a|b", "i -", "a-|b a-|b")
end)

test("delete and change", function(t)
	check(t, "^hello |world", "d", "|world")
	check(t, "a|bc", "d", "a|c")
	check(t, "^hello |world", "c b y e space", "bye |world")
end)

test("undo and redo", function(t)
	check(t, "^hello |world", "d u", "^hello |world")
	check(t, "^hello |world", "d u U", "|world")
end)

test("an insert session undoes as one step", function(t)
	check(t, "ab|c", "i x y z esc u", "ab|c")
	check(t, "^hello |world", "c b y e space esc u", "^hello |world")
	-- `o` moves the cursor to the line end before editing; undo restores that.
	check(t, "a|bc\ndef", "o x y esc u", "abc|\ndef")
	check(t, "ab|c", "i x esc i y esc u", "abx|c")
end)

test("open lines", function(t)
	check(t, "a|bc\ndef", "o x", "abc\nx|\ndef")
	check(t, "abc\nd|ef", "O x", "abc\nx|\ndef")
end)
