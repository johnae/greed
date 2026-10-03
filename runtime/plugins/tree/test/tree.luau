local test = require("@greed/test")
local greed = require("@greed")

-- The tree's lines.
local function lines(): { string }
	return string.split(greed.view():buffer():text(), "\n")
end

-- A project of its own for the test, with a folder and files in it, as the
-- current one. Returns its folder.
local function project(t: any): string
	local dir = t:tempdir({
		[".git/HEAD"] = "",
		["src/main.rs"] = "fn main() {}",
		["src/lib.rs"] = "",
		["notes.md"] = "",
	})
	greed.run("project", { args = { dir } })
	t:buffer("|x")
	return dir
end

test("space e opens the tree in a panel, folders first", function(t)
	project(t)
	t:keys("space e")
	assert(greed.view():buffer():kind() == "tree", "focused")
	local dir = "src"
	assert(lines()[1] == "▸ " .. dir .. "/", lines()[1])
	-- Typing in it is refused.
	assert(not pcall(function()
		t:keys("i z")
	end), "typing fails")
	t:keys("esc")
	assert(lines()[1] == "▸ " .. dir .. "/", "nothing typed")
end)

test("enter unfolds and folds a folder, h folds from inside it", function(t)
	project(t)
	t:keys("space e")
	local dir = "src"
	t:keys("enter")
	assert(lines()[1] == "▾ " .. dir .. "/", lines()[1])
	assert(
		string.match(lines()[2], "^%s+lib%.rs$") and string.match(lines()[3], "^%s+main%.rs$"),
		lines()[2]
	)
	t:keys("j h")
	assert(lines()[1] == "▸ " .. dir .. "/", "h folds the parent")
	t:keys("enter enter")
	assert(lines()[1] == "▸ " .. dir .. "/", "enter folds it again")
end)

test("space e moves back to the tree, and closes it from inside", function(t)
	t:buffer("|x")
	t:keys("space e")
	local tree = greed.view()
	t:keys("q")
	assert(greed.view():id() ~= tree:id(), "q closes it")
	t:keys("space e")
	t:keys("space e")
	assert(greed.view():buffer():kind() ~= "tree", "space e in the tree closes it")
end)

test("each project has its own tree, rooted in the project", function(t)
	local dir = t:tempdir({ [".git/HEAD"] = "", ["inside.txt"] = "" })
	t:buffer("|x")
	t:keys("space e")
	local first = greed.view():buffer():text()
	greed.run("project", { args = { dir } })
	t:keys("space e")
	assert(greed.view():buffer():kind() == "tree", "a tree of its own")
	assert(
		string.find(greed.view():buffer():text(), "inside.txt", 1, true) ~= nil,
		greed.view():buffer():text()
	)
	greed.project.switch(greed.project.list()[1].id)
	t:keys("space e")
	assert(greed.view():buffer():text() == first, "the first project's tree is as it was")
end)

test("a tree closed some other way opens again", function(t)
	t:buffer("|x")
	t:keys("space e")
	greed.view():close()
	t:keys("space e")
	assert(greed.view():buffer():kind() == "tree", "a new tree")
	t:keys("space e")
end)

-- The text of the line the tree marks as the open file, if any.
local function marked_open(): string?
	local buffer = greed.view():buffer()
	for _, mark in buffer:decorations("tree") do
		if mark.style == "ui.tree.open" then
			return buffer:slice(mark.from, mark.to)
		end
	end
	return nil
end

test("enter on a file opens it in the main view, and the tree marks it", function(t)
	project(t)
	t:keys("space e")
	assert(table.concat(lines(), "|") == "▸ src/|  notes.md", "hidden files are left out")
	t:keys("j enter")
	local path = greed.view():buffer():path() or ""
	assert(greed.view():buffer():kind() == "file" and string.sub(path, -8) == "notes.md", path)
	t:keys("space e")
	assert(marked_open() == "  notes.md", tostring(marked_open()))
	t:keys("q")
end)

test("the tree marks the file you came from", function(t)
	local dir = project(t)
	greed.open(dir .. "/notes.md")
	t:keys("space e")
	assert(marked_open() == "  notes.md", tostring(marked_open()))
	t:keys("q")
end)
