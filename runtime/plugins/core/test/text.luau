local test = require("@greed/test")
local text = require("@core").text

test("text width counts characters, and bytes when it isn't UTF-8", function()
	assert(text.width("abc") == 3)
	assert(text.width("‹ ›") == 3)
	assert(text.width("\255\254") == 2)
end)

test("clipped text ends in an ellipsis only when it was longer", function()
	assert(text.clip("‹ 2/5 ›", 3) == "‹ …")
	assert(text.clip("short", 5) == "short")
	assert(text.clip("shorter", 5) == "shor…")
end)

test("two texts' shared start counts whole lines only", function()
	local same = text.same_lines
	assert(same("a\nb\nc\n", "a\nb\nd\n") == 4)
	assert(same("a\nbc\n", "a\nbd\n") == 2, "not into a line that differs")
	assert(same("a\nb\n", "a\nb\nc\n") == 4)
	assert(same("", "x\n") == 0)
	assert(same("a\nb", "a\nb") == 2, "a last line without its break isn't whole")
end)
