local test = require("@kern/test")
local kern = require("@kern")

-- A git repository holding `files`, committed. Returns its folder.
local function repo(t: test.TestContext, files: { [string]: string }): string
	local dir = t:tempdir(files)
	local function git(...: string)
		local done = kern.process.run(
			{ "git", "-c", "user.name=t", "-c", "user.email=t@t", ... },
			{ cwd = dir }
		)
		assert(done and done.code == 0, done and done.stderr)
	end
	git("init", "-q")
	git("add", ".")
	git("commit", "-q", "-m", "first")
	return dir
end

-- Each line's sign, by 0-based line number.
local function signs(): { [number]: string }
	local buffer = kern.view():buffer()
	local out = {}
	for _, mark in buffer:decorations("vcs") do
		if mark.sign then
			out[buffer:line_of(mark.from)] = mark.sign
		end
	end
	return out
end

test("lines added, changed and removed since the last commit get signs", function(t)
	local dir = repo(t, { ["a.txt"] = "one\ntwo\nthree\nfour\n" })
	kern.open(dir .. "/a.txt")
	assert(next(signs()) == nil, "nothing changed yet")
	-- "one" becomes "ONE", "three" goes, and a line is added at the end.
	t:keys("e c O N E esc j j x d g e i n e w esc")
	t:wait(500)
	local s = signs()
	assert(s[0] == "~", "changed: " .. tostring(s[0]))
	assert(s[2] == "-", "removed above: " .. tostring(s[2]))
	assert(s[3] == "+", "added: " .. tostring(s[3]))
	assert(s[1] == nil, "untouched lines have no sign")
end)

test("] g and [ g go between changes, space g r puts one back", function(t)
	local dir = repo(t, { ["a.txt"] = "a\nb\nc\nd\ne\n" })
	kern.open(dir .. "/a.txt")
	t:keys("j e c B esc g g 4 j e c E esc")
	t:wait(500)
	t:keys("g g ] g")
	t:expect("a\n|B\nc\nd\nE\n")
	t:keys("] g")
	t:expect("a\nB\nc\nd\n|E\n")
	t:keys("[ g space g r")
	assert(kern.view():buffer():text() == "a\nb\nc\nd\nE\n", kern.view():buffer():text())
end)

test("a new file in a repository counts as added", function(t)
	local dir = repo(t, { ["a.txt"] = "a\n" })
	kern.fs.write(dir .. "/new.txt", "x\ny\n")
	kern.open(dir .. "/new.txt")
	t:wait(10)
	local s = signs()
	assert(s[0] == "+" and s[1] == "+", "every line added")
end)

test("files outside a repository get no signs", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a\n" })
	kern.open(dir .. "/a.txt")
	t:keys("x c z esc")
	t:wait(500)
	assert(next(signs()) == nil)
end)

test("with jj, changes are against the working copy's parent", function(t)
	if kern.which("jj") == nil then
		return
	end
	local dir = t:tempdir({ ["a.txt"] = "one\ntwo\n" })
	local function jj(...: string)
		local done = kern.process.run(
			{ "jj", "--config", "user.name=t", "--config", "user.email=t@t", ... },
			{ cwd = dir }
		)
		assert(done and done.code == 0, done and done.stderr)
	end
	jj("git", "init")
	jj("commit", "-m", "first")
	kern.open(dir .. "/a.txt")
	t:keys("j e c T W O esc")
	t:wait(500)
	local s = signs()
	assert(s[1] == "~" and s[0] == nil, "the changed line: " .. tostring(s[1]))
end)

test("space g b says who last changed the line", function(t)
	local dir = repo(t, { ["a.txt"] = "one\ntwo\n" })
	kern.open(dir .. "/a.txt")
	t:keys("j space g b")
	local messages = t:messages()
	assert(string.find(messages[#messages], "(t ", 1, true), messages[#messages])
end)
