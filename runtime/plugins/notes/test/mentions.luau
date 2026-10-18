-- Mentions: notes named in another note's text without a link, linked with
-- the quick fix, and listed at the end of the note they name.

local test = require("@greed/test")
local greed = require("@greed")
local notes = require("@notes")

local VAULT = {
	["Garden plans.md"] = "# Garden plans\n",
	["anna.md"] = "---\naliases: [the neighbour]\n---\n# Anna\n",
	["k.md"] = "# Kitchen remodel\n",
	["inbox.md"] = "- [ ] call\n",
	["today.md"] = "talked to Anna about the garden plans, see `garden plans` and [[k]]\n",
}

local function vault(t: test.TestContext): string
	local dir = t:tempdir(VAULT)
	greed.option.set("notes-folder", dir)
	greed.option.set("notes-project-folder", `{dir}/.no-project-notes`)
	notes.index.ensure()
	return dir
end

-- What a line mentions, as "words:note" each.
local function mentioned(text: string, here: string?): string
	local out = {}
	for _, mention in notes.mentions.in_line(text, here) do
		table.insert(out, `{mention.text}:{mention.note}`)
	end
	return table.concat(out, ", ")
end

test("a line mentions notes by name, title or alias, not in links, code or itself", function(t)
	vault(t)
	local got = mentioned("talked to Anna about the garden plans, see `garden plans` and [[k]]")
	assert(got == "Anna:anna, garden plans:Garden plans", got)
	assert(
		mentioned("the Kitchen remodel and the neighbour")
			== "Kitchen remodel:k, the neighbour:anna"
	)
	assert(mentioned("about Anna", "anna") == "", "not the note it's in")
	assert(mentioned("check the inbox") == "", "the inbox means little in a sentence")
	assert(mentioned("annabelle and gardening") == "", "whole words only")
end)

test("the quick fix links what the line mentions, keeping the words", function(t)
	local dir = vault(t)
	greed.open(`{dir}/today.md`)
	t:run("quick-fix")
	local line: string = greed.view():buffer():line_text(0)
	assert(
		line
			== "talked to [[anna|Anna]] about the [[Garden plans|garden plans]], see `garden plans` and [[k]]",
		line
	)
	greed.view():buffer():edit(function(e)
		e:insert(greed.view():buffer():len(), "and the neighbour")
	end)
	greed.view():set_cursor(greed.view():buffer():len())
	t:run("quick-fix")
	local second = greed.view():buffer():line_text(1)
	assert(second == "and [[the neighbour]]", second)
end)

test("the line the cursor is on says what it mentions", function(t)
	local dir = vault(t)
	greed.open(`{dir}/today.md`)
	local buffer = greed.view():buffer()
	greed.view():set_cursor(3)
	local hint = ""
	t:wait_for(function()
		for _, mark in buffer:decorations("mentions") do
			hint = mark.text or ""
		end
		return hint ~= ""
	end)
	assert(string.find(hint, "Anna, Garden plans", 1, true), hint)
end)

test("a note lists the notes that mention it without a link", function(t)
	local dir = vault(t)
	local found = notes.mentions.mentioning("Garden plans")
	assert(#found == 1 and found[1].note == "today", tostring(#found))
	assert(#notes.mentions.mentioning("k") == 0, "linked, so not only mentioned")
	greed.open(`{dir}/Garden plans.md`)
	local buffer = greed.view():buffer()
	t:wait_for(function()
		for _, mark in buffer:decorations("notes") do
			local lines: { greed.MarkLine } = mark.lines or {}
			for _, line in lines do
				if line == "Mentioned in:" then
					return true
				end
			end
		end
		return false
	end)
end)
