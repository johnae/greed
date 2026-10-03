local test = require("@greed/test")
local greed = require("@greed")
local restore = require("@restore")

-- Pretends the editor runs as session "work", so there's a file to keep.
local function session(): string
	restore.name = function()
		return "work"
	end
	return `{greed.fs.dirs().cache}/sessions/work.json`
end

local function saved(path: string): any
	local text = greed.fs.read(path)
	assert(text, "nothing was written")
	return greed.json.decode(text)
end

local function remember(path: string, value: any)
	greed.fs.write(path, greed.json.encode(value))
end

local function open_paths(): { [string]: boolean }
	local paths = {}
	for _, buffer in greed.buffers() do
		local path = buffer:path()
		if path then
			paths[path] = true
		end
	end
	return paths
end

local function cursor(): number
	return greed.view():selection().ranges[1].head
end

test("quitting writes down each project's open files and the cursor", function(t)
	local file = session()
	local dir = t:tempdir({ ["a.txt"] = "one\ntwo\n", ["b.txt"] = "three\n" })
	greed.open(dir .. "/b.txt")
	greed.open(dir .. "/a.txt")
	t:keys("j")
	t:run("quit")
	assert(t:quitting())
	local state = saved(file)
	local project = state.projects[1]
	assert(state.current == greed.project.current().root, state.current)
	assert(#project.files == 2, tostring(#project.files))
	assert(project.files[1] == dir .. "/a.txt" and project.files[2] == dir .. "/b.txt")
	assert(project.shown == dir .. "/a.txt", project.shown)
	assert(project.cursor == 4, tostring(project.cursor))
end)

test("saving a file writes it down too", function(t)
	local file = session()
	local dir = t:tempdir({ ["a.txt"] = "one\n" })
	greed.open(dir .. "/a.txt")
	t:run("save")
	assert(saved(file).projects[1].shown == dir .. "/a.txt")
end)

test("without a session nothing is written", function(t)
	local dir = t:tempdir({ ["a.txt"] = "one\n" })
	greed.open(dir .. "/a.txt")
	t:run("quit")
	assert(greed.fs.stat(`{greed.fs.dirs().cache}/sessions`) == nil)
end)

test("starting again opens the files, showing the one shown with its cursor", function(t)
	local file = session()
	local dir = t:tempdir({ ["a.txt"] = "one\ntwo\n", ["b.txt"] = "three\n" })
	local root = greed.project.current().root
	remember(file, {
		current = root,
		projects = {
			{
				root = root,
				files = { dir .. "/a.txt", dir .. "/b.txt", dir .. "/gone.txt" },
				shown = dir .. "/a.txt",
				cursor = 4,
			},
		},
	})
	restore.restore()
	local paths = open_paths()
	assert(paths[dir .. "/a.txt"] and paths[dir .. "/b.txt"], "both files are open")
	assert(not paths[dir .. "/gone.txt"], "a deleted file is skipped")
	assert(greed.view():buffer():path() == dir .. "/a.txt")
	assert(cursor() == 4, tostring(cursor()))
end)

test("a file the session started with stays shown, in its project", function(t)
	local file = session()
	local dir = t:tempdir({ ["a.txt"] = "one\n", ["b.txt"] = "two\n" })
	local other = t:tempdir({ ["c.txt"] = "three\n" })
	local root = greed.project.current().root
	greed.open(dir .. "/b.txt")
	remember(file, {
		current = other,
		projects = {
			{ root = root, files = { dir .. "/a.txt" }, shown = dir .. "/a.txt", cursor = 0 },
			{ root = other, files = { other .. "/c.txt" }, shown = other .. "/c.txt", cursor = 0 },
		},
	})
	restore.restore()
	assert(open_paths()[dir .. "/a.txt"], "the other file is open too")
	assert(greed.project.current().root == root, greed.project.current().root)
	assert(greed.view():buffer():path() == dir .. "/b.txt", greed.view():buffer():path())
end)

test("projects open again, and the one shown is shown", function(t)
	local file = session()
	local one = t:tempdir({ ["a.txt"] = "one\n" })
	local two = t:tempdir({ ["b.txt"] = "two\nlines\n" })
	remember(file, {
		current = two,
		projects = {
			{ root = one, files = { one .. "/a.txt" }, shown = one .. "/a.txt", cursor = 0 },
			{ root = two, files = { two .. "/b.txt" }, shown = two .. "/b.txt", cursor = 4 },
		},
	})
	restore.restore()
	assert(greed.project.current().root == two, greed.project.current().root)
	assert(greed.view():buffer():path() == two .. "/b.txt")
	assert(cursor() == 4, tostring(cursor()))
	local roots = {}
	for _, info in greed.project.list() do
		roots[info.root] = true
	end
	assert(roots[one] and roots[two], "both projects are open")

	-- What a project showed is kept while another one is shown.
	t:run("quit")
	local state = saved(file)
	for _, project in state.projects do
		if project.root == one then
			assert(project.shown == one .. "/a.txt", project.shown)
		end
	end
end)

test("nothing is opened with restore-session off", function(t)
	local file = session()
	local dir = t:tempdir({ ["a.txt"] = "one\n" })
	local root = greed.project.current().root
	remember(file, { current = root, projects = { { root = root, files = { dir .. "/a.txt" } } } })
	greed.option.set("restore-session", false)
	restore.restore()
	assert(not open_paths()[dir .. "/a.txt"])
end)
