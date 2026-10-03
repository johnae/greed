local test = require("@kern/test")

test("ctrl-h goes back through earlier selections and ctrl-k forward again", function(t)
	t:buffer("|one two three")
	t:keys("w w")
	t:expect("one ^two |three")
	t:keys("ctrl-h")
	t:expect("^one |two three")
	t:keys("ctrl-h")
	t:expect("|one two three")
	t:keys("ctrl-k ctrl-k")
	t:expect("one ^two |three")
end)

test("kept selections move with edits, and a new command drops the ones ahead", function(t)
	t:buffer("ab |one two")
	t:keys("w")
	t:expect("ab ^one |two")
	t:keys("g h i X esc")
	-- Back through the cursors around typing to the selection of "one ".
	local found = false
	for _ = 1, 5 do
		t:keys("ctrl-h")
		if t:marked() == "Xab ^one |two" then
			found = true
			break
		end
	end
	assert(found, "moved with the edit: " .. t:marked())
	t:keys("l")
	t:keys("ctrl-k")
	local messages = t:messages()
	assert(messages[#messages] == "no later selection", messages[#messages])
end)
