-- Types: each template in the templates folder is one, a new note can start
-- from one, and a note can take one's fields.

local test = require("@greed/test")
local greed = require("@greed")
local notes = require("@notes")

local MEETING = '---\ncategories:\n  - "[[Meetings]]"\ndate: {{date}}\npeople: []\n---\n## Notes\n'

local function vault(t: test.TestContext, files: { [string]: string }): string
	local dir = t:tempdir(files)
	greed.option.set("notes-folder", dir)
	greed.option.set("notes-project-folder", `{dir}/.no-project-notes`)
	notes.index.ensure()
	return dir
end

test("each template is a type, named without its Template", function(t)
	vault(t, {
		["templates/Meeting Template.md"] = MEETING,
		["templates/book.md"] = "---\nauthor:\n---\n",
		["Other.md"] = "# Other\n",
	})
	local names = {}
	for _, kind in notes.types.all() do
		table.insert(names, `{kind.name}={kind.template}`)
	end
	local listed = table.concat(names, ",")
	assert(listed == "book=templates/book,Meeting=templates/Meeting Template", listed)
end)

test("a new note starts from its type's template, filled in", function(t)
	local dir = vault(t, { ["templates/Meeting Template.md"] = MEETING })
	local meeting = notes.types.all()[1]
	notes.types.new("Meetings/Planning", meeting)
	local text = greed.fs.read(`{dir}/Meetings/Planning.md`) or ""
	assert(string.find(text, `date: {notes.today()}`, 1, true), text)
	assert(string.find(text, "## Notes", 1, true), text)
	assert(greed.view():buffer():path() == `{dir}/Meetings/Planning.md`, "opened")
	-- One that's there stays as it is.
	greed.fs.write(`{dir}/Kept.md`, "# Mine\n")
	notes.types.new("Kept", meeting)
	assert(greed.fs.read(`{dir}/Kept.md`) == "# Mine\n")
end)

test("a note takes a type's fields it doesn't have, keeping its own", function(t)
	local dir = vault(t, {
		["templates/Meeting Template.md"] = MEETING,
		["Standup.md"] = "---\ndate: 2026-01-05\ntopic: plans\n---\nwhat we said\n",
		["Bare.md"] = "just words\n",
	})
	local meeting = notes.types.all()[1]
	notes.types.apply("Standup", meeting)
	local text = greed.fs.read(`{dir}/Standup.md`) or ""
	assert(
		text
			== '---\ndate: 2026-01-05\ntopic: plans\ncategories:\n  - "[[Meetings]]"\npeople: []\n---\nwhat we said\n',
		text
	)
	notes.types.apply("Bare", meeting)
	local bare = greed.fs.read(`{dir}/Bare.md`) or ""
	assert(
		bare
			== `---\ncategories:\n  - "[[Meetings]]"\ndate: {notes.today()}\npeople: []\n---\njust words\n`,
		bare
	)
end)
