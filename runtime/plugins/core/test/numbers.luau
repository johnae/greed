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

test("an option set by a name that isn't one says the names that are like it", function()
	for _, wrong in { "line_numbers", "relativenumber" } do
		local ok, err = pcall(function()
			greed.option.set(wrong, "relative")
		end)
		assert(not ok, wrong)
		assert(
			string.find(tostring(err), `there is no option called "{wrong}"`, 1, true),
			tostring(err)
		)
		assert(string.find(tostring(err), '"line-numbers"', 1, true), tostring(err))
	end
	local _, err = pcall(function()
		greed.option.set("zzqx", true)
	end)
	assert(not string.find(tostring(err), "did you mean", 1, true), tostring(err))
end)

test("the ruler option paints file panes in both clients and clears immediately", function(t)
	local dir = t:tempdir({ ["rulers.txt"] = "short\n\nend" })
	greed.open(dir .. "/rulers.txt")
	greed.theme.set({ ["ui.ruler"] = { bg = "#303040" } })
	local function check(medium: "terminal" | "window")
		greed.option.set("rulers", { 4 })
		local frame = t:frame(20, 6, medium)
		assert(assert(frame.cell(5, 1)).bg == "#303040", "empty line")
		assert(assert(frame.cell(5, 4)).bg == "#303040", "below EOF")
		greed.option.set("rulers", {})
		frame = t:frame(20, 6, medium)
		assert(assert(frame.cell(5, 1)).bg ~= "#303040", "cleared")
		assert(assert(frame.cell(5, 4)).bg ~= "#303040", "cleared below EOF")
	end
	check("terminal")
	check("window")
end)
