local test = require("@greed/test")
local greed = require("@greed")
local notes = require("@notes")
local models: any = require("@models")

-- What the model is asked, each request as it came.
local function asked_model(): { any }
	local asked: { any } = {}
	models.turn = function(_role, request)
		table.insert(asked, table.clone(request))
		return { text = "Done.", calls = {}, stop = "done" }, nil
	end
	return asked
end

-- What the first request said, once it's there.
local function first_said(t: test.TestContext, asked: { any }): string
	t:wait_for(function()
		return asked[1] ~= nil
	end)
	return asked[1].said[1].text
end

test("notes-connect starts Greed's agent on the inbox with the notes tools on", function(t)
	local asked = asked_model()
	t:buffer("|x")
	t:run("notes-connect")
	local said = first_said(t, asked)
	assert(string.find(said, "my inbox note", 1, true), said)
	assert(string.find(said, "only with the propose tool", 1, true) ~= nil)
	local names: { [string]: boolean } = {}
	for _, tool in asked[1].tools do
		names[tool.name] = true
	end
	assert(names["notes_search"] and names["notes_add_thought"], "the notes tools are on")
end)

test("a job on a note needs one, and is told which", function(t)
	local asked = asked_model()
	local ok, why = notes.jobs.run("todos")
	assert(not ok and string.find(why or "", "open one first", 1, true), why)
	local dir = t:tempdir({ ["Standup.md"] = "Anna will send the budget.\n" })
	ok = notes.jobs.run("todos", `{dir}/Standup.md`)
	assert(ok, "started")
	local said = first_said(t, asked)
	assert(string.find(said, `{dir}/Standup.md`, 1, true), said)
	assert(string.find(said, "## Todos", 1, true), said)
end)

test("notes-ask asks the notes, and a question is needed", function(t)
	local asked = asked_model()
	local ok = notes.jobs.run("ask", nil, "  ")
	assert(not ok, "no question")
	t:buffer("|x")
	t:run("notes-ask", { "when", "is", "the", "plumber", "coming?" })
	local said = first_said(t, asked)
	assert(string.find(said, "when is the plumber coming?", 1, true), said)
	assert(string.find(said, "Don't change any notes", 1, true), said)
end)

test("a plugin adds a job of its own, in place of one by that name", function(t)
	local asked = asked_model()
	local before = #notes.jobs.all()
	notes.jobs.add({
		name = "poems",
		doc = "Find the poems",
		prompt = function()
			return "Find my poems."
		end,
	})
	notes.jobs.add({
		name = "poems",
		doc = "Find the poems",
		prompt = function()
			return "Find my poems, all of them."
		end,
	})
	assert(#notes.jobs.all() == before + 1, "one poems")
	assert(notes.jobs.run("poems"))
	local said = first_said(t, asked)
	assert(string.find(said, "Find my poems, all of them.", 1, true), said)
	local ok, why = notes.jobs.run("sonnets")
	assert(not ok and string.find(why or "", "no notes job", 1, true), why)
end)

test("notes-agent lists the jobs", function(t)
	t:buffer("|x")
	t:run("notes-agent")
	local text = greed.view():buffer():text()
	for _, name in { "connect", "todos", "ask" } do
		assert(string.find(text, name, 1, true), text)
	end
end)
