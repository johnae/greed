local test = require("@greed/test")
local overlap = require("../overlap")

-- A stand-in session with a workspace in project `root`.
local function session(id: number, name: string, root: string): any
	return {
		id = id,
		name = name,
		root = root,
		status = "idle",
		workspace = { kind = "jj", name = name, path = `/tmp/{name}` },
		entries = {},
		changed = function() end,
	}
end

local function notes(s: any): string
	local out = {}
	for _, entry in s.entries do
		table.insert(out, entry.text)
	end
	return table.concat(out, " | ")
end

test("agents changing the same files in their workspaces hear of it, once per file", function()
	local a, b = session(901, "Greed", "/p"), session(902, "Claude", "/p")
	local elsewhere = session(903, "Codex", "/q")
	local files: { [number]: { string } } = {
		[901] = { "src/a.rs", "src/b.rs" },
		[902] = { "src/b.rs", "README.md" },
		[903] = { "src/a.rs" },
	}
	local function changed(s: any): { string }?
		return files[s.id]
	end
	local all = { a, b, elsewhere }
	overlap.check(a, all, changed)
	assert(notes(a) == "Claude changes src/b.rs too; bringing both in may clash", notes(a))
	assert(notes(b) == "Greed changes src/b.rs too; bringing both in may clash", notes(b))
	assert(notes(elsewhere) == "", "another project's agent isn't told")
	-- Said once; a newly shared file is said again.
	overlap.check(b, all, changed)
	assert(#b.entries == 1, notes(b))
	files[901] = { "src/a.rs", "src/b.rs", "README.md" }
	overlap.check(a, all, changed)
	assert(string.find(notes(a), "Claude changes README.md too", 1, true), notes(a))
	for _, s in all do
		overlap.forget(s)
	end
end)

test("files shared between two lists keep the first list's order", function()
	local both = overlap.shared({ "c", "a", "b" }, { "b", "c" })
	assert(table.concat(both, " ") == "c b", table.concat(both, " "))
end)
