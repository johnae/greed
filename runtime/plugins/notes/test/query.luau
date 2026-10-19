-- Notes as a source for the query language: notes, todos and headings,
-- with their fields, the flags that depend on today, and where they sit.

local test = require("@greed/test")
local greed = require("@greed")
local notes = require("@notes")
local agent = require("@agent")

local function vault(t: test.TestContext)
	local today = notes.today()
	local dates = notes.dates
	local dir = t:tempdir({
		["garden.md"] = table.concat({
			"# Garden",
			"#garden",
			"",
			"## Seeds",
			`- [ ] buy seeds due:{dates.add_days(today, 1)}`,
			`- [x] dig the bed done:{today}`,
			"",
		}, "\n"),
		["kitchen.md"] = `- [ ] fix the tap due:{dates.add_days(today, -1)}\n`,
		[`daily/{today}.md`] = "- [ ] call mum\n",
		["habits.md"] = "- [ ] stretch every:day!\n",
	})
	greed.option.set("notes-folder", dir)
	greed.option.set("notes-project-folder", `{dir}/.no-project-notes`)
	notes.index.ensure()
end

-- What `text` finds, as each item's words, in its order.
local function found(text: string): string
	local items, problems = notes.query.run(text)
	assert(items, if problems[1] then problems[1].message else "no items")
	local out = {}
	for _, item in items do
		local node = item.node
		local task = if node then node.task else nil
		table.insert(
			out,
			if task then notes.todos.plain(task.text) elseif node then node.text else item.note.name
		)
	end
	return table.concat(out, ", ")
end

test("todos are found by when they're due, their tags and their note's", function(t)
	vault(t)
	local soon = found("is:todo is:open due:..+7d sort:due")
	assert(soon == "fix the tap, stretch, buy seeds", soon)
	local in_garden = found("is:todo in:(tag:garden) sort:title")
	assert(in_garden == "buy seeds, dig the bed", in_garden)
	assert(found("is:todo tag:garden is:open") == "buy seeds", "a todo has its note's tags")
	assert(found("done:today") == "dig the bed")
end)

test("what depends on today is a flag: overdue, today, habit", function(t)
	vault(t)
	assert(found("is:overdue") == "fix the tap", found("is:overdue"))
	local today = found("is:today sort:title")
	assert(
		string.find(today, "call mum", 1, true) and string.find(today, "stretch", 1, true),
		today
	)
	assert(found("is:habit") == "stretch")
	assert(found("is:recurring") == "stretch")
end)

test("notes are found by what they hold, and headings by their words", function(t)
	vault(t)
	local holding = found("is:note has:(is:todo is:open) sort:note")
	assert(holding == `daily/{notes.today()}, garden, habits, kitchen`, holding)
	assert(found("is:heading seeds") == "Seeds")
end)

