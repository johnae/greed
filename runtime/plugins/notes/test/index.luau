local test = require("@greed/test")
local greed = require("@greed")
local syntax = require("../syntax")
local index = require("../index")

local function folder(t: test.TestContext, files: { [string]: string }?): string
	local dir = t:tempdir(files)
	greed.option.set("notes-folder", dir)
	greed.option.set("notes-project-folder", `{dir}/.no-project-notes`)
	return dir
end

local function sorted_keys(t: { [string]: any }): string
	local out = {}
	for key in t do
		table.insert(out, key)
	end
	table.sort(out)
	return table.concat(out, ",")
end

test("links, embeds, headings and blocks in them are read from a line", function()
	local links =
		syntax.links("see [[Plans#Next week|next]] and ![[diagram]] or `[[not]]` [[a#^b1]]")
	assert(#links == 3, tostring(#links))
	assert(
		links[1].target == "Plans" and links[1].heading == "Next week" and links[1].shown == "next"
	)
	assert(not links[1].embed)
	assert(
		links[2].target == "diagram" and links[2].embed and links[2].from == 34,
		tostring(links[2].from)
	)
	assert(links[3].target == "a" and links[3].block == "b1" and links[3].heading == nil)
end)

test("tags are words after a #, in any language, and not headings or numbers", function()
	local tags = syntax.tags("#möte with #work/greed, and #2026 or an issue #12 `#code` x#y #ok.")
	assert(table.concat(tags, ",") == "möte,work/greed,ok", table.concat(tags, ","))
	assert(#syntax.tags("# Heading") == 0, "a heading")
end)

test("a line's block id and fields are read", function()
	assert(syntax.block_id("- an idea ^idea-1") == "idea-1")
	assert(syntax.block_id("^solo") == "solo")
	assert(syntax.block_id("costs 5 ^ 2") == nil)
	local fields = syntax.fields("- Status:: waiting")
	assert(fields.status == "waiting", sorted_keys(fields))
	local inline = syntax.fields("met [who:: Anna] about [topic:: plans]")
	assert(inline.who == "Anna" and inline.topic == "plans", sorted_keys(inline))
end)

test("a note reads as its title, tree, todos, tags, links, fields and reminders", function()
	local text = table.concat({
		"---",
		"title: Week 42",
		"tags: [work, Planning]",
		"aliases:",
		"  - w42",
		"---",
		"# Plans",
		"owner:: me",
		"## Monday",
		"- [ ] call the bank due:2026-10-20 remind:2026-10-19 18:00 #errand",
		"  - bring papers ^papers",
		"- talk to [[Anna]] about [[projects/greed#Hoard]]",
		"```sh",
		"# not a heading, [[not a link]] #nope",
		"```",
		"Look again remind:2026-10-21",
		"",
	}, "\n")
	local note = index.parse("week", "/n/week.md", text)
	assert(note.title == "Week 42", note.title)
	assert(sorted_keys(note.tags) == "errand,planning,work", sorted_keys(note.tags))
	local aliases = note.front.aliases :: any
	assert(aliases[1] == "w42")
	assert(note.fields.owner == "me" and note.fields.title == "Week 42")
	local kinds = {}
	for _, node in note.nodes do
		table.insert(kinds, `{node.kind}:{node.text}:{node.parent or 0}`)
	end
	assert(
		table.concat(kinds, "|")
			== "heading:Plans:0|heading:Monday:1|item:call the bank #errand:2|item:bring papers:3|item:talk to [[Anna]] about [[projects/greed#Hoard]]:2",
		table.concat(kinds, "|")
	)
	local task = assert(note.nodes[3].task)
	assert(not task.done and task.due == "2026-10-20" and task.reminds[1] == "2026-10-19 18:00")
	assert(note.nodes[4].id == "papers")
	assert(
		#note.links == 2
			and note.links[2].target == "projects/greed"
			and note.links[2].heading == "Hoard"
	)
	assert(#note.reminders == 2, tostring(#note.reminders))
	assert(note.reminders[2].text == "Look again" and note.reminders[2].date == "2026-10-21")
end)

test(
	"the index reads every note, follows changes on disk, and knows backlinks and tags",
	function(t)
		local dir = folder(t, {
			["a.md"] = "# A\nsee [[b]] #idea\n",
			["b.md"] = "# B\n- [ ] do it\n",
			["deep/c.md"] = "links to [[b]] and [[a]]\n",
		})
		local done = false
		greed.spawn(function()
			index.ensure()
			done = true
		end)
		t:wait_for(function()
			return done
		end)
		local names = {}
		for _, note in index.all() do
			table.insert(names, note.name)
		end
		assert(table.concat(names, ",") == "a,b,deep/c", table.concat(names, ","))
		assert(table.concat(index.backlinks("b"), ",") == "a,deep/c")
		assert(table.concat(index.tagged("IDEA"), ",") == "a")

		-- A note changed, one added and one removed outside the editor.
		greed.fs.write(`{dir}/a.md`, "# A\nno more links\n")
		greed.fs.write(`{dir}/d.md`, "[[b]]\n")
		greed.fs.remove(`{dir}/deep/c.md`)
		local heard: { string } = {}
		index.on_changed(function(name)
			table.insert(heard, name)
		end)
		done = false
		greed.spawn(function()
			index.refresh()
			done = true
		end)
		t:wait_for(function()
			return done
		end)
		assert(
			table.concat(index.backlinks("b"), ",") == "d",
			table.concat(index.backlinks("b"), ",")
		)
		assert(#index.tagged("idea") == 0, "the tag went with its line")
		assert(index.note("deep/c") == nil, "removed")
		table.sort(heard)
		assert(table.concat(heard, ",") == "a,d,deep/c", table.concat(heard, ","))
	end
)

test("a note being typed in is indexed from its buffer", function(t)
	local dir = folder(t, { ["e.md"] = "# E\n" })
	local done = false
	greed.spawn(function()
		index.ensure()
		done = true
	end)
	t:wait_for(function()
		return done
	end)
	greed.open(`{dir}/e.md`)
	t:keys("G o")
	t:keys("[ [ f ] ]")
	t:keys("esc")
	t:wait_for(function()
		return #index.backlinks("f") == 1
	end)
	assert(index.backlinks("f")[1] == "e")
end)

-- Where `a` and `b` first differ, or nil when they're the same.
local function difference(a: any, b: any, path: string): string?
	if type(a) ~= "table" or type(b) ~= "table" then
		return if a == b then nil else `{path}: {tostring(a)} ~= {tostring(b)}`
	end
	for key, value in a do
		local found = difference(value, b[key], `{path}.{key}`)
		if found then
			return found
		end
	end
	for key, value in b do
		if a[key] == nil then
			return `{path}.{key}: nil ~= {tostring(value)}`
		end
	end
	return nil
end

test("notes read with sikt are the same as read line by line", function()
	-- Pieces of lines, common and odd, put together every way below.
	local pieces = {
		"buy seeds",
		"due:2026-11-01",
		"due:2026-11-01 due:2026-12-01",
		"overdue:2026-11-02",
		"from:2026-01-01  until:2026-02-01",
		"every:mon,tue!",
		"every:day",
		"done:2026-10-18",
		"#garden",
		"#2026",
		"#a/b-c_d.",
		"word#nottag",
		"[[shop]]",
		"![[photo.png]]",
		"[[note#Heading|shown]]",
		"[[a [[b]]",
		"[[]] [[c]]",
		"[[x #inner]]",
		"#due:2026-11-03",
		"every:due:2026-11-04",
		"`#code [[code]] due:2026-01-01`",
		"key:: value",
		"[kind:: thing]",
		"^block-1",
		"remind:2026-10-06 18:00",
		"remind:9:30",
		"📅 2026-11-05",
		"🔁 every week on Monday",
		"  ",
	}
	local starts = { "- [ ] ", "- [x] ", "  * [X] ", "- [ ]  ", "1. ", "- ", "## ", "", "> - [ ] " }
	local lines = {}
	for _, start in starts do
		for i, a in pieces do
			for j, b in pieces do
				if (i + j) % 3 == 0 or i == 1 then
					table.insert(lines, `{start}{a} {b}`)
				end
			end
		end
	end
	-- Notes of a few dozen lines, with headings, front matter and code.
	local texts = { "---\ntags: [x]\ntitle: T\n---\n# Front\n- [ ] after due:2026-01-01" }
	for first = 1, #lines, 40 do
		local chunk = table.move(lines, first, math.min(first + 39, #lines), 1, {})
		table.insert(chunk, 1, "# Note")
		table.insert(chunk, 10, "```\n- [ ] in code #nottag\n```")
		table.insert(chunk, 20, "Title\n===")
		table.insert(texts, table.concat(chunk, "\n") .. "\n")
	end
	-- Each read alone, and read many at once.
	local many = index.read(texts)
	for i, text in texts do
		index.SIKT = false
		local slowly = index.parse(`n{i}`, `/x/n{i}.md`, text)
		index.SIKT = true
		local found = difference(slowly, index.parse(`n{i}`, `/x/n{i}.md`, text), `note {i}`)
			or difference(slowly, index.parse(`n{i}`, `/x/n{i}.md`, text, many[i]), `read {i}`)
		assert(found == nil, found)
	end
end)

test("in a table, a link's bar is written \\| and still parts its name from its words", function()
	local links = syntax.links("| [[List view\\|List]] | a [[Basic syntax#Lists\\|list]] |")
	assert(links[1].target == "List view" and links[1].shown == "List", links[1].target)
	assert(links[2].target == "Basic syntax" and links[2].heading == "Lists", links[2].target)
end)

test("links find notes as Obsidian does: by file name in any folder, in any case", function(t)
	folder(t, {
		["Bases/Layouts/Cards view.md"] = "# Cards view\n",
		["Bases/Views.md"] = "See [[cards view]], [[Cards view.md]] and [[Bases/Layouts/Cards view]].\n",
		["Work/Plan.md"] = "# Work plan\n",
		["Home/Plan.md"] = "# Home plan\n",
		["Work/Today.md"] = "- [[Plan]]\n",
		["Elsewhere/Note.md"] = "- [[Plan]]\n",
		["Elsewhere/Deep/Plan.md"] = "# Deep plan\n",
		["Elsewhere/Ref.md"] = "[[deep/Plan]]\n",
		["Movies/Blade Runner.md"] = '---\ncategories:\n  - "[[Movies]]"\n---\n',
		["Movies.md"] = "# Movies\n",
	})
	index.ensure()
	assert(index.linked("cards view") == "Bases/Layouts/Cards view", index.linked("cards view"))
	assert(index.linked("Cards view.md") == "Bases/Layouts/Cards view")
	assert(index.linked("nothing like it") == "nothing like it", "a note to make")
	-- Several with that name: the one beside the link, else the nearest
	-- the top (by name, when they're as near).
	assert(index.linked("Plan", "Work/Today") == "Work/Plan", index.linked("Plan", "Work/Today"))
	assert(
		index.linked("Plan", "Elsewhere/Note") == "Home/Plan",
		index.linked("Plan", "Elsewhere/Note")
	)
	local back = table.concat(index.backlinks("Bases/Layouts/Cards view"), ",")
	assert(back == "Bases/Views", back)
	assert(table.concat(index.backlinks("Work/Plan"), ",") == "Work/Today")
	assert(table.concat(index.backlinks("Home/Plan"), ",") == "Elsewhere/Note")
	-- Deeper than another of its name, it's found by the end of its path.
	local deep = table.concat(index.backlinks("Elsewhere/Deep/Plan"), ",")
	assert(deep == "Elsewhere/Ref", deep)
	-- A link naming folders finds the note whose path ends that way.
	assert(index.linked("deep/plan") == "Elsewhere/Deep/Plan", index.linked("deep/plan"))
	assert(index.linked("Layouts/Cards view") == "Bases/Layouts/Cards view")
	assert(index.linked("Other/Plan") == "Other/Plan", "no such ending: a note to make")
	-- A link in front matter is a link too.
	assert(table.concat(index.backlinks("Movies"), ",") == "Movies/Blade Runner")
end)
