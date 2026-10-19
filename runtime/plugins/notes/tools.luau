-- Tools for agents: find, read and write notes, and work with todos. They
-- reach the same files you do, through the editor, so an open note changes
-- in front of you.

local greed = require("@greed")
local agent = require("@agent")
agent.group(
	"notes",
	"Your notes and their todos: finding, reading, writing and adding to them, and reminders"
)
local notes = require("./notes")
local links = require("./links")
local todos = require("./todos")
local dates = require("./dates")
local query = require("./query")

local object = agent.schema.object

-- `name`, once it's a note agents may write; an error saying why if not.
local function writable(name: string): string
	notes.check_agent_write(name)
	return name
end

agent.tool({
	name = "notes_list",
	group = "notes",
	description = 'The names of every note, like "ideas" or "daily/2026-10-01". The user\'s own '
		.. 'notes go by their names; the project\'s start with "project:", like "project:plan"',
	run = function()
		return greed.json.array(notes.all())
	end,
})

agent.tool({
	name = "notes_search",
	group = "notes",
	description = "Search every note, the user's and the project's, for a regex; each match "
		.. "with its note and 1-based line",
	input = object({ pattern = { type = "string" } }, { "pattern" }),
	run = function(args)
		local found, err = notes.grep(args.pattern)
		if found == nil then
			error(err, 0)
		end
		local out = {}
		for _, line in found do
			table.insert(out, { note = line.note, line = line.line + 1, text = line.text })
		end
		return greed.json.array(out)
	end,
})

agent.tool({
	name = "notes_read",
	group = "notes",
	description = "A note's text, and the notes that link to it",
	input = object({ name = { type = "string" } }, { "name" }),
	run = function(args)
		local text = notes.read(args.name)
		if text == nil then
			error(`there's no note called {args.name}`, 0)
		end
		return {
			text = text,
			linked_from = greed.json.array(links.backlinks(args.name)),
			-- For the propose tool, to change it with the user's review.
			path = notes.path(args.name),
		}
	end,
})

agent.tool({
	name = "notes_write",
	kind = "edit",
	group = "notes",
	description = "Write a note's whole text, making it if it's new, or with append add lines "
		.. "at its end. A note that's there is changed as a proposal the user reviews; this "
		.. "waits for them. Link to other notes with [[name]]. Notes about the project go in its "
		.. 'notes, named "project:NAME", which live in the repository',
	input = object({
		name = { type = "string" },
		text = { type = "string" },
		append = { type = "boolean" },
	}, { "name", "text" }),
	run = function(args)
		writable(args.name)
		if args.append then
			notes.append(args.name, args.text)
			return `added to {args.name}`
		end
		local path = notes.path(args.name)
		local current = notes.read(args.name)
		if current == nil then
			local ok, err = greed.fs.write(path, args.text)
			if not ok then
				error(err, 0)
			end
			return `wrote {args.name}`
		end
		-- Rewriting what's there is for the user to review.
		local buffer = greed.load(path)
		local changes = greed.diff(buffer:text(), args.text)
		if #changes == 0 then
			return `{args.name} says that already`
		end
		local unsaved = buffer:modified()
		local decided =
			agent.propose_changes(buffer, path, changes, `an agent rewrites {args.name}`)
		if decided.accepted > 0 and not unsaved then
			buffer:save()
		end
		return `the user accepted {decided.accepted} and rejected {decided.rejected} of the changes to {args.name}`
	end,
})

