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
	assert(lines()[2] == "│   lib.rs" and lines()[3] == "│   main.rs", lines()[2])
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

-- Where the tree's line `n` (from 1) is on the screen, once drawn.
local function cell(t: any, n: number): (number, number)
	t:draw(80, 20)
	local area = assert(greed.view():area())
	return area.x + 2, area.y + n - 1
end

test("folders' contents have a guide down their side", function(t)
	project(t)
	greed.run("tree")
	t:keys("enter")
	local guides = 0
	for _, mark in greed.view():buffer():decorations("tree") do
		if mark.style == "ui.tree.guide" then
			guides += 1
		end
	end
	assert(guides == 2, `a guide on each of src's two files: {guides}`)
end)

test("a click opens a file or folds a folder, and the row under the mouse lights up", function(t)
	project(t)
	greed.run("tree")
	local col, row = cell(t, 1)
	t:mouse("move", col, row)
	local hover = greed.view():buffer():decorations("tree-hover")
	assert(#hover == 1 and hover[1].line, "the row under the mouse")
	t:mouse("press", col, row)
	assert(lines()[1] == "▾ src/", `a click unfolds it: {lines()[1]}`)
	t:mouse("press", col, row)
	assert(lines()[1] == "▸ src/", "and folds it")
	col, row = cell(t, 2)
	t:mouse("press", col, row)
	local path = greed.view():buffer():path() or ""
	assert(string.sub(path, -8) == "notes.md", `a click opens a file: {path}`)
end)

test("the row under the mouse goes dark once it leaves the tree", function(t)
	project(t)
	greed.run("tree")
	local tree = greed.view()
	local col, row = cell(t, 1)
	t:mouse("move", col, row)
	t:mouse("move", 70, 5)
	assert(#tree:buffer():decorations("tree-hover") == 0)
end)

test("with tree-icons set to nerd, Nerd Font icons show by each name", function(t)
	project(t)
	greed.option.set("tree-icons", "nerd")
	greed.run("tree")
	assert(lines()[1] == "\u{f07b} src/", lines()[1])
	assert(lines()[2] == "\u{e609} notes.md", lines()[2])
	t:keys("enter")
	assert(lines()[1] == "\u{f07c} src/", "an open folder")
	assert(lines()[2] == "│ \u{e7a8} lib.rs", lines()[2])
end)

test(
	"a makes a file or a folder, R renames, taking an open file along, d deletes after y",
	function(t)
		local dir = project(t)
		greed.open(`{dir}/notes.md`)
		t:keys("space e")
		-- On notes.md, at the top level: a new file beside it.
		for i, line in lines() do
			if string.find(line, "notes.md", 1, true) then
				greed.view():set_cursor(greed.view():buffer():line_start(i - 1))
			end
		end
		t:keys("a")
		t:type("todo.txt")
		t:keys("enter")
		assert(greed.fs.stat(`{dir}/todo.txt`), "made the file")
		t:keys("a")
		t:type("docs/")
		t:keys("enter")
		local docs = greed.fs.stat(`{dir}/docs`)
		assert(docs and docs.kind == "dir", "made the folder")
		for i, line in lines() do
			if string.find(line, "notes.md", 1, true) then
				greed.view():set_cursor(greed.view():buffer():line_start(i - 1))
			end
		end
		t:keys("R")
		t:type("journal.md")
		t:keys("enter")
		assert(greed.fs.stat(`{dir}/journal.md`) and not greed.fs.stat(`{dir}/notes.md`), "renamed")
		local open = greed.buffer_for(`{dir}/journal.md`)
		assert(open ~= nil, "the open file went along")
		for i, line in lines() do
			if string.find(line, "todo.txt", 1, true) then
				greed.view():set_cursor(greed.view():buffer():line_start(i - 1))
			end
		end
		t:keys("d n")
		assert(greed.fs.stat(`{dir}/todo.txt`), "kept without y")
		t:keys("d y")
		assert(greed.fs.stat(`{dir}/todo.txt`) == nil, "deleted with y")
	end
)
