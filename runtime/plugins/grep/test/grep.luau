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

test(":grep lists the matching lines in a panel", function(t)
	local dir = t:tempdir(FILES)
	t:buffer("|x")
	kern.run("grep", { args = { "FOO", dir } })
	assert(#t:messages() > 0)
	kern.run("grep-close")
	kern.run("grep", { args = { "foo", dir } })
	assert(kern.view():buffer():kind() == "grep", "the panel has focus")
	assert(text() == "a.txt:1: foo bar\nsrc/b.rs:1: let foo = 1;\nsrc/b.rs:2: foo();", text())
end)

test("editing the results and saving writes the changes to the files", function(t)
	local dir = t:tempdir(FILES)
	t:buffer("|x")
	kern.run("grep", { args = { "foo", dir } })
	t:keys("% s f o o enter c q u x esc")
	t:run("save")
	assert(kern.fs.read(dir .. "/a.txt") == "qux bar\nbaz\n")
	assert(
		kern.fs.read(dir .. "/src/b.rs") == "let qux = 1;\r\nqux();\r\n",
		"line endings are kept"
	)
	local messages = t:messages()
	assert(messages[#messages] == "changed 3 lines in 2 files", messages[#messages])
end)

test("files open in the editor are edited there, and lines changed since are skipped", function(t)
	local dir = t:tempdir(FILES)
	kern.open(dir .. "/src/b.rs")
	kern.run("grep", { args = { "foo", dir } })
	kern.fs.write(dir .. "/a.txt", "foo changed\nbaz\n")
	t:keys("% s f o o enter c q u x esc")
	t:run("save")
	local b: kern.Buffer? = nil
	for _, buffer in kern.buffers() do
		if buffer:path() == dir .. "/src/b.rs" then
			b = buffer
		end
	end
	assert(b and b:text() == "let qux = 1;\r\nqux();\r\n" and not b:modified(), "edited and saved")
	assert(kern.fs.read(dir .. "/a.txt") == "foo changed\nbaz\n", "left alone")
	local messages = t:messages()
	local message = messages[#messages]
	assert(
		message == "changed 2 lines in 1 files; skipped 1 that changed since the search",
		message
	)
end)

test("enter opens the match under the cursor", function(t)
	local dir = t:tempdir(FILES)
	t:buffer("|x")
	kern.run("grep", { args = { "foo", dir } })
	t:keys("j enter")
	assert(kern.view():buffer():path() == dir .. "/src/b.rs")
	t:expect("let |foo = 1;\r\nfoo();\r\n")
end)

test("space / searches the project and enter goes to the match", function(t)
	local dir = t:tempdir(FILES)
	kern.open(dir .. "/a.txt")
	t:keys("space / = space 1 enter")
	t:keys("enter")
	assert(kern.view():buffer():path() == dir .. "/src/b.rs")
	t:expect("let foo |= 1;\r\nfoo();\r\n")
end)

test("ctrl-e in the search picker puts what matches in the results panel", function(t)
	local dir = t:tempdir(FILES)
	kern.open(dir .. "/a.txt")
	t:keys("space / f o o enter b . r s ctrl-e")
	assert(text() == "src/b.rs:1: let foo = 1;\nsrc/b.rs:2: foo();", text())
end)
