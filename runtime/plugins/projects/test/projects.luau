local test = require("@greed/test")
local greed = require("@greed")
local projects = require("@projects")

-- Types `text` into whatever has the keys, a character at a time.
local function type_text(t: test.TestContext, text: string)
	for _, char in string.split(text, "") do
		t:keys(if char == " " then "space" else char)
	end
end

local function picker_text(): string
	return greed.view():buffer():text()
end

-- Looks at the sources again, from a command, since commands wait.
local function refresh(t: test.TestContext)
	greed.command({
		name = "test-refresh",
		run = function()
			projects.refresh()
		end,
	})
	t:run("test-refresh")
end

local function found_paths(): { [string]: string }
	local paths = {}
	for _, f in projects.found() do
		paths[f.path] = f.from
	end
	return paths
end

test("space P switches between the projects open here", function(t)
	local dir = t:tempdir({ [".git/HEAD"] = "" })
	t:buffer("|x")
	local first = greed.project.current().id
	greed.project.open(dir)
	t:keys("space P")
	-- Projects come first, in the order they were opened.
	t:keys("enter")
	assert(greed.project.current().id == first, "back in the first project")
end)

test("space P offers recent projects, which open in their own session", function(t)
	local core = require("@core")
	local dir = t:tempdir({ [".git/HEAD"] = "" })
	core.project.open(dir)
	greed.project.close(greed.project.current().id)
	assert(table.find(core.project.recent(), dir), "remembered")
	t:buffer("|x")
	t:keys("space P")
	assert(string.find(picker_text(), "(recent)", 1, true), picker_text())
	type_text(t, string.match(dir, "[^/]+$") :: string)
	t:keys("enter")
	local to = t:switched()
	assert(to and to.path == dir, "went to its session")
end)

test("alt-enter opens the project in a new session of its own", function(t)
	local core = require("@core")
	local dir = t:tempdir({ [".git/HEAD"] = "" })
	core.project.open(dir)
	greed.project.close(greed.project.current().id)
	t:buffer("|x")
	t:keys("space P")
	type_text(t, string.match(dir, "[^/]+$") :: string)
	t:keys("alt-enter")
	local to = t:switched()
	assert(to and to.path == dir, "for that project")
	assert(to.session ~= nil, "under a session name of its own")
end)

test("alt-w opens the project in another window, this one staying", function(t)
	local core = require("@core")
	local dir = t:tempdir({ [".git/HEAD"] = "" })
	core.project.open(dir)
	greed.project.close(greed.project.current().id)
	t:buffer("|x")
	t:keys("space P")
	type_text(t, string.match(dir, "[^/]+$") :: string)
	t:keys("alt-w")
	local to = t:switched()
	assert(to and to.path == dir and to.window, "in another window")
end)

test("a folder typed into space P opens in its own session", function(t)
	local dir = t:tempdir({ ["notes.md"] = "" })
	t:buffer("|x")
	t:keys("space P")
	type_text(t, dir)
	t:keys("enter")
	local to = t:switched()
	assert(to and to.path == dir, "went to the folder's session")
end)

test("a typed path that isn't a folder says so", function(t)
	t:buffer("|x")
	t:keys("space P")
	type_text(t, "/no/such/folder")
	t:keys("enter")
	assert(t:switched() == nil)
	local messages = t:messages()
	assert(string.find(messages[#messages], "no folder", 1, true), messages[#messages])
end)

test("a folder source lists the folders in it, leaving hidden ones out", function(t)
	local dir = t:tempdir({ ["one/a"] = "", ["two/b"] = "", [".hidden/c"] = "", ["file"] = "" })
	projects.sources({ { dirs = { dir } } })
	refresh(t)
	local found = found_paths()
	assert(found[`{dir}/one`] == "folders" and found[`{dir}/two`], "both folders")
	assert(found[`{dir}/.hidden`] == nil and found[`{dir}/file`] == nil, "not hidden or files")
	t:buffer("|x")
	t:keys("space P")
	assert(string.find(picker_text(), "one  (folders)", 1, true), picker_text())
	projects.sources({})
end)

test("with markers, folders that have one are projects, found as deep as asked", function(t)
	local dir = t:tempdir({
		["work/app/.git/HEAD"] = "",
		["work/notes/readme.md"] = "",
		["lib/.jj/repo"] = "",
		["lib/inner/.git/HEAD"] = "",
		["deep/a/b/c/.git/HEAD"] = "",
	})
	projects.sources({ { name = "repos", dirs = { dir }, depth = 3, markers = { ".git", ".jj" } } })
	refresh(t)
	local found = found_paths()
	assert(found[`{dir}/work/app`] == "repos", "a project two down")
	assert(found[`{dir}/lib`], "a project one down")
	assert(found[`{dir}/lib/inner`] == nil, "nothing inside a project")
	assert(found[`{dir}/work/notes`] == nil, "no marker, no project")
	assert(found[`{dir}/deep/a/b/c`] == nil, "deeper than asked")
	projects.sources({})
end)

test("a command source lists the folders it prints", function(t)
	local dir = t:tempdir({ ["proj/x"] = "" })
	local command = { "sh", "-c", `printf '%s\\n' {dir}/proj /no/such/folder ''` }
	projects.sources({ { command = command } })
	refresh(t)
	local found = found_paths()
	assert(found[`{dir}/proj`] == "sh", "named after its program")
	assert(found["/no/such/folder"] == nil, "only folders that are there")
	projects.sources({})
end)

test("a failing command says so and the rest still count", function(t)
	local dir = t:tempdir({ ["a/x"] = "" })
	projects.sources({ { command = { "sh", "-c", "echo broken >&2; exit 3" } }, { dirs = { dir } } })
	refresh(t)
	assert(found_paths()[`{dir}/a`], "the folder source still ran")
	local messages = t:messages()
	assert(
		string.find(table.concat(messages, "\n"), "broken", 1, true),
		table.concat(messages, "\n")
	)
	projects.sources({})
end)
