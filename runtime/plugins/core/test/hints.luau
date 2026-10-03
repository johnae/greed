local test = require("@kern/test")
local kern = require("@kern")

local function labels(): string
	local out = {}
	for _, mark in kern.view():buffer():decorations("motion-hints") do
		table.insert(out, `{mark.text}@{mark.from}`)
	end
	return table.concat(out, " ")
end

test("with motion-hints on, w numbers the next words and a digit goes there", function(t)
	kern.option.set("motion-hints", true)
	t:buffer("|one two three four five")
	t:keys("w")
	t:expect("^one |two three four five")
	-- Each number is where the cursor would land: after the word, as Helix has it.
	assert(labels() == "1@7 2@13 3@18 4@22", labels())
	t:keys("2")
	t:expect("one two ^three |four five")
	assert(labels() == "1@18 2@22", "numbered again from there: " .. labels())
	-- Any other key takes the numbers away, and digits are counts again.
	t:keys("l")
	assert(labels() == "", labels())
	t:keys("g h 2 w")
	t:expect("one ^two |three four five")
	kern.option.set("motion-hints", false)
end)

test("in select mode a digit extends; with the option off, nothing is numbered", function(t)
	kern.option.set("motion-hints", true)
	t:buffer("|one two three four")
	t:keys("v w 2")
	t:expect("^one two three |four")
	kern.option.set("motion-hints", false)
	t:buffer("|one two three")
	t:keys("w")
	assert(labels() == "", labels())
	t:keys("2 w")
	t:expect("one two ^three|")
end)

test("a key overlay binds keys for the next press only", function(t)
	t:buffer("|abc")
	kern.keymap.overlay({ x = "goto-end" })
	t:keys("x")
	t:expect("abc|")
	kern.keymap.overlay({ x = "goto-end" })
	t:keys("g h x")
	t:expect("^abc|")
end)
