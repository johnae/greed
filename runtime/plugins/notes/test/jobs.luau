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

test("a schedule is read as JOB DAY HH:MM, and says what it can't read", function()
	local schedule, wrong = notes.jobs.schedule(
		"week-less daily 8:00, connect weekdays 8:05, todos daily 09:00, ask monday 10:00"
	)
	assert(#schedule == 1 and schedule[1].job == "connect", tostring(#schedule))
	assert(schedule[1].day == "weekdays" and schedule[1].time == "08:05", schedule[1].time)
	local said = table.concat(wrong, " | ")
	assert(string.find(said, "no notes job week-less", 1, true), said)
	assert(string.find(said, "todos needs a note", 1, true), said)
	assert(string.find(said, "ask needs a question", 1, true), said)
	local _, bad = notes.jobs.schedule("connect someday 08:00, connect daily soon")
	assert(#bad == 2, table.concat(bad, " | "))
	assert(#notes.jobs.schedule("") == 0)
end)

test("a scheduled job is due once its time has come that day, and once", function()
	local schedule = notes.jobs.schedule("connect friday 16:00, connect weekdays 08:00")
	local function due(today: string, now: string, ran: any): string
		local out = {}
		for _, entry in notes.jobs.due(schedule, ran or {}, today, now) do
			table.insert(out, `{entry.day} {entry.time}`)
		end
		return table.concat(out, ",")
	end
	-- 2026-10-23 is a Friday, 2026-10-24 a Saturday.
	assert(due("2026-10-23", "07:59") == "", due("2026-10-23", "07:59"))
	assert(due("2026-10-23", "16:00") == "friday 16:00,weekdays 08:00", due("2026-10-23", "16:00"))
	assert(due("2026-10-24", "18:00") == "", "not on a Saturday")
	local ran = { connect = { slot = "2026-10-23 16:00", at = 0 } }
	assert(due("2026-10-23", "17:00", ran) == "", "ran today already")
	assert(due("2026-10-26", "09:00", ran) == "weekdays 08:00", "Monday's comes")
end)

test("a scheduled job runs quietly in the background when there's something new", function(t)
	local asked = asked_model()
	local dir = t:tempdir({ ["inbox.md"] = "- a thought to file\n" })
	greed.option.set("notes-folder", dir)
	greed.option.set("notes-project-folder", `{dir}/.no-project-notes`)
	notes.index.ensure()
	greed.option.set("notes-agent-schedule", "connect daily 00:00")
	local before = greed.view():buffer()
	local started = notes.jobs.tick()
	assert(table.concat(started, ",") == "connect", table.concat(started, ","))
	local said = first_said(t, asked)
	assert(string.find(said, "my inbox note", 1, true), said)
	assert(greed.view():buffer() == before, "the transcript didn't take the window")
	assert(#notes.jobs.tick() == 0, "once a day")
end)

test("a scheduled job with nothing new to work on is skipped", function(t)
	local asked = asked_model()
	local dir = t:tempdir({})
	greed.option.set("notes-folder", dir)
	greed.option.set("notes-project-folder", `{dir}/.no-project-notes`)
	notes.index.ensure()
	greed.option.set("notes-agent-schedule", "connect daily 00:00")
	assert(#notes.jobs.tick() == 0, "no inbox")
	t:wait(1)
	assert(asked[1] == nil, "the model wasn't asked")
end)
