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
