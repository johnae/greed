-- Buffers are written with markers: `|` is a selection's head and `^` its
-- anchor (left out for cursors). "^hello |world" selects "hello ".

local test = require("@kern/test")

local function check(t, before: string, keys: string, after: string)
	t:buffer(before)
	t:keys(keys)
	t:expect(after)
end

test("character moves stay on the line", function(t)
	check(t, "a|bc\ndef", "l l l", "abc|\ndef")
	check(t, "abc\nd|ef", "h h h", "abc\n|def")
end)

test("line moves keep the column", function(t)
	check(t, "ab|cd\nx\nwxyz", "j", "abcd\nx|\nwxyz")
	check(t, "ab|cd\nx\nwxyz", "j j", "abcd\nx\nwx|yz")
	check(t, "abcd\nwx|yz", "k", "ab|cd\nwxyz")
	check(t, "ab|cd", "k", "ab|cd")
	check(t, "é|é\néé", "j", "éé\né|é")
end)

test("word motions select what they move over", function(t)
	check(t, "|hello world", "w", "^hello |world")
	check(t, "|hello world", "w w", "hello ^world|")
	check(t, "|foo.bar", "w", "^foo|.bar")
	check(t, "|héllo wörld", "w", "^héllo |wörld")
	check(t, "hello wor|ld", "b", "hello |wor^ld")
	check(t, "hello |world", "b", "|hello ^world")
	check(t, "|hello world", "e", "^hello| world")
	check(t, "hello| world", "e", "hello^ world|")
end)

test("line and buffer jumps", function(t)
	check(t, "ab|c\ndef", "g l", "abc|\ndef")
	check(t, "ab|c\ndef", "g h", "|abc\ndef")
	check(t, "abc\nde|f", "g g", "|abc\ndef")
	check(t, "a|bc\ndef", "g e", "abc\ndef|")
end)

test("select line includes the line break", function(t)
	check(t, "a|bc\ndef", "x", "^abc\n|def")
	check(t, "abc\nd|ef", "x", "abc\n^def|")
end)

test("collapse and flip", function(t)
	check(t, "^hello |world", ";", "hello |world")
	check(t, "^hello |world", "alt-;", "|hello ^world")
end)
