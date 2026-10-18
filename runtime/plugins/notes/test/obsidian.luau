-- Notes as Obsidian writes them: aliases, links to headings and blocks, and
-- the Tasks plugin's dates.

local test = require("@greed/test")
local greed = require("@greed")
local notes = require("@notes")

local VAULT = {
	["Week 42.md"] = table.concat({
		"---",
		"aliases: [w42, this week]",
		"---",
		"# Week 42",
		"",
		"## Plans",
		"",
		"A paragraph that matters. ^key-point",
		"",
		"- [ ] call the bank 📅 2026-10-20",
		"- [ ] tidy up",
		"  ^tidy",
		"",
	}, "\n"),
	["Monday.md"] = "Back to [[w42]], see [[Week 42#Plans]] and [[Week 42#^key-point|the point]].\n",
	["Tuesday.md"] = "About [[This Week]].\n",
}

local function vault(t: test.TestContext): string
	local dir = t:tempdir(VAULT)
	greed.option.set("notes-folder", dir)
	greed.option.set("notes-project-folder", `{dir}/.no-project-notes`)
	notes.index.ensure()
	return dir
end

test("a link to an alias goes to its note, and counts as a link to it", function(t)
	vault(t)
	assert(notes.index.linked("w42") == "Week 42")
	assert(notes.index.linked("THIS WEEK") == "Week 42", "any case")
	assert(notes.index.linked("Elsewhere") == "Elsewhere", "a note to make")
	local back = table.concat(notes.index.backlinks("Week 42"), ",")
	assert(back == "Monday,Tuesday", back)
end)

test("headings and blocks are found by their names", function(t)
	vault(t)
	local index = notes.index
	assert(index.line_of("Week 42", "plans") == 5, tostring(index.line_of("Week 42", "plans")))
	assert(index.line_of("Week 42", nil, "key-point") == 7, "a paragraph's id")
	assert(index.line_of("Week 42", nil, "tidy") == 10, "an id alone names the line above")
	assert(index.line_of("Week 42", "nowhere") == nil)
end)

test("g d on a link to a heading or a block opens the note there", function(t)
	local dir = vault(t)
	greed.open(`{dir}/Monday.md`)
	local buffer = greed.view():buffer()
	local function follow(text: string): number
		greed.open(`{dir}/Monday.md`)
		local at = string.find(buffer:text(), text, 1, true) :: number
		greed.view():set_cursor(at - 1)
		t:keys("g d")
		t:wait_for(function()
			return string.find(greed.view():buffer():path() or "", "Week 42", 1, true) ~= nil
		end)
		local view = greed.view()
		return view:buffer():line_of(view:cursor())
	end
	assert(follow("Week 42#Plans") == 5, "the heading")
	assert(follow("key-point") == 7, "the block")
	assert(follow("w42") == 0, "the alias's note")
end)

test("the Tasks plugin's due dates are due dates", function(t)
	vault(t)
	local found = nil
	for _, todo in notes.todos.list() do
		if string.find(todo.text, "call the bank", 1, true) then
			found = todo
		end
	end
	assert(found and found.due == "2026-10-20", "due")
	assert(notes.todos.plain(found.text) == "call the bank", notes.todos.plain(found.text))
end)

-- The lines drawn under the line with `text` in the buffer in view.
local function embedded(text: string): string?
	local buffer = greed.view():buffer()
	local at = string.find(buffer:text(), text, 1, true)
	assert(at, text)
	for _, mark in buffer:decorations("notes") do
		if mark.lines and mark.from <= at - 1 and at - 1 < mark.to then
			local out = {}
			for _, line in mark.lines do
				if type(line) == "string" then
					table.insert(out, line)
				else
					local pieces = {}
					for _, piece in line do
						table.insert(pieces, piece.text)
					end
					table.insert(out, table.concat(pieces))
				end
			end
			return table.concat(out, "\n")
		end
	end
	return nil
end

test("embeds show the note, the heading's section or the block in place", function(t)
	local dir = vault(t)
	greed.fs.write(
		`{dir}/Sunday.md`,
		"![[Week 42#Plans]]\n![[Week 42#^key-point]]\n![[Monday]]\n![[Nowhere]]\n"
	)
	greed.open(`{dir}/Sunday.md`)
	t:wait_for(function()
		return embedded("![[Nowhere]]") ~= nil
	end)
	local plans = embedded("![[Week 42#Plans]]") :: string
	assert(string.find(plans, "^│ ## Plans"), plans)
	assert(string.find(plans, "call the bank", 1, true), plans)
	assert(not string.find(plans, "# Week 42\n", 1, true), "only the section")
	local point = embedded("#^key-point") :: string
	assert(point == "│ A paragraph that matters.", point)
	local monday = embedded("![[Monday]]") :: string
	assert(string.find(monday, "Back to [[w42]]", 1, true), monday)
	local nowhere = embedded("![[Nowhere]]") :: string
	assert(string.find(nowhere, "isn't there", 1, true), nowhere)
end)

