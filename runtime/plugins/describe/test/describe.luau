local test = require("@greed/test")
local greed = require("@greed")

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
	assert(help and string.find(help, "goto-last-line", 1, true), help)
	-- The keys described didn't run.
	t:keys("esc")
	t:expect("|abc")
end)

test("describing an unbound key says so", function(t)
	t:buffer("|abc")
	t:keys("space h k")
	t:keys("ctrl-g")
	assert(#t:floats() == 0, "no help window for an unbound key")
	t:expect("|abc")
end)

test("a command without a doc or keys says so, and q closes the help", function(t)
	greed.command({ name = "bare-test-command", run = function() end })
	t:buffer("|abc")
	describe(t, "bare-test-command")
	local help = t:floats()[1]
	assert(string.find(help, "(no description)", 1, true), help)
	assert(string.find(help, "Keys: none", 1, true), help)
	t:keys("q")
	assert(#t:floats() == 0, "q closes it")
end)

test(
	"a command bound in several layers lists each, and help opened twice replaces itself",
	function(t)
		greed.keymap.bind("edit", { ["alt-g"] = "goto-start" })
		describe(t, "goto-start")
		local help = t:floats()[1]
		assert(string.find(help, "Keys: g g (normal)", 1, true), help)
		assert(string.find(help, "Keys: alt-g (edit)", 1, true), help)
		t:keys("esc")
		describe(t, "goto-end")
		describe(t, "goto-start")
		assert(#t:floats() == 1, "one help window")
	end
)

test("enter does nothing for a command with no file to go to", function(t)
	-- Defined at the REPL, so it has no file.
	assert(
		greed.eval(
			"require('@greed').command({ name = 'no-file-test-command', doc = 'Here', run = function() end })"
		)
	)
	describe(t, "no-file-test-command")
	t:keys("enter")
	assert(#t:floats() == 1, "the help stays")
end)

test("a key bound to a missing command says so", function(t)
	greed.keymap.bind("normal", { ["g z"] = "nothing-by-this-name" })
	t:buffer("|abc")
	t:keys("space h k g z")
	local messages = t:messages()
	assert(
		messages[#messages] == "g z runs nothing-by-this-name, which doesn't exist",
		messages[#messages]
	)
end)

test("describing a key works in the mode you're in", function(t)
	t:buffer("|abc")
	greed.mode.set("insert")
	greed.run("describe-key")
	t:keys("esc")
	assert(string.find(t:floats()[1] or "", "normal-mode", 1, true), tostring(t:floats()[1]))
end)
