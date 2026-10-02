local test = require("@kern/test")
local kern = require("@kern")
local multibuffer = require("@multibuffer")

local function buffer_for(path: string): kern.Buffer?
	for _, buffer in kern.buffers() do
		if buffer:path() == path then
			return buffer
		end
	end
	return nil
end

-- A multibuffer of lines 1-2 of a.txt and line 0 of b.txt, shown and
-- focused, with the cursor on line `at`.
local function setup(t: test.TestContext, at: number): (string, kern.Buffer)
	local dir = t:tempdir({ ["a.txt"] = "zero\none\ntwo\nthree\n", ["b.txt"] = "only" })
	t:buffer("|x")
	local buffer = multibuffer.open({
		{ path = dir .. "/a.txt", from = 1, to = 2 },
		{ path = dir .. "/b.txt", from = 0 },
	}, { summary = "two files" })
	local view = kern.view()
	view:show(buffer)
	local pos = buffer:line_start(at)
	view:set_selection({ ranges = { { anchor = pos, head = pos } }, primary = 1 })
	return dir, buffer
end

test("excerpts show under a summary, each file's name above its lines", function(t)
	local _, buffer = setup(t, 0)
	assert(buffer:text() == "two files\none\ntwo\nonly\n", buffer:text())
	local headers = buffer:decorations("multibuffer.headers")
	assert(#headers == 2, `{#headers} headers`)
	assert(not buffer:line_numbers(), "its own line numbers are hidden")
	local numbers = buffer:decorations("multibuffer.numbers")
	assert(numbers[1].text == "2 " and numbers[3].text == "1 ", numbers[1].text)
end)

test("typing in an excerpt edits its file as you go, even at the excerpt's edges", function(t)
	local dir = setup(t, 1)
	t:keys("i > space esc")
	local a = buffer_for(dir .. "/a.txt") :: kern.Buffer
	assert(a and a:text() == "zero\n> one\ntwo\nthree\n", a and a:text())
	t:keys("j A ! esc")
	assert(a:text() == "zero\n> one\ntwo!\nthree\n", a:text())
	-- A new line at the end of an excerpt belongs to it.
	t:keys("o n e w esc")
	assert(a:text() == "zero\n> one\ntwo!\nnew\nthree\n", a:text())
	-- The file's last line has no line break; the multibuffer doesn't add one.
	t:keys("j A ? esc")
	local b = buffer_for(dir .. "/b.txt") :: kern.Buffer
	assert(b:text() == "only?", b:text())
	t:keys("u")
	assert(
		b:text() == "only",
		"undo in the multibuffer undoes in the file: "
			.. string.format("%q", b:text())
			.. " mb "
			.. string.format("%q", kern.view():buffer():text())
	)
end)

test("a file edited elsewhere shows the change in its excerpt", function(t)
	local dir, buffer = setup(t, 1)
	t:keys("i x esc u")
	local a = buffer_for(dir .. "/a.txt") :: kern.Buffer
	a:edit(function(e)
		e:insert(0, "new first line\n")
	end)
	a:edit(function(e)
		e:insert(a:line_start(2), "1: ")
	end)
	assert(buffer:text() == "two files\n1: one\ntwo\nonly\n", buffer:text())
	assert(buffer:decorations("multibuffer.numbers")[1].text == "3 ", "line numbers follow")
end)

test("deleting an excerpt's lines deletes them from the file", function(t)
	local dir = setup(t, 1)
	t:keys("x x d")
	local a = buffer_for(dir .. "/a.txt") :: kern.Buffer
	assert(a:text() == "zero\nthree\n", a:text())
end)

test("enter goes to the line in its file, and :w saves what changed", function(t)
	local dir = setup(t, 2)
	t:keys("w")
	t:keys("i 2 esc")
	t:run("save")
	assert(
		kern.fs.read(dir .. "/a.txt") == "zero\none\n2two\nthree\n",
		(kern.fs.read(dir .. "/a.txt"))
	)
	t:keys("enter")
	assert(kern.view():buffer():path() == dir .. "/a.txt")
	t:expect("zero\none\n2|two\nthree\n")
end)

test("excerpts that touch are joined, and context adds lines around them", function(t)
	local dir = t:tempdir({ ["a.txt"] = "0\n1\n2\n3\n4\n5\n" })
	local buffer = multibuffer.open({
		{ path = dir .. "/a.txt", from = 1 },
		{ path = dir .. "/a.txt", from = 2 },
		{ path = dir .. "/a.txt", from = 5 },
	}, { summary = "s" })
	assert(buffer:text() == "s\n1\n2\n5\n", buffer:text())
	local wide = multibuffer.open(
		{ { path = dir .. "/a.txt", from = 2 } },
		{ summary = "s", context = 1 }
	)
	assert(wide:text() == "s\n1\n2\n3\n", wide:text())
end)
