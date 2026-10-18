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
