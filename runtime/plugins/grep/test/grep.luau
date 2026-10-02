local test = require("@kern/test")
local kern = require("@kern")

local FILES = {
	[".git/HEAD"] = "",
	["a.txt"] = "foo bar\nbaz\n",
	["src/b.rs"] = "let foo = 1;\r\nfoo();\r\n",
}

local function text(): string
	return kern.view():buffer():text()
end

-- The file names shown above the excerpts.
local function headers(): { string }
	local out = {}
	for _, mark in kern.view():buffer():decorations("multibuffer.headers") do
		local lines = mark.lines :: { any }
		table.insert(out, lines[#lines][1].text)
	end
	return out
end

local function buffer_for(path: string): kern.Buffer?
	for _, buffer in kern.buffers() do
		if buffer:path() == path then
			return buffer
		end
	end
	return nil
end

test(":grep lists the matching lines under their files in a panel", function(t)
	local dir = t:tempdir(FILES)
	t:buffer("|x")
	t:run("grep", { "FOO", dir })
	assert(#t:messages() > 0)
	kern.run("grep-close")
	t:run("grep", { "foo", dir })
	assert(kern.view():buffer():kind() == "multibuffer", "the panel has focus")
	assert(text() == "3 lines match foo\nfoo bar\nlet foo = 1;\r\nfoo();\r\n", text())
	local shown = headers()
	assert(shown[1] == "a.txt:1" and shown[2] == "src/b.rs:1", table.concat(shown, " "))
end)

test("editing the results changes the files as you type, and :w saves them", function(t)
	local dir = t:tempdir(FILES)
	t:buffer("|x")
	t:run("grep", { "foo", dir })
	t:keys("% s f o o enter c q u x esc")
	local b = buffer_for(dir .. "/src/b.rs") :: kern.Buffer
	assert(
		b:text() == "let qux = 1;\r\nqux();\r\n",
		"changed in the editor, line endings kept: "
			.. string.format("%q", b:text())
			.. " mb "
			.. string.format("%q", text())
	)
	assert(kern.fs.read(dir .. "/a.txt") == "foo bar\nbaz\n", "not saved yet")
	t:run("save")
	assert(kern.fs.read(dir .. "/a.txt") == "qux bar\nbaz\n")
	assert(kern.fs.read(dir .. "/src/b.rs") == "let qux = 1;\r\nqux();\r\n")
	local messages = t:messages()
	assert(messages[#messages] == "saved 2 files", messages[#messages])
end)

test("a file changed on disk since the search is left alone", function(t)
	local dir = t:tempdir(FILES)
	t:buffer("|x")
	t:run("grep", { "foo bar", dir })
	kern.fs.write(dir .. "/a.txt", "changed meanwhile\nbaz\n")
	t:keys("% s f o o enter c q u x esc")
	local messages = t:messages()
	assert(string.find(messages[#messages], "a.txt", 1, true), messages[#messages])
	t:run("save")
	assert(kern.fs.read(dir .. "/a.txt") == "changed meanwhile\nbaz\n")
end)

test("enter opens the match under the cursor", function(t)
	local dir = t:tempdir(FILES)
	t:buffer("|x")
	t:run("grep", { "foo", dir })
	t:keys("j j w enter")
	assert(kern.view():buffer():path() == dir .. "/src/b.rs")
	t:expect("let |foo = 1;\r\nfoo();\r\n")
end)

test("space / searches the project as you type and enter goes to the match", function(t)
	local dir = t:tempdir(FILES)
	kern.open(dir .. "/a.txt")
	t:keys("space / = space 1")
	t:wait(100)
	t:keys("enter")
	assert(kern.view():buffer():path() == dir .. "/src/b.rs")
	t:expect("let foo |= 1;\r\nfoo();\r\n")
end)

test("ctrl-e in the search picker puts what it found in the results panel", function(t)
	local dir = t:tempdir(FILES)
	kern.open(dir .. "/a.txt")
	t:keys("space / 1 ;")
	t:wait(100)
	t:keys("ctrl-e")
	assert(text() == "1 line matches 1;\nlet foo = 1;\r\n", text())
end)

test("results closed some other way open in a new panel", function(t)
	local dir = t:tempdir(FILES)
	t:buffer("|x")
	t:run("grep", { "foo", dir })
	kern.view():close()
	t:run("grep", { "baz", dir })
	assert(kern.view():buffer():kind() == "multibuffer", "the new panel has focus")
	assert(text() == "1 line matches baz\nbaz\n", text())
	kern.run("grep-close")
end)
