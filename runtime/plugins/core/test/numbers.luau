local test = require("@greed/test")
local greed = require("@greed")

-- The line numbers drawn down the gutter, top to bottom.
local function numbers(t: test.TestContext): string
	local list = {}
	for _, row in t:draw(20, 6) do
		local number = string.match(row, "^%s*(%d+) ")
		if number then
			table.insert(list, number)
		end
	end
	return table.concat(list, " ")
end

test("line numbers count from the cursor's line when relative", function(t)
	t:buffer("one\ntwo\n|three\nfour\nfive")
	assert(numbers(t) == "1 2 3 4 5", numbers(t))
	greed.option.set("line-numbers", "relative")
	assert(numbers(t) == "2 1 0 1 2", numbers(t))
	t:keys("j")
	assert(numbers(t) == "3 2 1 0 1", "they follow the cursor")
	greed.option.set("line-numbers", "hybrid")
	assert(numbers(t) == "3 2 1 4 1", "the cursor's line is its own number")
	greed.option.set("line-numbers", "absolute")
	assert(numbers(t) == "1 2 3 4 5")
end)

test("a line-numbers style it doesn't know is refused with the choices", function()
	local ok, err = pcall(function()
		greed.option.set("line-numbers", "sideways")
	end)
	assert(not ok)
	assert(string.find(tostring(err), "absolute, relative, hybrid", 1, true), tostring(err))
	assert(greed.option.get("line-numbers") == "absolute", "the old value stays")
end)

test("with a whole line selected, 0 is the line the cursor is drawn on", function(t)
	t:buffer("one\n|two\nthree\nfour")
	greed.option.set("line-numbers", "relative")
	t:keys("x")
	assert(numbers(t) == "1 0 1 2", numbers(t))
end)
