local greed = require("@greed")
local test = require("@greed/test")

local function check(t: test.TestContext, before: string, keys: string, after: string)
	t:buffer(before)
	greed.mode.set("vscode")
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

test(":style vscode makes its mode the one to come back to", function(t)
	t:buffer("|abc")
	t:run("style", { "vscode" })
	t:expect_mode("vscode")
	t:keys("x")
	t:expect("x|abc")
	greed.option.set("editing-style", "helix")
	t:expect_mode("helix")
end)

test("ctrl-p, ctrl-b and ctrl-P open the pickers", function(t)
	for _, key in { "ctrl-p", "ctrl-b", "ctrl-P" } do
		t:buffer("|abc")
		greed.mode.set("vscode")
		t:keys(key)
		assert(greed.view():buffer():kind() == "picker", key)
		t:keys("esc")
		t:expect_mode("vscode")
	end
end)

test("enter, backspace and delete keep CRLF line breaks whole", function(t)
	t:buffer("a|b\r\ncd")
	greed.mode.set("vscode")
	t:keys("enter")
	assert(greed.view():buffer():text() == "a\r\nb\r\ncd")
	t:keys("backspace backspace")
	assert(
		greed.view():buffer():text() == "b\r\ncd",
		string.format("%q", greed.view():buffer():text())
	)
	t:keys("end delete")
	assert(greed.view():buffer():text() == "bcd", string.format("%q", greed.view():buffer():text()))
end)

test("page down and page up move a screen", function(t)
	local lines = {}
	for i = 0, 49 do
		table.insert(lines, `line {i}`)
	end
	t:buffer("|" .. table.concat(lines, "\n"))
	greed.mode.set("vscode")
	t:draw(40, 11)
	t:keys("pagedown")
	assert(greed.view():scroll() == 10, tostring(greed.view():scroll()))
	t:keys("pageup")
	assert(greed.view():scroll() == 0)
end)

test("tab indents selected lines, or types a level of indent; shift-tab dedents", function(t)
	check(t, "^ab\ncd|", "tab", "^    ab\n    cd|")
	check(t, "a|b", "tab", "a    |b")
	check(t, "^ab| c", "tab", "    | c")
	check(t, "    a|b", "shift-tab", "a|b")
end)

test("with nothing selected, copy and cut take the line, and paste puts it above", function(t)
	check(t, "a|b\ncd", "ctrl-c down ctrl-v", "ab\nab\nc|d")
	check(t, "a|b\ncd", "ctrl-x", "|cd")
	check(t, "a|b\ncd", "ctrl-x ctrl-v", "ab\n|cd")
end)

test("home goes to the first non-blank, then the line's start", function(t)
	check(t, "  ab|c", "home", "  |abc")
	check(t, "  ab|c", "home home", "|  abc")
	check(t, "  ab|c", "shift-home", "  |ab^c")
end)

test("alt-up and alt-down move lines, alt-shift copies them", function(t)
	check(t, "a\nb|b\nc", "alt-up", "b|b\na\nc")
	check(t, "a\nb|b\nc", "alt-down", "a\nc\nb|b")
	check(t, "a\nb|b\nc", "alt-shift-down", "a\nbb\nb|b\nc")
	check(t, "a\nb|b\nc", "alt-shift-up", "a\nb|b\nbb\nc")
	check(t, "a\nb|b\nc", "ctrl-K", "a\n|c")
end)

test("ctrl-l selects lines, ctrl-enter opens a line below", function(t)
	check(t, "a|b\ncd\nef", "ctrl-l", "^ab\n|cd\nef")
	check(t, "a|b\ncd\nef", "ctrl-l ctrl-l", "^ab\ncd\n|ef")
	check(t, "a|b\ncd", "ctrl-enter x", "ab\nx|\ncd")
	check(t, "a|b\ncd", "ctrl-shift-enter x", "x|\nab\ncd")
end)

test("ctrl-d selects the word, then adds the next match", function(t)
	check(t, "f|oo bar foo", "ctrl-d", "^foo| bar foo")
	check(t, "f|oo bar foo", "ctrl-d ctrl-d", "^foo| bar ^foo|")
	check(t, "f|oo bar foo foo", "ctrl-L", "^foo| bar ^foo| ^foo|")
end)

