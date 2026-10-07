local test = require("@greed/test")
local greed = require("@greed")
local operations = require("@operations")
local vcs = require("@vcs")

-- Each line's sign, by 0-based line number.
local function signs(): { [number]: string }
	local buffer = greed.view():buffer()
	local out = {}
	for _, mark in buffer:decorations("vcs") do
		if mark.sign then
			out[buffer:line_of(mark.from)] = mark.sign
		end
	end
	return out
end

test("lines added, changed and removed since the last commit get signs", function(t)
	local dir = t:repo("git", { ["a.txt"] = "one\ntwo\nthree\nfour\n" })
	greed.open(dir .. "/a.txt")
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
	local dir = t:repo("git", { ["a.txt"] = "a\nb\nc\nd\ne\n" })
	greed.open(dir .. "/a.txt")
	t:keys("j c B esc g g 4 j c E esc")
	t:wait(500)
	t:keys("g g ] g")
	t:expect("a\n|B\nc\nd\nE\n")
	t:keys("] g")
	t:expect("a\nB\nc\nd\n|E\n")
	t:keys("[ g space g r")
	assert(greed.view():buffer():text() == "a\nb\nc\nd\nE\n", greed.view():buffer():text())
end)

test("a new file in a repository counts as added", function(t)
	local dir = t:repo("git", { ["a.txt"] = "a\n" })
	greed.fs.write(dir .. "/new.txt", "x\ny\n")
	greed.open(dir .. "/new.txt")
	t:wait(10)
	local s = signs()
	assert(s[0] == "+" and s[1] == "+", "every line added")
	-- Only the signs are coloured, so the text keeps its highlighting.
	for _, mark in greed.view():buffer():decorations("vcs") do
		assert(mark.from == mark.to, "a sign covers no text")
	end
end)

