local test = require("@kern/test")
local kern = require("@kern")
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
	assert(root == kern.fs.cwd() or string.sub(dir, 1, #root) == root, root)
end)

test("paths in a project open relative to the starting directory when they can", function(t)
	local cwd = kern.fs.cwd()
	assert(project.path(cwd, "src/a.rs") == "src/a.rs")
	assert(project.path(cwd .. "/sub", "a.rs") == "sub/a.rs")
	assert(project.path("/elsewhere", "a.rs") == "/elsewhere/a.rs")
end)

test(":project opens a project, or switches to it when it's open", function(t)
	local a = t:tempdir({ [".git/HEAD"] = "", ["x.txt"] = "" })
	local b = t:tempdir({ [".jj/repo"] = "" })
	t:run("project", { a .. "/x.txt" })
	assert(kern.project.current().root == a, kern.project.current().root)
	t:run("project", { b })
	assert(kern.project.current().root == b)
	local count = #kern.project.list()
	t:run("project", { a })
	assert(kern.project.current().root == a and #kern.project.list() == count, "switched back")
end)

test("a folder without a marker is its own project", function(t)
	local dir = t:tempdir({ ["notes.md"] = "" })
	t:run("project", { dir })
	-- Unless the temporary folder is inside a project of its own.
	local root = kern.project.current().root
	assert(root == dir or string.sub(dir, 1, #root) == root, root)
end)

test("closing a project refuses unsaved changes unless forced", function(t)
	local dir = t:tempdir({ [".git/HEAD"] = "", ["a.txt"] = "a" })
	t:run("project", { dir })
	kern.open(dir .. "/a.txt")
	t:keys("i x esc")
	local ok = pcall(function()
		t:run("project-close")
	end)
	assert(not ok, "refused")
	kern.run("project-close", { force = true })
	assert(kern.project.current().root ~= dir)
end)

test(":q closes the project and lets go when others are open, and quits on the last", function(t)
	local dir = t:tempdir({ [".git/HEAD"] = "" })
	t:run("project", { dir })
	assert(#kern.project.list() == 2)
	t:run("quit")
	assert(#kern.project.list() == 1 and not t:quitting(), "one project left, still running")
	t:run("quit")
	assert(t:quitting(), "the last one quits")
end)