agent.tool({
	name = "notes_query",
	group = "notes",
	description = "Find notes, todos and headings with a query: words, field:value and is: flags, "
		.. "a space meaning and, OR and -term (not), ( ) to group. Fields: title, note, tag, due, "
		.. "done, starts, until, every, date, modified, and the notes' own key:: value fields. "
		.. "Flags: is:note, is:todo, is:heading, is:open, is:done, is:overdue, is:today, "
		.. "is:due-today, is:habit, is:recurring, is:waiting. Dates: due:..+7d (the next week), "
		.. "date:2w.. (the last two weeks), due:today, done:this-week. in:NAME or in:(query) for "
		.. "what's in a note, has:(query) for notes holding something; sort:due, limit:20. "
		.. "Examples: `is:todo is:open due:..+7d sort:due`, `is:note tag:meeting date:2w..`, "
		.. "`is:todo in:(tag:garden) -is:done`. A query with mistakes gives them back, each with "
		.. "a hint",
	input = object({ query = { type = "string" } }, { "query" }),
	run = function(args)
		local found, said = query.run(args.query)
		if found == nil then
			local problems = {}
			for _, problem in said do
				table.insert(problems, problem.message)
			end
			return { problems = greed.json.array(problems) }
		end
		local out = {}
		for i, item in found do
			if i > 200 then
				break
			end
			local node = item.node
			local task = if node then node.task else nil
			table.insert(out, {
				kind = item.kind,
				note = item.note.name,
				line = if node then node.line + 1 else nil,
				text = if task
					then todos.plain(task.text)
					elseif node then node.text
					else item.note.title,
				due = if task then task.due else nil,
				done = if task then task.done else nil,
			})
		end
		return { found = greed.json.array(out), count = #found }
	end,
})

agent.tool({
	name = "notes_todos",
	group = "notes",
	description = "The open todos in every note, soonest due first, or all of them with all",
	input = object({ all = { type = "boolean" } }),
	run = function(args)
		local out = {}
		for _, todo in todos.list(args.all) do
			table.insert(out, {
				note = todo.note,
				line = todo.line + 1,
				text = todo.text,
				done = todo.done,
				due = todo.due,
				reminds = greed.json.array(todo.reminds),
			})
		end
		return greed.json.array(out)
	end,
})

agent.tool({
	name = "notes_add_thought",
	kind = "edit",
	group = "notes",
	description = "Jot a thought or an idea down in a note, as an item with today's date: for "
		.. "things that aren't todos. Left out, the note is the inbox",
	input = object({ text = { type = "string" }, note = { type = "string" } }, { "text" }),
	run = function(args)
		local note = writable(args.note or todos.inbox())
		todos.add_thought(args.text, note)
		return `added to {note}`
	end,
})

-- Reminders as tools take them.
local REMINDS = {
	type = "array",
	items = { type = "string" },
	description = '"YYYY-MM-DD HH:MM" in local time, a date alone for the morning, or "HH:MM" '
		.. "alone for each of the line's days (each day it repeats on, or else every day)",
}

agent.tool({
	name = "notes_add_todo",
	kind = "edit",
	group = "notes",
	description = "Add a todo to a note, optionally due on a date (YYYY-MM-DD) and with "
		.. "reminders, as many as it needs. It can repeat: every is "
		.. '"day", "weekday", "week", "month", "year", weekdays ("monday,thursday") or a '
		.. 'count ("2weeks"); with habit it comes up on each of its days whether or not the '
		.. "last was done, and from and until (YYYY-MM-DD) bound it. Left out, the note is "
		.. "the inbox: the project's (\"project:inbox\") when it keeps notes, otherwise the user's",
	input = object({
		text = { type = "string" },
		note = { type = "string" },
		due = { type = "string" },
		remind = REMINDS,
		every = { type = "string" },
		habit = { type = "boolean" },
		from = { type = "string" },
		["until"] = { type = "string" },
	}, { "text" }),
	run = function(args)
		local note = writable(args.note or todos.inbox())
		local text: string = args.text
		if args.every then
			if not dates.known(args.every) then
				error(
					`{args.every} isn't a repeat: day, weekday, week, month, year, weekdays, 2weeks`,
					0
				)
			end
			text ..= ` every:{args.every}{if args.habit then "!" else ""}`
		end
		for _, marker in { "from", "until" } do
			if args[marker] then
				text ..= ` {marker}:{todos.checked_date(args[marker])}`
			end
		end
		todos.add(
			text,
			note,
			todos.checked_date(args.due),
			todos.checked_reminds(args.remind or {})
		)
		return `added to {note}`
	end,
})

agent.tool({
	name = "notes_remind",
	kind = "edit",
	group = "notes",
	description = "Remind the user at one or more times: on the line of a note given by note "
		.. "and line (1-based, as notes_todos and notes_search give them), added to the "
		.. "reminders it has, or as a new todo with text (in note, or the inbox). The user "
		.. "sees each in the editor and on their desktop",
	input = object({
		when = REMINDS,
		note = { type = "string" },
		line = { type = "number" },
		text = { type = "string" },
	}, { "when" }),
	run = function(args)
		local whens = todos.checked_reminds(args.when)
		if args.line then
			local note = writable(args.note or todos.inbox())
			local current = todos.line(note, args.line - 1)
			local reminds = todos.reminds(current)
			table.move(whens, 1, #whens, #reminds + 1, reminds)
			local changed = todos.with_reminds(current, reminds)
			notes.set_line(note, args.line - 1, changed)
			return `{note}:{args.line}: {changed}`
		elseif args.text then
			local note = writable(args.note or todos.inbox())
			todos.add(args.text, note, nil, whens)
			return `added to {note}`
		end
		error("give note and line for a line that's there, or text for a new todo", 0)
	end,
})

agent.tool({
	name = "notes_update_todo",
	kind = "edit",
	group = "notes",
	description = "Change one todo, given by note and line (1-based, as notes_todos gives "
		.. "them): its text (without its due date and reminders, which stay), its due date "
		.. "(YYYY-MM-DD), its reminders (replacing the ones it has), or tick it with done. "
		.. "An empty due or remind takes them away. Returns the line as it is now",
	input = object({
		note = { type = "string" },
		line = { type = "number" },
		text = { type = "string" },
		due = { type = "string" },
		remind = REMINDS,
		done = { type = "boolean" },
	}, { "note", "line" }),
	run = function(args)
		return todos.update(writable(args.note), args.line - 1, args)
	end,
})

return {}
