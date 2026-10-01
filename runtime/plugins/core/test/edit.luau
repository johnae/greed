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

test("copy and paste", function(t)
	check(t, "^hello| world", "y g l p", "hello world^hello|")
	check(t, "^hello| world", "y P", "^hello|hello world")
end)

test("each selection pastes its own piece", function(t)
	t:buffer("^ab| ^cd|")
	t:keys("y")
	t:keys("p")
	t:expect("ab^ab| cd^cd|")
end)

test("copying nothing says so", function(t)
	t:buffer("a|b")
	t:keys("y")
	t:expect("a|b")
end)

test("commands that wait finish when time passes", function(t)
	local kern = require("@kern")
	kern.command({
		name = "slow-insert",
		run = function(ctx)
			kern.sleep(100)
			ctx.buffer:edit(function(e)
				e:insert(0, "done ")
			end)
		end,
	})
	t:buffer("|x")
	t:run("slow-insert")
	t:expect("|x")
	t:wait(100)
	t:expect("done |x")
end)

test("pieces that don't match the selections paste joined, at each one", function(t)
	t:buffer("^ab| ^cd| ef")
	t:keys("y")
	t:buffer("x| y")
	t:keys("p")
	t:expect("x^ab\ncd| y")
end)

test("deleting back at the start of the buffer does nothing", function(t)
	check(t, "|abc", "i backspace esc", "|abc")
end)

test("o and O at several cursors on one line open one line each", function(t)
	check(t, "a|b|c\nd", "o", "abc\n|\nd")
end)

test("d and c copy what they delete; alt-d and alt-c don't", function(t)
	check(t, "^ab| cd", "d g l p", " cd^ab|")
	t:buffer("^xy| z")
	t:keys("y")
	t:buffer("^ab| cd")
	t:keys("alt-d g l p")
	t:expect(" cd^xy|")
	t:buffer("^ab| cd")
	t:keys("alt-c Q esc")
	t:expect("Q| cd")
end)

test("r replaces each selected character with the one typed", function(t)
	check(t, "^abc| d", "r x", "^xxx| d")
	check(t, "a|bc", "r z", "a|zc")
end)

test("~ switches case, ` lowers it and alt-` raises it", function(t)
	check(t, "^aBc| d", "~", "^AbC| d")
	check(t, "^aBc| d", "`", "^abc| d")
	check(t, "^aBc| d", "alt-`", "^ABC| d")
end)

test("> and < indent and dedent the lines of each selection", function(t)
	check(t, "a|b\ncd", ">", "    a|b\ncd")
	check(t, "^ab\ncd|\nef", ">", "^    ab\n    cd|\nef")
	check(t, "    a|b", "<", "a|b")
	check(t, "  a|b", "<", "a|b")
end)

test("J joins the next line, or the lines of a selection, with one space", function(t)
	check(t, "a|b\n   cd\nef", "J", "a|b cd\nef")
	check(t, "^a\nb\nc|\nd", "J", "^a b c|\nd")
end)

test("I and A insert at the start and end of the line", function(t)
	check(t, "  ab|c", "I x esc", "  x|abc")
	check(t, "a|bc\nd", "A x esc", "abcx|\nd")
end)

test("R replaces each selection with what was copied", function(t)
	t:buffer("^new| old")
	t:keys("y")
	t:buffer("new ^old|")
	t:keys("R")
	t:expect("new ^new|")
end)
