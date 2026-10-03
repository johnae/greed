local test = require("@kern/test")
local kern = require("@kern")
local operations = require("@operations")
local vcs = require("@vcs")

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
	t:keys("e c O N E esc j j x d g e o n e w esc")
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
	t:keys("j c B esc g g 4 j c E esc")
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
	-- Only the signs are coloured, so the text keeps its highlighting.
	for _, mark in kern.view():buffer():decorations("vcs") do
		assert(mark.from == mark.to, "a sign covers no text")
	end
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

-- The changes view, once shown.
local function changes_view(): kern.Buffer?
	for _, buffer in kern.buffers() do
		if buffer:kind() == "multibuffer" then
			return buffer
		end
	end
	return nil
end

test(
	"space g s shows every change since the last commit, removed lines where they were",
	function(t)
		local dir = repo(t, {
			["a.txt"] = "one\ntwo\nthree\nfour\nfive\nsix\nseven\n",
			["b.txt"] = "keep\n",
		})
		kern.project.open(dir)
		kern.fs.write(dir .. "/a.txt", "one\nTWO\nthree\nfour\nfive\nseven\n")
		kern.fs.write(dir .. "/c.txt", "brand new\n")
		t:buffer("|x")
		t:run("changes")
		local view = changes_view() :: kern.Buffer
		assert(view, "the changes view is open")
		local text = view:text()
		assert(string.find(text, "^3 changes in 2 files since HEAD\n"), text)
		assert(string.find(text, "TWO", 1, true) and string.find(text, "brand new", 1, true), text)
		assert(not string.find(text, "keep", 1, true), "unchanged files stay out")
		local removed = {}
		for _, mark in view:decorations("multibuffer.found") do
			for _, line in mark.lines or {} do
				table.insert(removed, line)
			end
		end
		table.sort(removed)
		assert(
			table.concat(removed, ",") == "six,two",
			"removed lines show: " .. table.concat(removed, ",")
		)

		-- space g r puts the change under the cursor back, and the view follows.
		local at = (string.find(text, "TWO", 1, true) :: number) - 1
		kern.view():set_selection({ ranges = { { anchor = at, head = at } }, primary = 1 })
		t:keys("space g r")
		local file = kern.load(dir .. "/a.txt")
		assert(string.find(file:text(), "\ntwo\n", 1, true), file:text())
		local now = changes_view() :: kern.Buffer
		assert(string.find(now:text(), "^2 changes in 2 files", 1), now:text())
	end
)

test("with nothing changed, it says so", function(t)
	local dir = repo(t, { ["a.txt"] = "one\n" })
	kern.project.open(dir)
	t:buffer("|x")
	t:run("changes")
	local messages = t:messages()
	assert(messages[#messages] == "nothing changed since HEAD", messages[#messages])
end)

test("with jj, the changes view shows the working copy's changes against its parent", function(t)
	if kern.which("jj") == nil then
		return
	end
	local dir = t:tempdir({ ["a.txt"] = "one\ntwo\n", ["old.txt"] = "going\n" })
	local function jj(...: string)
		local done = kern.process.run(
			{ "jj", "--config", "user.name=t", "--config", "user.email=t@t", ... },
			{ cwd = dir }
		)
		assert(done and done.code == 0, done and done.stderr)
	end
	jj("git", "init")
	jj("commit", "-m", "first")
	kern.fs.write(dir .. "/a.txt", "one\ntwo\nthree\n")
	kern.process.run({ "rm", dir .. "/old.txt" })
	kern.project.open(dir)
	t:buffer("|x")
	t:run("changes")
	local view = changes_view() :: kern.Buffer
	local text = view:text()
	assert(string.find(text, "^1 change in 1 file since the working copy's parent\n"), text)
	assert(string.find(text, "three", 1, true), text)
end)

test("space u c commits just the latest operation's files, named after it", function(t)
	local dir = repo(t, { ["a.txt"] = "a\n", ["b.txt"] = "b\n" })
	kern.fs.write(dir .. "/b.txt", "mine\n")
	local a = kern.load(dir .. "/a.txt")
	t:buffer("|x")
	operations.run("change a", function()
		a:edit(function(e)
			e:insert(0, "A")
		end)
	end)
	t:keys("space u c")
	local messages = t:messages()
	assert(messages[#messages] == 'committed "change a"', messages[#messages])
	local log = kern.process.run(
		{ "git", "log", "-1", "--format=%s", "--name-only" },
		{ cwd = dir }
	)
	assert(log and string.find(log.stdout, "^change a\n\na.txt\n$"), log and log.stdout)
	local status = kern.process.run({ "git", "status", "--porcelain" }, { cwd = dir })
	assert(
		status and status.stdout == " M b.txt\n",
		"b's change stays: " .. (status and status.stdout or "")
	)
end)

test("with jj, an operation commits as its own change", function(t)
	if kern.which("jj") == nil then
		return
	end
	local dir = t:tempdir({ ["a.txt"] = "a\n", ["b.txt"] = "b\n" })
	local function jj(...: string): string
		local done = kern.process.run(
			{ "jj", "--config", "user.name=t", "--config", "user.email=t@t", ... },
			{ cwd = dir }
		)
		assert(done and done.code == 0, done and done.stderr)
		return done.stdout
	end
	jj("git", "init")
	jj("commit", "-m", "first")
	kern.fs.write(dir .. "/b.txt", "mine\n")
	local a = kern.load(dir .. "/a.txt")
	t:buffer("|x")
	local op = operations.run("change a", function()
		a:edit(function(e)
			e:insert(0, "A")
		end)
	end)
	local ok, why = vcs.commit({ op.files[1].path }, op.name)
	assert(ok, why)
	assert(jj("log", "--no-graph", "-r", "@-", "-T", "description") == "change a\n")
	assert(string.find(jj("diff", "-s", "-r", "@-"), "a.txt", 1, true) ~= nil)
	assert(string.find(jj("diff", "-s"), "b.txt", 1, true), "b's change stays in the working copy")
end)

test("m i g selects the change under the cursor, m a g its lines", function(t)
	local dir = repo(t, { ["a.txt"] = "a\nb\nc\n" })
	kern.open(dir .. "/a.txt")
	t:keys("j c B esc")
	t:wait(500)
	t:keys("m a g")
	t:expect("a\n^B\n|c\n")
end)
