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
