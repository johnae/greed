local test = require("@kern/test")

local function describe(t: test.TestContext, command: string)
	t:buffer("|")
	t:keys("space h c")
	t:keys((string.gsub(command, ".", "%0 ")))
	t:keys("enter")
end

test("describing a command shows its doc, keys and source", function(t)
	describe(t, "next-word")
	local help = t:floats()[1]
	assert(help, "a help window opens")
	assert(string.find(help, "Select to the start of the next word", 1, true), help)
	assert(string.find(help, "Keys: w (normal)", 1, true), help)
	assert(string.find(help, "Defined in core/motions.luau:", 1, true), help)
end)

test("enter jumps to the definition", function(t)
	describe(t, "next-word")
	t:keys("enter")
	assert(#t:floats() == 0, "the help window closes")
	local line = string.match(t:marked(), "|[^\n]*")
	assert(line and string.find(line, "select_to", 1, true), line)
end)

test("esc closes the help window", function(t)
	describe(t, "next-word")
	t:keys("esc")
	assert(#t:floats() == 0, "the help window closes")
end)

test("describing a key waits for the keys and shows their command", function(t)
	t:buffer("|abc")
	t:keys("space h k")
	assert(#t:floats() == 0, "nothing shown before a key is pressed")
	t:keys("g")
	assert(#t:floats() == 0, "g starts longer sequences, so it waits for more")
	t:keys("e")
	local help = t:floats()[1]
	assert(help and string.find(help, "goto-end", 1, true), help)
	-- The keys described didn't run.
	t:keys("esc")
	t:expect("|abc")
end)

test("describing an unbound key says so", function(t)
	t:buffer("|abc")
	t:keys("space h k")
	t:keys("ctrl-o")
	assert(#t:floats() == 0, "no help window for an unbound key")
	t:expect("|abc")
end)
