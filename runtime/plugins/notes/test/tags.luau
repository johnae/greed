-- Renaming a tag in every note.

local test = require("@greed/test")
local greed = require("@greed")
local notes = require("@notes")

test("a tag is renamed in text and front matter, with the tags under it", function(t)
	local dir = t:tempdir({
		["a.md"] = "# A\n\n- [ ] dig #Garden and #garden/seeds, not #gardening\n`#garden` in code\n",
		["b.md"] = "---\ntags: [garden, work]\n---\n#garden\n\n```\n#garden\n```\n",
		["c.md"] = "---\ntags:\n  - '#garden'\n  - home\n---\nno tag here\n",
		["d.md"] = "# D #kitchen\n",
	})
	greed.option.set("notes-folder", dir)
	greed.option.set("notes-project-folder", `{dir}/.no-project-notes`)
	notes.index.ensure()
	assert(notes.tags.rename("#garden", "yard") == 3)
	local a = greed.fs.read(`{dir}/a.md`)
	assert(a == "# A\n\n- [ ] dig #yard and #yard/seeds, not #gardening\n`#garden` in code\n", a)
	local b = greed.fs.read(`{dir}/b.md`)
	assert(b == "---\ntags: [yard, work]\n---\n#yard\n\n```\n#garden\n```\n", b)
	local c = greed.fs.read(`{dir}/c.md`)
	assert(c == "---\ntags:\n  - '#yard'\n  - home\n---\nno tag here\n", c)
	assert(greed.fs.read(`{dir}/d.md`) == "# D #kitchen\n")
end)

test("notes-tag-rename says how many notes changed", function(t)
	local dir = t:tempdir({ ["a.md"] = "#old\n" })
	greed.option.set("notes-folder", dir)
	greed.option.set("notes-project-folder", `{dir}/.no-project-notes`)
	notes.index.ensure()
	t:buffer("|x")
	t:run("notes-tag-rename", { "old", "new" })
	assert(greed.fs.read(`{dir}/a.md`) == "#new\n")
	local said = t:messages()
	assert(string.find(said[#said], "in 1 note", 1, true), said[#said])
end)
