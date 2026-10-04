local test = require("@greed/test")
local greed = require("@greed")

type Jj = (...string) -> string

-- A jj repository with the changes "first", "second" and "third", each
-- adding a file, and an empty working copy on top. Returns a way to run jj
-- in it.
local function repo(t: test.TestContext): Jj
	local dir = t:tempdir({})
	local function jj(...: string): string
		local done = greed.process.run({
			"jj",
			"--config",
			"user.name=t",
			"--config",
			"user.email=t@t",
			"--color",
			"never",
			...,
		}, { cwd = dir })
		assert(done and done.code == 0, done and done.stderr)
		return done.stdout
	end
	jj("git", "init")
	for _, name in { "first", "second", "third" } do
		greed.fs.write(`{dir}/{name}.txt`, name .. "\n")
		jj("commit", "-m", name)
	end
	greed.project.open(dir)
	return jj
end

-- The descriptions from the working copy down, as jj has them.
local function descriptions(jj: Jj): { string }
	local out = {}
	for line in
		string.gmatch(
			jj("log", "--no-graph", "-r", "::@ ~ root()", "-T", 'description.first_line() ++ "\\n"'),
			"([^\n]*)\n"
		)
	do
		table.insert(out, if line == "" then "-" else line)
	end
	return out
end

-- The stack's lines, below its header.
local function rows(): { string }
	local lines = string.split(greed.view():buffer():text(), "\n")
	return { table.unpack(lines, 3) }
end

-- The line the cursor is on.
local function line(): string
	local view = greed.view()
	local buffer = view:buffer()
	local n = buffer:line_of(view:selection().ranges[1].head)
	return string.split(buffer:text(), "\n")[n + 1]
end

local function has_jj(): boolean
	return greed.which("jj") ~= nil
end

test("space g l lists the changes down from the working copy, cursor on it", function(t)
	if not has_jj() then
		return
	end
	repo(t)
	t:buffer("|x")
	t:keys("space g l")
	local r = rows()
	assert(#r == 4, table.concat(r, "\n"))
	assert(string.match(r[1], "^@ %w+ %(empty%) %(no description%)$"), r[1])
	assert(string.match(r[2], "^○ %w+ third$"), r[2])
	assert(string.match(r[4], "^○ %w+ first$"), r[4])
	assert(string.match(line(), "^@"), "the cursor is on the working copy")
	t:keys("q")
	assert(greed.view():buffer():text() == "x", "q goes back")
end)

test("d describes the change under the cursor", function(t)
	if not has_jj() then
		return
	end
	local jj = repo(t)
	t:keys("space g l d f o u r t h enter")
	assert(descriptions(jj)[1] == "fourth", descriptions(jj)[1])
	assert(string.match(rows()[1], "fourth$"), rows()[1])
end)

test("s squashes into the parent, a abandons after asking, u undoes", function(t)
	if not has_jj() then
		return
	end
	local jj = repo(t)
	t:keys("space g l j s")
	assert(
		table.concat(descriptions(jj), ",") == "-,second,first",
		table.concat(descriptions(jj), ",")
	)
	assert(
		string.find(jj("file", "list", "-r", "@-"), "third.txt", 1, true),
		"third's file went into second"
	)
	t:keys("u")
	assert(table.concat(descriptions(jj), ",") == "-,third,second,first")
	t:keys("j a n")
	assert(#descriptions(jj) == 4, "n keeps it")
	t:keys("j a y")
	assert(
		table.concat(descriptions(jj), ",") == "-,third,first",
		table.concat(descriptions(jj), ",")
	)
end)

test("alt-k and alt-j move a change through the stack, the cursor with it", function(t)
	if not has_jj() then
		return
	end
	local jj = repo(t)
	t:keys("space g l j j j")
	assert(string.match(line(), "first$"))
	t:keys("alt-k")
	assert(
		table.concat(descriptions(jj), ",") == "-,third,first,second",
		table.concat(descriptions(jj), ",")
	)
	assert(string.match(line(), "first$"), "the cursor follows: " .. line())
	t:keys("alt-j")
	assert(
		table.concat(descriptions(jj), ",") == "-,third,second,first",
		table.concat(descriptions(jj), ",")
	)
end)

test("enter shows a change's diff and q goes back to the stack", function(t)
	if not has_jj() then
		return
	end
	repo(t)
	t:keys("space g l j j enter")
	local text = greed.view():buffer():text()
	assert(string.find(text, "+++ b/second.txt", 1, true), text)
	assert(string.find(text, "\n+second", 1, true), text)
	t:keys("q")
	assert(string.match(line(), "second$"), "back on the same change: " .. line())
end)

test("n starts a change on the one under the cursor, e edits one", function(t)
	if not has_jj() then
		return
	end
	local jj = repo(t)
	t:keys("space g l j e")
	assert(string.match(line(), "^@ %w+ third$"), line())
	assert(#rows() == 3, "jj dropped the empty working copy it left")
	t:keys("j n")
	assert(string.match(line(), "^@ %w+ %(empty%)"), line())
	local parent = jj("log", "--no-graph", "-r", "@-", "-T", "description")
	assert(string.match(parent, "^second"), parent)
end)

test("? lists the keys and runs the one picked", function(t)
	if not has_jj() then
		return
	end
	local jj = repo(t)
	t:keys("space g l j ?")
	local menu = t:floats()[1]
	assert(string.find(menu, "s     Squash it into its parent", 1, true), menu)
	assert(string.find(menu, "u     Undo the last jj operation", 1, true), menu)
	t:keys("s")
	t:wait(0)
	assert(#t:floats() == 0)
	assert(#descriptions(jj) == 3, table.concat(descriptions(jj), ","))
end)

test("in a git repository it lists commits and shows them", function(t)
	local dir = t:tempdir({ ["a.txt"] = "a\n" })
	local function git(...: string)
		local done = greed.process.run(
			{ "git", "-c", "user.name=t", "-c", "user.email=t@t", ... },
			{ cwd = dir }
		)
		assert(done and done.code == 0, done and done.stderr)
	end
	git("init", "-q")
	git("add", ".")
	git("commit", "-q", "-m", "first")
	greed.project.open(dir)
	t:keys("space g l")
	assert(string.match(rows()[1], "^@ %x+ .*first$"), rows()[1])
	t:keys("s")
	local messages = t:messages()
	assert(messages[#messages] == "that needs a jj repository", messages[#messages])
	t:keys("enter")
	assert(string.find(greed.view():buffer():text(), "+a", 1, true) ~= nil)
end)
