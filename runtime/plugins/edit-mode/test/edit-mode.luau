local kern = require("@kern")
local test = require("@kern/test")

local function check(t: test.TestContext, before: string, keys: string, after: string)
	t:buffer(before)
	kern.mode.set("edit")
	t:keys(keys)
	t:expect(after)
end

test("typing inserts, replacing any selection", function(t)
	check(t, "ab|c", "x y", "abxy|c")
	check(t, "^hello| world", "J", "J| world")
	check(t, "a|b a|b", "-", "a-|b a-|b")
end)

test("shift and arrows select", function(t)
	check(t, "|abc", "shift-right shift-right", "^ab|c")
	check(t, "one |two three", "ctrl-shift-right", "one ^two |three")
	check(t, "a|bc\nd", "shift-end", "a^bc|\nd")
end)

test("backspace and delete take the selection or one character", function(t)
	check(t, "ab|c", "backspace", "a|c")
	check(t, "ab|c", "delete", "ab|")
	check(t, "^abc|d", "backspace", "|d")
end)

test("copy, cut and paste", function(t)
	check(t, "^ab|c", "ctrl-c end ctrl-v", "abcab|")
	check(t, "^ab|c", "ctrl-x end ctrl-v", "cab|")
	check(t, "^ab|c", "ctrl-c esc shift-end ctrl-v", "abab|")
end)

test("typing in a row undoes in one step", function(t)
	check(t, "|", "h i space t h e r e ctrl-z", "|")
	check(t, "|", "h i left right x ctrl-z", "hi|")
end)

test("esc drops the selection", function(t)
	check(t, "^ab|c", "esc", "ab|c")
end)

test(":style edit makes edit mode the one to come back to", function(t)
	t:buffer("|abc")
	t:run("style", { "edit" })
	t:expect_mode("edit")
	t:keys("x")
	t:expect("x|abc")
	kern.option.set("editing-style", "helix")
	t:expect_mode("normal")
end)

test("ctrl-p, ctrl-b and ctrl-P open the pickers", function(t)
	for _, key in { "ctrl-p", "ctrl-b", "ctrl-P" } do
		t:buffer("|abc")
		kern.mode.set("edit")
		t:keys(key)
		assert(kern.view():buffer():kind() == "picker", key)
		t:keys("esc")
		t:expect_mode("edit")
	end
end)

test("enter, backspace and delete keep CRLF line breaks whole", function(t)
	t:buffer("a|b\r\ncd")
	kern.mode.set("edit")
	t:keys("enter")
	assert(kern.view():buffer():text() == "a\r\nb\r\ncd")
	t:keys("backspace backspace")
	assert(
		kern.view():buffer():text() == "b\r\ncd",
		string.format("%q", kern.view():buffer():text())
	)
	t:keys("end delete")
	assert(kern.view():buffer():text() == "bcd", string.format("%q", kern.view():buffer():text()))
end)
