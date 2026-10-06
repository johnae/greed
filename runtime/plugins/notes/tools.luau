-- Tools for agents: find, read and write notes, and work with todos. They
-- reach the same files you do, through the editor, so an open note changes
-- in front of you.

local greed = require("@greed")
local agent = require("@agent")
agent.group("notes", "Your notes and their todos: finding, reading, writing and adding to them")
local notes = require("./notes")
local links = require("./links")
local todos = require("./todos")

local function object(properties: { [string]: any }, required: { string }?): { [string]: any }
	return { type = "object", properties = properties, required = required }
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
	group = "notes",
	description = "Write a note's whole text, making it if it's new, or with append add lines "
		.. "at its end. Link to other notes with [[name]]. Notes about the project go in its "
		.. 'notes, named "project:NAME", which live in the repository',
	input = object({
		name = { type = "string" },
		text = { type = "string" },
		append = { type = "boolean" },
	}, { "name", "text" }),
	run = function(args)
		if args.append then
			notes.append(args.name, args.text)
			return `added to {args.name}`
		end
		local buffer = notes.buffer(args.name)
		if buffer then
			buffer:edit(function(e)
				e:replace(0, buffer:len(), args.text)
			end)
			buffer:save()
			return `wrote {args.name}`
		end
		local ok, err = greed.fs.write(notes.path(args.name), args.text)
		if not ok then
			error(err, 0)
		end
		return `wrote {args.name}`
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
			})
		end
		return greed.json.array(out)
	end,
})

agent.tool({
	name = "notes_add_thought",
	group = "notes",
	description = "Jot a thought or an idea down in a note, as an item with today's date: for "
		.. "things that aren't todos. Left out, the note is the inbox",
	input = object({ text = { type = "string" }, note = { type = "string" } }, { "text" }),
	run = function(args)
		local note = args.note or todos.inbox()
		todos.add_thought(args.text, note)
		return `added to {note}`
	end,
})

agent.tool({
	name = "notes_add_todo",
	group = "notes",
	description = "Add a todo to a note, optionally due on a date (YYYY-MM-DD). Left out, the "
		.. 'note is the inbox: the project\'s ("project:inbox") when it keeps notes, otherwise '
		.. "the user's",
	input = object({
		text = { type = "string" },
		note = { type = "string" },
		due = { type = "string" },
	}, { "text" }),
	run = function(args)
		local note = args.note or todos.inbox()
		todos.add(args.text, note, args.due)
		return `added to {note}`
	end,
})

return {}
