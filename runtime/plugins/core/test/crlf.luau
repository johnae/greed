local test = require("@kern/test")
local kern = require("@kern")

local function text(): string
	return kern.view():buffer():text()
end

test("new lines in a CRLF file are CRLF too", function(t)
	t:buffer("a|b\r\ncd\r\n")
	t:keys("i enter esc")
	assert(text() == "a\r\nb\r\ncd\r\n", string.format("%q", text()))
	t:buffer("|ab\r\ncd\r\n")
	t:keys("o x esc")
	assert(text() == "ab\r\nx\r\ncd\r\n", string.format("%q", text()))
	t:buffer("ab\r\n|cd\r\n")
	t:keys("O x esc")
	assert(text() == "ab\r\nx\r\ncd\r\n", string.format("%q", text()))
end)

test("deleting a CRLF line break deletes both characters", function(t)
	t:buffer("ab\r\n|cd")
	t:keys("i backspace esc")
	assert(text() == "abcd", string.format("%q", text()))
	t:buffer("ab|\r\ncd")
	t:keys("d")
	assert(text() == "abcd", string.format("%q", text()))
end)

test("splitting into lines leaves the CR out", function(t)
	t:buffer("^ab\r\ncd|")
	t:keys("alt-s")
	t:expect("^ab|\r\n^cd|")
end)