test("an embed shows what its note says now", function(t)
	local dir = vault(t)
	greed.fs.write(`{dir}/Sunday.md`, "![[Tuesday]]\n")
	greed.open(`{dir}/Sunday.md`)
	t:wait_for(function()
		return embedded("![[Tuesday]]") ~= nil
	end)
	greed.fs.write(`{dir}/Tuesday.md`, "Changed my mind.\n")
	notes.index.refresh()
	t:wait_for(function()
		return string.find(embedded("![[Tuesday]]") or "", "Changed my mind", 1, true) ~= nil
	end)
end)

test("a long note's embed is cut short", function(t)
	local dir = vault(t)
	local lines = {}
	for n = 1, 100 do
		table.insert(lines, `line {n}`)
	end
	greed.fs.write(`{dir}/Long.md`, table.concat(lines, "\n") .. "\n")
	greed.fs.write(`{dir}/Sunday.md`, "![[Long]]\n")
	greed.open(`{dir}/Sunday.md`)
	t:wait_for(function()
		return embedded("![[Long]]") ~= nil
	end)
	local shown = string.split(embedded("![[Long]]") :: string, "\n")
	assert(#shown < 50, tostring(#shown))
	assert(shown[#shown] == "│ …", shown[#shown])
end)

-- Runs :notes-link in note `name`, typing `query` in the picker and taking
-- the best match; gives back the note's text.
local function link(t: test.TestContext, dir: string, name: string, query: string): string
	greed.open(`{dir}/{name}.md`)
	local view = greed.view()
	view:set_cursor(view:buffer():len())
	t:run("notes-link", {})
	t:keys(table.concat(string.split(query, ""), " "))
	t:keys("enter")
	return view:buffer():text()
end

test(":notes-link links to a heading, and to a block by its id", function(t)
	local dir = vault(t)
	local text = link(t, dir, "Tuesday", "Week 42 ## Plans")
	assert(string.find(text, "[[Week 42#Plans]]", 1, true), text)
	text = link(t, dir, "Tuesday", "key-point")
	assert(string.find(text, "[[Week 42#^key-point]]", 1, true), text)
end)

test(":notes-link gives a list item an id when it has none", function(t)
	local dir = vault(t)
	local text = link(t, dir, "Tuesday", "call the bank")
	local id = string.match(text, "%[%[Week 42#%^(%x+)%]%]")
	assert(id, text)
	local week = greed.fs.read(`{dir}/Week 42.md`) or ""
	for _, buffer in greed.buffers() do
		if buffer:path() == `{dir}/Week 42.md` then
			week = buffer:text()
		end
	end
	assert(string.find(week, `- [ ] call the bank 📅 2026-10-20 ^{id}\n`, 1, true), week)
end)

test(":notes-link in the note itself leaves out its name", function(t)
	local dir = vault(t)
	local text = link(t, dir, "Week 42", "Week 42 ## Plans")
	assert(string.find(text, "[[#Plans]]", 1, true), text)
end)

-- Note `name`'s text once `wanted` is in it.
local function once(t: test.TestContext, name: string, wanted: string): string
	local text = ""
	t:wait_for(function()
		text = notes.read(name) or ""
		return string.find(text, wanted, 1, true) ~= nil
	end)
	return text
end

test("renaming a note changes the links to it, but not those to its aliases", function(t)
	local dir = vault(t)
	greed.fs.write(`{dir}/Sunday.md`, "![[Week 42]] and [[Week 42]]\n")
	notes.index.refresh()
	greed.open(`{dir}/Week 42.md`)
	t:run("file-rename", { "Week 43.md" })
	local monday = once(t, "Monday", "Week 43#Plans")
	assert(
		monday == "Back to [[w42]], see [[Week 43#Plans]] and [[Week 43#^key-point|the point]].\n",
		monday
	)
	local sunday = once(t, "Sunday", "Week 43")
	assert(sunday == "![[Week 43]] and [[Week 43]]\n", sunday)
	assert(notes.read("Tuesday") == "About [[This Week]].\n", "an alias stays")
end)

test("a link in an open note changes in its buffer", function(t)
	local dir = vault(t)
	greed.open(`{dir}/Monday.md`)
	local buffer = greed.view():buffer()
	require("@core").file.rename(`{dir}/Week 42.md`, `{dir}/Weekly.md`)
	t:wait_for(function()
		return string.find(buffer:text(), "[[Weekly#Plans]]", 1, true) ~= nil
	end)
	assert(greed.fs.read(`{dir}/Monday.md`) == buffer:text(), "and saved")
end)

test("moving a folder of notes changes the links into it", function(t)
	local dir = vault(t)
	greed.fs.mkdir(`{dir}/plans`)
	greed.fs.write(`{dir}/plans/Trip.md`, "Pack.\n")
	greed.fs.write(`{dir}/Sunday.md`, "See [[plans/Trip|the trip]].\n")
	notes.index.refresh()
	require("@core").file.rename(`{dir}/plans`, `{dir}/later`)
	local sunday = once(t, "Sunday", "later/Trip")
	assert(sunday == "See [[later/Trip|the trip]].\n", sunday)
end)
