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

test("nothing is opened in a session started fresh", function(t)
	local file = session()
	local dir = t:tempdir({ ["a.txt"] = "one\n" })
	local root = greed.project.current().root
	remember(file, { current = root, projects = { { root = root, files = { dir .. "/a.txt" } } } })
	restore.fresh = function()
		return true
	end
	restore.restore()
	assert(not open_paths()[dir .. "/a.txt"])
end)

-- Writes down a session that was quit with `a.txt` open in `dir`.
local function quit_with(t: test.TestContext, file: string, dir: string)
	greed.open(dir .. "/a.txt")
	t:run("quit")
	assert(t:quitting())
	assert(saved(file).quit == true, "written down as quit")
	greed.run("buffer-close", { force = true })
	assert(not open_paths()[dir .. "/a.txt"], "closed again")
end

test("a session that was quit starts clean, one that ended otherwise is restored", function(t)
	local file = session()
	local dir = t:tempdir({ ["a.txt"] = "one\n" })
	quit_with(t, file, dir)
	restore.restore()
	assert(not open_paths()[dir .. "/a.txt"], "quit: nothing opened")

	-- Ended without quitting, as a crash or a reboot does: what was last
	-- written down.
	local state = saved(file)
	state.quit = nil
	remember(file, state)
	restore.restore()
	assert(open_paths()[dir .. "/a.txt"], "restored")
end)

test("with restore-after-quit a session that was quit is restored too", function(t)
	local file = session()
	local dir = t:tempdir({ ["a.txt"] = "one\n" })
	quit_with(t, file, dir)
	greed.option.set("restore-after-quit", true)
	restore.restore()
	assert(open_paths()[dir .. "/a.txt"])
end)

test("a session started to be restored, as for an upgrade, is restored after a quit", function(t)
	local file = session()
	local dir = t:tempdir({ ["a.txt"] = "one\n" })
	quit_with(t, file, dir)
	restore.restoring = function()
		return true
	end
	greed.option.set("restore-session", false)
	restore.restore()
	assert(not open_paths()[dir .. "/a.txt"], "restore-session off still wins")
	greed.option.set("restore-session", true)
	restore.fresh = function()
		return true
	end
	restore.restore()
	assert(not open_paths()[dir .. "/a.txt"], "--fresh still wins")
	restore.fresh = function()
		return false
	end
	restore.restore()
	assert(open_paths()[dir .. "/a.txt"], "restored")
end)

test("opening a file writes it down, once the session has restored", function(t)
	local file = session()
	local dir = t:tempdir({ ["a.txt"] = "one\n", ["b.txt"] = "two\n", ["c.txt"] = "three\n" })
	local root = greed.project.current().root
	remember(file, { current = root, projects = { { root = root, files = { dir .. "/a.txt" } } } })
	restore.started = false
	greed.open(dir .. "/b.txt")
	assert(#saved(file).projects[1].files == 1, "not before restoring, which would lose it")
	restore.restore()
	greed.open(dir .. "/c.txt")
	local files = saved(file).projects[1].files
	assert(#files == 3 and saved(file).quit == nil, table.concat(files, " "))
end)

test("quitting writes down the shown project's tabs, and starting opens them again", function(t)
	local file = session()
	local root = greed.project.current().root
	local dir = t:tempdir({ ["a.txt"] = "one\n", ["b.txt"] = "two\n" })
	greed.open(dir .. "/a.txt")
	greed.tab.new(greed.load(dir .. "/b.txt"))
	greed.view():split("right", greed.load(dir .. "/a.txt"))
	restore.save()
	local project = saved(file).projects[1]
	assert(project.tabs and #project.tabs == 2, "two tabs")
	assert(
		project.tabs[2].children and #project.tabs[2].children == 2,
		greed.json.encode(project.tabs[2])
	)

	-- Started again: the tabs come back, each showing what it did.
	for _, tab in greed.tab.list() do
		if tab.id ~= greed.tab.current().id then
			greed.tab.close(tab.id)
		end
	end
	greed.view():show(greed.create_buffer("file", ""))
	remember(file, { current = root, projects = { project } })
	restore.restore()
	local list = greed.tab.list()
	assert(#list == 2, `{#list} tabs`)
	assert(#list[2].panes == 2, "the second tab's two panes")
	local shown = {}
	for _, pane in list[2].panes do
		table.insert(shown, pane:buffer():path() or "")
	end
	table.sort(shown)
	assert(shown[1] == dir .. "/a.txt" and shown[2] == dir .. "/b.txt", table.concat(shown, " "))
end)

test("a terminal that ran something risky comes back as a shell", function(t)
	local file = session()
	local root = greed.project.current().root
	remember(file, {
		current = root,
		projects = {
			{
				root = root,
				files = {},
				tabs = {
					-- Of different shapes, as saved tabs are.
					{ file = "x.txt" } :: any,
					{ terminal = { "rm", "-rf", "build" } },
				},
			},
		},
	})
	restore.restore()
	local list = greed.tab.list()
	assert(#list == 2, `{#list} tabs`)
	local terminal = require("@terminal")
	local buffer = list[2].panes[1]:buffer()
	assert(terminal.terminal(buffer), "a terminal")
	assert(terminal.asked(buffer) == nil, "a shell, not rm -rf")
end)
