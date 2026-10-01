local test = require("@kern/test")
local kern = require("@kern")

-- The tree's lines.
local function lines(): { string }
	return string.split(kern.view():buffer():text(), "\n")
end

-- The first folder in the current directory, which the tests open.
local function first_dir(): string
	for _, entry in kern.fs.list(".") or {} do
		if entry.dir then
			return entry.name
		end
	end
	error("the tests need a folder in the current directory")
end

test("space e opens the tree in a panel, folders first", function(t)
	t:buffer("|x")
	t:keys("space e")
	assert(kern.view():buffer():kind() == "tree", "focused")
	local dir = first_dir()
	assert(lines()[1] == "▸ " .. dir .. "/", lines()[1])
	-- Typing in it is refused.
	assert(not pcall(function()
		t:keys("i z")
	end), "typing fails")
	t:keys("esc")
	assert(lines()[1] == "▸ " .. dir .. "/", "nothing typed")
end)

test("enter unfolds and folds a folder, h folds from inside it", function(t)
	t:buffer("|x")
	t:keys("space e")
	local dir = first_dir()
	t:keys("enter")
	assert(lines()[1] == "▾ " .. dir .. "/", lines()[1])
	local children = kern.fs.list(dir) or {}
	assert(#children > 0, "the folder has something in it")
	assert(string.sub(lines()[2], 1, 2) == "  ", "children are indented: " .. lines()[2])
	t:keys("j h")
	assert(lines()[1] == "▸ " .. dir .. "/", "h folds the parent")
	t:keys("enter enter")
	assert(lines()[1] == "▸ " .. dir .. "/", "enter folds it again")
end)

test("space e moves back to the tree, and closes it from inside", function(t)
	t:buffer("|x")
	t:keys("space e")
	local tree = kern.view()
	t:keys("q")
	assert(kern.view():id() ~= tree:id(), "q closes it")
	t:keys("space e")
	t:keys("space e")
	assert(kern.view():buffer():kind() ~= "tree", "space e in the tree closes it")
end)

test("each project has its own tree, rooted in the project", function(t)
	local dir = t:tempdir({ [".git/HEAD"] = "", ["inside.txt"] = "" })
	t:buffer("|x")
	t:keys("space e")
	local first = kern.view():buffer():text()
	kern.run("project", { args = { dir } })
	t:keys("space e")
	assert(kern.view():buffer():kind() == "tree", "a tree of its own")
	assert(
		string.find(kern.view():buffer():text(), "inside.txt", 1, true) ~= nil,
		kern.view():buffer():text()
	)
	kern.project.switch(kern.project.list()[1].id)
	t:keys("space e")
	assert(kern.view():buffer():text() == first, "the first project's tree is as it was")
end)

test("a tree closed some other way opens again", function(t)
	t:buffer("|x")
	t:keys("space e")
	kern.view():close()
	t:keys("space e")
	assert(kern.view():buffer():kind() == "tree", "a new tree")
	t:keys("space e")
end)
