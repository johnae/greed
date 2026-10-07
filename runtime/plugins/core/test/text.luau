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
