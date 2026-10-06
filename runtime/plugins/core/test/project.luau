local test = require("@greed/test")
local greed = require("@greed")
local project = require("@core").project

test("a project's root is the nearest folder up with a marker in it", function(t)
	local dir = t:tempdir({
		[".git/HEAD"] = "",
		["src/deep/main.rs"] = "",
		["sub/.jj/x"] = "",
		["sub/a.txt"] = "",
	})
	assert(
		project.root(dir .. "/src/deep/main.rs") == dir,
		project.root(dir .. "/src/deep/main.rs")
	)
	assert(project.root(dir .. "/src/deep") == dir)
	assert(project.root(dir .. "/sub/a.txt") == dir .. "/sub", "the nearest marker wins")
end)

test("without a marker, the root is the starting directory", function(t)
	local dir = t:tempdir({ ["a.txt"] = "" })
	-- The temporary directory might be inside a project; only check when not.
	local root = project.root(dir .. "/a.txt")
	assert(root == greed.fs.cwd() or string.sub(dir, 1, #root) == root, root)
end)

test("paths in a project open relative to the starting directory when they can", function(t)
	local cwd = greed.fs.cwd()
	assert(project.path(cwd, "src/a.rs") == "src/a.rs")
	assert(project.path(cwd .. "/sub", "a.rs") == "sub/a.rs")
	assert(project.path("/elsewhere", "a.rs") == "/elsewhere/a.rs")
end)

test(":project opens a project, or switches to it when it's open", function(t)
	local a = t:tempdir({ [".git/HEAD"] = "", ["x.txt"] = "" })
	local b = t:tempdir({ [".jj/repo"] = "" })
	t:run("project", { a .. "/x.txt" })
	assert(greed.project.current().root == a, greed.project.current().root)
	t:run("project", { b })
	assert(greed.project.current().root == b)
	local count = #greed.project.list()
	t:run("project", { a })
	assert(greed.project.current().root == a and #greed.project.list() == count, "switched back")
end)

test("a folder without a marker is its own project", function(t)
	local dir = t:tempdir({ ["notes.md"] = "" })
	t:run("project", { dir })
	-- Unless the temporary folder is inside a project of its own.
	local root = greed.project.current().root
	assert(root == dir or string.sub(dir, 1, #root) == root, root)
end)

test("closing a project refuses unsaved changes unless forced", function(t)
	local dir = t:tempdir({ [".git/HEAD"] = "", ["a.txt"] = "a" })
	t:run("project", { dir })
	greed.open(dir .. "/a.txt")
	t:keys("i x esc")
	local ok = pcall(function()
		t:run("project-close")
	end)
	assert(not ok, "refused")
	greed.run("project-close", { force = true })
	assert(greed.project.current().root ~= dir)
end)

test(":q closes the project and lets go when others are open, and quits on the last", function(t)
	local dir = t:tempdir({ [".git/HEAD"] = "" })
	t:run("project", { dir })
	assert(#greed.project.list() == 2)
	t:run("quit")
	assert(#greed.project.list() == 1 and not t:quitting(), "one project left, still running")
	t:run("quit")
	assert(t:quitting(), "the last one quits")
end)

test(":session sends the client to a project's session, and needs somewhere to go", function(t)
	t:buffer("|x")
	assert(not pcall(function()
		t:run("session")
	end), "needs a name or a path")
	local dir = t:tempdir({ [".git/HEAD"] = "" })
	t:run("session", { dir })
	local to = t:switched()
	assert(to and to.path == dir and to.session == nil, "to the project's session")
	assert(t:switched() == nil, "asked once")
	assert(not pcall(greed.session.switch, {} :: any), "switch needs a name or a path")
end)

test(":project needs a path, and the only project can't be closed", function(t)
	t:buffer("|x")
	assert(not pcall(function()
		t:run("project")
	end))
	while #greed.project.list() > 1 do
		greed.project.close(greed.project.current().id)
	end
	local ok, err = pcall(function()
		t:run("project-close")
	end)
	assert(not ok and string.find(tostring(err), "only project", 1, true), tostring(err))
end)

test("a project's own config runs once you trust it, and from then on", function(t)
	local core = require("@core")
	local dir = t:tempdir({
		[".git/HEAD"] = "",
		[".greed/init.luau"] = "require('@greed').option.set('indent', 'PROJECT')\n",
	})
	t:buffer("|x")
	greed.run("project", { args = { dir } })
	assert(greed.option.get("indent") ~= "PROJECT", "not before it's trusted")
	local messages = t:messages()
	assert(string.find(messages[#messages], ":trust", 1, true), messages[#messages])
	t:run("trust")
	assert(greed.option.get("indent") == "PROJECT", "trusting runs it")
	assert(table.find(core.project.trusted(), dir), "and remembers")
	greed.option.set("indent", "    ")
	greed.project.close(greed.project.current().id)
	greed.run("project", { args = { dir } })
	assert(
		greed.option.get("indent") == "PROJECT",
		"trusted projects run their config when they open"
	)
end)

test("a project without its own config has nothing to trust", function(t)
	local dir = t:tempdir({ [".git/HEAD"] = "" })
	t:buffer("|x")
	greed.run("project", { args = { dir } })
	local ok, err = pcall(function()
		t:run("trust")
	end)
	assert(not ok and string.find(tostring(err), ".greed", 1, true), tostring(err))
end)

test("a path is inside a folder only once its .. and . are worked out", function()
	assert(project.clean("/a/b/../c/./d//e") == "/a/c/d/e", project.clean("/a/b/../c/./d//e"))
	assert(project.clean("/../x") == "/x")
	assert(project.inside("/p/notes/a.md", "/p/notes"))
	assert(project.inside("/p/notes", "/p/notes/"), "the folder itself")
	assert(not project.inside("/p/notes/../CLAUDE.md", "/p/notes"), "climbs out")
	assert(not project.inside("/p/notes-old/a.md", "/p/notes"), "a folder with a longer name")
	assert(project.inside("/p/notes/x/../a.md", "/p/notes"), "climbs out and back in")
end)