test("a query with a mistake says so, and agents get the same", function(t)
	vault(t)
	local items, problems = notes.query.run("is:todo dew:today")
	assert(items == nil and #problems > 0, "a mistake")
	assert(string.find(problems[1].message, "dew", 1, true), problems[1].message)
	local function run_tool(args: { [string]: any }): any
		for _, tool in agent.tools() do
			if tool.name == "notes_query" then
				return tool.run(args, agent.caller())
			end
		end
		error("no notes_query")
	end
	local answer = run_tool({ query = "is:overdue" })
	assert(answer.count == 1 and answer.found[1].text == "fix the tap", answer.count)
	local wrong = run_tool({ query = "dew:today" })
	assert(#wrong.problems > 0, "problems back")
end)

test("a notes block in a note shows what its query finds, and keeps up", function(t)
	vault(t)
	local dir = greed.option.get("notes-folder") :: string
	greed.fs.write(`{dir}/agenda.md`, "# Soon\n\n```notes\nis:todo is:open is:overdue\n```\n")
	notes.index.refresh()
	greed.open(`{dir}/agenda.md`)
	local buffer = greed.view():buffer()
	local function shown(): string
		local out = {}
		for _, mark in buffer:decorations("data-blocks") do
			local lines: { greed.MarkLine } = mark.lines or {}
			for _, line in lines do
				if type(line) == "string" then
					table.insert(out, line)
				else
					for _, piece in line do
						table.insert(out, piece.text)
					end
				end
			end
		end
		return table.concat(out, " ")
	end
	t:wait_for(function()
		return string.find(shown(), "fix the tap", 1, true) ~= nil
	end)
	greed.fs.write(
		`{dir}/kitchen.md`,
		`- [ ] fix the sink due:{notes.dates.add_days(notes.today(), -2)}\n`
	)
	notes.index.refresh()
	t:wait_for(function()
		return string.find(shown(), "fix the sink", 1, true) ~= nil
	end)
end)

test("a todo in a notes block is ticked from its row, and the note opened", function(t)
	vault(t)
	local dir = greed.option.get("notes-folder") :: string
	greed.fs.write(`{dir}/agenda.md`, "# Soon\n\n```notes\nis:overdue\n```\n")
	notes.index.refresh()
	greed.open(`{dir}/agenda.md`)
	local view = greed.view()
	t:wait_for(function()
		local found = false
		for _, mark in view:buffer():decorations("data-blocks") do
			found = found or string.find(tostring(mark.text), "1 row", 1, true) ~= nil
		end
		return found
	end)
	local at = assert((string.find(view:buffer():text(), "```notes", 1, true))) - 1
	view:set_selection({ ranges = { { anchor = at, head = at } }, primary = 1 })
	t:keys("space m o")
	local float = greed.view()
	local shown = float:buffer()
	t:wait_for(function()
		return string.find(shown:slice(0, shown:len()), "fix the tap", 1, true) ~= nil
	end)
	local row = assert((string.find(shown:slice(0, shown:len()), "fix the tap", 1, true))) - 1
	float:set_selection({ ranges = { { anchor = row, head = row } }, primary = 1 })
	t:keys("enter")
	local record = greed.view():buffer()
	local text = record:slice(0, record:len())
	local tick = assert(string.find(text, "Tick or untick", 1, true), text) - 1
	greed.view():set_selection({ ranges = { { anchor = tick, head = tick } }, primary = 1 })
	t:keys("enter")
	t:wait_for(function()
		return string.find(greed.fs.read(`{dir}/kitchen.md`) or "", "- [x] fix the tap", 1, true)
			~= nil
	end)
	-- Open, on another row: the floats close and the note is where it is.
	greed.fs.write(
		`{dir}/kitchen.md`,
		`- [ ] call the plumber due:{notes.dates.add_days(notes.today(), -1)}\n`
	)
	notes.index.refresh()
	local again_button = assert((string.find(shown:slice(0, shown:len()), "Read again", 1, true)))
		- 1
	float:set_selection({ ranges = { { anchor = again_button, head = again_button } }, primary = 1 })
	t:keys("enter")
	t:wait_for(function()
		return string.find(shown:slice(0, shown:len()), "call the plumber", 1, true) ~= nil
	end)
	local again = assert((string.find(shown:slice(0, shown:len()), "call the plumber", 1, true)))
		- 1
	float:set_selection({ ranges = { { anchor = again, head = again } }, primary = 1 })
	t:keys("enter")
	local second = greed.view():buffer()
	local open = assert((string.find(second:slice(0, second:len()), "Open", 1, true))) - 1
	greed.view():set_selection({ ranges = { { anchor = open, head = open } }, primary = 1 })
	t:keys("enter")
	t:wait_for(function()
		return greed.view():buffer():path() == `{dir}/kitchen.md`
	end)
	assert(not float:valid(), "the table closed")
end)

test("front matter's lists and links are fields, and its date is the note's", function(t)
	local dir = t:tempdir({
		["Blade Runner.md"] = '---\ngenre:\n  - "[[Sci-fi]]"\n  - Noir\ndirector: "[[Ridley Scott]]"\nyear: 1982\n---\n',
		["Meeting.md"] = "---\ndate: 2023-09-12\npeople: [Steph, Ann]\n---\n",
		["Other.md"] = "# Other\n",
	})
	greed.option.set("notes-folder", dir)
	greed.option.set("notes-project-folder", `{dir}/.no-project-notes`)
	notes.index.ensure()
	assert(found("is:note genre:sci-fi") == "Blade Runner", found("is:note genre:sci-fi"))
	assert(found("is:note genre:noir") == "Blade Runner")
	assert(found("is:note director:ridley") == "Blade Runner", found("is:note director:ridley"))
	assert(found("is:note people:ann") == "Meeting")
	assert(found("is:note date:2023-09-12") == "Meeting", found("is:note date:2023-09-12"))
end)
