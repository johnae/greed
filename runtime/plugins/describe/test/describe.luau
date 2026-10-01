local test = require("@kern/test")

local function describe(t: test.TestContext, command: string)
	t:buffer("|")
	t:keys("space h")
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
