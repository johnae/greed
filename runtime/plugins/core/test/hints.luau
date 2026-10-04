local test = require("@greed/test")
local greed = require("@greed")

local function labels(): string
	local out = {}
	for _, mark in greed.view():buffer():decorations("motion-hints") do
		table.insert(out, `{mark.text}@{mark.from}`)
	end
	return table.concat(out, " ")
end

test("with motion-hints on, w numbers the next words and a digit goes there", function(t)
	greed.option.set("motion-hints", true)
	t:buffer("|one two three four five")
	t:keys("w")
	t:expect("^one |two three four five")
	-- Each number is where the cursor would land: after the word, as Helix has it.
	assert(labels() == "1@7 2@13 3@18 4@22", labels())
	-- The nearest stand out, the rest are quieter.
	local styles = {}
	for _, mark in greed.view():buffer():decorations("motion-hints") do
		table.insert(styles, mark.style)
	end
	assert(
		styles[3] == "ui.motion.hint" and styles[4] == "ui.motion.hint.far",
		table.concat(styles, " ")
	)
	t:keys("2")
	t:expect("one two ^three |four five")
	assert(labels() == "1@18 2@22", "numbered again from there: " .. labels())
	-- Any other key takes the numbers away, and digits are counts again.
	t:keys("l")
	assert(labels() == "", labels())
	t:keys("g h 2 w")
	t:expect("one ^two |three four five")
	greed.option.set("motion-hints", false)
end)

test("in select mode a digit extends; with the option off, nothing is numbered", function(t)
	greed.option.set("motion-hints", true)
	t:buffer("|one two three four")
	t:keys("v w 2")
	t:expect("^one two three |four")
	greed.option.set("motion-hints", false)
	t:buffer("|one two three")
	t:keys("w")
	assert(labels() == "", labels())
	t:keys("2 w")
	t:expect("one two ^three|")
end)

test("a key overlay binds keys for the next press only", function(t)
	t:buffer("|abc")
	greed.keymap.overlay({ x = "goto-end" })
	t:keys("x")
	t:expect("abc|")
	greed.keymap.overlay({ x = "goto-end" })
	t:keys("g h x")
	t:expect("^abc|")
end)

test("a number goes on the space beside a word rather than over its letters", function(t)
	greed.option.set("motion-hints", true)
	t:buffer("one two three four five|")
	t:keys("b")
	-- b lands on each word's first letter; its number takes the space before
	-- it, and the first word, with none, keeps its own.
	assert(labels() == "1@13 2@7 3@3 4@0", labels())
	t:keys("2")
	t:expect("one two |three ^four five")
	greed.option.set("motion-hints", false)
end)
