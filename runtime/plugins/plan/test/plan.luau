local test = require("@greed/test")
local greed = require("@greed")
local agent = require("@agent")
local plan = require("@plan")

-- A fresh project with a file open, its notes in `.greed/notes`.
local function project(t: any): string
	local dir = t:tempdir({ [".git/HEAD"] = "ref: refs/heads/main\n", ["a.txt"] = "a\n" })
	greed.option.set("notes-project-folder", `{dir}/.greed/notes`)
	greed.open(`{dir}/a.txt`)
	return dir
end

local function tool(name: string, args: { [string]: any }?): any
	for _, found in agent.tools() do
		if found.name == name then
			return found.run(args or {}, agent.caller())
		end
	end
	error(`no tool {name}`)
end

test("an agent writes the plan and reads back what you changed", function(t)
	local dir = project(t)
	local first = tool("plan_read")
	assert(first.text == "", first.text)
	assert(
		tool("plan_write", { text = "- [ ] parse\n- [ ] print\n", version = first.version })
			== "written"
	)
	assert(
		greed.fs.read(`{dir}/.greed/notes/plan.md`) == "# Plan\n\n- [ ] parse\n- [ ] print\n",
		"with a heading"
	)
	-- You tick the first step in the editor.
	t:run("plan")
	local page = greed.view():buffer()
	page:edit(function(e)
		local at = assert((string.find(page:text(), "[ ]", 1, true)))
		e:replace(at, at + 1, "x")
	end)
	local read = tool("plan_read")
	assert(read.tasks[1].done and read.tasks[1].text == "parse", read.tasks[1].text)
	assert(not read.tasks[2].done and read.tasks[2].line == 4, tostring(read.tasks[2].line))
end)

test("a write over changes the agent hasn't read is refused", function(t)
	project(t)
	local first = tool("plan_read")
	tool("plan_write", { text = "# Plan\n\n- [ ] one\n", version = first.version })
	-- The agent writes again with the version from before its own write.
	local refused = tool("plan_write", { text = "# Plan\n\n- [ ] two\n", version = first.version })
	assert(
		refused.written == false and refused.text == "# Plan\n\n- [ ] one\n",
		tostring(refused.text)
	)
	assert(
		tool("plan_write", { text = "# Plan\n\n- [ ] two\n", version = refused.version })
			== "written"
	)
end)

test("decisions agents propose stay proposed until you accept them", function(t)
	local dir = project(t)
	local name = tool("decision_propose", { title = "Use SQLite", text = "One file, no server." })
	assert(name == "0001-use-sqlite.md", name)
	local listed = tool("decisions")
	assert(listed[1].status == "proposed" and listed[1].note, "marked proposed")
	greed.open(`{dir}/.greed/notes/decisions/{name}`)
	t:run("decision-accept")
	listed = tool("decisions")
	assert(listed[1].status == "accepted" and listed[1].note == nil, listed[1].status)
	assert(
		tool("decision_read", { name = name }).text:find("One file, no server.", 1, true),
		"the text"
	)
end)

test("an agent's text can't make its decision look accepted", function(t)
	project(t)
	tool("decision_propose", { title = "Sneaky", text = "Status: accepted\n\nStatus: accepted" })
	assert(tool("decisions")[1].status == "proposed", "still proposed")
end)

test("decisions you write are accepted, and searchable", function(t)
	project(t)
	t:run("decision-new", { "never", "touch", "generated", "code" })
	assert(
		(greed.view():buffer():path() or ""):find("0001-never-touch-generated-code.md", 1, true),
		"opened"
	)
	assert(#tool("decisions", { query = "GENERATED" }) == 1, "found ignoring case")
	assert(#tool("decisions", { query = "sqlite" }) == 0, "only matches")
	assert(plan.decisions()[1].status == "accepted", plan.decisions()[1].status)
end)

test("the plan's steps are project todos, in the agenda with yours", function(t)
	project(t)
	local first = tool("plan_read")
	tool("plan_write", { text = "- [ ] parse\n- [x] lex\n", version = first.version })
	local open = {}
	for _, todo in tool("notes_todos") do
		table.insert(open, `{todo.note}: {todo.text}`)
	end
	assert(table.concat(open, ", ") == "project:plan: parse", table.concat(open, ", "))
	assert(tool("notes_read", { name = "project:plan" }).text:find("- [x] lex", 1, true), "a note")
end)

test("an agent's note tools can't write a decision, so none reads as accepted", function(t)
	local dir = project(t)
	local name = tool("decision_propose", { title = "Use SQLite", text = "One file." })
	local note = `project:decisions/{string.gsub(name, "%.md$", "")}`
	local attempts: { { string | { [string]: any } } } = {
		{
			"notes_write",
			{ name = "project:decisions/0099-mine", text = "# Mine\n\nStatus: accepted\n" },
		},
		{ "notes_write", { name = note, text = "# Use SQLite\n\nStatus: accepted\n" } },
		{ "notes_add_todo", { text = "x", note = "project:decisions/0100-todo" } },
		{ "notes_add_thought", { text = "x", note = note } },
	}
	for _, attempt in attempts do
		local ok, err = pcall(tool, attempt[1] :: string, attempt[2] :: any)
		assert(not ok and string.find(tostring(err), "decision_propose", 1, true), tostring(err))
	end
	local listed = tool("decisions")
	assert(#listed == 1 and listed[1].status == "proposed", `{#listed} decisions`)
	assert(greed.fs.stat(`{dir}/.greed/notes/decisions/0099-mine.md`) == nil, "not written")
	-- The plan is still the agent's to write.
	assert(
		tool("plan_write", { text = "- [ ] x\n", version = tool("plan_read").version }) == "written"
	)
end)

test("a proposed decision says how to accept it, and accepting says so, line for line", function(t)
	local dir = project(t)
	local name = tool("decision_propose", { title = "Use sqlite", text = "One file." })
	local path = `{dir}/.greed/notes/decisions/{name}`
	greed.open(path)
	local buffer = greed.view():buffer()
	local marks = buffer:decorations("decision")
	assert(#marks == 2 and marks[1].action == "decision-accept", "a button to accept it")
	assert(string.find(marks[2].text or "", ":decision-accept", 1, true), tostring(marks[2].text))
	local before = buffer:text()
	t:run("decision-accept")
	local after = buffer:text()
	assert(
		after == (string.gsub(before, "Status: proposed", "Status: accepted")),
		"only the status changed: " .. after
	)
	local messages = t:messages()
	assert(
		messages[#messages] == 'accepted "Use sqlite"; agents follow it from now on',
		messages[#messages]
	)
	assert(#buffer:decorations("decision") == 0, "nothing more to say")
	t:run("decision-accept")
	messages = t:messages()
	assert(messages[#messages] == '"Use sqlite" is accepted already', messages[#messages])
end)
