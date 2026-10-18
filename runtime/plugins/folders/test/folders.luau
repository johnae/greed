local test = require("@greed/test")
local greed = require("@greed")
local folders = require("@folders")

-- What `changes` say, a line each.
local function said(changes: { folders.Change }): string
	local out = {}
	for _, c in changes do
		table.insert(out, `{c.kind} {c.from or ""} {c.to or ""}`)
	end
	return table.concat(out, "\n")
end

test("a line reads as its hidden number, its name and whether it's a folder", function()
	local id, name, dir = folders.parse("0012 src/")
	assert(id == 12 and name == "src" and dir)
	local new_id, new_name, new_dir = folders.parse("new.txt")
	assert(new_id == nil and new_name == "new.txt" and not new_dir)
end)

test("saving plans renames, new files and folders, moves, copies and deletes", function(t)
	local dir = t:tempdir({ ["a.txt"] = "", ["b.txt"] = "", ["c.txt"] = "", ["sub/d.txt"] = "" })
	local known = {
		[1] = { path = `{dir}/a.txt`, dir = false },
		[2] = { path = `{dir}/b.txt`, dir = false },
		[3] = { path = `{dir}/c.txt`, dir = false },
		[4] = { path = `{dir}/sub`, dir = true },
		[5] = { path = `{dir}/sub/d.txt`, dir = false },
	}
	local changes, why = folders.plan({
		-- a renamed, b left out (deleted), c kept, a new file and folder.
		{ dir = dir, lines = { "0001 z.txt", "0003 c.txt", "0004 sub/", "new.txt", "made/", "" } },
		-- d moved up out of sub, c copied in.
		{ dir = `{dir}/sub`, lines = { "0003 c.txt" } },
		{ dir = dir, lines = { "0005 d.txt" } },
	}, known)
	assert(changes, why)
	local expect = table.concat({
		`make  {dir}/made`,
		`make  {dir}/new.txt`,
		`rename {dir}/sub/d.txt {dir}/d.txt`,
		`rename {dir}/a.txt {dir}/z.txt`,
		`copy {dir}/c.txt {dir}/sub/c.txt`,
		`delete {dir}/b.txt `,
	}, "\n")
	-- Renames and copies in any order among themselves; makes first, deletes last.
	local got = said(changes)
	for line in string.gmatch(expect, "[^\n]+") do
		assert(string.find(got, line, 1, true), got)
	end
	assert(string.match(got, "^make") and string.match(got, "delete [^\n]*$"), got)
end)

test("two lines with one name, or a name that's there, are refused", function(t)
	local dir = t:tempdir({ ["a.txt"] = "", ["b.txt"] = "" })
	local known =
		{ [1] = { path = `{dir}/a.txt`, dir = false }, [2] = { path = `{dir}/b.txt`, dir = false } }
	local changes, why = folders.plan({ { dir = dir, lines = { "0001 x", "0002 x" } } }, known)
	assert(changes == nil and why and string.find(why, "twice", 1, true), why)
	changes, why = folders.plan({ { dir = dir, lines = { "0001 b.txt", "0002 b.txt" } } }, known)
	assert(changes == nil, "b.txt twice")
	changes, why = folders.plan({ { dir = dir, lines = { "0001 b.txt" } } }, { [1] = known[1] })
	assert(changes == nil and why and string.find(why, "there already", 1, true), why)
end)

test(
	"a folder's buffer, edited and saved with y, changes the files; :folder-undo takes it back",
	function(t)
		local dir = t:tempdir({ ["a.txt"] = "A", ["b.txt"] = "B" })
		t:buffer("|x")
		folders.open(dir)
		local buffer = greed.view():buffer()
		assert(buffer:kind() == "folder")
		local text = buffer:text()
		assert(string.match(text, "^%d%d%d%d a%.txt\n%d%d%d%d b%.txt$"), text)
		-- Rename a, delete b, add a folder with a file in it.
		local renamed = string.gsub(text, " a%.txt", " renamed.txt")
		local without_b = string.gsub(renamed, "\n%d+ b%.txt", "")
		buffer:edit(function(e)
			e:replace(0, buffer:len(), without_b .. "\nnew/one.txt")
		end)
		t:run("save")
		t:keys("y")
		assert(greed.fs.read(`{dir}/renamed.txt`) == "A", "renamed, with what it held")
		assert(greed.fs.stat(`{dir}/a.txt`) == nil and greed.fs.stat(`{dir}/b.txt`) == nil)
		assert(greed.fs.stat(`{dir}/new/one.txt`), "made in a new folder")
		assert(
			string.find(buffer:text(), "renamed.txt", 1, true),
			"the buffer shows the folder again"
		)
		t:run("folder-undo")
		assert(greed.fs.read(`{dir}/a.txt`) == "A", "the rename taken back")
		assert(greed.fs.read(`{dir}/b.txt`) == "B", "back from the trash")
		assert(greed.fs.stat(`{dir}/new/one.txt`) == nil, "the new file gone")
	end
)

test("a save you don't confirm changes nothing", function(t)
	local dir = t:tempdir({ ["a.txt"] = "A" })
	t:buffer("|x")
	folders.open(dir)
	local buffer = greed.view():buffer()
	buffer:edit(function(e)
		e:replace(0, buffer:len(), "")
	end)
	t:run("save")
	t:keys("n")
	assert(greed.fs.read(`{dir}/a.txt`) == "A", "kept")
end)

test("enter opens the file on the line, and - goes up", function(t)
	local dir = t:tempdir({ ["sub/a.txt"] = "hello" })
	t:buffer("|x")
	folders.open(`{dir}/sub`)
	t:keys("-")
	assert(string.find(greed.view():buffer():text(), "sub/", 1, true), greed.view():buffer():text())
	t:keys("enter")
	assert(string.find(greed.view():buffer():text(), "a.txt", 1, true), "into sub")
	t:keys("enter")
	assert(greed.view():buffer():path() == `{dir}/sub/a.txt`, greed.view():buffer():path())
end)

test("deleting a file moves it to the trash, with a note of where it was", function(t)
	local core = require("@core")
	local dir = t:tempdir({ ["gone.txt"] = "bye" })
	local trashed = core.file.remove(`{dir}/gone.txt`)
	assert(trashed and greed.fs.read(trashed) == "bye", "in the trash")
	assert(greed.fs.stat(`{dir}/gone.txt`) == nil)
	local trash, name = string.match(trashed, "^(.*)/files/([^/]+)$")
	local note = greed.fs.read(`{trash}/info/{name}.trashinfo`) or ""
	assert(string.find(note, "Path=", 1, true), note)
	greed.option.set("trash", false)
	greed.fs.write(`{dir}/also.txt`, "x")
	assert(core.file.remove(`{dir}/also.txt`) == nil, "with trash off, deleted for good")
	greed.option.set("trash", true)
end)
