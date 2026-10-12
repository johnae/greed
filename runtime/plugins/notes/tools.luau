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

-- `date` if it's a date as notes write them (YYYY-MM-DD); an error if it
-- isn't.
local function checked_date(date: string?): string?
	if date and dates.days(date) == nil then
		error(`{date} isn't a date like 2026-10-06`, 0)
	end
	return date
end

-- `when` as a reminder writes it, "YYYY-MM-DD HH:MM" or a date alone; an
-- error if it isn't one.
local function checked_remind(when: string): string
	local date, time = string.match(when, "^(%d%d%d%d%-%d%d%-%d%d)[ T](%d%d?:%d%d)$")
	if date and time and dates.moment(date, time) then
		return `{date} {time}`
	end
	return checked_date(when) :: string
end

-- Each of `whens` as a reminder writes it; one alone may come as a string.
local function checked_reminds(whens: { string } | string): { string }
	if type(whens) == "string" then
		return { checked_remind(whens) }
	end
	local out = {}
	for _, when in whens do
		table.insert(out, checked_remind(when))
	end
	return out
end

-- Reminders as tools take them.
local REMINDS = {
	type = "array",
	items = { type = "string" },
	description = '"YYYY-MM-DD HH:MM" in local time, or a date alone for the morning',
}

agent.tool({
	name = "notes_add_todo",
	kind = "edit",
	group = "notes",
	description = "Add a todo to a note, optionally due on a date (YYYY-MM-DD) and with "
		.. "reminders, as many as it needs. Left out, the note is the inbox: the project's "
		.. '("project:inbox") when it keeps notes, otherwise the user\'s',
	input = object({
		text = { type = "string" },
		note = { type = "string" },
		due = { type = "string" },
		remind = REMINDS,
	}, { "text" }),
	run = function(args)
		local note = writable(args.note or todos.inbox())
		todos.add(args.text, note, checked_date(args.due), checked_reminds(args.remind or {}))
		return `added to {note}`
	end,
})

-- Line `line` (1-based) of note `name`, which must be there.
local function line_of(name: string, line: number): string
	local text = notes.read(name)
	if text == nil then
		error(`there's no note called {name}`, 0)
	end
	local lines = string.split(text, "\n")
	local found = lines[line]
	if found == nil or line < 1 or (line == #lines and found == "") then
		error(`{name} has no line {line}`, 0)
	end
	return found
end

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
		local whens = checked_reminds(args.when)
		if args.line then
			local note = writable(args.note or todos.inbox())
			local current = line_of(note, args.line)
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
		local current = line_of(writable(args.note), args.line)
		local done, rest = todos.parse(current)
		if done == nil or rest == nil then
			error(`{args.note}:{args.line} isn't a todo: {current}`, 0)
		end
		local text = rest
		if args.text then
			-- The markers it had stay, unless the new text has its own.
			text = args.text
			local due = todos.due(rest)
			if due and todos.due(text) == nil then
				text = todos.with_due(text, due)
			end
			if #todos.reminders(text) == 0 then
				text = todos.with_reminds(text, todos.reminds(rest))
			end
		end
		if args.due then
			local due = if args.due == "" then nil else checked_date(args.due)
			text = todos.with_due(text, due)
		end
		if args.remind then
			local reminds = if args.remind == "" then {} else checked_reminds(args.remind)
			text = todos.with_reminds(text, reminds)
		end
		local ticked = if args.done == nil then done else args.done
		local before = string.match(current, "^%s*[-*+] ") :: string
		local changed = `{before}[{if ticked then "x" else " "}] {text}`
		notes.set_line(args.note, args.line - 1, changed)
		return changed
	end,
})

return {}