test("switching to the vscode style says where commands are", function(t)
	t:buffer("|")
	greed.option.set("editing-style", "vscode")
	local messages = t:messages()
	assert(string.find(messages[#messages], "ctrl-P", 1, true), messages[#messages])
	greed.option.set("editing-style", "helix")
end)

test("ctrl-q with unsaved changes asks to save, not save or cancel", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a" })
	greed.open(dir .. "/a.txt")
	greed.mode.set("vscode")
	t:keys("x ctrl-q")
	local shown = t:floats()[1]
	assert(string.find(shown, "Save, then quit", 1, true), shown)
	t:keys("esc")
	assert(not t:quitting() and #t:floats() == 0, "cancelled")
	t:keys("ctrl-q s")
	assert(greed.fs.read(dir .. "/a.txt") == "xa")
	assert(t:quitting())
end)

-- The whole screen, where the find bar shows its label.
local function screen(t: test.TestContext): string
	return table.concat(t:screen(80, 12), "\n")
end

-- The text `view` has selected and where it starts, for the file while a
-- bar has focus.
local function selected(view: greed.View): (string, number)
	local selection = view:selection()
	local range = selection.ranges[selection.primary]
	local from, to = math.min(range.anchor, range.head), math.max(range.anchor, range.head)
	return view:buffer():slice(from, to), from
end

-- Opens `text` (with "|" for the cursor) in the vscode style, and returns
-- its view.
local function file(t: test.TestContext, text: string): greed.View
	t:buffer(text)
	greed.mode.set("vscode")
	return greed.view()
end

test(
	"ctrl-f finds as you type; enter and shift-enter go on with the bar open, esc closes",
	function(t)
		local view = file(t, "|foo bar Foo baz foo")
		t:keys("ctrl-f f o o")
		assert(select(2, selected(view)) == 0)
		assert(string.find(screen(t), "1 of 3", 1, true), screen(t))
		t:keys("enter")
		local text, at = selected(view)
		assert(text == "Foo" and at == 8, `{text} at {at}`)
		assert(#t:floats() == 1, "the bar stays open")
		assert(string.find(screen(t), "2 of 3", 1, true), screen(t))
		t:keys("enter enter")
		assert(select(2, selected(view)) == 0, "round the end")
		t:keys("shift-enter")
		assert(select(2, selected(view)) == 16, "and back")
		t:keys("esc")
		assert(#t:floats() == 0, "esc closes it")
		t:expect("foo bar Foo baz ^foo|")
		t:expect_mode("vscode")
		-- f3 goes on from there.
		t:keys("f3")
		t:expect("^foo| bar Foo baz foo")
	end
)

test("ctrl-f finds text as written, brackets and all, and says when there's none", function(t)
	local view = file(t, "|f(x) f(y)")
	t:keys("ctrl-f ( y")
	local text, at = selected(view)
	assert(text == "(y" and at == 6, `{text} at {at}`)
	t:keys("backspace backspace z")
	assert(string.find(screen(t), "No results", 1, true), screen(t))
	t:keys("esc")
end)

test("ctrl-f starts with the selected text", function(t)
	local view = file(t, "^ab| x ab")
	t:keys("ctrl-f enter")
	assert(select(2, selected(view)) == 5)
	t:keys("esc")
end)

test("ctrl-h counts the matches, then replaces them all as one change", function(t)
	local view = file(t, "|a.b a.b ab")
	t:keys("ctrl-h a . b")
	assert(string.find(screen(t), "2 matches", 1, true), screen(t))
	t:keys("enter")
	assert(string.find(screen(t), "replace 2 matches of a.b with", 1, true), screen(t))
	t:keys("x enter")
	assert(view:buffer():text() == "x x ab", view:buffer():text())
	t:expect_mode("vscode")
	t:keys("ctrl-z")
	assert(view:buffer():text() == "a.b a.b ab", "one undo step")
end)

test("ctrl-w shows the file you were in before, as closing an editor tab does", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a", ["b.txt"] = "b", ["c.txt"] = "c" })
	greed.mode.set("vscode")
	for _, name in { "a", "b", "c", "a" } do
		greed.open(`{dir}/{name}.txt`)
		t:keys("end")
	end
	t:keys("ctrl-w")
	assert(greed.view():buffer():path() == dir .. "/c.txt", greed.view():buffer():path())
end)

test("ctrl-k starts VS Code's chords, and never deletes to the line's end", function(t)
	check(t, "a|bc", "ctrl-k esc", "a|bc")
	assert(greed.keymap.resolve("ctrl-k ctrl-0") == "fold-close-all")
	assert(greed.keymap.resolve("ctrl-k s") == "save-all")
	local _, more = greed.keymap.resolve("ctrl-k")
	assert(more, "ctrl-k waits for the rest")
	assert(greed.keymap.resolve("ctrl-\\") == "pane-split-right")
end)
