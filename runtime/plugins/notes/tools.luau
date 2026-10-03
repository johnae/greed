-- Tools for agents: find, read and write notes, and work with todos. They
-- reach the same files you do, through the editor, so an open note changes
-- in front of you.

local greed = require("@greed")
local agent = require("@agent")
local notes = require("./notes")
local links = require("./links")
local todos = require("./todos")

local function object(properties: { [string]: any }, required: { string }?): { [string]: any }
	return { type = "object", properties = properties, required = required }
end

agent.tool({
	name = "notes_list",
	description = 'The names of every note, like "ideas" or "daily/2026-10-01"',
	run = function()
		return greed.json.array(notes.all())
	end,
})

agent.tool({
	name = "notes_search",
	description = "Search every note for a regex; each match with its note and 1-based line",
	input = object({ pattern = { type = "string" } }, { "pattern" }),
	run = function(args)
		local found, err = greed.fs.grep(args.pattern, notes.folder())
		if found == nil then
			error(err, 0)
		end
		local out = {}
		for _, line in found do
			table.insert(out, {
				note = notes.name(`{notes.folder()}/{line.path}`),
				line = line.line + 1,
				text = line.text,
			})
		end
		return greed.json.array(out)
	end,
})

agent.tool({
	name = "notes_read",
	description = "A note's text, and the notes that link to it",
	input = object({ name = { type = "string" } }, { "name" }),
	run = function(args)
		local text = notes.read(args.name)
		if text == nil then
			error(`there's no note called {args.name}`, 0)
		end
		return { text = text, linked_from = greed.json.array(links.backlinks(args.name)) }
	end,
})

agent.tool({
	name = "notes_write",
	description = "Write a note's whole text, making it if it's new, or with append add lines "
		.. "at its end. Link to other notes with [[name]].",
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
	name = "notes_add_todo",
	description = "Add a todo to a note (the inbox if left out), optionally due on a date (YYYY-MM-DD)",
	input = object({
		text = { type = "string" },
		note = { type = "string" },
		due = { type = "string" },
	}, { "text" }),
	run = function(args)
		todos.add(args.text, args.note, args.due)
		return `added to {args.note or "inbox"}`
	end,
})

return {}
