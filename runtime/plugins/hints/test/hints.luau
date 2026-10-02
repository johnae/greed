local test = require("@kern/test")
local kern = require("@kern")

test("a prefix key shows what can follow it", function(t)
	t:buffer("|abc")
	t:keys("g")
	local floats = t:floats()
	assert(#floats == 1, "one hint window")
	assert(string.find(floats[1], "g        Move to the start of the buffer", 1, true), floats[1])
	assert(string.find(floats[1], "e        Move to the end of the buffer", 1, true), floats[1])
	t:expect("|abc")
end)

test("hints go away when the sequence ends", function(t)
	t:buffer("ab|c")
	t:keys("g g")
	assert(#t:floats() == 0, "no hint window left")
	t:expect("|abc")

	t:keys("g x")
	assert(#t:floats() == 0, "an unbound sequence also hides them")
end)

test(
	"keys that start longer sequences say more, and commands without a doc show their name",
	function(t)
		kern.command({ name = "hint-test-nodoc", run = function() end })
		kern.keymap.bind("normal", { ["g q"] = "hint-test-nodoc" })
		t:buffer("|abc")
		t:keys("m")
		assert(string.find(t:floats()[1], "i        more...", 1, true), t:floats()[1])
		t:keys("esc g")
		assert(string.find(t:floats()[1], "q        hint-test-nodoc", 1, true), t:floats()[1])
	end
)

test("long key names keep the descriptions lined up", function(t)
	kern.keymap.bind("normal", { ["g ctrl-shift-home"] = "goto-start" })
	t:buffer("|abc")
	t:keys("g")
	local columns = {}
	for _, line in string.split(t:floats()[1], "\n") do
		local key, rest = string.match(line, "^(%S+)(%s+)")
		if key and rest then
			columns[#key + #rest] = true
		end
	end
	local count = 0
	for _ in columns do
		count += 1
	end
	assert(count == 1, "every description starts in the same column")
end)

test("f1 shows the keys of the mode you're in until the next command", function(t)
	t:buffer("|abc")
	t:keys("f1")
	local floats = t:floats()
	assert(#floats == 1 and string.find(floats[1], "Select the whole buffer", 1, true), floats[1])
	t:keys("l")
	assert(#t:floats() == 0, "gone with the next command")
	t:expect("a|bc")
end)

test("the first time in a mode with an intro, the status line says how to get out", function(t)
	local hints = require("@hints")
	hints.intro["hint-test"] = "you're in the test mode"
	t:buffer("|abc")
	kern.mode.set("hint-test")
	local messages = t:messages()
	assert(messages[#messages] == "you're in the test mode", messages[#messages])
	kern.mode.set("normal")
	kern.mode.set("hint-test")
	assert(#t:messages() == 0, "only once")
	kern.mode.set("normal")
end)
