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

local M = {}

--- A job: its `name`, what it does (`doc`), and what the agent is told,
--- given the note you're in (nil when you're in none) and the question.
--- A job that `needs` a note or a question doesn't start without one.
export type Job = {
	name: string,
	doc: string,
	needs: "note" | "question" | nil,
	prompt: (note: string?, question: string?) -> string,
}

-- How changes are made, said to every job that makes any.
local CHANGES = [=[
Change notes that already exist only with the propose tool, using the path notes_read gives,
so I can review each change; make new notes with notes_write. Don't delete anything.]=]

local jobs: { Job } = {}

--- Adds `job`, in place of one with its name; it goes when the plugin
--- adding it does.
function M.add(job: Job)
	greed.plugin.tie(core.registry.put(jobs, job, function(other: Job): boolean
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
--- `question` as the job needs, and shows its transcript. False and why
--- when it can't.
function M.run(name: string, note: string?, question: string?): (boolean, string?)
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
	acp.show(s)
	return acp.prompt(s, job.prompt(note, question))
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
