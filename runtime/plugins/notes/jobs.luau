-- Jobs for Greed's agent on your notes: it starts with the notes tools on,
-- shows its transcript, and what it changes in notes you have comes as
-- proposals you review. `:notes-agent` (`space n j`) picks one;
-- `:notes-connect` (`space n l`) is the first:
--
--   connect   link the inbox (or the note you're in) to your other notes,
--             tag it and say what belongs together
--   todos     pull the todos out of the note you're in (a meeting's)
--   ask       answer a question from your notes, linking what it used
--
-- Other plugins add their own (`M.add`): Hoard's weekly summary is one.

local greed = require("@greed")
local core = require("@core")
local acp = require("@acp")
local picker = require("@picker")
local index = require("./index")
local todos = require("./todos")
local reminders = require("./reminders")

local dates = core.dates

greed.option.define({
	name = "notes-agent-schedule",
	doc = "Jobs Greed's agent runs on its own, as JOB DAY HH:MM separated by commas, "
		.. "e.g. `week friday 16:00, connect weekdays 08:00`; DAY is daily, weekdays or a "
		.. "weekday's name. Empty runs none",
	default = "",
	needs = "proc",
})

local M = {}

--- A job: its `name`, what it does (`doc`), and what the agent is told,
--- given the note you're in (nil when you're in none) and the question.
--- A job that `needs` a note or a question doesn't start without one.
--- `worth` says whether there's anything for it to do since it last ran
--- on its schedule (`since`, seconds since 1970; 0 for never), so a
--- scheduled run with nothing new is skipped.
export type Job = {
	name: string,
	doc: string,
	needs: "note" | "question" | nil,
	prompt: (note: string?, question: string?) -> string,
	worth: ((since: number) -> boolean)?,
}

