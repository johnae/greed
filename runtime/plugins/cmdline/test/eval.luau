local test = require("@greed/test")
local greed = require("@greed")

local function mark()
	return greed.view():buffer():decorations("eval")[1]
end

-- What the eval mark shows, if any.
local function result(): string?
	local shown = mark()
	return shown and shown.text
end

test("space l e runs the line and shows what it returns at its end", function(t)
	t:buffer("|1 + 2\nnext\n")
	t:keys("space l e")
	assert(result() == "  ⇒ 3", tostring(result()))
	assert(mark().eol and mark().from == 5, "at the end of the line")
end)

test("a selection runs as one chunk, and its globals last like :lua", function(t)
	t:buffer("|answer = 40\nreturn answer + 2\n")
	t:keys("x x space l e")
	assert(result() == "  ⇒ 42", tostring(result()))
	t:buffer("|answer\n")
	t:keys("space l e")
	assert(result() == "  ⇒ 40", "a later run sees it: " .. tostring(result()))
end)

test("an error shows as one, and editing takes the result away", function(t)
	t:buffer('|error("no")\n')
	t:keys("space l e")
	local text = result() :: string
	assert(string.find(text, "^  ✗ ") and string.find(text, "no", 1, true), text)
	assert(mark().style == "diagnostic.error")
	t:keys("A space esc")
	assert(result() == nil, "gone after an edit")
end)