test("a file whose last commit isn't text, like an image, gets no signs", function(t)
	local dir = t:repo("git", { ["icon.bin"] = "\x89PNG\r\n\x1a\n\0\0" })
	greed.fs.write(dir .. "/icon.bin", "now text\n")
	greed.open(dir .. "/icon.bin")
	t:wait(10)
	assert(next(signs()) == nil)
	assert(#greed.errors() == 0, greed.errors()[1] and greed.errors()[1].message)
end)

test("files outside a repository get no signs", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a\n" })
	greed.open(dir .. "/a.txt")
	t:keys("x c z esc")
	t:wait(500)
	assert(next(signs()) == nil)
end)

test("with jj, changes are against the working copy's parent", function(t)
	if greed.which("jj") == nil then
		return
	end
	local dir = t:repo("jj", { ["a.txt"] = "one\ntwo\n" })
	greed.open(dir .. "/a.txt")
	t:keys("j e c T W O esc")
	t:wait(500)
	local s = signs()
	assert(s[1] == "~" and s[0] == nil, "the changed line: " .. tostring(s[1]))
end)

test("space g b says who last changed the line", function(t)
	local dir = t:repo("git", { ["a.txt"] = "one\ntwo\n" })
	greed.open(dir .. "/a.txt")
	t:keys("j space g b")
	local messages = t:messages()
	assert(string.find(messages[#messages], "(t ", 1, true), messages[#messages])
end)

-- The changes view, once shown.
local function changes_view(): greed.Buffer?
	for _, buffer in greed.buffers() do
		if buffer:kind() == "multibuffer" then
			return buffer
		end
	end
	return nil
end

test("space g s shows every change not staged, removed lines where they were", function(t)
	local dir = t:repo("git", {
		["a.txt"] = "one\ntwo\nthree\nfour\nfive\nsix\nseven\n",
		["b.txt"] = "keep\n",
	})
	greed.project.open(dir)
	greed.fs.write(dir .. "/a.txt", "one\nTWO\nthree\nfour\nfive\nseven\n")
	greed.fs.write(dir .. "/c.txt", "brand new\n")
	t:buffer("|x")
	t:run("changes")
	local view = changes_view() :: greed.Buffer
	assert(view, "the changes view is open")
	local text = view:text()
	assert(string.find(text, "^3 changes in 2 files not staged\n"), text)
	assert(string.find(text, "TWO", 1, true) and string.find(text, "brand new", 1, true), text)
	assert(not string.find(text, "keep", 1, true), "unchanged files stay out")
	local removed = {}
	for _, mark in view:decorations("multibuffer.found") do
		local lines: { any } = mark.lines or {}
		for _, line in lines do
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
	greed.view():set_selection({ ranges = { { anchor = at, head = at } }, primary = 1 })
	t:keys("space g r")
	local file = greed.load(dir .. "/a.txt")
	assert(string.find(file:text(), "\ntwo\n", 1, true), file:text())
	local now = changes_view() :: greed.Buffer
	assert(string.find(now:text(), "^2 changes in 2 files", 1), now:text())
end)

test("space g s leaves out files that aren't text", function(t)
	local dir = t:repo("git", { ["a.txt"] = "one\n", ["icon.bin"] = "\x89PNG\r\n\x1a\n\0\0" })
	greed.project.open(dir)
	greed.fs.write(dir .. "/a.txt", "ONE\n")
	greed.fs.write(dir .. "/icon.bin", "\x89PNG\r\n\x1a\n\1\1")
	t:buffer("|x")
	t:run("changes")
	local view = changes_view() :: greed.Buffer
	assert(view, "the changes view is open")
	assert(string.find(view:text(), "^1 change in 1 file not staged\n"), view:text())
	assert(#greed.errors() == 0, greed.errors()[1] and greed.errors()[1].message)
end)

test("with nothing changed, it says so", function(t)
	local dir = t:repo("git", { ["a.txt"] = "one\n" })
	greed.project.open(dir)
	t:buffer("|x")
	t:run("changes")
	local messages = t:messages()
	assert(messages[#messages] == "nothing to stage", messages[#messages])
end)

test("with jj, the changes view shows the working copy's changes against its parent", function(t)
	if greed.which("jj") == nil then
		return
	end
	local dir = t:repo("jj", { ["a.txt"] = "one\ntwo\n", ["old.txt"] = "going\n" })
	greed.fs.write(dir .. "/a.txt", "one\ntwo\nthree\n")
	greed.fs.remove(dir .. "/old.txt")
	greed.project.open(dir)
	t:buffer("|x")
	t:run("changes")
	local view = changes_view() :: greed.Buffer
	local text = view:text()
	assert(string.find(text, "^1 change in 1 file since the working copy's parent\n"), text)
	assert(string.find(text, "three", 1, true), text)
end)

test("space u c commits just the latest operation's files, named after it", function(t)
	local dir, git = t:repo("git", { ["a.txt"] = "a\n", ["b.txt"] = "b\n" })
	greed.fs.write(dir .. "/b.txt", "mine\n")
	local a = greed.load(dir .. "/a.txt")
	t:buffer("|x")
	operations.run("change a", function()
		a:edit(function(e)
			e:insert(0, "A")
		end)
	end)
	t:keys("space u c")
	local messages = t:messages()
	assert(messages[#messages] == 'committed "change a"', messages[#messages])
	local log = git("log", "-1", "--format=%s", "--name-only")
	assert(log == "change a\n\na.txt\n", log)
	local status = git("status", "--porcelain")
	assert(status == " M b.txt\n", "b's change stays: " .. status)
end)

test("with jj, an operation commits as its own change", function(t)
	if greed.which("jj") == nil then
		return
	end
	local dir, jj = t:repo("jj", { ["a.txt"] = "a\n", ["b.txt"] = "b\n" })
	greed.fs.write(dir .. "/b.txt", "mine\n")
	local a = greed.load(dir .. "/a.txt")
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
	local dir = t:repo("git", { ["a.txt"] = "a\nb\nc\n" })
	greed.open(dir .. "/a.txt")
	t:keys("j c B esc")
	t:wait(500)
	t:keys("m a g")
	t:expect("a\n^B\n|c\n")
end)

test("changed_files lists the files changed since the last commit", function(t)
	local dir = t:repo("git", { ["a.txt"] = "a\n", ["b.txt"] = "b\n" })
	greed.fs.write(dir .. "/b.txt", "B\n")
	local files = require("@vcs").changed_files(dir) :: { string }
	assert(#files == 1 and string.match(files[1], "/b%.txt$"), table.concat(files, ", "))
end)

-- What git has staged, as a diff.
local function staged_diff(dir: string): string
	local done = greed.process.run({ "git", "diff", "--cached" }, { cwd = dir })
	return if done then done.stdout else ""
end

test("space g a stages just the change under the cursor, and its sign goes", function(t)
	local dir = t:repo("git", { ["a.txt"] = "a\nb\nc\nd\ne\n" })
	greed.open(dir .. "/a.txt")
	t:keys("c A esc g g 4 j c E esc")
	t:wait(500)
	t:keys("g g space g a")
	local staged = staged_diff(dir)
	assert(string.find(staged, "+A", 1, true), staged)
	assert(not string.find(staged, "+E", 1, true), "only that change: " .. staged)
	t:wait(500)
	local s = signs()
	assert(s[0] == nil and s[4] == "~", "signs count from what's staged")
	assert(greed.view():buffer():text() == "A\nb\nc\nd\nE\n", "the file is untouched")
end)

test("space g a in the changes view stages a change and the view follows", function(t)
	local dir = t:repo("git", { ["a.txt"] = "a\nb\nc\nd\ne\nf\ng\nh\n", ["b.txt"] = "x\n" })
	greed.project.open(dir)
	greed.fs.write(dir .. "/a.txt", "A\nb\nc\nd\ne\nf\ng\nH\n")
	greed.fs.write(dir .. "/b.txt", "X\n")
	t:buffer("|x")
	t:run("changes")
	local text = (changes_view() :: greed.Buffer):text()
	assert(string.find(text, "^3 changes in 2 files not staged\n"), text)
	local at = string.find(text, "\nH\n", 1, true) :: number
	greed.view():set_selection({ ranges = { { anchor = at, head = at } }, primary = 1 })
	t:keys("space g a")
	local staged = staged_diff(dir)
	assert(string.find(staged, "+H", 1, true) and not string.find(staged, "+A", 1, true), staged)
	local now = (changes_view() :: greed.Buffer):text()
	assert(string.find(now, "^2 changes in 2 files not staged; 1 file staged"), now)
end)

test("space g S shows what's staged; u unstages a hunk and c commits", function(t)
	local dir, git = t:repo("git", { ["a.txt"] = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n" })
	greed.project.open(dir)
	greed.fs.write(dir .. "/a.txt", "A\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nL\n")
	git("add", "a.txt")
	t:buffer("|x")
	t:keys("space g S")
	local view = greed.view()
	assert(view:buffer():kind() == "staged-diff", view:buffer():kind())
	local text = view:buffer():text()
	assert(string.find(text, "+A", 1, true) and string.find(text, "+L", 1, true), text)
	local at = (string.find(text, "+A", 1, true) :: number) - 1
	view:set_selection({ ranges = { { anchor = at, head = at } }, primary = 1 })
	t:keys("u")
	local staged = staged_diff(dir)
	assert(not string.find(staged, "+A", 1, true) and string.find(staged, "+L", 1, true), staged)
	assert(not string.find(view:buffer():text(), "+A", 1, true), "the view follows")
	t:keys("c o n l y space l enter")
	local log = git("log", "-1", "--format=%s")
	assert(log == "only l\n", log)
	local after = view:buffer():text()
	assert(string.find(after, "nothing staged", 1, true), after)
end)

test("with jj, space g a says to split instead", function(t)
	if greed.which("jj") == nil then
		return
	end
	local dir = t:repo("jj")
	greed.fs.write(dir .. "/a.txt", "one\n")
	greed.open(dir .. "/a.txt")
	t:keys("c O N E esc")
	t:wait(500)
	t:keys("space g a")
	local messages = t:messages()
	assert(string.find(messages[#messages], "jj has no staging", 1, true), messages[#messages])
end)

test("space g w shows the commits that made the selected lines", function(t)
	local dir, git = t:repo("git", { ["a.txt"] = "one\ntwo\nthree\nfour\n" })
	greed.fs.write(dir .. "/a.txt", "one\nTWO\nthree\n")
	git("commit", "-q", "-am", "shout two")
	greed.open(dir .. "/a.txt")
	t:keys("j space g w")
	local text = greed.view():buffer():text()
	assert(string.find(text, "^Why line 2 of a.txt are as they are"), text)
	assert(string.find(text, "shout two", 1, true) and string.find(text, "first", 1, true), text)
	assert(string.find(text, "+TWO", 1, true), text)
	-- Agents get the same.
	local why = vcs.why
	local same = why.history(dir .. "/a.txt", 2, 2) :: string
	assert(string.find(same, "shout two", 1, true), same)
end)

test("with jj, the changes that last touched the lines, newest first", function(t)
	if greed.which("jj") == nil then
		return
	end
	local dir, jj = t:repo("jj", { ["a.txt"] = "one\ntwo\n" })
	greed.fs.write(dir .. "/a.txt", "one\nTWO\n")
	jj("commit", "-m", "shout two")
	greed.open(dir .. "/a.txt")
	t:keys("x x space g w")
	local text = greed.view():buffer():text()
	assert(string.find(text, "^Why lines 1%-2 of a.txt are as they are"), text)
	local newest = string.find(text, "shout two", 1, true) :: number
	local oldest = string.find(text, "first", 1, true) :: number
	assert(newest and oldest and newest < oldest, text)
end)

test("the status line shows the branch and the lines changed in the file", function(t)
	local dir, git = t:repo("git", { ["a.txt"] = "one\ntwo\nthree\nfour\n" })
	git("checkout", "-q", "-b", "topic")
	greed.open(dir .. "/a.txt")
	t:wait(300)
	local _, right = t:status()
	assert(right and string.find(right, " topic ", 1, true), right)
	-- "one" changes, "three" goes, and a line is added at the end.
	t:keys("e c O N E esc j j x d g e o n e w esc")
	t:wait(500)
	_, right = t:status()
	assert(right and string.find(right, " topic +1 ~1 -1 ", 1, true), right)
end)

test("with jj, the status line shows the nearest bookmark and the change", function(t)
	if greed.which("jj") == nil then
		return
	end
	local dir, jj = t:repo("jj", { ["a.txt"] = "one\n" })
	jj("bookmark", "create", "-r", "@-", "trunk")
	greed.open(dir .. "/a.txt")
	t:wait(300)
	local _, right = t:status()
	assert(right and string.match(right, " trunk · %w+ "), right)
end)
