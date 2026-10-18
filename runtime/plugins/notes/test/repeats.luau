-- Repeats, habits and reminders that are a time alone: how often, from and
-- until when, ticking them off, and when their reminders go off.

local test = require("@greed/test")
local greed = require("@greed")
local notes = require("@notes")
local dates = notes.dates
local syntax = notes.syntax
local todos = notes.todos
local reminders = notes.reminders

-- Runs `f` with the clock at Wednesday 14 October 2026, 10:00.
local function on_a_wednesday(f: () -> ())
	local clock = notes.clock
	notes.clock = function(): number
		return os.time({ year = 2026, month = 10, day = 14, hour = 10, min = 0 } :: any)
	end
	local ok, err = pcall(function()
		f()
	end)
	notes.clock = clock
	assert(ok, tostring(err))
end

local function folder(t: test.TestContext, files: { [string]: string }): string
	local dir = t:tempdir(files)
	greed.option.set("notes-folder", dir)
	greed.option.set("notes-project-folder", `{dir}/.no-project-notes`)
	notes.index.ensure()
	return dir
end

test("repeats come back on their next day: weekdays, several, every few", function()
	local cases = {
		{ "2026-10-14", "monday", "2026-10-19" },
		{ "2026-10-14", "monday,thursday", "2026-10-15" },
		{ "2026-10-15", "monday,thursday", "2026-10-19" },
		{ "2026-10-16", "weekday", "2026-10-19" },
		{ "2026-10-14", "2weeks", "2026-10-28" },
		{ "2026-10-14", "3days", "2026-10-17" },
		{ "2026-01-31", "month", "2026-02-28" },
	}
	for _, case in cases do
		local got = dates.next(case[1], case[2])
		assert(got == case[3], `{case[2]} after {case[1]}: {got}`)
	end
	assert(dates.known("mon,thu") and dates.known("2weeks") and not dates.known("sometimes"))
end)

test("a repeat falls on its days, counting from its start", function()
	assert(dates.falls_on("2026-10-15", "monday,thursday"), "a Thursday")
	assert(not dates.falls_on("2026-10-14", "monday,thursday"), "a Wednesday")
	assert(dates.falls_on("2026-10-28", "2weeks", "2026-10-14"), "two weeks on")
	assert(not dates.falls_on("2026-10-21", "2weeks", "2026-10-14"), "one week on")
	assert(dates.falls_on("2026-12-14", "month", "2026-10-14"), "two months on")
	assert(not dates.falls_on("2026-10-13", "day", "2026-10-14"), "before it starts")
	assert(dates.every_words("monday,thursday") == "every Mon, Thu", dates.every_words("mon,thu"))
	assert(dates.every_words("2weeks") == "every 2 weeks")
end)

-- What `text` reads as: "text|date|times|every|habit|from|until".
local function read(text: string): string
	local w = dates.read_words(text)
	return table.concat({
		w.text,
		w.date or "-",
		table.concat(w.times, ","),
		w.every or "-",
		if w.habit then "habit" else "-",
		w.from or "-",
		w["until"] or "-",
	}, "|")
end

test("plain words say how often, as a habit or not, several times, from and until", function()
	on_a_wednesday(function()
		local cases = {
			{ "vitamins every day! at 8", "vitamins|2026-10-14|08:00|day|habit|-|-" },
			{
				"water plants every monday and thursday at 18",
				"water plants|2026-10-15|18:00|monday,thursday|-|-|-",
			},
			{ "pay rent every 2 weeks", "pay rent|2026-10-14||2weeks|-|-|-" },
			{ "air the room every other day", "air the room|2026-10-14||2days|-|-|-" },
			{
				"stretch every weekday at 10:30 and 15:00 from nov 2",
				"stretch|2026-11-02|10:30,15:00|weekday|-|2026-11-02|-",
			},
			{ "pills every day until december", "pills|2026-10-14||day|-|-|2026-12-31" },
			{
				"gym every mon, wed until 2027-01-31",
				"gym|2026-10-14||monday,wednesday|-|-|2027-01-31",
			},
		}
		for _, case in cases do
			local got = read(case[1])
			assert(got == case[2], `{case[1]}: {got}`)
		end
	end)
end)

test("a line says how it repeats, from and until when, and as the Tasks plugin does", function()
	local every, habit = syntax.every("- [ ] stretch every:mon,thu! remind:10:30")
	assert(every == "mon,thu" and habit, tostring(every))
	local tasks = syntax.every("- [ ] review 🔁 every week on Monday 📅 2026-10-19")
	assert(tasks == "monday", tostring(tasks))
	assert(syntax.every("- [ ] gym 🔁 every 2 weeks") == "2weeks")
	assert(syntax.starts("x from:2026-11-01 until:2027-01-01") == "2026-11-01")
	assert(syntax.starts("x 🛫 2026-11-01") == "2026-11-01")
	assert(syntax.ends("x from:2026-11-01 until:2027-01-01") == "2027-01-01")
	local reminder = syntax.reminders("stretch remind:10:30 remind:2026-10-20 18:00")
	assert(
		#reminder == 2 and reminder[1].date == nil and reminder[1].time == "10:30",
		"a time alone"
	)
	assert(reminder[2].date == "2026-10-20" and reminder[2].time == "18:00", "with a date")
	local plain = syntax.plain(
		"stretch every:weekday! remind:10:30 from:2026-11-01 until:2027-01-01 done:2026-10-14 🔁 every day"
	)
	assert(plain == "stretch", plain)
end)