-- How changes are made, said to every job that makes any.
local CHANGES = [=[
Change notes that already exist only with the propose tool, using the path notes_read gives,
so I can review each change; make new notes with notes_write. Don't delete anything.]=]

local jobs: { Job } = {}

--- Adds `job`, in place of one with its name; it goes when the plugin
--- adding it does.
function M.add(job: Job)
	greed.plugin.cleanup(core.registry.put(jobs, job, function(other: Job): boolean
		return other.name == job.name
	end))
end

--- The jobs there are, in the order they were added.
function M.all(): { Job }
	return table.clone(jobs)
end

--- The job named `name`, if there's one.
function M.get(name: string): Job?
	for _, job in jobs do
		if job.name == name then
			return job
		end
	end
	return nil
end

--- Starts Greed's agent on job `name`, for the note at `note` and with
--- `question` as the job needs, and shows its transcript, unless `quiet`
--- (a scheduled run, which only says it started). False and why when it
--- can't.
function M.run(name: string, note: string?, question: string?, quiet: boolean?): (boolean, string?)
	local job = M.get(name)
	if job == nil then
		return false, `there's no notes job {name}`
	elseif job.needs == "note" and note == nil then
		return false, `{name} works on a note: open one first`
	elseif job.needs == "question" and (question == nil or not string.match(question, "%S")) then
		return false, `{name} needs a question`
	end
	local agent = acp.installed("greed")
	if agent == nil then
		return false, "Greed's agent isn't registered"
	end
	local s, err = acp.start(agent, core.project.root())
	if s == nil then
		return false, `can't start Greed's agent: {err}`
	end
	acp.switch_on(s, "notes")
	if quiet then
		greed.echo(`Greed's agent started the {name} job; what it changes waits for your review`)
	else
		acp.show(s)
	end
	-- The transcript shows the question, or what the job does, rather than
	-- the instructions the agent gets.
	return acp.prompt(s, job.prompt(note, question), question or `{name}: {job.doc}`)
end

M.add({
	name = "connect",
	doc = "Link the inbox (or the note you're in) to your other notes, tag it, and add context",
	prompt = function(note)
		local what = if note
			then `the note I have open, {note}`
			else "my inbox note (the project's when it keeps notes)"
		return string.format(
			[=[
Go through %s and connect it with the rest of my notes. For each thought, idea or todo:
find related notes (notes_search, notes_list, notes_read), link them with [[name]], add #tags my
other notes use where they fit, and add a line of context where it helps: what it relates to, why
it matters, what could come next. Where several items belong together, say so, and suggest a note
gathering them.

%s End with a short summary of what you connected and what you'd suggest next.]=],
			what,
			CHANGES
		)
	end,
	worth = function(since)
		local inbox = index.note(todos.inbox())
		return inbox ~= nil and inbox.modified > since
	end,
})

M.add({
	name = "todos",
	doc = "Pull the todos out of the note you're in: what someone said they'd do, as boxes to tick",
	needs = "note",
	prompt = function(note)
		return string.format(
			[=[
Read %s (notes_read) and find what someone said they'd do or what needs doing next: decisions
to act on, promises, follow-ups. Add them to that note under a "## Todos" heading, one `- [ ] `
line each, with who in the words when it's someone else ("Anna: send the budget") and
`due:YYYY-MM-DD` when a date was said. Leave out what's already a todo there.

%s End with the list of todos you proposed.]=],
			note :: string,
			CHANGES
		)
	end,
})

M.add({
	name = "ask",
	doc = "Answer a question from your notes, with links to what the answer used",
	needs = "question",
	prompt = function(_, question)
		return `Answer this from my notes: {question}\n\n`
			.. [=[
Search them (notes_search, notes_query, notes_list) and read what you find (notes_read). Answer
briefly, and after each thing you say link where it came from: [[note#Heading]] for a section,
[[note]] for a whole note. Say so when my notes don't hold the answer, rather than guessing.
Don't change any notes.]=]
	end,
})

--- A job on the schedule: run on `day` ("daily", "weekdays" or a
--- weekday's name) at `time` ("16:00").
export type Scheduled = { job: string, day: string, time: string }

local DAYS = { "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday" }

--- The schedule `text` says (`notes-agent-schedule`), and what's wrong
--- with the parts that can't be read.
function M.schedule(text: string): ({ Scheduled }, { string })
	local out: { Scheduled } = {}
	local wrong: { string } = {}
	for _, part in string.split(text, ",") do
		local trimmed = core.text.trim(part)
		if trimmed == "" then
			continue
		end
		local job, day, hour, minute = string.match(trimmed, "^(%S+)%s+(%a+)%s+(%d%d?):(%d%d)$")
		local found = if job then M.get(job) else nil
		day = if day then string.lower(day) else nil
		if job == nil or day == nil or hour == nil or minute == nil then
			table.insert(wrong, `{trimmed}: write it as JOB DAY HH:MM`)
		elseif found == nil then
			table.insert(wrong, `{trimmed}: there's no notes job {job}`)
		elseif found.needs then
			table.insert(
				wrong,
				`{trimmed}: {job} needs a {found.needs}, so it can't run on its own`
			)
		elseif day ~= "daily" and day ~= "weekdays" and not table.find(DAYS, day) then
			table.insert(wrong, `{trimmed}: the day is daily, weekdays or a weekday's name`)
		else
			local entry: Scheduled = {
				job = job,
				day = day :: string,
				time = string.format("%02d:%s", tonumber(hour) :: number, minute),
			}
			table.insert(out, entry)
		end
	end
	return out, wrong
end

-- When each scheduled job last ran, by job: the run it was (`date time`)
-- and when, in Greed's cache, read again each time as reminders' are.
type Ran = { [string]: { slot: string, at: number } }

local function ran_file(): string?
	local cache = greed.fs.dirs().cache
	return if cache then `{cache}/notes-jobs.json` else nil
end

local function load_ran(): Ran
	local file = ran_file()
	local text = if file then greed.fs.read(file) else nil
	local ok, value = pcall(greed.json.decode, text or "")
	return if ok and type(value) == "table" then value else {}
end

--- The scheduled runs due now, at `today` (a date) and `now` ("HH:MM"),
--- that haven't run yet as `ran` says: each job's run of today once its
--- time has come, so a run missed while Greed was closed happens when it
--- starts again that day.
function M.due(schedule: { Scheduled }, ran: Ran, today: string, now: string): { Scheduled }
	local weekday = dates.weekday(today)
	local out: { Scheduled } = {}
	for _, entry in schedule do
		local today_too = entry.day == "daily"
			or entry.day == DAYS[weekday]
			or (entry.day == "weekdays" and weekday <= 5)
		local last = ran[entry.job]
		if
			today_too
			and entry.time <= now
			and (last == nil or last.slot < `{today} {entry.time}`)
		then
			table.insert(out, entry)
		end
	end
	return out
end

--- Runs the scheduled jobs that are due, in the one session that does what
--- should happen once (see reminders), skipping those with nothing new to
--- work on. Returns the names of those started.
function M.tick(): { string }
	local text = greed.option.get("notes-agent-schedule") :: string
	if text == "" or not reminders.yours_here() then
		return {}
	end
	local clock = dates.clock()
	local today, now = dates.today(), os.date("%H:%M", clock) :: string
	local ran = load_ran()
	local started: { string } = {}
	local due = M.due(M.schedule(text), ran, today, now)
	for _, entry in due do
		local job = M.get(entry.job) :: Job
		local last = ran[entry.job]
		-- Marked first, so a run that fails isn't tried again each minute.
		ran[entry.job] = { slot = `{today} {entry.time}`, at = clock }
		if job.worth == nil or job.worth(if last then last.at else 0) then
			local ok, why = M.run(entry.job, nil, nil, true)
			if ok then
				table.insert(started, entry.job)
			else
				greed.echo(`notes-agent-schedule: {entry.job}: {why}`)
			end
		end
	end
	local file = ran_file()
	if file and #due > 0 then
		greed.fs.write(file, greed.json.encode(ran))
	end
	return started
end

-- Once a minute, on the minute, as reminders go off.
greed.spawn(function()
	while true do
		greed.sleep((60 - dates.clock() % 60) * 1000)
		local ok, err = pcall(M.tick)
		if not ok then
			greed.echo(`notes-agent-schedule: {err}`)
		end
	end
end)

-- A schedule that can't be read says so as it's set: a moment later, so
-- the plugins adding jobs (Hoard's week) have loaded when it's in a config.
greed.on("option.changed", function(event)
	if event.name == "notes-agent-schedule" then
		greed.spawn(function()
			greed.sleep(1000)
			local _, wrong = M.schedule(greed.option.get("notes-agent-schedule") :: string)
			if #wrong > 0 then
				greed.echo(`notes-agent-schedule: {table.concat(wrong, "; ")}`)
			end
		end)
	end
end)

-- The note at the cursor's buffer's path, when it's Markdown.
local function note_of(buffer: greed.Buffer): string?
	local path = buffer:path()
	return if path and string.match(path, "%.md$") then path else nil
end

-- Runs `name` from a command, saying why when it can't.
local function run_here(name: string, note: string?, question: string?)
	local ok, err = M.run(name, note, question)
	if not ok then
		greed.echo(err :: string)
	end
end

greed.command({
	name = "notes-agent",
	doc = "Pick a job for Greed's agent on your notes: connect them, pull out todos, ask them",
	run = function(ctx)
		local note = note_of(ctx.buffer)
		local items: { picker.Item } = {}
		for _, job in jobs do
			table.insert(items, { label = job.name, detail = job.doc, value = job })
		end
		picker.pick("Have the agent", items, function(item)
			local job = item.value :: Job
			if job.needs ~= "question" then
				run_here(job.name, note)
				return
			end
			greed.spawn(function()
				local question = core.prompt.ask("Ask your notes")
				if question then
					run_here(job.name, note, question)
				end
			end)
		end)
	end,
})

greed.command({
	name = "notes-connect",
	doc = "Have Greed's agent go through the inbox (or the note you're in), link it to your other notes and add context, as changes you review",
	run = function(ctx)
		run_here("connect", note_of(ctx.buffer))
	end,
})

greed.command({
	name = "notes-ask",
	doc = "Ask your notes a question: Greed's agent answers from them, linking what it used",
	args = { { name = "question", doc = "What to ask", type = "rest" } },
	run = function(ctx)
		run_here("ask", nil, ctx.values.question)
	end,
})

return M
