-- Notes and todos as objects, for the inspector and agents: a note's file
-- and the notes linking to it, and each todo with its note, its due date
-- and its reminders, opened by default and ticked as an action.

local core = require("@core")
local notes = require("./notes")
local links = require("./links")
local todos = require("./todos")

type Todo = todos.Todo

local function note_object(name: string): core.Object
	return { kind = "note", id = `note:{name}`, label = name, value = name }
end

local function todo_object(todo: Todo): core.Object
	return {
		kind = "todo",
		id = `todo:{todo.note}#{todo.line}`,
		label = todo.text,
		value = todo,
	}
end

core.objects.kind({
	name = "note",
	doc = "A note: a Markdown file in a notes folder, by its name",
	list = function()
		local out = {}
		for _, name in notes.all() do
			table.insert(out, note_object(name))
		end
		return out
	end,
	get = function(key)
		local ok, path = pcall(notes.path, key)
		return if ok and core.file.text(path) then note_object(key) else nil
	end,
	inspect = function(name: string)
		return { name = name, file = notes.path(name) }
	end,
	relations = function(name: string)
		local file = core.objects.get(`file:{notes.path(name)}`)
		local linking = {}
		for _, other in links.backlinks(name) do
			table.insert(linking, note_object(other))
		end
		return { file = if file then { file } else {}, linked_from = linking }
	end,
})

core.objects.kind({
	name = "todo",
	doc = "A todo in a note, by its note and line: open or done, when it's due and reminds you",
	list = function()
		local out = {}
		for _, todo in todos.list() do
			table.insert(out, todo_object(todo))
		end
		return out
	end,
	get = function(key)
		for _, todo in todos.list(true) do
			if `{todo.note}#{todo.line}` == key then
				return todo_object(todo)
			end
		end
		return nil
	end,
	relations = function(todo: Todo)
		return { note = { note_object(todo.note) } }
	end,
})

-- The todo on the cursor's line in a note, to act on with `space .`.
core.actions.finder({
	name = "todo",
	find = function(view, range)
		local buffer = view:buffer()
		local path = buffer:path()
		if path == nil or not notes.is_note(buffer) then
			return nil
		end
		local line = buffer:line_of(range.head)
		local todo = todos.at(notes.name(path), line, buffer:line_text(line))
		return if todo then { core.objects.target(todo_object(todo)) } else nil
	end,
})

core.actions.action({
	kind = "note",
	name = "open",
	doc = "Open it",
	run = function(target)
		core.file.open(notes.path(target.value))
	end,
})
core.actions.set_default("note", "open")

core.actions.action({
	kind = "todo",
	name = "open",
	doc = "Open its note at it",
	run = function(target)
		todos.open_at(target.value.note, target.value.line)
	end,
})
core.actions.set_default("todo", "open")

core.actions.action({
	kind = "todo",
	name = "tick",
	doc = "Mark it done, or not done again",
	run = function(target)
		local todo: Todo = target.value
		local text = notes.read(todo.note) or ""
		local line = string.split(text, "\n")[todo.line + 1] or ""
		local box = if todo.done then "[ ]" else "[x]"
		local ticked = string.gsub(line, "%[[ xX]%]", box, 1)
		notes.set_line(todo.note, todo.line, ticked)
	end,
})

return {}