test("a todo captured as a habit has its days and reminders, but no due date", function(t)
	local dir = folder(t, {})
	on_a_wednesday(function()
		local said = todos.capture("vitamins every day! at 8 and 20:00", "inbox")
		assert(string.find(said, "a habit", 1, true), said)
		todos.capture("pay rent every 2 weeks until december", "inbox")
	end)
	local text = greed.fs.read(`{dir}/inbox.md`) or ""
	assert(
		string.find(text, "- [ ] vitamins every:day! remind:08:00 remind:20:00\n", 1, true),
		text
	)
	assert(
		string.find(text, "- [ ] pay rent every:2weeks until:2026-12-31 due:2026-10-14\n", 1, true),
		text
	)
end)

test("ticking a habit says it was done today; the box stays for its next day", function(t)
	local dir = folder(t, { ["a.md"] = "- [ ] stretch every:day! remind:10:30\n" })
	local today = notes.today()
	todos.update("a", 0, { done = true })
	assert(
		(greed.fs.read(`{dir}/a.md`)) == `- [ ] stretch every:day! remind:10:30 done:{today}\n`,
		(greed.fs.read(`{dir}/a.md`))
	)
	local task = (notes.index.note("a") :: notes.Note).nodes[1].task :: any
	t:wait_for(function()
		task = (notes.index.note("a") :: notes.Note).nodes[1].task
		return task ~= nil and task.done_on == today
	end)
	assert(todos.due_on(task, today) == nil, "not due again today")
	assert(todos.due_on(task, dates.add_days(today, 1)) == dates.add_days(today, 1), "due tomorrow")
	greed.open(`{dir}/a.md`)
	t:keys("space n x")
	assert(
		greed.view():buffer():line_text(0) == "- [ ] stretch every:day! remind:10:30",
		"ticked again, it's not done today"
	)
end)

test("a repeating todo stops coming back after its until", function(t)
	local dir = folder(t, {
		["a.md"] = "- [ ] rent every:month due:2026-11-01 until:2026-11-30 remind:09:00\n",
	})
	todos.update("a", 0, { done = true })
	assert(
		(greed.fs.read(`{dir}/a.md`))
			== `- [x] rent every:month due:2026-11-01 until:2026-11-30 remind:09:00 done:{notes.today()}\n`,
		(greed.fs.read(`{dir}/a.md`))
	)
	local again = todos.again("rent every:week due:2026-11-01 remind:09:00 remind:2026-11-01 18:00")
	assert(again == "rent every:week due:2026-11-08 remind:09:00 remind:2026-11-08 18:00", again)
end)

test("a reminder that's a time alone goes off on the line's own days", function()
	local function day(fields: { [string]: any }): string
		local reminder: any = {
			line = 0,
			text = "x",
			time = "10:30",
			todo = false,
			habit = false,
		}
		for k, v in fields do
			reminder[k] = v
		end
		return reminders.day_of(reminder, "2026-10-14") or "-"
	end
	assert(day({}) == "2026-10-14", "a plain line: every day")
	assert(day({ every = "thursday" }) == "-", "not its day")
	assert(day({ every = "wednesday" }) == "2026-10-14", "its day")
	assert(day({ todo = true, due = "2026-10-20" }) == "2026-10-20", "a todo's due date")
	assert(day({ habit = true, every = "day", done_on = "2026-10-14" }) == "-", "done today")
	assert(day({ habit = true, every = "day" }) == "2026-10-14", "not done yet")
	assert(day({ starts = "2026-11-01" }) == "-", "not started")
	assert(day({ ends = "2026-10-01" }) == "-", "over")
end)

test("today's reminders of lines that repeat are found with the others", function(t)
	folder(t, {
		["a.md"] = "- stretch every:day remind:10:30\n- [ ] gym every:day! remind:07:00 done:"
			.. notes.today()
			.. "\n",
	})
	local found = {}
	for _, reminder in reminders.scan() do
		table.insert(found, `{reminder.text} {reminder.date} {reminder.time}`)
	end
	local all = table.concat(found, "; ")
	assert(string.find(all, `stretch {notes.today()} 10:30`, 1, true), all)
	assert(not string.find(all, "gym", 1, true), "a habit done today stays quiet: " .. all)
end)

test("new words for a repeating todo keep how it repeats", function(t)
	local dir =
		folder(t, { ["a.md"] = "- [ ] stretch every:weekday! from:2026-11-01 remind:10:30\n" })
	todos.update("a", 0, { text = "stretch and breathe" })
	local text = greed.fs.read(`{dir}/a.md`)
	assert(text == "- [ ] stretch and breathe remind:10:30 every:weekday! from:2026-11-01\n", text)
end)

test("weeks are counted as ISO 8601 counts them", function()
	local year, week, monday = dates.week("2026-10-18")
	assert(year == 2026 and week == 42 and monday == "2026-10-12", `{year} {week} {monday}`)
	local year2, week2, monday2 = dates.week("2027-01-01")
	assert(year2 == 2026 and week2 == 53 and monday2 == "2026-12-28", `{year2} {week2} {monday2}`)
	local year3, week3 = dates.week("2026-01-01")
	assert(year3 == 2026 and week3 == 1, `{year3} {week3}`)
end)
